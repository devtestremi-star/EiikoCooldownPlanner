-- EiikoCooldownPlanner - Core/ProfileShare.lua
-- CODEC de PROFIL d'affichage : encode / decode / valide / importe un profil complet
-- (options + positions de fenetres + reglages de sorts de boss) sous forme de chaine
-- copiable. Aucun transport ici : l'echange se fait au copier/coller, depuis les boutons
-- Export / Import de l'onglet Profiles (UI/ProfileShare.lua).
--
-- CANAL SEPARE de l'import de donjon/variante (UI.ImportVariantString). Un profil ne
-- decrit AUCUN plan et les deux stores n'ont rien en commun : melanger les deux entrees
-- ne rendrait service a personne. Chaque cote RECONNAIT le format de l'autre, uniquement
-- pour le refuser avec un message juste -- jamais pour l'avaler.
--
-- Le PIPELINE d'encodage n'est PAS redefini ici : on reutilise Share.EncodeRaw /
-- Share.DecodeRaw (CBOR -> Deflate -> Base64). C'est LE pipeline de l'addon et il ne doit
-- exister qu'une fois (cf. l'en-tete de Core/Share.lua) ; le PAYLOAD, lui, est a nous.
--
-- REGLE : l'import ne MODIFIE JAMAIS un profil existant. Il en CREE un nouveau (nom
-- desambiguise au besoin) puis bascule dessus. Aucun reglage deja pose par le joueur
-- n'est ecrase, et le profil importe se supprime d'un clic s'il ne plait pas.
local addonName, HR = ...

HR.ProfileShare = HR.ProfileShare or {}
local PS = HR.ProfileShare

-- Version du payload PROFIL. Independante du PROTO de variante (Core/Share.lua) et du
-- protocole de transport de la synchro (Core/Sync/Net.lua) : trois choses differentes.
local PROTO = 1

--------------------------------------------------------------------------------
-- Bornes. Le payload vient d'un copier/coller : c'est une entree NON FIABLE, au meme
-- titre qu'un message reseau. On ne se protege pas d'un plantage (le pcall du pipeline
-- s'en charge) mais d'une ECRITURE ABERRANTE en SavedVariables -- le seul dommage qui
-- survit au /reload.
--------------------------------------------------------------------------------

local MAX_OPTION_KEYS  = 200      -- garde-fou de volume, tres au-dessus du besoin reel (~60)
local MAX_STRING_LEN   = 64       -- toute valeur texte d'option
local MAX_NAME_LEN     = 32       -- nom du profil
local MAX_SPELL_NAME   = 40       -- nom custom d'un sort de boss (aligne sur l'UI)
local MAX_ENCOUNTERS   = 200      -- nb d'encounterID portant des reglages
local MAX_SPELLS_TOTAL = 2000     -- nb total d'enregistrements bossSpells
local MAX_DEPTH        = 4        -- options > glow > glowPixel > scalaire
local NUM_LIMIT        = 100000   -- borne absolue de toute valeur numerique

