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
--   * `noSync = true` : NON PARTAGEABLE. Elle ne quitte jamais la DB du joueur (Core/Share.lua
--     la retire de tout payload et a toute reception). Indispensable : `U:<n>` est un compteur
--     LOCAL, le `U:1` d'un joueur n'est pas celui d'un autre.
--   * `custom = true` : la marque. Exclue des index par spellID (ShareText, Capture,
--     ResolveDefEntry) et des listes de sorts natifs (talents du heal, variante de test).
--   * `class` / `role = "HEALER"` / `spec` tires du PROFIL DE HEAL : un sort custom appartient
--     TOUJOURS a une spe (pas de Spiritwalker's Grace chez un paladin). Consequences gratuites :
--     « mien » correct au runtime (HR.PlayerCanUseDefensive), et le sort suit l'option
--     « Show heal cooldowns » de la Personal Timeline (IsHealToolkit, UI/RuntimeBox.lua).
--
-- STOCKAGE (additif, aucun bump de schema) : `ECPlannerDB.customSpells = { nextId, entries =
-- { ["U:<n>"] = { spellID, name, icon, cooldown, [charges], profile, [archived], createdAt } } }`.
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
local addonName, HR = ...

HR.CustomSpells = HR.CustomSpells or {}
local CS = HR.CustomSpells

local PREFIX = "U:"
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
        noSync   = true,
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
    inject(key, e)
    return key
end

function CS.SetArchived(key, archived)
    local e = CS.Get(key); if not e then return false end
    e.archived = archived and true or nil
    inject(key, e)
    return true
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
