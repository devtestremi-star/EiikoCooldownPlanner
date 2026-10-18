-- EiikoCooldownPlanner - Core/Share.lua
-- CODEC de plan : serialisation, validation et import d'une variante. Aucun transport
-- ici -- le partage par lien (diffusion PROTO 2 + hyperlien |Hhealplanner:|h + apercu)
-- a ete RETIRE au profit du canal de synchro (bouton Sync, cf. Core/Sync/). Ce fichier
-- ne garde que ce qui sert encore, a deux consommateurs :
--   * Core/Sync/PlanSync.lua  -- encode la poussee, valide et importe la reception ;
--   * UI/HealerSpecs.lua      -- modales Export / Import (chaine copiable).
--
-- Payload minimal : la data statique (defID, encounterID, occKey) est commune aux
-- deux joueurs (meme addon), on ne transmet que { dID, name, healer, assignments... }.
-- Encodage natif 12.0 (zero lib externe) : SerializeCBOR -> CompressString(Deflate)
-- -> EncodeBase64. Tout est garde sous pcall (entrees reseau = non fiables).
local addonName, HR = ...

HR.Share = HR.Share or {}
local Share = HR.Share

local PROTO = 2   -- version du format de PAYLOAD (2 = variante V2). Sans rapport avec le
                  -- protocole de transport de la synchro (Core/Sync/Net.lua, PROTO 1).

-- Enums d'encodage (12.0). Locales : si absents, on passe nil (valeurs par defaut)
-- de facon coherente entre encodage et decodage.
local DEFLATE = (Enum and Enum.CompressionMethod and Enum.CompressionMethod.Deflate) or nil
local B64     = (Enum and Enum.Base64Variant and Enum.Base64Variant.StandardUrlSafe) or nil

--------------------------------------------------------------------------------
-- Encodage / decodage
--------------------------------------------------------------------------------

-- table -> chaine ASCII transportable. nil en cas d'echec.
--
-- PUBLIQUE et GENERIQUE a dessein : c'est LE pipeline de transport de l'addon, et il ne
-- doit exister qu'une fois. L'addon compagnon « ECP Packager » definit son propre payload
-- (un conteneur de packs) mais le fait voyager PAR ICI -- sinon deux implementations
-- devraient s'accorder sans que rien ne le verifie, et le jour ou l'une change d'enum,
-- l'autre reçoit « chaine corrompue » sur une chaine parfaitement valide.
-- Le PIPELINE est a nous ; le PAYLOAD est a celui qui le definit.
function Share.EncodeRaw(value)
    if not C_EncodingUtil then return nil end
    local ok, cbor = pcall(C_EncodingUtil.SerializeCBOR, value)
    if not ok or type(cbor) ~= "string" then return nil end
    local ok2, comp = pcall(C_EncodingUtil.CompressString, cbor, DEFLATE)
    if not ok2 or type(comp) ~= "string" then return nil end
    local ok3, b64 = pcall(C_EncodingUtil.EncodeBase64, comp, B64)
    if not ok3 or type(b64) ~= "string" then return nil end
    return b64
end

-- Chaine d'export partageable d'une variante (MEME encodage que le Share : CBOR -> Deflate ->
-- Base64). Sert a l'export hors-groupe (copier/coller) ET a la poussee Sync. nil si echec.
-- ⚠️ `opts` DECIDE DU CANAL (transmis tel quel a BuildPayload) : SANS `opts.full`, c'est le mode
-- SYNC (defaut, le plus restrictif) -> sorts `noSync` retires, sorts custom non partages omis.
-- Un EXPORT (chaine a copier, passee a un healer de la meme spe) DOIT passer `{ full = true }`,
-- sinon il perd ces sorts sans le moindre avertissement (decision du 2026-10-16).
-- `Share.BuildPayload` est definie plus bas -> resolue a l'appel (runtime), pas a la definition.
function Share.EncodeVariant(dungeonID, variant, opts)
    local payload = Share.BuildPayload(dungeonID, variant, opts)
    if not payload then return nil end
    return Share.EncodeRaw(payload)
end