-- Points d'ancrage acceptes pour une position de fenetre. Un point inconnu ferait lever
-- SetPoint a CHAQUE restauration -- donc a chaque login, sans moyen evident de s'en sortir.
local VALID_POINTS = {
    TOPLEFT = true, TOP = true, TOPRIGHT = true,
    LEFT = true, CENTER = true, RIGHT = true,
    BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

-- Fenetres HUD connues (cf. HR.db.ui). Liste FERMEE : une cle inconnue n'a aucun cadre
-- a repositionner, elle ne ferait qu'occuper la DB.
local UI_KEYS = { config = true, runtime = true, comm = true,
                  timeline = true, progress = true, announce = true }

-- Contraintes EXPLICITES, uniquement pour les valeurs dont une saisie libre pourrait
-- faire lever une API du client. Le reste passe par le controle de type generique :
-- une option absente de cette table n'est pas perdue pour autant (cf. SanitizeOptions).
local ENUMS = {
    alertChannel = { Master = true, SFX = true, Music = true, Ambience = true, Dialog = true },
    glowType     = { pixel = true, autocast = true, button = true, proc = true },
    progressGrow = { down = true, up = true },
    commLayout   = { horizontal = true, vertical = true },
}

--------------------------------------------------------------------------------
-- Assainissement
--------------------------------------------------------------------------------

-- Nombre FINI borne. Rejette NaN et les infinis : ils traversent les comparaisons sans
-- erreur et ressortent en coordonnees de cadre ou en tailles de police.
local function Num(v, lo, hi)
    v = tonumber(v)
    if not v or v ~= v then return nil end                       -- NaN (seule valeur ~= a elle-meme)
    if v == math.huge or v == -math.huge then return nil end
    return math.max(lo or -NUM_LIMIT, math.min(hi or NUM_LIMIT, v))
end

-- Chaine bornee, DEBARRASSEE de toute balise (le tube ouvre `|cff`, `|H`, `|T`...).
--
-- On RETIRE au lieu d'ECHAPPER, alors que HR.EscapeMarkup existe : echapper produit une
-- valeur DIFFERENTE de l'entree, et cette valeur est STOCKEE puis re-exportee -- un aller-
-- retour doublerait les tubes a chaque passage. L'echappement est une affaire d'AFFICHAGE ;
-- ici on assainit une donnee, et le retrait est la seule operation idempotente.
local function Str(v, maxLen)
    if type(v) ~= "string" then return nil end
    v = strtrim((v:gsub("|", "")))
    if v == "" then return nil end
    return v:sub(1, maxLen or MAX_STRING_LEN)
end

-- Couleur { r, g, b, a } bornee a 0..1. Alpha optionnel (defaut 1), comme partout ailleurs.
local function Color(v)
    if type(v) ~= "table" then return nil end
    local r, g, b = Num(v[1], 0, 1), Num(v[2], 0, 1), Num(v[3], 0, 1)
    if not (r and g and b) then return nil end
    return { r, g, b, Num(v[4], 0, 1) or 1 }
end

-- Valeur d'option, controlee PAR TYPE et non par liste blanche de cles.
--
-- POURQUOI PAS UNE LISTE BLANCHE : les options ne vivent pas toutes dans
-- HR.DB_DEFAULTS.options -- `commColumns` en est volontairement absent (il est infere
-- depuis l'ancien `commLayout`), et toute la famille `alert*` est creee a la volee par
-- l'onglet General. Une liste blanche batie sur les defauts perdrait silencieusement une
-- douzaine de reglages a l'export, et en perdrait un de plus a chaque option ajoutee, sans
-- que rien ne le signale. Une cle inconnue est de toute facon INERTE : le code ne lit que
-- les cles qu'il connait, et l'addon tolere deja des cles orphelines (les restes du V1).
-- Ce qu'on controle, c'est donc la FORME de la valeur -- la seule chose qui puisse nuire.
local function Value(key, v, depth)
    depth = depth or 1
    local t = type(v)
    if t == "boolean" then return v end
    if t == "number"  then return Num(v) end
    if t == "string" then
        local e = ENUMS[key]
        if e then return e[v] and v or nil end                   -- hors enum => on laisse le defaut jouer
        return Str(v)
    end
    if t == "table" and depth < MAX_DEPTH then
        if type(key) == "string" and key:match("Color$") then return Color(v) end
        local out, n = nil, 0
        for k, sub in pairs(v) do
            if (type(k) == "string" or type(k) == "number") and n < MAX_OPTION_KEYS then
                local sv = Value(k, sub, depth + 1)
                if sv ~= nil then out = out or {}; out[k] = sv; n = n + 1 end
            end
        end
        return out
    end
    return nil
end

function PS.SanitizeOptions(src)
    local out = {}
    if type(src) ~= "table" then return out end
    local n = 0
    for k, v in pairs(src) do
        if type(k) == "string" and n < MAX_OPTION_KEYS then
            local sv = Value(k, v, 1)
            if sv ~= nil then out[k] = sv; n = n + 1 end
        end
    end
    return out
end

-- Positions de fenetres. Forme imposee : { point, relPoint, x, y } (cf. HR.SaveFramePos*).
function PS.SanitizeUI(src)
    local out = {}
    if type(src) ~= "table" then return out end
    for key, p in pairs(src) do
        if UI_KEYS[key] and type(p) == "table" and VALID_POINTS[p.point] then
            out[key] = {
                point    = p.point,
                relPoint = VALID_POINTS[p.relPoint] and p.relPoint or p.point,
                x        = Num(p.x) or 0,
                y        = Num(p.y) or 0,
            }
        end
    end
    return out
end

-- Reglages de sorts de boss. Les encounterID INCONNUS sont CONSERVES (bornes en nombre) :
-- HR.content est choisi par version de client (HR.contentByVersion), donc un id absent ici
-- peut etre parfaitement valide chez l'emetteur -- et le redeviendra au prochain patch. Un
-- id qui ne correspond a rien n'est jamais lu : il dort, il ne casse rien.
function PS.SanitizeBossSpells(src)
    local out = {}
    if type(src) ~= "table" then return out end
    local encCount, total = 0, 0
    for encID, spells in pairs(src) do
        encID = tonumber(encID)
        if encID and type(spells) == "table" and encCount < MAX_ENCOUNTERS then
            local encOut
            for spellID, rec in pairs(spells) do
                spellID = tonumber(spellID)
                if spellID and type(rec) == "table" and total < MAX_SPELLS_TOTAL then
                    local r = {}
                    if type(rec.enabled)   == "boolean" then r.enabled   = rec.enabled end
                    if type(rec.playSound) == "boolean" then r.playSound = rec.playSound end
                    r.name     = Str(rec.name, MAX_SPELL_NAME)
                    r.sound    = Num(rec.sound, 0, NUM_LIMIT)
                    r.barColor = Color(rec.barColor)
                    if next(r) then
                        encOut = encOut or {}
                        encOut[spellID] = r
                        total = total + 1
                    end
                end
            end
            if encOut then out[encID] = encOut; encCount = encCount + 1 end
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- Payload
--------------------------------------------------------------------------------

-- Payload d'un profil du store (nil si le profil n'existe pas). On assainit DES L'EXPORT :
-- une DB peut deja contenir une valeur aberrante (vieille version, edition manuelle), et
-- il n'y a aucune raison de la propager.
function PS.BuildPayload(profileName)
    local prof = HR.db and HR.db.profiles and HR.db.profiles[profileName]
    if not prof then return nil end
    return {
        v    = PROTO,
        kind = "profile",
        name = Str(profileName, MAX_NAME_LEN) or "Profile",
        opt  = PS.SanitizeOptions(prof.options),
        ui   = PS.SanitizeUI(prof.ui),
        bs   = PS.SanitizeBossSpells(prof.bossSpells),
    }
end

-- Chaine copiable d'un profil. nil si le profil est introuvable ou l'encodage indisponible.
function PS.Encode(profileName)
    local payload = PS.BuildPayload(profileName)
    if not payload then return nil end
    return (HR.Share and HR.Share.EncodeRaw) and HR.Share.EncodeRaw(payload) or nil
end

-- Forme minimale attendue. Le CONTENU, lui, est filtre a l'import : aucune valeur n'est
-- "invalide" au point de faire echouer tout l'import -- une valeur douteuse tombe seule,
-- le reste passe.
function PS.Validate(p)
    if type(p) ~= "table" then return false end
    if p.kind ~= "profile" then return false end
    if type(p.v) ~= "number" or p.v > PROTO then return false end
    if p.opt ~= nil and type(p.opt) ~= "table" then return false end
    if p.ui  ~= nil and type(p.ui)  ~= "table" then return false end
    if p.bs  ~= nil and type(p.bs)  ~= "table" then return false end
    return true
end

-- Chaine -> payload de profil. Renvoie (nil, raison) en cas d'echec, la raison etant
-- destinee au joueur : distinguer "ce n'est pas un profil" de "c'est illisible" evite le
-- message faux qui envoie chercher le probleme au mauvais endroit.
function PS.Decode(str)
    if not (HR.Share and HR.Share.DecodeRaw) then return nil, "unavailable" end
    local payload, err = HR.Share.DecodeRaw(str)
    if err == "too_large" then return nil, "too_large" end
    if type(payload) ~= "table" then return nil, "corrupt" end
    if payload.kind ~= "profile" then return nil, "not_a_profile" end
    if not PS.Validate(payload) then return nil, "corrupt" end
    return payload
end

-- Ce que l'import va poser, pour le dire au joueur plutot que de le laisser chercher la
-- difference. Compte le payload TEL QU'IL SERA ecrit (il a deja ete assaini a l'export).
function PS.Describe(p)
    local nOpt, nUI, nSpell = 0, 0, 0
    for _ in pairs((p and p.opt) or {}) do nOpt = nOpt + 1 end
    for _ in pairs((p and p.ui)  or {}) do nUI  = nUI  + 1 end
    for _, spells in pairs((p and p.bs) or {}) do
        for _ in pairs(spells) do nSpell = nSpell + 1 end
    end
    return nOpt, nUI, nSpell
