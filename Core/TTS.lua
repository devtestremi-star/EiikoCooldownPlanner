-- HealPlanner - Core/TTS.lua
-- Annonce vocale (Text-To-Speech NATIF, C_VoiceChat.SpeakText) du defensif qui TE
-- concerne, quand son icone de timeline passe sous le seuil. Branche sur le bus de
-- hooks de la timeline (cf. UI/TimelineBox.lua). Aucune lib, aucun fichier embarque.
--
-- API 12.0 : SpeakText(voiceID, text, rate, volume [, overlap]) -- le parametre
-- `destination` a ete SUPPRIME en 12.0.0 (pas de "canal" comme PlaySoundFile ; le TTS
-- sort par le systeme vocal au volume donne -> equivalent "master").
local addonName, HR = ...

local TTS_VOLUME = 100   -- 0..100 (plein volume = "master-equivalent")
local TTS_RATE   = 0     -- ~ -10..10 (0 = normal)

-- Liste des voix TTS installees (cote OS), exposee a l'UI. Peut etre VIDE (aucun pack
-- vocal Windows) -> on n'annonce simplement pas.
function HR.GetTtsVoices()
    if C_VoiceChat and C_VoiceChat.GetTtsVoices then return C_VoiceChat.GetTtsVoices() or {} end
    return {}
end

-- Voix AUTO : 1re voix dont le nom contient "english", sinon la 1re de la liste (= ordre
-- pilote par la locale du client WoW -> souvent la voix de ta langue de jeu). Mise en cache.
local cachedAuto
local function AutoVoiceID()
    if cachedAuto then return cachedAuto end
    local voices = HR.GetTtsVoices()
    if not voices[1] then return nil end
    for _, v in ipairs(voices) do
        if (v.name or ""):lower():find("english") then cachedAuto = v.voiceID; break end
    end
    cachedAuto = cachedAuto or voices[1].voiceID
    return cachedAuto
end

-- voiceID effectif : override joueur (Opt().alertVoice) sinon AUTO (anglais si dispo).
local function GetVoiceID()
    local o = HR.db and HR.db.options
    if o and o.alertVoice ~= nil then return o.alertVoice end
    return AutoVoiceID()
end

-- Libelle d'une voix pour le dropdown (nil = Auto).
function HR.AlertVoiceName(voiceID)
    if voiceID == nil then return "Auto (English if available)" end
    for _, v in ipairs(HR.GetTtsVoices()) do
        if v.voiceID == voiceID then return v.name end
    end
    return "Voice " .. tostring(voiceID)
end

-- Dit un texte via le TTS natif (sous pcall : entree non critique).
function HR.SpeakTTS(text)
    if not text or text == "" then return end
    if not (C_VoiceChat and C_VoiceChat.SpeakText) then return end
    local voiceID = GetVoiceID()
    if not voiceID then return end
    pcall(C_VoiceChat.SpeakText, voiceID, text, TTS_RATE, TTS_VOLUME, false)
end

--------------------------------------------------------------------------------
-- ALERTES sonores : quand un de TES sorts (defensif OU external) est requis (icone qui
-- passe sous le seuil), on joue le son/la voix configure. Deux reglages SEPARES :
--   * defensif (perso)  -> HR.db.options.alertDefEnabled / alertDefSound
--   * external (groupe)  -> HR.db.options.alertExtEnabled / alertExtSound
-- Le choix de son = un id de SOUNDKIT (numerique) OU une option TTS :
--   "TTS_DEF" -> lit "Defensive" ; "TTS_EXT" -> lit le NOM REEL de l'external.
--------------------------------------------------------------------------------

local TTS_DEF, TTS_EXT, TTS_CD = "TTS_DEF", "TTS_EXT", "TTS_CD"

