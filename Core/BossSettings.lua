-- HealPlanner - Core/BossSettings.lua
-- Reglages JOUEUR par sort de boss (case Activer, nom custom, son a jouer).
-- Persistes dans la DB, indexes par encounterID puis par spellID (matching PAR ID :
-- toutes les occurrences d'un meme sort partagent le meme reglage).
--   HR.db.bossSpells[encounterID][spellID] = { enabled=bool, name=string,
--                                              playSound=bool, sound=number,
--                                              barColor={r,g,b,a} }
-- Les VALEURS PAR DEFAUT viennent de la data statique (Data/Content.lua) :
--   allowInTimeline (bool, defaut true) et overridenName (string|nil). La DB ne
--   stocke que les ECARTS du joueur ; la resolution fusionne defaut + override.
local addonName, HR = ...

-- Couleur de barre PAR DEFAUT (quand le joueur n'a defini aucun override). Alignee sur la
-- couleur de StatusBar des progress bars (UI/ProgressBars.lua). Sert au swatch de l'UI ;
-- l'application reelle a la barre en combat viendra plus tard.
HR.DEFAULT_BAR_COLOR = { 0.20, 0.50, 0.90, 0.85 }

--------------------------------------------------------------------------------
-- Sons Blizzard proposes (preview a la selection ; jeu reel en combat = plus tard)
--------------------------------------------------------------------------------

-- SOUNDKIT.* sont des constantes globales ; repli numerique si absente (la valeur
-- exacte importe peu : un id inconnu ne joue rien, sans erreur).
local function sk(name, fallback)
    return (type(SOUNDKIT) == "table" and SOUNDKIT[name]) or fallback
end

HR.BOSS_SOUND_CHOICES = {
    { name = "Raid Warning", id = sk("RAID_WARNING", 8959) },
    { name = "Ready Check",  id = sk("READY_CHECK", 8960) },
    { name = "Alarm Clock",  id = sk("ALARM_CLOCK_WARNING_3", 12867) },
    { name = "Bell Toll",    id = sk("TELL_MESSAGE", 3081) },
}

-- Libelle d'un id de son (pour le bouton de selection). Repli generique.
function HR.BossSoundName(id)
    if not id then return "None" end
    for _, c in ipairs(HR.BOSS_SOUND_CHOICES) do
        if c.id == id then return c.name end
    end
    return "Sound " .. tostring(id)
end

--------------------------------------------------------------------------------
-- Store DB (override par spellID, scope par boss)
--------------------------------------------------------------------------------

-- Enregistrement d'override d'un sort. create=true alloue la table au passage.
function HR.GetBossSpellOverride(encounterID, spellID, create)
    if not HR.db or encounterID == nil or spellID == nil then return nil end
    local store = HR.db.bossSpells
    if not store then
        if not create then return nil end
        store = {}
        HR.db.bossSpells = store
    end
    local enc = store[encounterID]
    if not enc then
        if not create then return nil end
        enc = {}
        store[encounterID] = enc
    end
    local rec = enc[spellID]
    if not rec and create then
        rec = {}
        enc[spellID] = rec
    end
    return rec
end

-- Supprime l'enregistrement s'il est vide (toutes valeurs par defaut) pour garder
-- la DB propre et laisser les futurs changements de defaut s'appliquer.
local function PruneIfEmpty(encounterID, spellID)
    local rec = HR.GetBossSpellOverride(encounterID, spellID, false)
    if not rec then return end
    if rec.enabled == nil and rec.name == nil and rec.playSound == nil and rec.sound == nil
        and rec.barColor == nil then
        HR.db.bossSpells[encounterID][spellID] = nil
    end
end

-- Ecrit une valeur d'override (value=nil => efface ce champ). `field` parmi
-- "enabled" | "name" | "playSound" | "sound" | "barColor" (table {r,g,b,a}).
function HR.SetBossSpellOverride(encounterID, spellID, field, value)
    local rec = HR.GetBossSpellOverride(encounterID, spellID, true)
    if not rec then return end
    rec[field] = value
    PruneIfEmpty(encounterID, spellID)
end

--------------------------------------------------------------------------------
-- Resolution (defauts statiques + override DB)
--------------------------------------------------------------------------------

-- Resout l'affichage/comportement d'un sort de boss. `ab` = entree statique
-- (ability OU event de phase), nilable ; `spellID` deduit de `ab` si absent.
-- Renvoie { spellID, enabled, name, defaultName, playSound, sound }.
function HR.ResolveBossSpell(encounterID, ab, spellID)
    spellID = spellID or (ab and ab.spellID)
    local rec = HR.GetBossSpellOverride(encounterID, spellID, false)

    local enabled = true
    if rec and rec.enabled ~= nil then
        enabled = rec.enabled and true or false
    elseif ab and ab.allowInTimeline == false then
        enabled = false
    end

    local defaultName = (ab and (ab.overridenName or ab.name)) or tostring(spellID)
    local name = defaultName
    if rec and type(rec.name) == "string" and rec.name ~= "" then
        name = rec.name
    end

    return {
        spellID     = spellID,
        enabled     = enabled,
        name        = name,
        defaultName = defaultName,
        playSound   = (rec and rec.playSound) and true or false,
        sound       = rec and rec.sound or nil,
        barColor    = (rec and rec.barColor) or nil,   -- nil = pas d'override (defaut HR.DEFAULT_BAR_COLOR)
    }
end

-- Applique les reglages sur une liste d'occurrences deja generee (matching par id) :
-- nom custom (DB > overridenName statique > nom d'origine) + flag `allowInTimeline`
-- resolu + infos de son. Mute la liste en place et la renvoie.
function HR.ApplyBossSpellSettings(encounterID, list)
    for _, o in ipairs(list or {}) do
        local rec = HR.GetBossSpellOverride(encounterID, o.spellID, false)
        if rec and type(rec.name) == "string" and rec.name ~= "" then
            o.name = rec.name
        elseif o.overridenName and o.overridenName ~= "" then
            o.name = o.overridenName
        end
        local enabled = true
        if rec and rec.enabled ~= nil then
            enabled = rec.enabled and true or false
        elseif o.allowInTimeline == false then
            enabled = false
        end
        o.allowInTimeline = enabled
        o.playSound = (rec and rec.playSound) and true or false
        o.sound = rec and rec.sound or nil
    end
    return list
end

-- Retire les occurrences DESACTIVEES (allowInTimeline=false) pour les affichages
-- "timeline" (runtime live + test / TimelineBox). Le PLAN (ConfigFrame) n'est PAS
-- filtre ici : il continue d'afficher tous les sorts (avec leur nom custom).
function HR.FilterTimeline(list)
    local out = {}
    for _, o in ipairs(list or {}) do
        if o.allowInTimeline ~= false then
            out[#out + 1] = o
        end
    end
    return out
end

-- Liste DEDUPLIQUEE (par spellID) des sorts d'un boss, dans l'ordre de declaration
-- (abilities puis events de phase). Pour l'UI de reglages (1 ligne par sort).
function HR.GetBossSpells(boss)
    local seen, list = {}, {}
    local function add(sp)
        if not sp or sp.spellID == nil or seen[sp.spellID] then return end
        seen[sp.spellID] = true
        list[#list + 1] = sp
    end
    if boss then
        for _, ab in ipairs(boss.abilities or {}) do add(ab) end
        for _, p in ipairs(boss.phases or {}) do
            for _, ev in ipairs(p.events or {}) do add(ev) end
        end
    end
    return list
end
