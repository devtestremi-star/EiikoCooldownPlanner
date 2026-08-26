-- HealPlanner - Database.lua
-- Initialise les SavedVariables et applique les valeurs par defaut.
local addonName, HR = ...

-- Version de schema de la DB. A INCREMENTER pour forcer un WIPE general au prochain
-- chargement (ex. changement de format des entrees de plan : tokens string -> {token, offset}).
local DB_SCHEMA = 2

-- Appele depuis Core.lua au moment de PLAYER_LOGIN, quand les SavedVariables
-- ont ete chargees par le client.
function HR:InitDB()
    -- PREMIERE INSTALLATION (DB absente) ou BUMP de schema -> DB fraiche. Retenu AVANT le wipe
    -- pour, plus bas, CENTRER les fenetres UI (on ne PRE-PLACE pas les elements pour les joueurs).
    local freshInstall = (not HealPlannerDB) or (HealPlannerDB.schema ~= DB_SCHEMA)

    -- WIPE general : si le schema stocke ne correspond pas (premiere fois ou bump), on
    -- repart de ZERO sur les 3 SavedVariables. Les anciens plans (entrees en string) sont
    -- incompatibles avec le nouveau format inline {token, offset} -> on les efface.
    if freshInstall then
        HealPlannerDB     = { schema = DB_SCHEMA }
        HealPlannerCharDB = {}
        ECPlannerDB       = {}
    end

    -- _G[...] : les SavedVariables declarees dans le .toc sont des globales.
    HealPlannerDB = HR.ApplyDefaults(HealPlannerDB or {}, HR.DB_DEFAULTS)
    HealPlannerCharDB = HR.ApplyDefaults(HealPlannerCharDB or {}, HR.DB_CHAR_DEFAULTS)

    self.db = HealPlannerDB
    self.charDB = HealPlannerCharDB

    -- PROFILS d'AFFICHAGE : migre/active le profil (re-pointe db.options/ui/bossSpells).
    self:InitProfiles()

    -- PREMIERE INSTALLATION : positions par defaut = CENTRE de l'ecran pour TOUTES les fenetres UI
    -- (on ne PRE-PLACE pas les elements aux coins). Seede dans le profil actif (db.ui) ; les frames
    -- restaurent ces coords au PreBuild (Core.lua) / a l'ouverture de la config. N'affecte PAS les
    -- joueurs existants (freshInstall=false -> db.ui laisse tel quel). `x or` : ne rien ecraser.
    if freshInstall then
        for _, key in ipairs({ "config", "runtime", "comm", "timeline", "progress", "announce" }) do
            self.db.ui[key] = self.db.ui[key] or { point = "CENTER", relPoint = "CENTER", x = 0, y = 0 }
        end
    end

    -- NOUVEAU format (setup = spe heal + externals), SavedVariable SEPAREE de l'ancien
    -- (HealPlannerDB) pour ne rien casser. Migration ancien->nouveau a faire plus tard.
    ECPlannerDB = ECPlannerDB or {}
    -- Schema PAR DONJON : db2.dungeons[dID] = { variants, used, lastSeen }. Fresh-start
    -- depuis l'ancien format GLOBAL (db2.variants a plat) : on repart de zero (les variantes
    -- globales etaient du test).
    if ECPlannerDB.variants and not ECPlannerDB.dungeons then
        ECPlannerDB = { dungeons = {}, nextId = 1 }
    end
    ECPlannerDB.dungeons = ECPlannerDB.dungeons or {}
    ECPlannerDB.nextId   = ECPlannerDB.nextId or 1
    -- Variantes par defaut (auto-chargees a l'entree du donjon) : cle "dID:specID" -> variantId.
    -- UNE par (donjon, spe heal). Init additive (pas de bump de schema).
    ECPlannerDB.defaultVariants = ECPlannerDB.defaultVariants or {}
    self.db2 = ECPlannerDB

    -- Le concept de "Base template" (variante PRE-FOURNIE par l'addon) est retire : on nettoie
    -- les ex-base templates (coquilles vides -> supprimees ; avec plan -> converties en variantes
    -- normales). Un nouveau joueur demarre sans variante et cree la sienne (bouton New).
    HR.CleanupBaseVariants()

    HR.debug = self.db.debug    -- restaure le flag de debug (persiste au /reload)

    -- Marqueur de session dans le devlog (si actif, persiste au /reload) : delimite les runs.
    if HR.DevLog then HR.DevLog("session", "--- InitDB (login/reload) v%s ---", tostring(HR.VERSION)) end

    -- Variantes par DEFAUT : leur table est reconstruite depuis HealerDefaults.lua a
    -- chaque chargement (donc volatile). On relie leurs `assignments` a un store DB
    -- (seede une fois depuis la base .lua) pour que les editions in-game persistent.
    self.db.healerDefaults = self.db.healerDefaults or {}
    for key, def in pairs(HR.healerDefaults or {}) do
        if self.db.healerDefaults[key] == nil then
            self.db.healerDefaults[key] = HR.DeepCopy(def.assignments or {})
        end
        def.assignments = self.db.healerDefaults[key]   -- lecture/ecriture directe dans la DB
    end

    -- V1 ABANDONNE : on supprime les variantes de l'ancien format (HealPlannerDB). Les
    -- variantes V2 (ECPlannerDB / HR.db2) sont une SavedVariable distincte -> intactes.
    -- (Plus de HR.MigratePlans : il repeuplerait V1 depuis les vieux plans plats.)
    HealPlannerDB.dungeons      = {}
    HealPlannerDB.plans         = {}    -- ancien store plat (V0), abandonne aussi
    HealPlannerDB.nextVariantId = 1

    self:Debug("DB initialized, known variants:", HR.CountPlans())
end

--------------------------------------------------------------------------------
-- PROFILS d'AFFICHAGE
-- Les reglages d'AFFICHAGE (options + ui + bossSpells) sont groupes en PROFILS nommes,
-- STOCKES AU COMPTE (HealPlannerDB.profiles). Le profil ACTIF est choisi PAR PERSONNAGE
-- (HealPlannerCharDB.profile). Les donnees de PLAN (variantes/donjons/healerDefaults)
-- restent au compte, HORS profil (partagees par tous les profils).
--
-- Implementation NON invasive : on re-POINTE les racines live HR.db.options/ui/bossSpells
-- vers les sous-tables du profil actif -> tout le code existant (qui lit HR.db.options...)
-- suit automatiquement le profil, sans changement. Migration ADDITIVE (aucun bump de schema,
-- aucune donnee de plan touchee).
--------------------------------------------------------------------------------

-- Racines d'affichage qui composent un profil.
local PROFILE_KEYS = { "options", "ui", "bossSpells" }

-- Re-pointe les racines live vers le profil `name` (defauts garantis). Renvoie true si ok.
function HR:ActivateProfile(name)
    local db = self.db
    local prof = db.profiles and db.profiles[name]
    if not prof then return false end
    prof.options    = HR.ApplyDefaults(prof.options or {}, HR.DB_DEFAULTS.options)
    prof.ui         = prof.ui or {}
    prof.bossSpells = prof.bossSpells or {}
    db.options    = prof.options       -- racines live = sous-tables du profil actif
    db.ui         = prof.ui
    db.bossSpells = prof.bossSpells
    self.charDB.profile = name
    HR.activeProfile = name
    return true
end

-- Init au login : cree le store, MIGRE (1re fois) les reglages racine existants dans
-- "Default", et active le profil du personnage (defaut "Default").
function HR:InitProfiles()
    local db = self.db
    db.profiles = db.profiles or {}
    -- MIGRATION additive (1re fois) : aucun profil -> "Default" = reglages d'affichage actuels.
    if not next(db.profiles) then
        local def = {}
        for _, k in ipairs(PROFILE_KEYS) do def[k] = db[k] or {} end
        db.profiles["Default"] = def
    end
    -- Pointeur ACTIF par personnage. 1er demarrage du perso (ou profil disparu) -> Default/1er.
    local active = self.charDB.profile
    if not active or not db.profiles[active] then
        active = db.profiles["Default"] and "Default" or next(db.profiles)
        self.charDB.profile = active
    end
    self:ActivateProfile(active)
end

-- Liste TRIEE des noms de profils.
function HR.ListProfiles()
    local out = {}
    for name in pairs((HR.db and HR.db.profiles) or {}) do out[#out + 1] = name end
    table.sort(out)
    return out
end

function HR.GetActiveProfileName()
    return HR.charDB and HR.charDB.profile
end

-- Cree un profil `name`. copyFrom = nom d'un profil source (copie ses reglages) sinon vide.
-- Renvoie true si cree (false si nom vide / deja pris).
function HR.CreateProfile(name, copyFrom)
    name = name and strtrim(name) or ""
    if name == "" or not HR.db then return false end
    HR.db.profiles = HR.db.profiles or {}
    if HR.db.profiles[name] then return false end
    local src = copyFrom and HR.db.profiles[copyFrom]
    if src then
        HR.db.profiles[name] = HR.DeepCopy({ options = src.options, ui = src.ui, bossSpells = src.bossSpells })
    else
        HR.db.profiles[name] = { options = {}, ui = {}, bossSpells = {} }
    end
    return true
end

-- Renomme un profil (met a jour le pointeur actif si besoin). Renvoie true si ok.
function HR.RenameProfile(old, new)
    new = new and strtrim(new) or ""
    if not HR.db or not HR.db.profiles[old] or new == "" or HR.db.profiles[new] then return false end
    HR.db.profiles[new] = HR.db.profiles[old]
    HR.db.profiles[old] = nil
    if HR.charDB and HR.charDB.profile == old then HR.charDB.profile = new; HR.activeProfile = new end
    return true
end

-- Supprime un profil (jamais le dernier). Renvoie "reload" si l'actif a change (besoin reload),
-- "deleted" si simple suppression, false sinon.
function HR.DeleteProfile(name)
    if not HR.db or not HR.db.profiles[name] then return false end
    if #HR.ListProfiles() <= 1 then return false end                 -- garde toujours >=1 profil
    local wasActive = (HR.charDB and HR.charDB.profile == name)
    HR.db.profiles[name] = nil
    if wasActive then
        HR.charDB.profile = HR.db.profiles["Default"] and "Default" or next(HR.db.profiles)
        return "reload"
    end
    return "deleted"
end

-- Re-applique TOUT l'affichage depuis le profil ACTIF = le "non mandatory" de l'init, RE-JOUABLE
-- (par opposition au mandatory-once : creation des frames, macros, comm securisee). NE recree PAS
-- les frames. Reutilise les memes Apply* que l'init -> zero duplication de logique.
--   * Positions (db.ui) : runtime/announce/timeline/progress = libres ; comm bar (boutons
--     securises) repositionnee HORS COMBAT uniquement.
--   * Options (db.options + glow/compo) : ApplyUIScale + Apply{Upcoming,Announce,Timeline,
--     Progress,Comm}Options (ApplyCommOptions se garde deja en combat pour scale/layout).
--   * Visibilite + re-render de la config ouverte.
function HR.ApplyActiveProfile()
    local R  = HR.Runtime or {}
    local ui = HR.UI or {}
    local combat = InCombatLockdown()
    if ui.frame       then HR.RestoreFramePos("config", ui.frame) end
    if ui.runtimeBox  then HR.RestoreFramePos("runtime", ui.runtimeBox) end
    if ui.announceBox then HR.RestoreFramePos("announce", ui.announceBox) end
    if ui.timelineBox then HR.RestoreFramePos("timeline", ui.timelineBox) end
    if ui.progressBox then HR.RestoreFramePos("progress", ui.progressBox) end
    if ui.commBar and not combat then HR.RestoreFramePos("comm", ui.commBar) end
    if HR.ApplyUIScale then HR.ApplyUIScale() end
    if R.ApplyUpcomingOptions then R.ApplyUpcomingOptions() end
    if R.ApplyAnnounceOptions then R.ApplyAnnounceOptions() end
    if R.ApplyTimelineOptions then R.ApplyTimelineOptions() end
    if R.ApplyProgressOptions then R.ApplyProgressOptions() end
    if R.ApplyCommOptions     then R.ApplyCommOptions() end
    if R.UpdateVisibility     then R.UpdateVisibility() end
    -- Masquage des bossmods tiers : seul son volet "timeline Blizzard" est stateful.
    if HR.ForeignBars and HR.ForeignBars.Apply then HR.ForeignBars.Apply() end
    -- Accroche aux barres BigWigs : purge les decorations si le nouveau profil la desactive.
    if HR.BossModAttach and HR.BossModAttach.Apply then HR.BossModAttach.Apply() end
    if ui.frame and ui.frame:IsShown() and ui.RefreshRows then ui.RefreshRows() end
end

-- Bascule le profil ACTIF du personnage. HORS COMBAT : switch LIVE (ActivateProfile + re-apply,
-- pas de reload). EN COMBAT : ReloadUI (la comm bar securisee ne peut etre repositionnee/rescale).
-- No-op si deja actif/inconnu.
function HR.SwitchProfile(name)
    if not HR.db or not HR.db.profiles[name] then return false end
    if HR.charDB and HR.charDB.profile == name then return false end
    if InCombatLockdown() then
        HR.charDB.profile = name
        ReloadUI()
        return true
    end
    HR:ActivateProfile(name)
    -- Panneau Settings : ses widgets lisent leur valeur au build -> on le RECONSTRUIT pour qu'ils
    -- relisent le nouveau profil (RefreshRows -> RenderOptions -> BuildOptionsPanel). Vieux frames
    -- caches (rare action ; pas de fuite genante).
    local ui = HR.UI
    if ui then
        if ui.settingsBar  then ui.settingsBar:Hide() end
        if ui.optionsPanel then ui.optionsPanel:Hide() end
        ui.optionsPanel, ui.settingsBar, ui.profileSelect = nil, nil, nil
    end
    HR.ApplyActiveProfile()     -- inclut RefreshRows (reconstruit le panneau Settings si ouvert)
    return true
end