-- chaine ASCII -> table. nil en cas d'echec (entree corrompue / malveillante).
-- Publique pour la meme raison que Share.EncodeRaw : un seul pipeline, un seul endroit
-- ou vivent les choix d'enum. Le decodeur des chaines de catalogue passe par ici.
-- Plafond de la charge DECOMPRESSEE. Une chaine courte peut se decompresser en quelque
-- chose d'enorme ; les controles de structure n'agissent qu'apres la deserialisation,
-- donc trop tard. C'est ICI, entre la decompression et le CBOR, le seul endroit ou la
-- taille reelle est mesurable.
--   Repere : un conteneur de ~32 variantes pese ~70 Ko decompresses. 512 Ko laisse un
--   facteur 7 -- assez large pour ne jamais gener, assez serre pour couper l'absurde.
--   Limite honnete : le pic memoire de la decompression a deja eu lieu quand on teste.
--   On empeche la deserialisation et l'ecriture en SavedVariables -- le dommage durable --
--   pas l'allocation. L'API ne rend la chaine que d'un bloc.
local MAX_DECOMPRESSED = 512 * 1024

function Share.DecodeRaw(str)
    if not C_EncodingUtil or type(str) ~= "string" then return nil end
    local ok, comp = pcall(C_EncodingUtil.DecodeBase64, str, B64)
    if not ok or type(comp) ~= "string" then return nil end
    local ok2, cbor = pcall(C_EncodingUtil.DecompressString, comp, DEFLATE)
    if not ok2 or type(cbor) ~= "string" then return nil end
    if #cbor > MAX_DECOMPRESSED then return nil, "too_large" end
    local ok3, value = pcall(C_EncodingUtil.DeserializeCBOR, cbor)
    if not ok3 then return nil end
    return value
end

-- Chaine d'import (copier/coller) -> payload VALIDE de variante. nil si echec (chaine
-- corrompue / forme invalide / donjon inconnu). Pendant de Share.EncodeVariant.
function Share.DecodeVariant(str)
    local payload = Share.DecodeRaw(str)
    if not Share.ValidatePayload(payload) then return nil end
    return payload
end

--------------------------------------------------------------------------------
-- Payload + validation
--------------------------------------------------------------------------------

-- Donjon connu de HR.content ? (id de donjon)
local function IsKnownDungeon(dID)
    for _, d in ipairs(HR.content) do
        if d.id == dID then return true end
    end
    return false
end