-- Choix proposes dans les dropdowns d'alerte = sons communs (sans `kind`, montres partout) +
-- options TTS taguees par `kind` ("def"|"ext"|"heal") -> chaque dropdown ne montre QUE le TTS
-- de son type (cf. filtre dans UI/ConfigFrame.lua).
HR.ALERT_SOUND_CHOICES = {}
for _, c in ipairs(HR.BOSS_SOUND_CHOICES or {}) do
    HR.ALERT_SOUND_CHOICES[#HR.ALERT_SOUND_CHOICES + 1] = c
end
HR.ALERT_SOUND_CHOICES[#HR.ALERT_SOUND_CHOICES + 1] = { name = "TTS Defensive", id = TTS_DEF, kind = "def" }
HR.ALERT_SOUND_CHOICES[#HR.ALERT_SOUND_CHOICES + 1] = { name = "TTS External",  id = TTS_EXT, kind = "ext" }
HR.ALERT_SOUND_CHOICES[#HR.ALERT_SOUND_CHOICES + 1] = { name = "TTS [CD]",      id = TTS_CD,  kind = "heal" }

-- Canal de sortie commun a TOUS les sons d'alerte (PlaySound). Le TTS n'a pas de canal
-- (sort par le systeme vocal). "Master" = ignore les reglages de volume par categorie.
HR.ALERT_CHANNELS = { "Master", "SFX", "Music", "Ambience", "Dialog" }
local function AlertChannel()
    local o = HR.db and HR.db.options
    return (o and o.alertChannel) or "Master"
end

-- Libelle d'un choix de son d'alerte (bouton du dropdown).
function HR.AlertSoundName(id)
    if id == nil then return "None" end
    if id == TTS_DEF then return "TTS Defensive" end
    if id == TTS_EXT then return "TTS External" end
    if id == TTS_CD then return "TTS [CD]" end
    return HR.BossSoundName(id)
end

-- Nom REEL a LIRE (TTS External / TTS [CD]) : nom du sort sans le suffixe de CD "(3 min)".
-- Renvoie nil si non resolu (PlayAlertSound applique alors un repli de demo).
local function SpokenName(defID)
    local d = defID and HR.ResolveDefEntry(defID)
    local n = d and d.name
    if n then return (n:gsub("%s*%b()%s*$", "")) end
    return nil
end

-- Joue un choix de son d'alerte. `spoken` = nom reel a lire pour TTS External / TTS [CD]
-- (sinon repli de demo : AMZ / Celestial Conduit).
function HR.PlayAlertSound(id, spoken)
    if id == nil then return end
    if id == TTS_DEF then HR.SpeakTTS("Defensive")
    elseif id == TTS_EXT then HR.SpeakTTS(spoken or "Anti Magic Zone")
    elseif id == TTS_CD then HR.SpeakTTS(spoken or "Celestial Conduit")
    elseif type(id) == "number" then PlaySound(id, AlertChannel()) end
end

-- Apercu depuis l'UI (selection dans le dropdown) : sans nom reel -> replis de demo.
function HR.PreviewAlertSound(id)
    HR.PlayAlertSound(id)
end

-- ============================================================================
-- Moteur d'alerte SONORE AUTONOME (aucun rendu UI : il joue juste les sons).
-- Decouple des autres composants : il INTERROGE la timeline backend
-- (HR.Schedule.Active) avec son PROPRE seuil (options.alertThreshold, 0-5 s) au lieu
-- de consommer l'event "threshold" partage (qui suit le seuil de l'Upcoming bar).
-- A.Tick est appele par l'OnUpdate de la boite runtime (cf. UI/RuntimeBox.lua), a la
-- meme cadence que HR.Schedule.Tick. EDGE one-shot par defensif (reset au pull).
-- ============================================================================
HR.Alerts = HR.Alerts or {}
local A = HR.Alerts

-- Joue le bon son pour un defensif requis de TOI. Classe en 3 types : external
-- (`external`) / CD de heal (`role == "HEALER"`) / defensif (le reste). On ne joue QUE
-- si tu peux reellement utiliser ce sort (chasseur sans external -> jamais l'alerte
-- external ; SMALL_DEF generique -> defensif pour tous) et si le toggle du type est on.
local function fireAlert(token)
    local o = HR.db and HR.db.options
    if not o then return end
    local d = HR.ResolveDefEntry(token)
    if not HR.PlayerCanUseDefensive(d) then return end   -- requis de TOI uniquement
    if d and d.external then
        if o.alertExtEnabled then HR.PlayAlertSound(o.alertExtSound, SpokenName(token)) end
    elseif d and d.role == "HEALER" then
        if o.alertHealEnabled then HR.PlayAlertSound(o.alertHealSound, SpokenName(token)) end
    else
        if o.alertDefEnabled then HR.PlayAlertSound(o.alertDefSound) end
    end
end

-- Tick par frame : detecte le franchissement du seuil SONORE propre. Independant des seuils
-- Upcoming/Timeline/Announcement.
-- ⚠ MODE TEST : on ne joue JAMAIS de son (le visuel reste : glow/upcoming). Le test sert a
-- placer/regler l'UI, pas a preview le son (l'apercu de son se fait via le dropdown d'options).
local fired, firedPull = {}, nil
function A.Tick(now)
    now = now or GetTime()
    local s = HR.Runtime and HR.Runtime.state
    if not s then return end
    if s.mode == "test" then return end       -- aucun son en mode test
    if firedPull ~= s.pullTime then fired = {}; firedPull = s.pullTime end
    local o = HR.db and HR.db.options
    if not o then return end
    -- Aucune alerte activee -> ne rien scanner.
    if not (o.alertDefEnabled or o.alertExtEnabled or o.alertHealEnabled) then return end
    local thr = o.alertThreshold or 5
    if thr < 0 then thr = 0 elseif thr > 5 then thr = 5 end
    for _, e in ipairs(HR.Schedule.Active(now)) do
        local rem = (e.baseTime + e.offset / 1000) - now    -- temps EFFECTIF (offset compris)
        if rem <= thr and rem > -0.5 then
            local key = tostring(e.token) .. "@" .. tostring(e.occKey)
            if not fired[key] then
                fired[key] = true
                fireAlert(e.token)
            end
        end
    end
end
