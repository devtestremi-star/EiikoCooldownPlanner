-- EiikoCooldownPlanner - Core/CustomSpells.lua
-- SORTS CUSTOM : la bibliotheque personnelle du joueur. Il y ajoute un sort que l'addon ne
-- connait pas (par spellID), avec SON cooldown (un talent le reduit, on ne le scanne pas), et
-- le place ensuite dans ses plans comme un sort natif.
--
-- PRINCIPE : chaque entree est INJECTEE dans HR.defensives sous une cle `U:<n>`. Tout l'addon
-- lit les sorts au meme endroit (`HR.defensives[HR.DefKeyOf(token)]`) -- picker, dispo du CD,
-- runtime, annonce, TTS, timelines marchent donc sans le savoir.
--
-- Une entree injectee porte :
--   * `noSync = true` SAUF si le joueur a coche « Share with my group » (`shared`). Un sort non
--     partage ne part pas au SYNC (Core/Share.lua) ; l'EXPORT, lui, emporte tout.
--   * La cle `U:<n>` ne voyage JAMAIS, partage ou non : c'est un compteur LOCAL, le `U:1` d'un
--     joueur n'est pas celui d'un autre. Le sort part sous un TOKEN DE FIL (cf. plus bas).
--   * `custom = true` : la marque. Exclue des index par spellID (ShareText, Capture,
--     ResolveDefEntry) et des listes de sorts natifs (talents du heal, variante de test).
--   * `class` / `role = "HEALER"` / `spec` tires du PROFIL DE HEAL : un sort custom appartient
--     TOUJOURS a une spe (pas de Spiritwalker's Grace chez un paladin). Consequences gratuites :
--     « mien » correct au runtime (HR.PlayerCanUseDefensive), et le sort suit l'option
--     « Show heal cooldowns » de la Personal Timeline (IsHealToolkit, UI/RuntimeBox.lua).
--
-- STOCKAGE (additif, aucun bump de schema) : `ECPlannerDB.customSpells = { nextId, entries =
-- { ["U:<n>"] = { spellID, name, icon, cooldown, [charges], profile, [archived], [shared],
-- createdAt } } }`.
-- Au COMPTE et hors profil d'affichage, comme les plans.
--
-- PAR VARIANTE : `v.customOff = { ["U:<n>"] = true }` liste les sorts DESACTIVES (opt-out). Un
-- sort de la spe de la variante absent de cette table est actif -> un sort cree APRES la
-- variante y apparait tout de suite. Champ additif : une variante sans lui = tout actif.
--
-- ARCHIVER (jamais supprimer) : l'entree n'est plus PRESENTEE (bibliotheque, picker, modale
-- Edit plan) mais reste injectee et placable la ou elle est deja placee. Aucune ecriture dans
-- les plans du joueur. Restaurable.
--
-- La SPE d'un sort est VERROUILLEE des qu'il est place quelque part : la changer rendrait
-- orphelins ses placements dans les variantes de l'ancienne spe.
--
-- PARTAGE (`shared`, choix du joueur dans la modale, non par defaut). A l'emission
-- (Share.OutgoingAssignments), `U:<n>` est reecrit en TOKEN DE FIL auto-descriptif :
--   `C:<profil>:<spellID>:<cd>[:<charges>]`   sort PARTAGE      ex. "C:SHAMAN:79206:90"
--   `N:<profil>:<spellID>:<cd>[:<charges>]`   sort NON partage  (EXPORT seulement)
-- Il porte tout ce qu'il faut pour reconstruire le sort chez le destinataire, sans table
-- d'accompagnement dans le payload ni nouvelle cle de DB : le token est stocke tel quel dans
-- les `assignments` de la variante recue, et l'entree HR.defensives correspondante est
-- SYNTHETISEE A LA LECTURE (metatable __index, plus bas) -- jamais persistee. Un `N:` y est
-- `noSync` : le destinataire ne le repousse pas a SON groupe, l'intention de l'auteur suit le
-- sort. Un client d'avant la feature ne connait pas la cle : SanitizeAssignments la jette, le
-- plan reste importable. A la reception (Share.IncomingAssignments), un token de fil dont le
-- profil n'est pas celui du plan est jete.
-- IDENTITE = le token entier. Meme sort a deux CD = deux sorts (comme les variantes de CD
-- natives) ; meme sort, meme CD, deux auteurs = une seule entree, identique.
local addonName, HR = ...

HR.CustomSpells = HR.CustomSpells or {}
local CS = HR.CustomSpells

local PREFIX = "U:"
local WIRE_SHARED  = "C:"
local WIRE_PRIVATE = "N:"
CS.MIN_COOLDOWN = 1
CS.MAX_COOLDOWN = 3600
CS.MAX_CHARGES  = 5

--------------------------------------------------------------------------------
-- Store
--------------------------------------------------------------------------------

local function store()
    local db = HR.db2
    if not db then return nil end
    db.customSpells = db.customSpells or { nextId = 1, entries = {} }
    local s = db.customSpells
    s.nextId  = s.nextId or 1
    s.entries = s.entries or {}
    return s
end

function CS.IsCustomKey(key)
    return type(key) == "string" and key:sub(1, #PREFIX) == PREFIX
end

function CS.Get(key)
    local s = store()
    return s and s.entries[key] or nil
end

-- Entree de bibliotheque -> entree HR.defensives. Reconstruite a chaque ecriture.
local function inject(key, e)
    if type(e) ~= "table" then return end
    local prof = HR.GetHealProfile(e.profile)
    HR.defensives[key] = {
        name     = e.name or ("Spell " .. tostring(e.spellID)),
        cooldown = tonumber(e.cooldown) or CS.MIN_COOLDOWN,
        charges  = (tonumber(e.charges) or 1) > 1 and tonumber(e.charges) or nil,
        spellID  = e.spellID,
        icon     = e.icon,
        class    = prof and prof.class or nil,
        role     = "HEALER",
        spec     = prof and prof.spec or nil,
        profile  = e.profile,
        archived = e.archived or nil,
        custom   = true,
        shared   = e.shared or nil,
        noSync   = not e.shared or nil,
    }
end

-- Appelee par HR:OnInitialize, juste apres InitDB : injecte toute la bibliotheque (archives
-- comprises -- elles doivent rester resolues dans les plans existants).
function CS.Init()
    local s = store(); if not s then return end
    for key, e in pairs(s.entries) do inject(key, e) end
end

--------------------------------------------------------------------------------
-- Lecture
--------------------------------------------------------------------------------

-- Entrees d'un profil de heal, triees par nom. { key, entry }.
function CS.List(profile, includeArchived)
    local out = {}
    local s = store(); if not s then return out end
    for key, e in pairs(s.entries) do
        if e.profile == profile and (includeArchived or not e.archived) then
            out[#out + 1] = { key = key, entry = e }
        end
    end
    table.sort(out, function(a, b)
        local na, nb = a.entry.name or "", b.entry.name or ""
        if na ~= nb then return na < nb end
        return a.key < b.key
    end)
    return out
end

-- Le sort custom `key` est-il ACTIF dans la variante v ? (spe de la variante + pas desactive)
-- Sert a IsTokenPlaceable : un sort ARCHIVE reste placable (il est deja dans des plans).
function CS.IsActiveIn(v, key)
    if not v then return false end
    local d = HR.defensives[key]
    if not (d and d.custom) then return false end
    if d.profile ~= v.healer then return false end
    return not (v.customOff and v.customOff[key])
end

-- Sorts custom PROPOSES dans le picker de la variante v : actifs ET non archives.
function CS.PlaceableFor(v)
    local out = {}
    if not v then return out end
    for _, it in ipairs(CS.List(v.healer, false)) do
        if not (v.customOff and v.customOff[it.key]) then out[#out + 1] = it end
    end
    return out
end

-- Nombre de VARIANTES (tous donjons) ou le sort est place. Lecture seule.
function CS.UsageCount(key)
    local n = 0
    local db = HR.db2
    if not (db and db.dungeons) then return 0 end
    for _, ds in pairs(db.dungeons) do
        for _, v in pairs(ds.variants or {}) do
            local found = false
            for _, occs in pairs(v.assignments or {}) do
                for _, list in pairs(occs) do
                    if type(list) == "table" then
                        for _, e in ipairs(list) do
                            if HR.DefKeyOf(HR.EntryToken(e)) == key then found = true; break end
                        end
                    end
                    if found then break end
                end
                if found then break end
            end
            if found then n = n + 1 end
        end
    end
    return n
end

--------------------------------------------------------------------------------
-- Ecriture (actions 100 % joueur, depuis l'UI)
--------------------------------------------------------------------------------

local function clampCD(cd)
    cd = math.floor((tonumber(cd) or 0) + 0.5)
    if cd < CS.MIN_COOLDOWN or cd > CS.MAX_COOLDOWN then return nil end
    return cd
end

local function clampCharges(n)
    n = math.floor(tonumber(n) or 1)
    return math.max(1, math.min(CS.MAX_CHARGES, n))
end

-- data = { spellID, name, icon, cooldown, charges, profile }. Renvoie la cle, ou nil + raison.
function CS.Create(data)
    local s = store(); if not s then return nil, "no db" end
    if type(data) ~= "table" then return nil, "invalid" end
    local sid = tonumber(data.spellID)
    if not sid then return nil, "invalid spell" end
    if not HR.GetHealProfile(data.profile) then return nil, "invalid spec" end
    local cd = clampCD(data.cooldown)
    if not cd then return nil, "invalid cooldown" end
    local key = PREFIX .. s.nextId
    s.nextId = s.nextId + 1
    s.entries[key] = {
        spellID   = sid,
        name      = type(data.name) == "string" and data.name or nil,
        icon      = data.icon,
        cooldown  = cd,
        charges   = clampCharges(data.charges) > 1 and clampCharges(data.charges) or nil,
        profile   = data.profile,
        shared    = data.shared and true or nil,
        createdAt = (GetServerTime and GetServerTime()) or time(),
    }
    inject(key, s.entries[key])
    return key
end

-- Edite CD / charges, et la spe SEULEMENT si le sort n'est place nulle part.
function CS.Update(key, data)
    local e = CS.Get(key); if not e then return nil, "unknown" end
    local cd = clampCD(data.cooldown)
    if not cd then return nil, "invalid cooldown" end
    if data.profile and data.profile ~= e.profile then
        if not HR.GetHealProfile(data.profile) then return nil, "invalid spec" end
        if CS.UsageCount(key) > 0 then return nil, "spec locked" end
        e.profile = data.profile
    end
    e.cooldown = cd
    local ch = clampCharges(data.charges)
    e.charges = ch > 1 and ch or nil
    -- Le partage se change a tout moment : il ne vaut que pour les PROCHAINS Sync/Export.
    e.shared = data.shared and true or nil
    inject(key, e)
    return key
end

function CS.SetArchived(key, archived)
    local e = CS.Get(key); if not e then return false end
    e.archived = archived and true or nil
    inject(key, e)
    return true
end

-- Toutes les tables `assignments` du joueur ou une cle `U:` peut etre placee : variantes de
-- tous les donjons + plans de base des healers (HR.db.healerDefaults). Le catalogue n'en
-- contient jamais (IncomingAssignments jette les `U:`).
local function eachAssignments(fn)
    local db = HR.db2
    for _, ds in pairs((db and db.dungeons) or {}) do
        for _, v in pairs(ds.variants or {}) do
            if type(v.assignments) == "table" then fn(v.assignments, v) end
        end
    end
    for _, asg in pairs((HR.db and HR.db.healerDefaults) or {}) do
        if type(asg) == "table" then fn(asg, nil) end
    end
end

-- Nombre de placements de `key` (toutes tables confondues). Lecture seule.
function CS.PlacementCount(key)
    local n = 0
    eachAssignments(function(asg)
        for _, occs in pairs(asg) do
            for _, list in pairs(occs) do
                if type(list) == "table" then
                    for _, e in ipairs(list) do
                        if HR.DefKeyOf(HR.EntryToken(e)) == key then n = n + 1 end
                    end
                end
            end
        end
    end)
    return n
end

-- SUPPRESSION DEFINITIVE -- MODE DEV UNIQUEMENT (HR.IsDevMode, garde ici ET dans l'UI).
-- ⚠️ Seule ecriture de masse de ce module, et elle est CIBLEE : uniquement les placements de
-- CETTE cle et sa mention dans les `customOff`, sur demande explicite (modale de confirmation
-- qui annonce le nombre). L'archivage reste la voie normale pour un joueur. Sans retrait des
-- placements, ils resteraient dans les plans comme un sort inconnu.
-- `nextId` n'est JAMAIS recule : la cle `U:<n>` n'est pas reattribuee a un autre sort.
-- Renvoie le nombre de placements retires, ou nil si refuse.
function CS.Delete(key)
    if not (HR.IsDevMode and HR.IsDevMode()) then return nil end
    local s = store(); if not (s and s.entries[key]) then return nil end
    local removed = 0
    eachAssignments(function(asg, v)
        for _, occs in pairs(asg) do
            for occKey, list in pairs(occs) do
                if type(list) == "table" then
                    for i = #list, 1, -1 do
                        if HR.DefKeyOf(HR.EntryToken(list[i])) == key then
                            table.remove(list, i); removed = removed + 1
                        end
                    end
                    if #list == 0 then occs[occKey] = nil end
                end
            end
        end
        if v and v.customOff then
            v.customOff[key] = nil
            if not next(v.customOff) then v.customOff = nil end
        end
    end)
    s.entries[key] = nil
    rawset(HR.defensives, key, nil)
    return removed
end

--------------------------------------------------------------------------------
-- Lecture d'un sort du client (hors combat : rien n'est secret ici)
--------------------------------------------------------------------------------

local function safe(fn, ...)
    if not fn then return nil end
    local ok, a, b = pcall(fn, ...)
    if ok then return a, b end
    return nil
end

--------------------------------------------------------------------------------
-- Token de fil d'un sort PARTAGE (cf. en-tete)
--------------------------------------------------------------------------------

function CS.IsWireKey(key)
    if type(key) ~= "string" then return false end
    local pre = key:sub(1, 2)
    return pre == WIRE_SHARED or pre == WIRE_PRIVATE
end

local function wireOf(shared, profile, spellID, cd, charges)
    return (shared and WIRE_SHARED or WIRE_PRIVATE) .. profile .. ":" .. spellID .. ":" .. cd
        .. ((charges and charges > 1) and (":" .. charges) or "")
end

-- Token de fil de la cle de bibliotheque `key`. Un sort non partage n'en a un que si
-- `includePrivate` (EXPORT) ; sinon nil (SYNC : il ne part pas).
function CS.WireToken(key, includePrivate)
    local e = CS.Get(key)
    if not (e and e.spellID and e.cooldown and e.profile) then return nil end
    if not e.shared and not includePrivate then return nil end
    return wireOf(e.shared, e.profile, e.spellID, e.cooldown, e.charges)
end

-- Token de fil -> profil, spellID, cd, charges, partage ; nil si mal forme. Exige la forme
-- CANONIQUE (pas de zero en tete, pas de `:1` pour une charge) : un meme sort n'a qu'une cle.
function CS.ParseWire(key)
    if not CS.IsWireKey(key) then return nil end
    local pre, prof, sid, cd, ch = key:match("^([CN]):([%w_]+):(%d+):(%d+):?(%d*)$")
    if not pre then return nil end
    sid, cd, ch = tonumber(sid), tonumber(cd), tonumber(ch) or 1
    if sid <= 0 or cd < CS.MIN_COOLDOWN or cd > CS.MAX_COOLDOWN then return nil end
    if ch < 1 or ch > CS.MAX_CHARGES then return nil end
    if not HR.GetHealProfile(prof) then return nil end
    local shared = pre == "C"
    if wireOf(shared, prof, sid, cd, ch) ~= key then return nil end
    return prof, sid, cd, ch, shared
end

-- Entree HR.defensives d'un sort RECU. Nom lu du client ; s'il n'est pas encore en cache, un
-- nom provisoire est remplace des que le client a charge le sort.
local function buildWireDef(key)
    local prof, sid, cd, ch, shared = CS.ParseWire(key)
    if not prof then return nil end
    local p = HR.GetHealProfile(prof)
    local name = C_Spell and safe(C_Spell.GetSpellName, sid)
    local d = {
        name     = name or ("Spell " .. sid),
        cooldown = cd,
        charges  = ch > 1 and ch or nil,
        spellID  = sid,
        class    = p.class,
        role     = "HEALER",
        spec     = p.spec,
        profile  = prof,
        custom   = true,
        received = true,           -- sort d'un AUTRE joueur : absent de la bibliotheque
        shared   = shared or nil,
        noSync   = not shared or nil,   -- `N:` : l'auteur ne le partageait pas -> jamais au Sync
    }
    if not name and Spell and Spell.CreateFromSpellID then
        local sp = Spell:CreateFromSpellID(sid)
        if sp and sp.ContinueOnSpellLoad and not sp:IsSpellEmpty() then
            sp:ContinueOnSpellLoad(function()
                d.name = (C_Spell and safe(C_Spell.GetSpellName, sid)) or d.name
            end)
        end
    end
    return d
end

--------------------------------------------------------------------------------
-- ADOPTION : un sort recu entre dans la bibliotheque quand le plan devient LE MIEN
--------------------------------------------------------------------------------
-- Un token de fil n'est pas dans la bibliotheque : il reste lisible la ou il est place, mais
-- le picker ne le propose nulle part ailleurs. On l'adopte donc au moment ou un plan devient
-- modifiable par le joueur : import d'un EXPORT (variante entiere / un boss) et DUPLICATION.
-- PAS au Sync ni a l'ajout depuis le catalogue : ces variantes sont LIEES (leur source les
-- reecrit) et ne se modifient pas ; elles gardent les tokens de fil.
--
-- Appeler UNIQUEMENT sur des assignments QU'ON VIENT D'ECRIRE (variante neuve, boss importe) :
-- les tokens y sont remplaces EN PLACE par la cle de bibliotheque. Jamais sur une donnee
-- existante (regle absolue).
--
-- Correspondance = meme profil, spellID, CD et charges. Un sort de la bibliotheque qui
-- correspond est REUTILISE (son reglage de partage fait foi), et restaure s'il etait archive :
-- le plan importe s'en sert. Sinon, creation ; partage = celui de l'auteur (`C:`/`N:`).
-- `variant` (optionnel) = la variante qui recoit ces assignments : chaque sort adopte y est
-- REACTIVE (retire de `customOff`). Sinon un sort que la variante desactivait serait place
-- mais introuvable au picker, et V2_UpdateVariant purgerait ses placements a la sauvegarde
-- suivante. Importer un plan qui s'en sert = le vouloir (decision du 2026-10-17).
-- Renvoie { added = { noms }, linked = n }.

local function findLibraryMatch(prof, sid, cd, ch)
    local s = store(); if not s then return nil end
    local best
    for key, e in pairs(s.entries) do
        if e.profile == prof and e.spellID == sid and e.cooldown == cd and (e.charges or 1) == ch then
            if not e.archived then return key end
            best = best or key
        end
    end
    return best
end

function CS.AdoptInto(asg, healer, variant)
    local res = { added = {}, linked = 0 }
    if type(asg) ~= "table" then return res end
    local map = {}                                   -- token de fil -> cle de bibliotheque
    local function adopt(wire)
        if map[wire] ~= nil then return map[wire] end
        local prof, sid, cd, ch, shared = CS.ParseWire(wire)
        if not prof or prof ~= healer then map[wire] = false; return false end
        local key = findLibraryMatch(prof, sid, cd, ch)
        if key then
            if CS.Get(key).archived then CS.SetArchived(key, false) end
            res.linked = res.linked + 1
        else
            local name = C_Spell and safe(C_Spell.GetSpellName, sid)
            local icon
            if C_Spell and C_Spell.GetSpellTexture then
                local ok, a, b = pcall(C_Spell.GetSpellTexture, sid)
                if ok then icon = b or a end
            end
            key = CS.Create({ spellID = sid, name = name, icon = icon, cooldown = cd,
                              charges = ch, profile = prof, shared = shared })
            if not key then map[wire] = false; return false end
            res.added[#res.added + 1] = name or ("Spell " .. sid)
            -- Nom pas encore en cache : complete des que le client a charge le sort.
            if not name then
                local k = key
                CS.LookupSpell(sid, function(info)
                    local e = CS.Get(k)
                    if info and e and not e.name then
                        e.name, e.icon = info.name, e.icon or info.icon
                        inject(k, e)
                    end
                end)
            end
        end
        map[wire] = key
        local off = variant and variant.customOff
        if off and off[key] then
            off[key] = nil
            if not next(off) then variant.customOff = nil end
        end
        return key
    end
    for _, occs in pairs(asg) do
        if type(occs) == "table" then
            for _, list in pairs(occs) do
                if type(list) == "table" then
                    for i, e in ipairs(list) do
                        local t = HR.EntryToken(e)
                        if CS.IsWireKey(t) then
                            local key = adopt(t)
                            if key then
                                if type(e) == "table" then e.token = key else list[i] = key end
                            end
                        end
                    end
                end
            end
        end
    end
    return res
end

-- Message chat apres une adoption (rien si aucun sort recu).
function CS.ReportAdoption(res)
    if not res then return end
    if #res.added > 0 then
        HR:Print(("%d custom spell%s added to your library: %s."):format(#res.added,
            #res.added > 1 and "s" or "", table.concat(res.added, ", ")))
    end
end

-- SYNTHESE A LA LECTURE : tout le code lit `HR.defensives[HR.DefKeyOf(token)]` ; un token de fil
-- y trouve donc son sort ou qu'il soit stocke (variante recue, catalogue, defaut du heal), sans
-- scan au chargement. Mise en cache (rawset) en memoire seulement. `pairs` ne voit une entree
-- qu'une fois lue -- elle porte `custom`, deja exclu des index et listes de sorts natifs.
setmetatable(HR.defensives, { __index = function(t, k)
    if not CS.IsWireKey(k) then return nil end
    local d = buildWireDef(k)
    if d then rawset(t, k, d) end
    return d
end })

-- Infos d'un spellID, ou nil si le sort n'existe pas. Le chargement du client est ASYNCHRONE
-- pour un sort pas encore en cache : `cb(info)` est appele quand il est pret (parfois tout de
-- suite). info = { spellID, name, icon, baseCooldown (s, 0 si inconnu), charges (>=1),
-- passive, known }.
function CS.LookupSpell(spellID, cb)
    spellID = tonumber(spellID)
    if not spellID or spellID <= 0 or spellID ~= math.floor(spellID) then cb(nil); return end
    if C_Spell and C_Spell.DoesSpellExist and not safe(C_Spell.DoesSpellExist, spellID) then
        cb(nil); return
    end
    local function read()
        local si = C_Spell and safe(C_Spell.GetSpellInfo, spellID)
        if type(si) ~= "table" or not si.name then return nil end
        local ms = safe(GetSpellBaseCooldown, spellID)
        local base = (type(ms) == "number" and ms > 0) and math.floor(ms / 1000 + 0.5) or 0
        local charges = 1
        local ci = C_Spell and safe(C_Spell.GetSpellCharges, spellID)
        if type(ci) == "table" then
            local ok, n = pcall(function() return (ci.maxCharges or 1) > 1 and ci.maxCharges or 1 end)
            if ok and type(n) == "number" then charges = n end
            -- Le CD d'une charge est souvent la seule duree connue d'un sort a charges.
            if base == 0 then
                local ok2, dur = pcall(function() return (ci.cooldownDuration or 0) > 0 and ci.cooldownDuration or 0 end)
                if ok2 and type(dur) == "number" then base = math.floor(dur + 0.5) end
            end
        end
        return {
            spellID      = spellID,
            name         = si.name,
            -- `originalIconID` : l'icone du sort LUI-MEME, pas celle d'un override du joueur
            -- local (cf. HR.GetDefensiveIcon -- AW rendu avec l'icone d'AC).
            icon         = si.originalIconID or si.iconID,
            baseCooldown = base,
            charges      = charges,
            passive      = (C_Spell and safe(C_Spell.IsSpellPassive, spellID)) and true or false,
            known        = safe(IsPlayerSpell, spellID) and true or false,
        }
    end
    local info = read()
    if info then cb(info); return end
    if Spell and Spell.CreateFromSpellID then
        local sp = Spell:CreateFromSpellID(spellID)
        if sp and sp.ContinueOnSpellLoad and not sp:IsSpellEmpty() then
            sp:ContinueOnSpellLoad(function() cb(read()) end)
            return
        end
    end
    cb(nil)
end

-- Sorts NATIFS d'une spe qui partagent ce spellID (pour avertir d'un doublon). { name, cooldown }.
function CS.NativeTwins(spellID, profile)
    local out = {}
    local prof = HR.GetHealProfile(profile)
    for key, d in pairs(HR.defensives) do
        if not d.custom and HR.GetDefensiveSpellID(key) == spellID
           and (not d.class or not prof or d.class == prof.class) then
            out[#out + 1] = { name = d.name, cooldown = d.cooldown }
        end
    end
    table.sort(out, function(a, b) return (a.cooldown or 0) > (b.cooldown or 0) end)
    return out
end
