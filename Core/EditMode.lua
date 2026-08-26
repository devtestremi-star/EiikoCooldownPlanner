-- EiikoCooldownPlanner - Core/EditMode.lua
-- Rattache nos fenetres HUD a l'UNLOCK MODE d'EllesmereUI (son edit mode maison, `/unlock`).
-- Sans EllesmereUI, ce fichier ne fait STRICTEMENT rien.
--
-- Pourquoi : aujourd'hui la seule facon de deplacer un cadre HUD est de lancer le MODE TEST
-- (HR.Runtime.AnchorsVisible() n'est vrai qu'en `state.mode == "test"`). Un edit mode externe
-- supprime ce detour.
--
-- MEMES REGLES QUE Core/ForeignBars.lua, sans exception :
--   * detection par DUCK-TYPING sur _G (jamais IsAddOnLoaded, jamais un test sur le nom du
--     dossier : le packager d'EUI renomme son core en EUICoreStandalone* pour les builds
--     standalone) ;
--   * INTERDIT d'ecrire dans EllesmereUIDB ou dans la SavedVariable d'un autre addon ;
--   * pcall sur chaque appel etranger, Init() idempotent, tout est runtime-only et reversible.
--
-- QUI POSSEDE QUOI (le point qui structure tout le fichier) :
--   EUI deplace le cadre pendant le drag (ClearAllPoints + SetPoint sur UIParent) puis appelle
--   NOS callbacks. Il n'ecrit rien chez nous : les positions restent dans HR.db.ui[key], donc
--   toujours PAR PROFIL d'affichage.
--
-- ⚠️ CONFLIT D'UNITES -- la raison pour laquelle savePos ignore les coordonnees d'EUI :
--   EUI convertit en CENTER/CENTER et raisonne en unites UIParent BRUTES (il divise par
--   l'echelle du cadre au moment du SetPoint). Nous, HR.SaveFramePosTopLeft stocke du TOPLEFT
--   DANS L'ECHELLE DU CADRE (ratio UIParent/frame, cf. Core/Util.lua). Melanger les deux
--   ferait deriver toute fenetre dont le module a un scale != 1. On garde donc UNE seule
--   convention -- la notre : au moment du save le cadre vient d'etre deplace, le rect est a
--   jour, ce qui est exactement le contrat de SaveFramePosTopLeft (drag/reset).
--
-- ⚠️ noInitHook = true sur TOUS nos elements : EUI ne re-applique JAMAIS notre position. Sans
--   ca son ApplySavedPositions appellerait applyPos au login pour CHAQUE element enregistre,
--   meme ceux que isHidden() declare masques. C'est HR.ApplyActiveProfile() qui reste seul
--   maitre de l'application, et le profil garde la main.
local addonName, HR = ...

HR.EditMode = HR.EditMode or {}
local EM = HR.EditMode

local FOLDER = "EiikoCooldownPlannerDev"   -- attribue l'element a notre addon (export/import EUI)
local GROUP  = "Eiiko Cooldown Planner"    -- intitule du groupe dans la fenetre d'unlock
local OWNER  = "EiikoCooldownPlanner"      -- cle du listener de session
-- Prefixe des libelles affiches sur les movers : la fenetre d'unlock melange les elements de
-- TOUS les addons, un "Timeline" nu ne dit pas a qui il appartient. Applique une seule fois,
-- dans MakeDescriptor -> les entrees de ELEMENTS restent lisibles.
local PREFIX = "ECP - "

-- Options RELUES a chaque appel : HR.db.options est re-pointe a chaque changement de profil
-- (Core/Database.lua) -- une reference gardee deviendrait silencieusement perimee.
local function Opt() return (HR.db and HR.db.options) or {} end

--------------------------------------------------------------------------------
-- Les elements exposes
--------------------------------------------------------------------------------

-- La Communication bar (`comm`) est VOLONTAIREMENT ABSENTE : HealPlannerCommBar est le parent
-- de boutons SecureActionButtonTemplate. EUI refuse d'ouvrir l'unlock mode en combat et
-- suspend la session si le combat eclate, mais son garde `frame:IsProtected()` ne se declenche
-- PAS pour un cadre nu qui se contente de CONTENIR des boutons securises -- rien ne nous
-- protegerait d'un SetPoint tainte sur ce conteneur precis. Elle garde son drag maison.
local ELEMENTS = {
    {
        key = "ECP_Upcoming", label = "Upcoming bar", order = 600, dbKey = "runtime",
        frame  = function() return HR.UI and HR.UI.runtimeBox end,
        hidden = function() return Opt().upcomingEnabled == false end,
        save   = function(f) HR.SaveFramePosTopLeft("runtime", f) end,
    },
    {
        key = "ECP_Timeline", label = "Timeline", order = 601, dbKey = "timeline",
        frame  = function() return HR.UI and HR.UI.timelineBox end,
        hidden = function() return Opt().timelineMode ~= true end,
        save   = function(f) HR.SaveFramePosTopLeft("timeline", f) end,
    },
    {
        key = "ECP_Progress", label = "Progress bars", order = 602, dbKey = "progress",
        frame  = function() return HR.UI and HR.UI.progressBox end,
        hidden = function() return Opt().timelineProgressBars ~= true end,
        save   = function(f) HR.SaveFramePosTopLeft("progress", f) end,
        -- Seul element redimensionnable : sa taille EST celle d'une barre (cf. UI/ProgressBars).
        -- Meme ecriture que la poignee de resize maison, pour que les deux chemins coincident.
        setW = function(w)
            Opt().progressBarWidth = math.floor(w + 0.5)
            if HR.Runtime and HR.Runtime.ApplyProgressOptions then HR.Runtime.ApplyProgressOptions() end
        end,
        setH = function(h)
            Opt().progressBarHeight = math.floor(h + 0.5)
            if HR.Runtime and HR.Runtime.ApplyProgressOptions then HR.Runtime.ApplyProgressOptions() end
        end,
    },
    {
        key = "ECP_Announce", label = "Announcement", order = 603, dbKey = "announce",
        frame  = function() return HR.UI and HR.UI.announceBox end,
        hidden = function() return Opt().announceDisabled == true end,
        -- EXCEPTION documentee : banniere CENTREE -> ancre HAUT-CENTRE, sinon elle se decale
        -- horizontalement des que la largeur du contenu change.
        save   = function(f) HR.SaveFramePosTop("announce", f) end,
    },
}

--------------------------------------------------------------------------------
-- Construction d'un descripteur EUI
--------------------------------------------------------------------------------

local function MakeDescriptor(EUI, e)
    return EUI.MakeUnlockElement({
        key   = e.key,
        label = PREFIX .. e.label,
        group = GROUP,
        order = e.order,

        -- Resolution PARESSEUSE : si le joueur s'est connecte EN COMBAT, HR.Runtime.PreBuild
        -- est sorti tot et aucun cadre HUD n'existe -- EUI se contente alors de ne pas creer
        -- de mover. Rien a gerer de plus.
        getFrame = function() return e.frame() end,
        getSize  = function()
            local f = e.frame()
            if not f then return 0, 0 end
            return f:GetWidth() or 0, f:GetHeight() or 0
        end,

        -- Module desactive -> pas de mover (il n'y a rien a placer).
        isHidden = function() return e.hidden() and true or false end,

        -- On ne re-applique pas depuis EUI (cf. l'entete du fichier).
        noInitHook = true,
        noResize   = (e.setW == nil) or nil,
        setWidth   = e.setW and function(_, w) e.setW(w) end or nil,
        setHeight  = e.setH and function(_, h) e.setH(h) end or nil,

        -- Les coordonnees passees par EUI sont IGNOREES (conflit d'unites, cf. entete) : le
        -- cadre vient d'etre deplace, donc son rect est a jour et nos helpers sont exacts.
        savePos = function()
            local f = e.frame()
            if f then e.save(f) end
        end,

        -- nil VOLONTAIRE : EUI attend du CENTER/CENTER en unites UIParent, notre store est en
        -- TOPLEFT dans l'echelle du cadre. Avec noInitHook il n'en a pas besoin -- le mover se
        -- synchronise sur le rect du cadre vivant, loadPos ne sert que de repli pour dessiner
        -- une boite fantome quand le cadre n'existe pas. Si un mover se posait a cote du
        -- cadre, c'est ICI qu'il faudrait ecrire la conversion.
        loadPos = function() return nil end,

        -- Une position d'affichage est la SEULE classe de donnee persistee que ce codebase
        -- considere jetable (precedent : la migration de `announce`, UI/RuntimeBox.lua). Un
        -- plan, lui, ne s'efface jamais.
        clearPos = function()
            if HR.db and HR.db.ui then HR.db.ui[e.dbKey] = nil end
        end,

        applyPos = function()
            local f = e.frame()
            if f then HR.RestoreFramePos(e.dbKey, f) end
        end,
    })
end

--------------------------------------------------------------------------------
-- Session d'unlock -> mode test
--------------------------------------------------------------------------------

-- Hors combat, UpdateVisibility masque tout le HUD sauf en mode test : sans ca, l'unlock mode
-- s'ouvrirait sur des cadres invisibles et vides. On demarre donc notre mode test avec la
-- session (c'est ce que fait ItruliaQoL avec le meme listener).
-- GARDE : ne JAMAIS toucher a un encounter LIVE -- HR.Runtime.Stop() efface l'etat, ce qui
-- couperait le suivi d'un vrai combat. On ne demarre que s'il n'y a aucun etat, et on n'arrete
-- que ce qu'on a demarre.
local startedByUs = false

local function OnUnlockSession(active)
    local R = HR.Runtime
    if not R then return end
    if active then
        if R.state then return end                        -- live (ou test deja lance) : on ne touche a rien
        if R.StartTestMode then startedByUs = R.StartTestMode() and true or false end
    else
        if not startedByUs then return end
        startedByUs = false
        if R.state and R.state.mode == "test" and R.Stop then R.Stop() end
    end
end

--------------------------------------------------------------------------------
-- Amorcage
--------------------------------------------------------------------------------

-- Appele depuis Core/Core.lua (OnInitialize), APRES HR.Runtime.PreBuild. Idempotent.
-- Le calendrier d'EUI : il applique les positions ~0.6 s (ActionBars charge) a 1 s apres
-- PLAYER_ENTERING_WORLD -- s'enregistrer a PLAYER_LOGIN passe donc largement avant. Et EUI
-- accepte de toute facon les enregistrements TARDIFS (il cree le mover a la volee si une
-- session est deja ouverte).
function EM.Init()
    if EM._inited then return end

    local EUI = _G.EllesmereUI
    if not (EUI and EUI.RegisterUnlockElements and EUI.MakeUnlockElement) then return end
    EM._inited = true

    local list = {}
    for _, e in ipairs(ELEMENTS) do
        local ok, desc = pcall(MakeDescriptor, EUI, e)
        if ok and desc then list[#list + 1] = desc end
    end
    if #list == 0 then return end

    pcall(EUI.RegisterUnlockElements, EUI, list, FOLDER)

    if EUI.RegisterUnlockModeListener then
        pcall(EUI.RegisterUnlockModeListener, EUI, OWNER, function(active)
            OnUnlockSession(active and true or false)
        end)
    end

    HR:Debug("[editmode] EllesmereUI:", #list, "elements")
end
