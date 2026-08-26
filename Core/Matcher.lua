-- HealPlanner - Core/Matcher.lua
-- Reconnaissance d'un sort de boss par la DUREE d'annonce serveur (lisible meme quand
-- le spellID est secret en M+). Donnees : Data/Content.lua (`durations`/`durationGroups`).
--   - duree unique => 1 sort.
--   - duree partagee => `durationGroups[d]` :
--       * liste ordonnee  -> CYCLE   : choix = liste[((count-1) % N)+1]
--       * { kind="threshold", first, rest } -> SEUIL : 1ere occ = first, sinon rest
--            (rest = spellID unique, OU liste = cycle a partir de la 2e occ)
--   - compteur PAR duree, remis a zero au pull (cf. RuntimeBox StartLive).
-- Le lien vers l'occurrence PLANIFIEE se fait par le NOM (les ids de la data de durees
-- peuvent differer de ceux du plan ; le nom est commun) : HR.PlanIdFor.
local addonName, HR = ...

local EPS = 0.2   -- tolerance d'appariement de duree (arrondi / jitter serveur)

-- Index par boss (cache faible).
local cache = setmetatable({}, { __mode = "k" })

local function build(boss)
    local idx = {
        durs         = {},   -- liste des durees connues (recherche du plus proche)
        byDur        = {},   -- [duree] = { spellID, ... }
        byDurPhase   = {},   -- [duree][phase] = { spellID, ... } : resolution scopee par phase (optionnel)
        planOkByDurPhase = {}, -- [duree][phase] = { bool, ... } : parallele a byDurPhase (allowedInPlan~=false de chaque entree)
        tolByDur     = {},   -- [duree] = tolerance d'appariement (defaut EPS ; elargie via { d, tol=x })
        groups       = boss.durationGroups or {},
        phaseTransitions = boss.phaseTransitions or {}, -- [duree] = phase cible (marqueur de transition)
        nameById     = {},   -- [spellID] = nom (sorts portant des durees)
        planIdByName = {},   -- [nom] = spellID utilise dans le PLAN (phases / abilities firstAt)
    }
    local seen = {}
    -- `d` = nombre, OU { valeur, tol = x } pour une fenetre d'appariement elargie (jitter serveur
    -- important : ex. un cast dont la duree d'annonce varie de +-1s). tol par defaut = EPS.
    local function addDur(d, spellID, phase, planOk)
        local val, tol = d, nil
        if type(d) == "table" then val, tol = d[1], d.tol end
        idx.byDur[val] = idx.byDur[val] or {}
        idx.byDur[val][#idx.byDur[val] + 1] = spellID
        idx.tolByDur[val] = math.max(idx.tolByDur[val] or EPS, tol or EPS)
        if not seen[val] then seen[val] = true; idx.durs[#idx.durs + 1] = val end
        if phase ~= nil then   -- index secondaire scope par phase (peuple SEULEMENT si l'ability tague `phase`)
            idx.byDurPhase[val] = idx.byDurPhase[val] or {}
            local lst = idx.byDurPhase[val][phase] or {}
            lst[#lst + 1] = spellID
            idx.byDurPhase[val][phase] = lst
            -- Parallele : plan-linkable de CETTE entree (display-only => on bloquera le lien plan cote runtime,
            -- pour un sort P1 qui partage son NOM avec une occurrence planifiee en P2 : cf. Gilded Destruction).
            idx.planOkByDurPhase[val] = idx.planOkByDurPhase[val] or {}
            local pl = idx.planOkByDurPhase[val][phase] or {}
            pl[#pl + 1] = planOk
            idx.planOkByDurPhase[val][phase] = pl
        end
    end
    for _, ab in ipairs(boss.abilities or {}) do
        if ab.durations then
            idx.nameById[ab.spellID] = ab.name
            for _, d in ipairs(ab.durations) do addDur(d, ab.spellID, ab.phase, ab.allowedInPlan ~= false) end
        end
    end
    for d in pairs(idx.groups) do                 -- defensif : cle de groupe toujours connue
        if not seen[d] then seen[d] = true; idx.durs[#idx.durs + 1] = d end
    end
    for d in pairs(idx.phaseTransitions) do       -- defensif : durees-marqueurs toujours resolvables par nearest()
        if not seen[d] then seen[d] = true; idx.durs[#idx.durs + 1] = d end
    end
    -- ids du PLAN (ceux des occurrences generees) : events de phase + abilities a firstAt.
    local function reg(sp)
        if sp and sp.spellID and sp.name and idx.planIdByName[sp.name] == nil then
            idx.planIdByName[sp.name] = sp.spellID
        end
    end
    for _, ab in ipairs(boss.abilities or {}) do
        if ab.firstAt ~= nil then reg(ab) end
    end
    for _, p in ipairs(boss.phases or {}) do
        for _, ev in ipairs(p.events or {}) do reg(ev) end
    end
    return idx
end

local function getIndex(boss)
    local idx = cache[boss]
    if not idx then idx = build(boss); cache[boss] = idx end
    return idx
end

local function nearest(idx, raw)
    if type(raw) ~= "number" then return nil end
    local best, bestDiff
    for _, d in ipairs(idx.durs) do
        local diff = math.abs(d - raw)
        local tol = idx.tolByDur[d] or EPS
        if diff <= tol and (not bestDiff or diff < bestDiff) then best, bestDiff = d, diff end
    end
    return best
end

-- Reconnait le sort d'un event serveur par sa duree. `counters` = etat par duree
-- (remis a zero au pull). Renvoie spellID, nom (ou nil si duree inconnue), planOk.
-- `planOk` (bool, defaut true) = le sort resolu est-il planifiable ? false = entree display-only
-- (allowedInPlan=false) resolue par phase -> le runtime NE relie PAS au plan (evite qu'un sort P1
-- homonyme d'un sort planifie en P2 tire le defensif P2 en P1). Toujours true hors resolution par phase.
function HR.MatchByDuration(boss, rawDuration, counters, phase)
    if not boss then return nil end
    local idx = getIndex(boss)
    local d = nearest(idx, rawDuration)
    if not d then return nil end
    counters[d] = (counters[d] or 0) + 1   -- increment INCONDITIONNEL (les groupes coexistants cyclent pareil)
    local n = counters[d]
    local id
    local planOk = true
    -- Precedence #1 : resolution scopee par phase. Consultee UNIQUEMENT si l'appelant fournit une
    -- `phase` ET que la duree est taguee pour cette phase par exactement un sort. Sinon (phase nil ou
    -- aucune data taguee) la branche est sautee => chemin legacy identique au bit pres.
    local ph = phase and idx.byDurPhase[d] and idx.byDurPhase[d][phase]
    if ph and #ph == 1 then
        id = ph[1]
        local pl = idx.planOkByDurPhase[d] and idx.planOkByDurPhase[d][phase]
        if pl and pl[1] == false then planOk = false end
    else
        local g = idx.groups[d]
        if g then
            if g.kind == "threshold" then
                -- seuil : 1re occ = `first` ; ensuite `rest` = spellID unique OU liste (cycle a partir de n=2).
                if n == 1 then id = g.first
                elseif type(g.rest) == "table" then id = g.rest[((n - 2) % #g.rest) + 1]
                else id = g.rest end
            else
                id = g[((n - 1) % #g) + 1]
            end
        else
            local lst = idx.byDur[d]
            if lst and #lst == 1 then id = lst[1] end -- duree UNIQUE ; sinon ambigu => nil (log amont)
        end
    end
    return id, idx.nameById[id], planOk
end

-- Phase cible si `rawDuration` est un marqueur de transition declare (boss.phaseTransitions), sinon nil.
-- A appeler AVANT MatchByDuration cote runtime pour que l'ouverture de la nouvelle phase resolve dans
-- le bon scope. LECTURE SEULE : ne touche aucun compteur ni etat.
function HR.PhaseTransitionFor(boss, rawDuration)
    if not boss then return nil end
    local idx = getIndex(boss)
    local d = nearest(idx, rawDuration)
    if not d then return nil end
    return idx.phaseTransitions[d]
end

-- spellID du PLAN correspondant au sort reconnu (mappe par NOM). nil s'il n'a pas
-- d'occurrence planifiee (sort importe seulement pour la timeline, pas pour le plan).
function HR.PlanIdFor(boss, name)
    if not boss or not name then return nil end
    return getIndex(boss).planIdByName[name]
end
