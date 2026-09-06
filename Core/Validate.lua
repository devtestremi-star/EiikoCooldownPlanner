-- EiikoCooldownPlanner - Core/Validate.lua
-- Validation de la ROUTE D'IMPORT DE BOSS (memo §14 / §15.5). Ecrite pour etre reprise,
-- mais elle n'a AUJOURD'HUI qu'un seul consommateur : UI/ImportBoss.lua.
--
-- ⚠️ CE FICHIER N'EST PAS « LA COUCHE DE VALIDATION DE L'ADDON ».
-- `Core/Share.lua` (ValidatePayload / Sanitize*), `Core/ShareText.lua` (Parse / Resolve /
-- ValidateAgainstVariant) et `Core/Catalog.lua` (sanitizeEntry) gardent CHACUN les leurs, et
-- c'est deliberé : la migration de ces validateurs-la a ete etudiee et **ecartee** (memo §15,
-- mauvais rapport risque/benefice -- le pire echec des sanitizers est un drop SILENCIEUX sur
-- des DB deployees). N'ajoute donc pas ici un predicat destine a un autre chemin en supposant
-- que « tout passe par la » : ce serait fabriquer deux endroits qui ont l'air de faire
-- autorite, exactement ce qu'on cherchait a eviter.
--
-- Pourquoi ce fichier existe quand meme, avec un seul appelant : de la validation de donnees
-- de jeu n'a rien a faire dans un fichier `UI/`. C'est un argument de COUCHE, pas de
-- reutilisation.
--
-- Convention : chaque feuille rend `(valeur|nil, code)` -- la valeur resolue quand elle
-- existe, un CODE SYMBOLIQUE sinon. Jamais une phrase anglaise construite au fond de la pile :
-- c'est `V.Message` qui traduit, en un seul endroit.
local addonName, HR = ...

HR.Valid = HR.Valid or {}
local V = HR.Valid

--------------------------------------------------------------------------------
-- Codes
--------------------------------------------------------------------------------

V.E_DUNGEON       = "DUNGEON_UNKNOWN"
V.E_ENCOUNTER     = "BOSS_UNKNOWN"
V.E_BOSS_DUNGEON  = "BOSS_WRONG_DUNGEON"
V.E_BOSS_DISABLED = "BOSS_DISABLED"
V.E_OCCKEY        = "OCCURRENCE_UNKNOWN"
V.E_TOKEN         = "DEFENSIVE_UNKNOWN"
V.E_HEALER        = "HEALER_UNKNOWN"
V.E_EMPTY         = "NOTHING_TO_IMPORT"

V.E_NO_VARIANT    = "NO_VARIANT_SELECTED"
V.E_WRONG_DUNGEON = "VARIANT_WRONG_DUNGEON"
V.E_WRONG_SPEC    = "VARIANT_WRONG_SPEC"
V.E_READONLY      = "VARIANT_READ_ONLY"

--------------------------------------------------------------------------------
-- Rapport
--------------------------------------------------------------------------------

-- Un enregistrement = { code, path, detail }. Le `path` ADRESSE l'element (« Zuraal >
-- 12345:2 ») : sans lui, un rapport de vingt lignes est un mur. Le rendu en phrases est
-- separe (V.Message) pour que l'UI puisse aussi grouper ou compter.
local ReportMT = {}
ReportMT.__index = ReportMT

