-- HealPlanner - Constants.lua
-- Le second argument vararg de chaque fichier d'addon est une table privee
-- partagee entre tous les fichiers de l'addon. On y stocke tout l'etat.
local addonName, HR = ...

HR.ADDON_NAME = addonName
HR.VERSION = C_AddOns.GetAddOnMetadata(addonName, "Version") or "0.0.0"

-- Version du CLIENT WoW (string complete, ex. "12.1.0"), lue via GetBuildInfo au
-- chargement. Sert de cle de selection de la table de contenu statique par version :
-- cf. Data/Content.lua (HR.contentByVersion). Ciblage patch-exact => a mettre a jour
-- dans contentByVersion a chaque nouveau build cible.
HR.CLIENT_VERSION = GetBuildInfo()

-- Prefixe utilise pour les messages de chat de l'addon.
HR.CHAT_PREFIX = "|cff33ff99ECP|r: "

-- Couleurs reutilisables (format |cAARRGGBB).
HR.COLORS = {
    GREEN = "|cff33ff99",
    RED = "|cffff5555",
    YELLOW = "|cffffd100",
    RESET = "|r",
}

-- Duree de combat theorique utilisee pour generer les occurrences (5 min).
HR.FIGHT_LENGTH = 300

-- Schema des SavedVariables par defaut. Toute nouvelle cle ajoutee ici sera
-- fusionnee dans la DB existante au chargement (voir Database.lua).
HR.DB_DEFAULTS = {
    enabled = true,
    debug = false,      -- messages de debug (persiste le flag de session HR.debug)
    minimap = { hide = false },
    -- "What's new" : derniere VERSION pour laquelle la modale a ete masquee (case cochee).
    -- account-wide (racine, hors profil). Differente de HR.VERSION => modale re-affichee a l'init.
    whatsNewVersion = "",
    -- Variantes de plan par donjon. dungeons[dungeonID] = { usedVariant, variants }.
    dungeons = {},
    nextVariantId = 1,  -- compteur d'ID de variante (unique, stable)
    plans = {},         -- ANCIEN store (par encounterID) : conserve pour migration
    -- Reglages joueur par sort de boss (case Activer / nom custom / son) :
    -- bossSpells[encounterID][spellID] = { enabled, name, playSound, sound }
    bossSpells = {},
    -- "Available Externals" : quantite de chaque CD de groupe (hors heal) declaree
    -- dispo dans le groupe. externals[defKey] = nombre. (UI pour l'instant.)
    externals = {},
    -- Variante de timeline active choisie par le joueur, par boss (encounterID) :
    -- bossTimelineVariant[encounterID] = <id de variante> (ex. "4-1-1"). Cf. Content.lua.
    bossTimelineVariant = {},
    ui = {},            -- positions de fenetres : ui[key] = { point, relPoint, x, y }
    healerDefaults = {},-- placements EDITES des variantes par defaut : [profileKey] = assignments
    options = {         -- reglages d'affichage de la boite runtime
        uiScale        = 1.0,                 -- echelle de la fenetre principale + modales (PAS le runtime)
        hideOOC        = true,                -- masque (alpha 0) hors combat / hors encounter
        variantSpecOnly = false,              -- popup de variantes : n'afficher que les variantes de la SPE heal active du joueur
        showSyncedPlans = false,              -- popup de variantes : afficher UNIQUEMENT les plans recus par sync (bypasse variantSpecOnly)
        upcomingEnabled = true,               -- Upcoming bar affichee (independante de la Timeline)
        upcomingHideNext = false,             -- masquer le "what's next" (container 1 : prochain sort)
        upcomingHideName = false,             -- masquer le nom du sort de boss dans l'Upcoming bar
        upcomingThreshold = 5,                -- (s) fenetre avant le hit ou la box s'affiche (3-15)
        upcomingMineOnly = false,             -- ne montrer que les defensifs du joueur (sa classe)
        upcomingPlayerCDs = true,             -- afficher le container 2 (CD perso + external du joueur)
        upcomingScale  = 1.0,
        upcomingBg     = { 0, 0, 0, 0.85 },   -- couleur de fond {r,g,b,a}
        upcomingVertical = false,             -- Personal Timeline en COLONNE (true) au lieu de RANGEE (false)
        upcomingHeals    = false,             -- afficher aussi les CD de HEAL du joueur (healer only)
        upcomingMax      = 0,                 -- Personal Timeline : nb max de sorts A VENIR affiches (0 = tous)
        commLayout    = "horizontal",         -- LEGACY ("horizontal"|"vertical") : ne sert plus qu'a
                                              -- inferer commColumns (cf. HR.Runtime.CommColumns) ;
                                              -- commColumns N'EST PAS seede ici (sinon ecrase l'infer)
        commDisabled  = false,                 -- desactive ENTIEREMENT la Communication bar
        commReverse   = false,                 -- inverse l'ordre des boutons
        commNonHealer = false,                 -- afficher la comm bar meme en role NON-soigneur
        commPing      = true,                  -- clic sur un CD = ping natif "assist" du proprietaire (en plus du /p)
        commScale     = 1.0,
        commBg        = { 0, 0, 0, 0.6 },      -- couleur de fond de la communication bar
        -- Announcement : icones ACCUMULEES (une par defensif "mien" sous le seuil), timer overlay
        -- AU CENTRE de chaque icone. Plus aucun texte de nom. Couleur du timer = compo "announce"
        -- textColor. Rangee horizontale centree (ancre haut-centre).
        announceDisabled  = false,             -- desactive la feature
        announceShowAll   = false,             -- montre TOUS les sorts du plan (pas seulement les miens)
        announceThreshold = 5,                  -- (s) seuil d'apparition (3-15) = fenetre d'accumulation
        announceIconSize  = 32,                 -- taille des icones (le timer overlay suit la taille)
        announceGlowMine  = false,              -- "Glow mine" : glow proc sur les icones annoncees
        -- Alerte SONORE autonome (cf. Core/TTS.lua) : son propre seuil, decouple de
        -- l'Upcoming bar / Timeline / Announcement. Joue le son N s avant l'usage planifie.
        alertThreshold    = 5,                   -- (s) seuil de declenchement du son (0-5)
        -- Mode Timeline (reproduction de la timeline native : icones poussees par le
        -- serveur qui defilent du haut vers le bas + CD defensifs planifies). Quand
        -- actif, remplace l'Upcoming bar (cf. UI/TimelineBox.lua).
        timelineMode      = false,             -- bascule entre Upcoming bar et Timeline
        timelineWindow    = 30,                -- fenetre d'anticipation affichee (s)
        timelineScale     = 1.0,
        timelineTextColor = { 1, 1, 1 },       -- couleur du compte a rebours (centre de l'icone)
        timelineTextSize  = 14,                -- taille du compte a rebours
        -- Progress bars : representation ALTERNATIVE de la timeline, INDEPENDANTE de la timeline
        -- d'icones (on peut afficher les DEUX ; plus d'exclusivite, cf. UI/ProgressBars.lua).
        -- Consomme le MEME producteur (HR.Runtime.TimelineBossEvents). Placement/resize en mode test.
        timelineProgressBars = false,          -- ON => affiche les barres (en plus/au lieu de la timeline)
        progressGrow         = "down",         -- "down"|"up" : sens d'ajout des barres suivantes
        progressWindow       = 30,             -- look-ahead propre aux barres (s)
        progressTextSize     = 12,             -- taille du texte des barres (nom + decompte)
        progressBarWidth     = 220,            -- largeur d'UNE barre (repere, regle au resize)
        progressBarHeight    = 22,             -- hauteur d'UNE barre (repere, regle au resize)
        -- Masque les timers des AUTRES bossmods qui font doublon avec les notres
        -- (BigWigs/LittleWigs, DBM, timeline native Blizzard). Cf. Core/ForeignBars.lua.
        -- OFF par defaut : on ne desactive jamais l'UI d'un autre addon sans accord.
        hideOtherBossMods    = false,
        -- Accroche les icones des defensifs planifies aux barres BigWigs/LittleWigs
        -- (cf. Core/BossModAttach.lua). EXCLUSIF avec hideOtherBossMods : masquer les
        -- barres et les decorer n'a aucun sens ensemble.
        attachDefsToBossMods = false,
    },
}

HR.DB_CHAR_DEFAULTS = {}