-- Un token de defensif est-il flagge `noSync` ? Le flag vit sur l'entree HR.defensives,
-- jamais sur le plan. Deux familles le portent : les sorts de GESTION du healer (courts, tres
-- repetes, sans interet pour le groupe) et les sorts CUSTOM du joueur (Core/CustomSpells.lua),
-- qui n'existent que dans SA bibliotheque.
--
-- REGLE : un sort `noSync` ne part pas au SYNC (le groupe n'en a pas besoin). L'EXPORT, lui,
-- emporte tout : il sert a passer un plan a un healer de la meme spe (decision du 2026-10-16,
-- qui annule celle du 2026-10-15 ou l'export filtrait aussi). Un sort custom part toujours sous
-- un token de fil, jamais sous sa cle `U:<n>` (compteur LOCAL) -- cf. OutgoingAssignments.
local function isNoSync(token)
    local d = HR.defensives[HR.DefKeyOf(token)]
    return d and d.noSync == true
end

-- Recopie filtree d'assignments. `fn(token)` renvoie le token a garder (le meme, ou un token
-- REECRIT) ou nil pour retirer l'entree. NOUVELLE table a chaque niveau (encounter, occurrence,
-- liste) : la source -- `variant.assignments` cote emetteur -- n'est JAMAIS touchee (regle
-- absolue sur les donnees sauvegardees). Une entree gardee telle quelle est recopiee TELLE QUELLE
-- (pas de normalisation : c'est le role de SanitizeAssignments, qui passe derriere) ; une entree
-- reecrite devient { token, [offset] }. Une occurrence ou un boss vide n'est pas ecrit.
-- Renvoie la copie et le nombre d'entrees retirees.
local function filterAssignments(asg, fn)
    local out, dropped = {}, 0
    if type(asg) ~= "table" then return out, 0 end
    for encID, occs in pairs(asg) do
        if type(occs) == "table" then
            local encOut
            for occKey, defs in pairs(occs) do
                if type(defs) == "table" then
                    local list = {}
                    for _, e in ipairs(defs) do
                        local t = HR.EntryToken(e)
                        local keep = fn(t)
                        if keep == nil then
                            dropped = dropped + 1
                        elseif keep == t then
                            list[#list + 1] = e
                        else
                            local off = HR.EntryOffset(e)
                            list[#list + 1] = (off ~= 0) and { token = keep, offset = off } or { token = keep }
                        end
                    end
                    if #list > 0 then encOut = encOut or {}; encOut[occKey] = list end
                end
            end
            if encOut then out[encID] = encOut end
        end
    end
    return out, dropped
end

-- DEUX CANAUX, DEUX REGLES (decision du 2026-10-16) :
--   * SYNC  (`full` absent) : informe le GROUPE -> les `noSync` restent chez le joueur.
--   * EXPORT (`full = true`) : transmet le plan a un autre healer de la MEME spe -> TOUT part,
--     sorts de gestion et sorts custom non partages compris. Export de variante, export d'un
--     boss, et donc catalogue (fait d'exports de createurs).

-- EMISSION. Un sort CUSTOM part sous son token de fil (`C:` partage / `N:` non partage, ce
-- dernier a l'export seulement) -- sa cle `U:<n>` ne voyage jamais (Core/CustomSpells.lua).
-- Au Sync, tout autre token `noSync` est retire (un `N:` recu compris).
function Share.OutgoingAssignments(asg, full)
    local CS = HR.CustomSpells
    return filterAssignments(asg, function(t)
        local key = HR.DefKeyOf(t)
        if CS and CS.IsCustomKey(key) then return CS.WireToken(key, full) end
        if not full and isNoSync(t) then return nil end
        return t
    end)
end

-- RECEPTION, juste apres le decodage : PlanSync (Sync), import natif UI.ImportVariantString et
-- catalogue `sanitizeEntry` (`full`). Toujours retires : toute cle de bibliotheque `U:<n>` (celle
-- d'un autre joueur tomberait sur une des NOTRES) et un token de fil illisible ou d'un autre
-- profil de heal que le plan (`healer`). Au Sync seulement : les `noSync` (`N:` compris) --
-- un emetteur en version anterieure ne les filtrait pas.
function Share.IncomingAssignments(asg, healer, full)
    local CS = HR.CustomSpells
    return filterAssignments(asg, function(t)
        local key = HR.DefKeyOf(t)
        if CS and CS.IsCustomKey(key) then return nil end
        if CS and CS.IsWireKey(key) and CS.ParseWire(key) ~= healer then return nil end
        if not full and isNoSync(t) then return nil end
        return t
    end)
end

-- Construit le payload partageable d'une variante (format V2 : healer + externals + plan).
-- NB : pour les boss multi-timelines (ex. L'ura), les plans des DEUX variantes sont DEJA
-- dans `asg` (cles d'occurrence prefixees par la variante). On ajoute `tlv` = la variante
-- JOUEE choisie par l'emetteur, par boss, pour la transmettre aussi.
-- `asg` est TOUJOURS une COPIE passee par OutgoingAssignments. `opts.full` = EXPORT (tout part) ;
-- sans lui = SYNC (les `noSync` restent). Le defaut est le canal le plus restrictif.
function Share.BuildPayload(dungeonID, variant, opts)
    if not dungeonID or not variant then return nil end
    local asg = Share.OutgoingAssignments(variant.assignments, opts and opts.full)
    local tlv
    for _, d in ipairs(HR.content) do
        if d.id == dungeonID then
            for _, b in ipairs(d.bosses) do
                if HR.GetTimelineVariants(b) then
                    tlv = tlv or {}
                    tlv[b.id] = HR.GetActiveTimelineVariantId(b)
                end
            end
        end
    end
    return {
        v      = PROTO,
        kind   = "variant",
        dID    = dungeonID,
        name   = variant.name,
        healer = variant.healer,            -- profil de heal (jeton, ex. "MONK"/"PRIEST_HOLY")
        ext    = variant.externals,         -- { [defKey] = count } (externals de groupe)
        tsp    = variant.talentSpells,      -- { [spellID] = cle_de_variante_de_CD }
        asg    = asg,                       -- [encounterID][occKey] = { {token,offset}, ... }
        tlv    = tlv,                        -- [encounterID] = variante de timeline JOUEE
        phl    = variant.phaseLengths,      -- [encounterID][k] = longueur de phase (s), additif
        boff   = variant.bossOff,           -- [encounterID] = true : boss sans annonce, additif
    }
end

-- Payload d'UN SEUL BOSS (memo §14.1). C'est le MEME format que ci-dessus -- « comme si ce
-- boss etait le seul du donjon » -- plus un champ qui declare l'intention.
--
-- Pourquoi pas une enveloppe dediee : `ValidatePayload` ne controle que des champs NOMMES et
-- ne rejette aucun champ inconnu, `ImportPayload` ne lit que dID/name/healer/ext/tsp/asg/tlv/phl/boff,
-- et aucun code ne parcourt un payload en `pairs()`. `bossOnly` est donc INERTE sur tout le
-- parc deja installe : un client d'avant la feature cree une variante ordinaire ne contenant
-- que ce boss. Il ajoute, il n'ecrase rien.
--
-- ⚠️ PAS de `tlv` ici, contrairement a BuildPayload. `ImportPayload` l'applique via
-- HR.SetActiveTimelineVariant, qui ecrit une PREFERENCE D'AFFICHAGE du joueur, hors variante.
-- L'ecrire en effet de bord de l'import d'un seul boss est exactement le probleme ecarte en
-- §6.5.
--
-- PAS de `boff` non plus : desactiver un boss est un choix de la variante qui le JOUE. Importer
-- le plan d'un boss ne doit pas couper les annonces chez le destinataire.
--
-- `name` voyage mais n'est PAS ecrit a l'import : la variante de destination garde le sien.
-- Il ne sert qu'a l'ecran de confirmation.
-- Filtre d'emission comme BuildPayload (`opts.full` = export). Un boss dont il ne reste rien
-- n'a pas de plan.
function Share.BuildBossPayload(dungeonID, variant, encID, opts)
    if not dungeonID or not variant or encID == nil then return nil end
    local src = variant.assignments and variant.assignments[encID]
    if type(src) ~= "table" or not next(src) then return nil end
    local asg = Share.OutgoingAssignments({ [encID] = src }, opts and opts.full)[encID]
    if not asg then return nil end
    return {
        v        = PROTO,
        kind     = "variant",
        dID      = dungeonID,
        name     = variant.name,
        healer   = variant.healer,
        ext      = variant.externals,
        tsp      = variant.talentSpells,
        asg      = { [encID] = asg },
        bossOnly = encID,
        phl      = variant.phaseLengths and variant.phaseLengths[encID]
                   and { [encID] = variant.phaseLengths[encID] } or nil,
    }
end

-- Chaine d'export du plan d'un seul boss. nil si le boss n'a aucun placement.
function Share.EncodeBossPlan(dungeonID, variant, encID, opts)
    local payload = Share.BuildBossPayload(dungeonID, variant, encID, opts)
    if not payload then return nil end
    return Share.EncodeRaw(payload)
end

-- Le payload recu est-il exploitable ? (forme V2 + donjon connu)
function Share.ValidatePayload(p)
    if type(p) ~= "table" then return false end
    if p.kind ~= "variant" then return false end
    if type(p.dID) ~= "string" or not IsKnownDungeon(p.dID) then return false end
    -- V2 : profil de heal obligatoire. On exige une clef REELLE (profil connu, ou le
    -- pseudo-profil "No healer" d'une variante DPS/TANK) et pas un simple type string : une
    -- clef inconnue creerait chez le receveur une variante FANTOME, absente du selecteur
    -- (qui n'itere que HR.HEAL_PROFILES + NO_HEALER) donc ni selectionnable ni supprimable.
    if not HR.GetHealProfileOrNone(p.healer) then return false end
    if p.cls ~= nil and type(p.cls) ~= "string" then return false end   -- ancien champ : tolere a la lecture
    if p.ext ~= nil and type(p.ext) ~= "table" then return false end
    if p.tsp ~= nil and type(p.tsp) ~= "table" then return false end
    if p.asg ~= nil and type(p.asg) ~= "table" then return false end
    if p.tlv ~= nil and type(p.tlv) ~= "table" then return false end
    if p.phl ~= nil and type(p.phl) ~= "table" then return false end
    if p.boff ~= nil and type(p.boff) ~= "table" then return false end
    return true
end

-- Recopie filtree des externals partages : ne garde que les defKey connus, count borne.
function Share.SanitizeExternals(ext)
    local out = {}
    if type(ext) ~= "table" then return out end
    for k, n in pairs(ext) do
        n = tonumber(n)
        if n and n > 0 and HR.defensives[HR.DefKeyOf(k)] then
            out[k] = math.min(20, math.floor(n))
        end
    end
    return out
end

-- Recopie filtree des longueurs de phase (`phl`, boss a `phaseSegments`) : boss du donjon a
-- phases variables, index de phase 1..N-1 (la derniere est ouverte), valeur bornee
-- [PHASE_MIN_LENGTH, FIGHT_LENGTH]. nil si rien ne survit (une variante sans reglage n'a pas
-- la cle). Un client d'avant la feature ignore le champ : ses longueurs restent par defaut.
function Share.SanitizePhaseLengths(dungeonID, phl)
    if type(phl) ~= "table" then return nil end
    local segsOf = {}
    for _, d in ipairs(HR.content) do
        if d.id == dungeonID then
            for _, b in ipairs(d.bosses) do
                if b.phaseSegments then segsOf[b.id] = b.phaseSegments end
            end
        end
    end
    local out
    for encID, lens in pairs(phl) do
        encID = tonumber(encID) or encID
        local segs = segsOf[encID]
        local n = segs and #segs
        if n and type(lens) == "table" then
            for k, sec in pairs(lens) do
                k, sec = tonumber(k), tonumber(sec)
                if k and k == math.floor(k) and k >= 1 and k < n and sec
                   and not segs[k].intermission then                 -- intermission : longueur fixe
                    sec = math.max(HR.PHASE_MIN_LENGTH, math.min(HR.FIGHT_LENGTH, math.floor(sec + 0.5)))
                    out = out or {}
                    out[encID] = out[encID] or {}
                    out[encID][k] = sec
                end
            end
        end
    end
    return out
end

-- Recopie filtree des boss desactives (`boff`) : encounterID du donjon a valeur `true`. nil si
-- rien ne survit. Un client d'avant la feature ignore le champ : le boss reste actif chez lui.
function Share.SanitizeBossOff(dungeonID, boff)
    if type(boff) ~= "table" then return nil end
    local validEnc = {}
    for _, d in ipairs(HR.content) do
        if d.id == dungeonID then
            for _, b in ipairs(d.bosses) do validEnc[b.id] = true end
        end
    end
    local out
    for encID, off in pairs(boff) do
        encID = tonumber(encID) or encID
        if validEnc[encID] and off == true then
            out = out or {}
            out[encID] = true
        end
    end
    return out
end

-- Recopie filtree des assignments : on ne garde que les encounterID du donjon,
-- les occKey en chaine et les defID connus de HR.defensives. Tout le reste tombe.
function Share.SanitizeAssignments(dungeonID, asg)
    local out = {}
    if type(asg) ~= "table" then return out end
    local validEnc = {}
    for _, d in ipairs(HR.content) do
        if d.id == dungeonID then
            for _, b in ipairs(d.bosses) do validEnc[b.id] = true end
        end
    end
    for encID, occs in pairs(asg) do
        encID = tonumber(encID) or encID
        if validEnc[encID] and type(occs) == "table" then
            local encOut
            for occKey, defs in pairs(occs) do
                if type(occKey) == "string" and type(defs) == "table" then
                    local list = {}
                    for _, e in ipairs(defs) do
                        local token = HR.EntryToken(e)
                        if token and HR.defensives[HR.DefKeyOf(token)] then
                            local offMax = (HR.OFFSET_MAX_S or 30) * 1000
                            local off = math.max(-offMax, math.min(offMax, HR.EntryOffset(e)))
                            list[#list + 1] = (off ~= 0) and { token = token, offset = off } or { token = token }
                        end
                    end
                    if #list > 0 then
                        encOut = encOut or {}
                        encOut[occKey] = list
                    end
                end
            end
            if encOut then out[encID] = encOut end
        end
    end
    return out
end

-- Cree une variante V2 a partir d'un payload valide. `autodelete` => expire dans 24h (prune).
-- Renvoie (variante, dID) ou nil si invalide.
function Share.ImportPayload(payload, sender, autodelete)
    if not Share.ValidatePayload(payload) then return nil end
    local short = sender and sender:match("^[^-]+") or nil
    local name = payload.name or "Imported plan"
    if type(name) ~= "string" then name = "Imported plan" end
    if short then name = name .. " (" .. short .. ")" end
    local asg = Share.SanitizeAssignments(payload.dID, payload.asg)
    local ext = Share.SanitizeExternals(payload.ext)
    local tsp = (type(payload.tsp) == "table") and payload.tsp or {}
    local expires
    if autodelete then expires = ((GetServerTime and GetServerTime()) or time()) + 24 * 3600 end
    local v = HR.V2_ImportVariant(payload.dID, name, payload.healer, ext, tsp, asg, expires)
    if not v then return nil end
    v.phaseLengths = Share.SanitizePhaseLengths(payload.dID, payload.phl)
    v.bossOff = Share.SanitizeBossOff(payload.dID, payload.boff)
    -- Applique le choix de variante de timeline JOUEE de l'emetteur (par boss du donjon).
    if type(payload.tlv) == "table" then
        for encID, vid in pairs(payload.tlv) do
            encID = tonumber(encID) or encID
            if type(vid) == "string" then HR.SetActiveTimelineVariant(encID, vid) end
        end
    end
    return v, payload.dID
end