end

--------------------------------------------------------------------------------
-- Import
--------------------------------------------------------------------------------

-- Nom LIBRE derive de `base` : "Setup", puis "Setup (2)", "Setup (3)"... On ne remplace
-- jamais un profil existant, il faut donc bien poser le nouveau quelque part.
function PS.UniqueName(base)
    base = Str(base, MAX_NAME_LEN) or "Imported profile"
    local profiles = (HR.db and HR.db.profiles) or {}
    if not profiles[base] then return base end
    for i = 2, 99 do
        local candidate = ("%s (%d)"):format(base, i)
        if not profiles[candidate] then return candidate end
    end
    return nil
end

-- Cree un profil depuis un payload valide et bascule dessus. Renvoie (nom, nOpt, nUI,
-- nSpell) ou nil. Rien d'existant n'est touche : le seul effet sur la DB est l'ajout d'une
-- entree dans HR.db.profiles, plus le pointeur de profil actif du personnage.
function PS.Import(payload)
    if not PS.Validate(payload) then return nil end
    local name = PS.UniqueName(payload.name)
    if not name then return nil end
    if not HR.CreateProfile(name) then return nil end            -- refuse un nom vide / deja pris

    local prof = HR.db.profiles[name]
    prof.options    = PS.SanitizeOptions(payload.opt)
    prof.ui         = PS.SanitizeUI(payload.ui)
    prof.bossSpells = PS.SanitizeBossSpells(payload.bs)

    local nOpt, nUI, nSpell = PS.Describe(payload)
    HR.SwitchProfile(name)                                       -- ReloadUI si on est en combat
    return name, nOpt, nUI, nSpell
end
