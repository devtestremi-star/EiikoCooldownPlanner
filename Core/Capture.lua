-- HealPlanner - Core/Capture.lua
-- Outil de capture des IDs reels pour remplir Data/Content.lua :
--   - encounterID (+ nom) via l'event ENCOUNTER_START a chaque pull de boss ;
--   - zone courante (instanceID / uiMapID) via GetInstanceInfo.
-- Active/desactive par /hp scan (flag de session HR.capture, off au demarrage).
local addonName, HR = ...

-- Imprime les infos de la zone courante (zoneID + journalInstanceID pour l'EJ).
function HR.PrintZoneInfo()
    local name, instanceType, _, _, _, _, _, instanceID = GetInstanceInfo()
    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local journalID = (EJ_GetInstanceForMap and mapID) and EJ_GetInstanceForMap(mapID) or nil
    HR:Print(("Zone: \"%s\" | type=%s | %szoneID(instanceID)=%s%s | uiMapID=%s | journalInstanceID=%s")
        :format(tostring(name), tostring(instanceType),
            HR.COLORS.YELLOW, tostring(instanceID), HR.COLORS.RESET,
            tostring(mapID), tostring(journalID)))
end

-- ENCOUNTER_START(encounterID, encounterName, difficultyID, groupSize)
local function OnEncounterStart(self, encounterID, encounterName)
    if not HR.capture then return end
    local zoneName, _, _, _, _, _, _, instanceID = GetInstanceInfo()
    HR:Print(("|cff33ff99CAPTURE|r %sencounterID=%s%s  name=\"%s\"  (zone \"%s\", instanceID=%s)")
        :format(HR.COLORS.YELLOW, tostring(encounterID), HR.COLORS.RESET,
            tostring(encounterName), tostring(zoneName), tostring(instanceID)))
end

-- HR.eventFrame / HR:RegisterEvent sont definis dans Events.lua (charge avant).
HR:RegisterEvent("ENCOUNTER_START", OnEncounterStart)

--------------------------------------------------------------------------------
-- /hp gather : journalise la TIMELINE SERVEUR (C_EncounterTimeline) du boss.
-- En Midnight 12.0 le combat log (CLEU) n'est plus accessible aux addons ; on lit
-- donc les events pousses par le serveur (spellID, nom, temps restant). Chaque
-- event est logge une fois (a sa 1re apparition) avec son heure de declenchement
-- estimee (vu + reste), relative a l'activation. Persiste dans HealPlannerDB.gatherLog.
--------------------------------------------------------------------------------

local ET = C_EncounterTimeline

-- Active/desactive le gather. Renvoie le nouvel etat (bool).
function HR.SetGather(on)
    HR.gather = on and true or false
    if HR.gather then
        HR.gatherStart = GetTime()
        if HR.db then HR.db.gatherLog = {} end
    end
    return HR.gather
end

-- Journalisation event-driven : le serveur pousse chaque capacite a venir.
HR:RegisterEvent("ENCOUNTER_TIMELINE_EVENT_ADDED", function(_, eventInfo)
    if not HR.gather then return end
    if type(eventInfo) ~= "table" then return end

    -- En contenu restreint, spellID/spellName/iconFileID sont des Secret Values :
    -- toute operation (tostring/format) leve une erreur. On protege chaque champ.
    local function safe(getter)
        local ok, v = pcall(function() return tostring(getter()) end)
        return ok and v or "<secret>"
    end

    local seen = HR.gatherStart and (GetTime() - HR.gatherStart) or 0
    local line = string.format("+%.1fs  id=%s  spellID=%s  \"%s\"  duration=%s",
        seen,
        safe(function() return eventInfo.id end),
        safe(function() return eventInfo.spellID end),
        safe(function() return eventInfo.spellName end),
        safe(function() return eventInfo.duration end))

    HR:Print("|cff66ccff[gather]|r " .. line)
    if HR.db then
        HR.db.gatherLog = HR.db.gatherLog or {}
        HR.db.gatherLog[#HR.db.gatherLog + 1] = line
    end
end)

--------------------------------------------------------------------------------
-- Diagnostic : etat de C_EncounterTimeline + log de TOUS les events de timeline,
-- pour savoir si la feature est alimentee/active sur l'encounter teste.
--------------------------------------------------------------------------------

function HR.PrintTimelineStatus()
    if not ET then
        HR:Print("|cffff5555C_EncounterTimeline ABSENT|r (API unavailable on this client).")
        return
    end
    local function call(fn) return (ET[fn]) and tostring(ET[fn]()) or "n/a" end
    local n = "n/a"
    if ET.GetSortedEventList then
        local l = ET.GetSortedEventList()
        n = l and tostring(#l) or "nil"
    end
    local blz = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_EncounterTimeline")
    HR:Print(("C_EncounterTimeline: present | IsFeatureAvailable=%s | IsFeatureEnabled=%s | GetSortedEventList=%s | Blizzard_EncounterTimeline loaded=%s")
        :format(call("IsFeatureAvailable"), call("IsFeatureEnabled"), n, tostring(blz)))
end

-- Loggue les AUTRES events de timeline (en plus de _ADDED ci-dessus) quand gather
-- est actif : permet de voir si la moindre activite de timeline arrive.
local TL_DIAG_EVENTS = {
    "ENCOUNTER_TIMELINE_EVENT_REMOVED",
    "ENCOUNTER_TIMELINE_EVENT_STATE_CHANGED",
    "ENCOUNTER_TIMELINE_EVENT_HIGHLIGHT",
    "ENCOUNTER_TIMELINE_EVENT_BLOCK_STATE_CHANGED",
    "ENCOUNTER_TIMELINE_EVENT_TRACK_CHANGED",
    "ENCOUNTER_TIMELINE_LAYOUT_UPDATED",
    "ENCOUNTER_TIMELINE_STATE_UPDATED",
    "ENCOUNTER_TIMELINE_VIEW_ACTIVATED",
    "ENCOUNTER_TIMELINE_VIEW_DEACTIVATED",
}
for _, ev in ipairs(TL_DIAG_EVENTS) do
    HR:RegisterEvent(ev, function(_, a1)
        if not HR.gather then return end
        HR:Print("|cffff8800[TL]|r " .. ev .. "  arg=" .. tostring(a1))
    end)
end

--------------------------------------------------------------------------------
-- /ecp devscan : capture STRUCTUREE de la timeline serveur pour AUTORING de la data
-- (Data/Content.lua). PTR nouvelle saison : les boss sont inconnus, on les decouvre en
-- direct. Chaque ENCOUNTER_START (si actif) ouvre un RECORD ; chaque event ADDED y ajoute
-- une ligne avec tout ce qu'il faut pour ecrire `durations` / `durationGroups` / `at`/`firstAt`
-- avec la strategie de matching par DUREE (cf. Core/Matcher.lua). Persiste dans la
-- SavedVariable dediee ECPDevScan (SEPAREE de la DB des plans -> aucune donnee sacree touchee).
-- Historique conserve pull apres pull (seul `clear` vide). Tourne en parallele de /hp gather
-- et du runtime (multi-handlers, cf. Core/Events.lua).
--------------------------------------------------------------------------------

local function scanEnsure()
    if type(ECPDevScan) ~= "table" then ECPDevScan = {} end
    if type(ECPDevScan.records) ~= "table" then ECPDevScan.records = {} end
    return ECPDevScan
end

function HR.DevScanEnabled()
    return type(ECPDevScan) == "table" and ECPDevScan.enabled == true
end

-- Dernier record (encounter courant), ou nil si aucun pull capture.
local function scanCurrent()
    local S = ECPDevScan
    return (type(S) == "table" and S.records) and S.records[#S.records] or nil
end

-- (Dé)active la capture. N'EFFACE PAS l'historique (accumule les pulls) ; seul Clear vide.
function HR.SetDevScan(on)
    local S = scanEnsure()
    S.enabled = on and true or false
    return S.enabled
end

-- Vide les records SANS changer l'etat actif.
function HR.DevScanClear()
    local S = scanEnsure()
    S.records = {}
end

-- Arrondi 0.1 (convention d'ecriture des `durations` ; le runtime tolere +-0.2, cf. Matcher EPS).
local function round1(x)
    return math.floor((tonumber(x) or 0) * 10 + 0.5) / 10
end

-- Lit un champ potentiellement SECRET (spellID/spellName/iconFileID en contenu restreint) sans
-- jamais lever ni le comparer : stocke la string affichable, ou "<secret>". Cf. HR.DevSafe.
local function safeField(getter)
    local ok, v = pcall(function() return tostring(getter()) end)
    return ok and v or "<secret>"
end

-- ENCOUNTER_START(self, encounterID, encounterName, difficultyID, groupSize) : ouvre un record.
-- Handler DEDIE (laisse OnEncounterStart / HR.capture intact).
HR:RegisterEvent("ENCOUNTER_START", function(_, encounterID, encounterName, difficultyID)
    if not HR.DevScanEnabled() then return end
    local S = scanEnsure()
    local _, _, _, _, _, _, _, instanceID = GetInstanceInfo()
    S.records[#S.records + 1] = {
        encounterID   = encounterID,                    -- arg lisible (normal event)
        encounterName = encounterName,                  -- arg lisible
        difficultyID  = difficultyID,                   -- arg lisible
        zoneID        = instanceID,                     -- 8e retour de GetInstanceInfo
        startedAt     = (date and date("%H:%M:%S")) or "?",
        pullTime      = GetTime(),                       -- NOTRE horloge de pull (t = depuis ici)
        events        = {},
        durCount      = {},                              -- ordinal par duree arrondie
        seen          = {},                              -- dedup re-ADDED par eventInfo.id
    }
    HR:Print(("|cff33ff99[devscan]|r new record #%d  encounterID=%s  \"%s\"  zoneID=%s")
        :format(#S.records, tostring(encounterID), tostring(encounterName), tostring(instanceID)))
end)

-- ENCOUNTER_TIMELINE_EVENT_ADDED : append un event au record courant. id/duration LISIBLES ;
-- spellID/spellName/iconFileID via safeField (Secret Values en M+). t = (now - pull) + rem.
HR:RegisterEvent("ENCOUNTER_TIMELINE_EVENT_ADDED", function(_, eventInfo)
    if not HR.DevScanEnabled() then return end
    if type(eventInfo) ~= "table" or eventInfo.id == nil then return end
    local rec = scanCurrent()
    if not rec then return end                          -- actif mais pas encore d'encounter

    rec.seen = rec.seen or {}
    if rec.seen[eventInfo.id] then return end           -- dedup re-ADD (pas de double ordinal)
    rec.seen[eventInfo.id] = true

    -- rem = temps restant avant declenchement (GetEventTimeRemaining prioritaire, fallback duration).
    local rawDur = tonumber(eventInfo.duration) or 0
    local rem = rawDur
    if ET and ET.GetEventTimeRemaining then
        local ok, r = pcall(ET.GetEventTimeRemaining, eventInfo.id)
        if ok and type(r) == "number" then rem = r end
    end
    local t = (GetTime() - (rec.pullTime or GetTime())) + rem

    local durR = round1(rawDur)
    rec.durCount = rec.durCount or {}
    rec.durCount[durR] = (rec.durCount[durR] or 0) + 1

    rec.events[#rec.events + 1] = {
        t         = round1(t),
        dur       = rawDur,                             -- precision pleine (lisible)
        durR      = durR,
        ord       = rec.durCount[durR],                 -- ordinal par duree -> CYCLE vs THRESHOLD
        id        = eventInfo.id,                       -- lisible meme en M+
        spellID   = safeField(function() return eventInfo.spellID end),
        spellName = safeField(function() return eventInfo.spellName end),
        icon      = safeField(function() return eventInfo.iconFileID end),
    }
end)

-- Apercu chat du dernier record (sans /reload) : entete + N derniers events.
function HR.DevScanShow(n)
    local rec = scanCurrent()
    if not rec then HR:Print("|cff33ff99[devscan]|r no record captured yet."); return end
    n = n or 30
    HR:Print(("|cff33ff99[devscan]|r \"%s\"  encounterID=%s  zoneID=%s  events=%d")
        :format(tostring(rec.encounterName), tostring(rec.encounterID),
            tostring(rec.zoneID), #rec.events))
    local from = math.max(1, #rec.events - n + 1)
    for i = from, #rec.events do
        local e = rec.events[i]
        HR:Print(("  +%.1fs  dur=%.1f  ord#%d  id=%s  spellID=%s  \"%s\"")
            :format(e.t, e.durR, e.ord, tostring(e.id), tostring(e.spellID), tostring(e.spellName)))
    end
end

-- Construit un texte Lua-commentaire COPIABLE (dernier record) : entete + 1 ligne/event +
-- section SUMMARY (duree -> occurrences ordonnees) qui suggere `durations` / `durationGroups`.
-- Pur assemblage de strings (aucune IO). Champs deja stringifies (secret-safe a la capture).
function HR.DevScanExportString()
    local S = ECPDevScan
    if type(S) ~= "table" or type(S.records) ~= "table" or #S.records == 0 then
        return "-- devscan: no records. /ecp devscan (ON), pull a boss, then /ecp devscan copy."
    end
    local rec = S.records[#S.records]
    local out = {}
    local function add(s) out[#out + 1] = s end

    add("-- ECP DevScan export")
    add("-- ============================================================")
    add(("-- Encounter: \"%s\"  encounterID=%s  zoneID=%s  difficulty=%s")
        :format(tostring(rec.encounterName), tostring(rec.encounterID),
            tostring(rec.zoneID), tostring(rec.difficultyID)))
    add(("-- started %s   events=%d   (record %d of %d)")
        :format(tostring(rec.startedAt), #rec.events, #S.records, #S.records))
    add("-- NB: casts au PULL sans event serveur = invisibles ici -> a ajouter a la main.")
    add("-- ------------------------------------------------------------")
    add("-- EVENTS  (t = secondes depuis le pull -> at / firstAt)")
    for _, e in ipairs(rec.events) do
        add(("--   +%-6.1fs  dur=%-5.1f (raw %s)  ord#%d  id=%s  spellID=%s  \"%s\"")
            :format(e.t, e.durR, tostring(e.dur), e.ord, tostring(e.id),
                tostring(e.spellID), tostring(e.spellName)))
    end
    add("-- ------------------------------------------------------------")
    add("-- SUMMARY: durees distinctes -> occurrences  (ecrire `durations` / `durationGroups`)")

    -- Buckets par duree arrondie, dans l'ordre d'apparition (= ordre d'ord).
    local order, bucket = {}, {}
    for _, e in ipairs(rec.events) do
        if not bucket[e.durR] then bucket[e.durR] = {}; order[#order + 1] = e.durR end
        local b = bucket[e.durR]
        b[#b + 1] = { spellID = e.spellID, name = e.spellName }
    end
    table.sort(order)
    for _, d in ipairs(order) do
        local b = bucket[d]
        local parts = {}
        local distinct, firstID, secret = {}, nil, false
        for i, occ in ipairs(b) do
            parts[#parts + 1] = ("[%d] %s \"%s\""):format(i, tostring(occ.spellID), tostring(occ.name))
            firstID = firstID or occ.spellID
            if occ.spellID == "<secret>" then secret = true end
            distinct[occ.spellID] = true
        end
        local nDistinct = 0
        for _ in pairs(distinct) do nDistinct = nDistinct + 1 end
        local hint
        if secret then
            hint = "-> spellID <secret> (M+) : rejouer en difficulte NON restreinte pour les obtenir"
        elseif nDistinct <= 1 then
            hint = ("-> UNIQUE : durations = { %s, ... }"):format(tostring(d))
        else
            local ids, seenId = {}, {}
            for _, occ in ipairs(b) do
                if not seenId[occ.spellID] then seenId[occ.spellID] = true; ids[#ids + 1] = occ.spellID end
            end
            local cycle = table.concat(ids, ", ")
            hint = ("-> SHARED : durationGroups[%s] = { %s } (CYCLE) | { kind=\"threshold\", first=%s, rest=%s }")
                :format(tostring(d), cycle, tostring(ids[1]), tostring(ids[2]))
        end
        add(("--   dur %-5s x%d :  %s   %s"):format(tostring(d), #b, table.concat(parts, "  "), hint))
    end
    add("-- ============================================================")
    return table.concat(out, "\n")
end

--------------------------------------------------------------------------------
-- SCAN DU GUIDE DE L'AVENTURIER (Encounter Journal) : nom + spellID des capacites
-- d'un boss, SANS pull. Sert a resoudre/confirmer les spellID (sorts renommes, entrees
-- BIDON, donjons stubs) : ouvrir le Guide sur le boss puis `/ecp journal`. Lecture SEULE
-- (aucune ecriture DB). `jeid` = journalEncounterID (celui de la fenetre ouverte,
-- EncounterJournal.encounterID) -- DIFFERENT du dungeonEncounterID stocke dans
-- Data/Content.lua (`id`). EJ_GetEncounterInfo expose les deux -> on affiche le
-- dungeonEncounterID pour reconnaitre le boss. Sortie = lignes `{ spellID, name }`
-- pretes a coller dans un `abilities`.
--------------------------------------------------------------------------------
function HR.JournalScanExport(jeid)
    jeid = tonumber(jeid)
    if not jeid then
        return "-- Aucun boss selectionne. Ouvre le Guide de l'aventurier sur un boss, puis relance."
    end
    if not (EJ_GetEncounterInfo and C_EncounterJournal and C_EncounterJournal.GetSectionInfo) then
        return "-- API Encounter Journal indisponible (ouvre le Guide au moins une fois dans la session)."
    end
    -- Certaines versions exigent la selection prealable pour peupler l'arbre de sections.
    pcall(function() if EJ_SelectEncounter then EJ_SelectEncounter(jeid) end end)
    local name, _, _, rootSectionID, _, _, dungeonEncID = EJ_GetEncounterInfo(jeid)

    local out, seen = {}, {}
    local function add(s) out[#out + 1] = s end
    add("-- ============================================================")
    add(("-- JOURNAL SCAN : %s  (journalEncounterID=%s  dungeonEncounterID=%s)")
        :format(tostring(name or "?"), tostring(jeid), tostring(dungeonEncID or "?")))
    add("-- Colle les spellID voulus dans le `abilities` du boss (id = dungeonEncounterID) de Content.lua.")
    add("-- ------------------------------------------------------------")

    local count = 0
    local function walk(sid, depth)
        local guard = 0
        while sid and sid > 0 and guard < 1000 do
            if seen[sid] then break end
            seen[sid] = true
            guard = guard + 1
            local info = C_EncounterJournal.GetSectionInfo(sid)
            if not info then break end
            if info.spellID and info.spellID > 0 then
                count = count + 1
                add(("    { spellID = %d, name = \"%s\" },")
                    :format(info.spellID, tostring(info.title or ""):gsub("\"", "'")))
            end
            if info.firstChildSectionID and info.firstChildSectionID > 0 and depth < 30 then
                walk(info.firstChildSectionID, depth + 1)
            end
            sid = info.siblingSectionID
        end
    end

    if rootSectionID and rootSectionID > 0 then
        walk(rootSectionID, 0)
    else
        add("-- (pas de section racine lisible : ouvre le Guide SUR CE boss, puis relance /ecp journal)")
    end
    add(("-- ------------------------------------------------------------  %d capacite(s)"):format(count))
    add("-- ============================================================")
    return table.concat(out, "\n")
end

--------------------------------------------------------------------------------
-- /ecp comms : SONDE DE LISIBILITE des cooldowns du JOUEUR (lui SEUL).
--
-- BUT : repondre a la question qui bloque tout tracking coopératif de CD (cf. le modele
-- de LowDurbTracker) -- « en combat, en contenu restreint, que puis-je encore LIRE de MON
-- PROPRE cooldown ? ». On ne sonde donc QUE le joueur : `UNIT_SPELLCAST_SUCCEEDED` filtre
-- sur unit == "player". Aucune lecture sur un autre membre du groupe (impossible en 12.0).
--
-- ⚠ POINT CRITIQUE : chaque champ est teste SEPAREMENT (`duration` vs `startTime`,
-- et les 4 champs de charges). Les addons existants les testent ENSEMBLE et concluent
-- « secret » des qu'un seul l'est -- on ne sait donc pas si l'autre passait. C'est
-- exactement l'inconnue qu'on veut lever ici.
--
-- Lecture SEULE : aucune ecriture DB (sortie console + miroir dans ECPDevLog si /ecp devlog
-- est actif). Flag de session `HR.comms`, off au demarrage.
--------------------------------------------------------------------------------

-- Sondes differees : une valeur illisible a l'instant du cast peut se stabiliser juste apres.
local COMMS_DELAYS = { 0, 0.5 }

-- En dessous de ce CD de base (s), un sort est un filler : sonder sa lisibilite n'apprend rien.
-- Filtre applique UNIQUEMENT si la base est elle-meme lisible (sinon on garde, cf. commsKeep).
local COMMS_MIN_BASE = 5

-- Handler declare en amont : l'enregistrement est PARESSEUX (cf. SetComms). UNIT_SPELLCAST_SUCCEEDED
-- fire pour TOUS les membres du groupe, en continu ; on ne l'ecoute donc qu'une fois la sonde
-- demandee. HR:RegisterEvent est append-only (cf. Core/Events.lua) => le flag empeche les doublons.
local commsHandler, commsRegistered

function HR.CommsEnabled()
    return HR.comms == true
end

-- (Dé)active la sonde. Renvoie le nouvel etat (bool).
function HR.SetComms(on, logAll)
    HR.comms = on and true or false
    if HR.comms then
        HR.commsStart = GetTime()
        HR.commsAll = logAll and true or false
        if not commsRegistered then
            commsRegistered = true
            HR:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", commsHandler)
        end
    end
    return HR.comms
end

-- Index inverse spellID -> cle de HR.defensives (les cles peuvent etre "51052:0" pour les
-- variantes de CD). Construit a la demande ; on ne veut qu'un libelle de diagnostic, donc
-- la premiere variante rencontree suffit.
local commsDefIndex
local function commsDefKey(spellID)
    if not commsDefIndex then
        commsDefIndex = {}
        for key, d in pairs(HR.defensives or {}) do
            local sid = tonumber(d and d.spellID) or tonumber(key)
            if sid and not commsDefIndex[sid] then commsDefIndex[sid] = key end
        end
    end
    return commsDefIndex[spellID]
end

-- Lit un champ potentiellement SECRET et dit s'il est REELLEMENT lisible.
-- ⚠ Ne PAS utiliser HR.DevSafe ici : `tostring` REUSSIT sur une Secret Value (on peut
-- l'AFFICHER sans la lire, cf. CLAUDE.md), donc un pcall ne detecte RIEN. Seul
-- `issecretvalue` tranche. Renvoie (texte colore, estLisible).
local function commsProbe(v)
    if v == nil then return "nil", nil end
    if issecretvalue and issecretvalue(v) then
        return HR.COLORS.RED .. "<secret>" .. HR.COLORS.RESET, false
    end
    local ok, s = pcall(tostring, v)
    if not ok then return "<err>", false end
    return HR.COLORS.GREEN .. s .. HR.COLORS.RESET, true
end

-- CD de base en ms (reste lisible en 12.0 : ignore talents/hate). Renvoie (texte, valeurSecondes|nil).
local function commsBase(spellID)
    if not GetSpellBaseCooldown then return "n/a", nil end
    local ok, ms = pcall(GetSpellBaseCooldown, spellID)
    if not ok then return "<err>", nil end
    local txt, readable = commsProbe(ms)
    local seconds = (readable and tonumber(ms)) and (tonumber(ms) / 1000) or nil
    return txt, seconds
end

-- Une ligne de sonde a l'instant `tag`. Chaque champ est teste independamment.
local function commsSnapshot(spellID, tag)
    local baseTxt = commsBase(spellID)

    local cdTxt = "n/a"
    if C_Spell and C_Spell.GetSpellCooldown then
        local ok, info = pcall(C_Spell.GetSpellCooldown, spellID)
        if not ok then
            cdTxt = "<call err>"
        elseif type(info) ~= "table" then
            cdTxt = "nil"
        else
            -- Parentheses obligatoires : commsProbe renvoie 2 valeurs, et un appel en
            -- DERNIERE position d'une liste d'arguments s'y developpe entierement.
            cdTxt = ("duration=%s start=%s enabled=%s modRate=%s")
                :format(commsProbe(info.duration), commsProbe(info.startTime),
                    commsProbe(info.isEnabled), (commsProbe(info.modRate)))
        end
    end

    local chgTxt = "n/a"
    if C_Spell and C_Spell.GetSpellCharges then
        local ok, c = pcall(C_Spell.GetSpellCharges, spellID)
        if not ok then
            chgTxt = "<call err>"
        elseif type(c) ~= "table" then
            chgTxt = "nil (pas de charges)"
        else
            chgTxt = ("cur=%s max=%s cdDuration=%s cdStart=%s")
                :format(commsProbe(c.currentCharges), commsProbe(c.maxCharges),
                    commsProbe(c.cooldownDuration), (commsProbe(c.cooldownStartTime)))
        end
    end

    HR:Print(("|cffffd100[comms]|r   %s  base(ms)=%s"):format(tag, baseTxt))
    HR:Print(("|cffffd100[comms]|r     GetSpellCooldown: %s"):format(cdTxt))
    HR:Print(("|cffffd100[comms]|r     GetSpellCharges : %s"):format(chgTxt))

    -- Miroir dans le devlog (no-op si /ecp devlog est OFF) : les couleurs restent, sans gene.
    HR.DevLog("comms", "%s base=%s | cd: %s | charges: %s", tag, baseTxt, cdTxt, chgTxt)
end

-- Faut-il sonder ce cast ? On ne jette QUE les fillers confirmes (base lisible ET courte) :
-- si la base est secrete/absente on garde, car c'est peut-etre justement un cas interessant.
local function commsKeep(spellID)
    if HR.commsAll then return true end
    if commsDefKey(spellID) then return true end
    local _, seconds = commsBase(spellID)
    if seconds == nil then return true end
    return seconds >= COMMS_MIN_BASE
end

-- UNIT_SPELLCAST_SUCCEEDED(unit, castGUID, spellID) -- SEUL le joueur est sonde.
commsHandler = function(_, unit, _, spellID)
    if not HR.comms then return end
    if unit ~= "player" then return end

    -- Le spellID de CE canal est lisible pour ses propres casts (contrairement a celui de
    -- C_EncounterTimeline, secret en M+). On verifie quand meme avant tout usage : la suite
    -- s'en sert comme CLE DE TABLE, ce qui leverait sur une Secret Value.
    if type(spellID) ~= "number" or (issecretvalue and issecretvalue(spellID)) then
        HR:Print("|cffffd100[comms]|r " .. HR.COLORS.RED
            .. "spellID ILLISIBLE sur son propre cast" .. HR.COLORS.RESET
            .. " (invalide le modele coopératif)")
        HR.DevLog("comms", "spellID secret sur cast joueur")
        return
    end

    if not commsKeep(spellID) then return end

    local elapsed = HR.commsStart and (GetTime() - HR.commsStart) or 0
    local name = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)) or "?"
    local defKey = commsDefKey(spellID)
    -- GetInstanceInfo : name, instanceType, difficultyID, difficultyName, ...
    local _, instanceType, difficultyID, difficultyName = GetInstanceInfo()

    HR:Print(("|cffffd100[comms]|r +%.1fs  %s%s%s (%d)%s  combat=%s  %s/diff=%s")
        :format(elapsed, HR.COLORS.YELLOW, tostring(name), HR.COLORS.RESET, spellID,
            defKey and ("  " .. HR.COLORS.GREEN .. "[DEF " .. tostring(defKey) .. "]" .. HR.COLORS.RESET) or "",
            InCombatLockdown() and "ON" or "off",
            tostring(instanceType), tostring(difficultyName or difficultyID)))
    HR.DevLog("comms", "CAST %s (%d)%s combat=%s %s/diff=%s", tostring(name), spellID,
        defKey and (" [DEF " .. tostring(defKey) .. "]") or "",
        InCombatLockdown() and "ON" or "off", tostring(instanceType), tostring(difficultyName or difficultyID))

    for _, delay in ipairs(COMMS_DELAYS) do
        if delay <= 0 then
            commsSnapshot(spellID, "probe@0.0")
        else
            C_Timer.After(delay, function()
                if HR.comms then commsSnapshot(spellID, ("probe@%.1f"):format(delay)) end
            end)
        end
    end
end

-- Etat de la sonde + rappel de ce qu'on cherche.
function HR.PrintCommsStatus()
    HR:Print(("|cffffd100[comms]|r %s | filtre=%s | secretAPI=%s")
        :format(HR.comms and (HR.COLORS.GREEN .. "ON" .. HR.COLORS.RESET)
                          or (HR.COLORS.RED .. "OFF" .. HR.COLORS.RESET),
            HR.commsAll and "aucun (tous les casts)" or ("defensifs + base >= " .. COMMS_MIN_BASE .. "s"),
            issecretvalue and "issecretvalue present" or (HR.COLORS.RED .. "issecretvalue ABSENT" .. HR.COLORS.RESET)))
end
