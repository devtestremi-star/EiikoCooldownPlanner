-- HealPlanner - Core/Planner.lua
-- Generation des occurrences d'un boss + verification de disponibilite des sorts.
-- Tout est THEORIQUE (temps en secondes depuis le debut du boss), pas de runtime.
local addonName, HR = ...

-- Champs communs d'une occurrence : { time, spellID, name, aoe, occIndex, key, phase }.
-- La cle "spellID:occIndex" est stable et sert d'identifiant pour les placements.
-- `prefix` (variante de timeline) : "<id>|spellID:N" -> les plans de variantes
-- differentes coexistent sans collision (cf. boss._tlVariant / HR.ResolveBossTimeline).

-- Affecte occIndex + cle a une liste DEJA triee par temps : compteur chronologique
-- par sort (la Nieme occurrence du sort X => "X:N"). Stable et coherent entre les
-- deux representations (abilities / phases).
local function NumberOccurrences(list, prefix)
    local counts = {}
    local pre = prefix and (tostring(prefix) .. "|") or ""
    for _, o in ipairs(list) do
        local n = (counts[o.spellID] or 0) + 1
        counts[o.spellID] = n
        o.occIndex = n
        o.key = pre .. tostring(o.spellID) .. ":" .. n
    end
end

-- Representation SIMPLE (`boss.abilities`) : 1 sort = firstAt + k*period.
-- `phase` = cycle, base sur l'ANCRE (capacite au plus petit firstAt) : chacune de
-- ses reapparitions demarre une phase. (Comportement historique inchange.)
local function GenerateFromAbilities(boss, fightLength)
    local list = {}
    -- Seules les entrees avec `firstAt` alimentent la timeline THEORIQUE du plan.
    -- Les entrees "duration-only" (sans firstAt) ne servent qu'au matching runtime
    -- (par duree d'event serveur) -> on les ignore ici pour ne pas polluer le plan.
    local abilities = {}
    for _, ab in ipairs(boss and boss.abilities or {}) do
        if ab.firstAt ~= nil then abilities[#abilities + 1] = ab end
    end
    local anchorSpell, anchorFirst
    for _, ab in ipairs(abilities) do
        local t = ab.firstAt or 0
        local fa = ab.firstAt or 0
        if not anchorFirst or fa < anchorFirst then
            anchorFirst, anchorSpell = fa, ab.spellID
        end
        while t <= fightLength do
            list[#list + 1] = { time = t, spellID = ab.spellID, name = ab.name, aoe = ab.aoe,
                cast = ab.cast, defMarker = ab.defMarker,
                overridenName = ab.customName or ab.overridenName, allowInTimeline = ab.allowInTimeline }
            if not ab.period or ab.period <= 0 then break end
            t = t + ab.period
        end
    end
    table.sort(list, function(a, b)
        if a.time == b.time then return tostring(a.spellID) < tostring(b.spellID) end
        return a.time < b.time
    end)
    NumberOccurrences(list, boss and boss._tlVariant)
    -- Phases : seulement si >=2 capacites (avec une seule, c'est un sort qui se
    -- repete, pas une rotation a regrouper -> tout en phase 1, aucun separateur).
    if #abilities >= 2 then
        local phase, anchorSeen = 1, 0
        for _, o in ipairs(list) do
            if o.spellID == anchorSpell then anchorSeen = anchorSeen + 1; phase = anchorSeen end
            o.phase = phase
        end
    else
        for _, o in ipairs(list) do o.phase = 1 end
    end
    return list
end

-- Representation RICHE (`boss.phases`) : une PHASE = plusieurs sorts a offsets fixes,
-- qui se repete. Generalise le cas simple (phase a 1 event).
--   boss.phases = { phase, ... }
--   phase = { [name], firstAt, period, [count], events = { {spellID, name, at, [aoe]}, ... } }
--     firstAt : debut de la 1re instance de la phase (s depuis le pull)
--     period  : la phase se repete tous les `period` s ; nil/<=0 => une seule fois
--     count   : nombre max de repetitions (optionnel ; sinon jusqu'a fightLength)
--     event.at: offset (s) du sort depuis le DEBUT de la phase
-- Les instances de phase sont numerotees par ordre de debut => champ `phase` (separateur).
local function GenerateFromPhases(boss, fightLength)
    -- Deroule les instances de chaque phase (debut + reference au patron).
    local instances = {}
    for _, p in ipairs(boss.phases or {}) do
        local k = 0
        while true do
            local start = (p.firstAt or 0) + k * (p.period or 0)
            if start > fightLength then break end
            instances[#instances + 1] = { start = start, phase = p }
            if not p.period or p.period <= 0 then break end
            if p.count and (k + 1) >= p.count then break end
            k = k + 1
            if k > 1000 then break end          -- garde-fou anti-boucle
        end
    end
    table.sort(instances, function(a, b) return a.start < b.start end)

    local list = {}
    for num, inst in ipairs(instances) do
        for _, ev in ipairs(inst.phase.events or {}) do
            local t = inst.start + (ev.at or 0)
            if t >= 0 and t <= fightLength then
                list[#list + 1] = {
                    time            = t,
                    spellID         = ev.spellID,
                    name            = ev.name,
                    aoe             = ev.aoe,
                    cast            = ev.cast,
                    defMarker       = ev.defMarker,
                    overridenName   = ev.customName or ev.overridenName,
                    allowInTimeline = ev.allowInTimeline,
                    phase           = num,
                    phaseName       = inst.phase.name,
                }
            end
        end
    end
    table.sort(list, function(a, b)
        if a.time == b.time then return tostring(a.spellID) < tostring(b.spellID) end
        return a.time < b.time
    end)
    NumberOccurrences(list, boss and boss._tlVariant)
    return list
end

-- Le boss a-t-il une timeline exploitable (representation `abilities` OU `phases`) ?
function HR.BossHasTimeline(boss)
    if not boss then return false end
    if boss.phases and #boss.phases > 0 then return true end
    if boss.abilities and #boss.abilities > 0 then return true end
    return false
end

-- Genere la liste chronologique des occurrences sur `fightLength` secondes.
-- Dispatche selon la representation du boss : `phases` (riche) sinon `abilities`.
function HR.GenerateOccurrences(boss, fightLength)
    fightLength = fightLength or HR.FIGHT_LENGTH
    local list
    if boss and boss.phases then
        list = GenerateFromPhases(boss, fightLength)
    else
        list = GenerateFromAbilities(boss, fightLength)
    end
    -- Fusionne les reglages joueur (nom custom + flag timeline + son), matching par id.
    -- Le PLAN garde tous les sorts ; le filtrage timeline se fait chez le consommateur
    -- (HR.FilterTimeline, cote runtime), pas ici.
    if boss and HR.ApplyBossSpellSettings then
        HR.ApplyBossSpellSettings(boss.id, list)
    end
    return list
end

-- Instant d'AFFICHAGE/USAGE du defensif d'une occurrence, selon son marqueur :
--   castStart = `castStart` (theorique = occ.time ; live = instant de l'event matche),
--   castEnd   = castStart + occ.cast. Sans defMarker => castStart (retro-compatible).
-- offset en MILLISECONDES. Modes : BEFORE/AFTER x CAST_START/CAST_END.
function HR.OccDefTime(occ, castStart)
    castStart = castStart or occ.time
    local m = occ.defMarker
    if not m then return castStart end
    local off     = (m.offset or 0) / 1000
    local castEnd = castStart + (occ.cast or 0)
    local mode    = m.mode
    if mode == "BEFORE_CAST_START" then return castStart - off
    elseif mode == "AFTER_CAST_START" then return castStart + off
    elseif mode == "BEFORE_CAST_END" then return castEnd - off
    elseif mode == "AFTER_CAST_END" then return castEnd + off end
    return castStart
end