function ReportMT:Add(code, path, detail)
    self[#self + 1] = { code = code, path = path, detail = detail }
end

function ReportMT:Failed() return #self > 0 end

-- Rend le rapport sous forme de liste de phrases, prete pour UI.ShowImportReport.
function ReportMT:Lines()
    local out = {}
    for _, rec in ipairs(self) do out[#out + 1] = V.Message(rec) end
    return out
end

function V.Report() return setmetatable({}, ReportMT) end

-- Politique : STRICT UNIQUEMENT (memo §15.5). « Strict » = le moindre motif refuse
-- l'import ; on collecte quand meme TOUS les motifs, parce qu'un rapport qui s'arrete au
-- premier oblige le joueur a reimporter autant de fois qu'il a de problemes.
-- Pas de constante `V.LENIENT`/`V.QUIET` : une constante a une seule valeur est
-- l'abstraction qu'on a refuse de financer. Le jour ou une 2e politique existe, le
-- parametre apparait ce jour-la.

--------------------------------------------------------------------------------
-- Feuilles -- un seul lookup chacune
--------------------------------------------------------------------------------

-- Le `dID` nomme-t-il un donjon du pool courant ? Rend le donjon.
function V.CheckDungeon(dID)
    if type(dID) ~= "string" then return nil, V.E_DUNGEON end
    for _, d in ipairs(HR.content or {}) do
        if d.id == dID then return d end
    end
    return nil, V.E_DUNGEON
end

-- Le boss existe, appartient a CE donjon, et n'est pas desactive. Rend le boss.
-- Les trois controles ensemble : un boss d'un autre donjon est aussi faux qu'un boss
-- inconnu, et un boss desactive ne peut pas porter de plan.
function V.CheckEncounter(encID, dungeon)
    if type(encID) ~= "number" then return nil, V.E_ENCOUNTER end
    local boss, dg = HR.GetBossByEncounterID(encID)
    if not boss then return nil, V.E_ENCOUNTER end
    if dungeon and dg ~= dungeon then return nil, V.E_BOSS_DUNGEON end
    if not HR.BossEnabled(boss) then return nil, V.E_BOSS_DISABLED end
    return boss
end

-- Ensemble des occKey VALIDES du boss, construit UNE FOIS.
-- ⚠️ Seule feuille non pure, et sa signature le dit : les occKey sont prefixes par la
-- variante de TIMELINE (HR.ResolveBossTimeline). `tlFor(boss)` doit rendre la meme variante
-- que celle affichee par l'editeur (UI.GetViewedTlVariant), sinon on validerait contre des
-- cles qui ne sont pas celles du plan visible.
function V.OccKeys(boss, tlFor)
    local set = {}
    if not boss then return set end
    local resolved = HR.ResolveBossTimeline(boss, tlFor and tlFor(boss) or nil)
    for _, o in ipairs(HR.GenerateOccurrences(resolved, HR.FIGHT_LENGTH) or {}) do
        set[o.key] = true
    end
    return set
end

function V.CheckOccKey(occKey, set)
    if type(occKey) ~= "string" then return false, V.E_OCCKEY end
    if set and not set[occKey] then return false, V.E_OCCKEY end
    return true
end

-- Le token designe-t-il un defensif connu ? Rend le defKey.
-- ⚠️ On EXIGE une chaine, et ce n'est pas de la coquetterie : `ST.ValidateAgainstVariant`
-- fait `t.token:find("#")` sur le token, ce qui ERREUR sur un nombre. Une charge hostile
-- (CBOR colle a la main) pourrait porter une cle numerique -- elle s'arrete ici.
function V.CheckToken(token)
    if type(token) ~= "string" then return nil, V.E_TOKEN end
    local key = HR.DefKeyOf(token)
    if not HR.defensives[key] then return nil, V.E_TOKEN end
    return key
end

-- Profil de heal REEL. `opts.allowNone` NOMME la tolerance au lieu de la deviner : le
-- codebase a deux accesseurs (GetHealProfile / GetHealProfileOrNone) et le choix entre eux
-- etait jusqu'ici implicite au point d'appel.
function V.CheckHealer(key, opts)
    local prof = (opts and opts.allowNone) and HR.GetHealProfileOrNone(key)
                                            or HR.GetHealProfile(key)
    if not prof then return nil, V.E_HEALER end
    return prof
end

--------------------------------------------------------------------------------
-- Relationnel : « est-ce que ca rentre LA ? »
--------------------------------------------------------------------------------

-- Le portail du memo §14.2 : un import de boss ne ROUTE PAS. Le joueur doit deja etre sur
-- une variante eligible ; on ne change ni de donjon, ni de variante, et on n'en cree pas.
-- `currentDID` = donjon AFFICHE, fourni par l'appelant (une fonction de Core/ ne lit pas
-- l'etat de l'UI). Il sert de repli : les variantes creees avant le correctif §9.1 n'ont
-- pas de `dID`.
--
-- Ordre des controles = ordre d'utilite du message : ou aller d'abord, pourquoi ensuite.
function V.CheckEligible(dID, healerKey, variant, currentDID)
    if type(variant) ~= "table" then return false, V.E_NO_VARIANT end
    if (variant.dID or currentDID) ~= dID then return false, V.E_WRONG_DUNGEON end
    if healerKey ~= nil and variant.healer ~= healerKey then return false, V.E_WRONG_SPEC end
    -- Verrou d'edition (§11). `ST.ApplyBoss` le porte aussi, au point d'ecriture : ici c'est
    -- pour l'expliquer, la-bas c'est pour la surete.
    if not HR.CanEditVariant(variant) then return false, V.E_READONLY end
    return true
end

--------------------------------------------------------------------------------
-- Composite : le plan d'UN boss
--------------------------------------------------------------------------------

-- Valide la STRUCTURE d'un bloc `[occKey] = { entrees }` et rend, au passage, la liste des
-- tokens distincts qu'il utilise -- au format attendu par `ST.ValidateAgainstVariant`
-- (`{ token = ... }`). On parcourt une seule fois : la placabilite se teste ensuite sur
-- cette liste, contre la variante de destination.
--
-- ⚠️ Ici on ne teste PAS la placabilite. C'est `ST.ValidateAgainstVariant` qui la porte, et
-- on ne reecrit pas ce qu'on peut appeler (memo §14.4).
--
-- ctx = { boss, bossName, occSet }. Rend la liste, ou nil si le rapport a echoue.
function V.CheckBossPlan(block, ctx, rep)
    local name = (ctx and ctx.bossName) or "?"
    if type(block) ~= "table" or not next(block) then
        rep:Add(V.E_EMPTY, name)
        return nil
    end

    local tokens, seen = {}, {}
    for occKey, list in pairs(block) do
        local okKey = V.CheckOccKey(occKey, ctx and ctx.occSet)
        if not okKey then
            rep:Add(V.E_OCCKEY, name, tostring(occKey))
        elseif type(list) ~= "table" or #list == 0 then
            rep:Add(V.E_EMPTY, ("%s > %s"):format(name, occKey))
        else
            for _, e in ipairs(list) do
                local token = HR.EntryToken(e)
                if not V.CheckToken(token) then
                    rep:Add(V.E_TOKEN, ("%s > %s"):format(name, occKey), tostring(token))
                elseif not seen[token] then
                    seen[token] = true
                    tokens[#tokens + 1] = { token = token }
                end
            end
        end
    end

    if rep:Failed() then return nil end
    if #tokens == 0 then rep:Add(V.E_EMPTY, name); return nil end
    return tokens
end

--------------------------------------------------------------------------------
-- Rendu des codes
--------------------------------------------------------------------------------

-- Un seul endroit ou un code devient une phrase. `ctx` (optionnel) permet de nommer le
-- donjon et la spe attendus dans les messages d'eligibilite -- un refus doit dire OU ALLER,
-- pas seulement que ca a rate.
local TEXT = {
    [V.E_DUNGEON]       = "this plan targets a dungeon this client does not know",
    [V.E_ENCOUNTER]     = "unknown boss for this client version",
    [V.E_BOSS_DUNGEON]  = "that boss does not belong to this dungeon",
    [V.E_BOSS_DISABLED] = "that boss is disabled in the addon: it cannot hold a plan",
    [V.E_OCCKEY]        = "that occurrence does not exist on this boss",
    [V.E_TOKEN]         = "that cooldown is unknown to the addon",
    [V.E_HEALER]        = "unknown healing specialization",
    [V.E_EMPTY]         = "nothing to import",
    [V.E_NO_VARIANT]    = "no variant is selected",
    [V.E_WRONG_DUNGEON] = "the selected variant belongs to another dungeon",
    [V.E_WRONG_SPEC]    = "the selected variant is for another healing specialization",
    [V.E_READONLY]      = "the selected variant is read-only",
}

function V.Message(rec)
    if type(rec) ~= "table" then return tostring(rec) end
    local base = TEXT[rec.code] or tostring(rec.code)
    if rec.path and rec.detail then
        return ("%s (%s): %s."):format(rec.path, rec.detail, base)
    elseif rec.path then
        return ("%s: %s."):format(rec.path, base)
    end
    return base:sub(1, 1):upper() .. base:sub(2) .. "."
end

-- Phrase d'un code d'eligibilite, avec le remede. Separee de V.Message parce qu'elle a
-- besoin du contexte (nom du donjon, nom de la spe) que le rapport ne transporte pas.
function V.EligibleMessage(code, ctx)
    ctx = ctx or {}
    if code == V.E_NO_VARIANT then
        return ("Open a variant of %s first: a boss plan is applied to the variant you have "
             .. "on screen, it never creates one."):format(ctx.dungeonName or "that dungeon")
    elseif code == V.E_WRONG_DUNGEON then
        return ("This plan is for %s. Open a variant of that dungeon, then import again.")
            :format(ctx.dungeonName or "another dungeon")
    elseif code == V.E_WRONG_SPEC then
        return ("This plan is for %s. Select a variant of that specialization, then import "
             .. "again."):format(ctx.healerName or "another healing specialization")
    elseif code == V.E_READONLY then
        return HR.EditBlockedText(select(2, HR.CanEditVariant(ctx.variant)), ctx.variant)
    end
    return V.Message({ code = code })
end
