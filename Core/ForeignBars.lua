-- EiikoCooldownPlanner - ForeignBars.lua
-- Masquage des timers des AUTRES bossmods, pour qu'ils ne fassent pas doublon avec les
-- notres (Timeline, Progress bars, Personal Timeline, Announcement). Option UNIQUE :
-- HR.db.options.hideOtherBossMods (onglet "Bars and Timeline").
--
-- QUATRE sources traitees :
--   A. barres de SORT BigWigs/LittleWigs  -> key numerique (spellID ou section EJ)
--   B. barres du plugin Timeline BigWigs  -> module/key nil mais "bigwigs:eventId" pose
--   C. timeline native Blizzard           -> frame globale EncounterTimeline
--   D. timers de sort DBM                 -> callback DBM_TimerBegin + DBT:CancelBar
--
-- REGLE : on ne masque QUE ce que notre addon remplace. Pull timer, break, respawn,
-- best-time, barres custom, stages/berserk restent intacts.
--
-- INTERDIT ici : ecrire dans la SavedVariable d'un autre addon (BigWigs3DB,
-- DBM_AllSavedOptions, *_AllSavedVars, DBT_AllPersistentOptions) ou dans un CVar.
-- Tout est runtime-only et reversible.
local addonName, HR = ...

HR.ForeignBars = HR.ForeignBars or {}
local FB = HR.ForeignBars

-- Table cible de BigWigsLoader.RegisterMessage (le loader refuse BigWigsLoader lui-meme).
local bwProxy = {}

-- EXCLUSIF avec attachDefsToBossMods (Core/BossModAttach.lua) : accrocher nos defensifs a
-- des barres qu'on masque n'a aucun sens. L'exclusivite est resolue ICI, A LA LECTURE --
-- JAMAIS en reecrivant l'option du joueur dans la DB.
local function Enabled()
    -- GATE DE ZONE (imposee, pas une option) : hors d'un donjon de HR.content, l'addon est
    -- DORMANT -- on ne masque donc RIEN. Sans ca, en raid/monde ouvert on supprimerait les
    -- barres de DBM/BigWigs sans rien afficher a la place (cf. UI/RuntimeBox.lua, gate de zone).
    -- FAIL-CLOSED : si la gate n'est pas encore chargee (UI/RuntimeBox.lua vient APRES ce
    -- fichier dans le .toc), on ne masque rien plutot que de masquer a tort.
    if not (HR.RuntimeAllowed and HR.RuntimeAllowed()) then return false end
    local o = HR.db and HR.db.options
    if not o then return false end
    if o.attachDefsToBossMods == true then return false end
    return o.hideOtherBossMods == true
end

--------------------------------------------------------------------------------
-- A + B : BigWigs / LittleWigs
--------------------------------------------------------------------------------
-- LittleWigs n'a pas de barres propres : ses modules passent par le plugin Bars de
-- BigWigs. On intercepte le message public BigWigs_BarCreated, emis SYNCHRONEMENT a la
-- creation de la barre (donc avant le prochain paint) -> bar:Stop() ne produit aucun
-- flash, et declenche le nettoyage natif (LibCandyBar_Stop -> barStopped).

local function ShouldHideBWBar(bar, module, key)
    -- A : toute barre portant une option key numerique = capacite de boss
    -- (spellID > 0, ou section Encounter Journal < 0).
    if type(key) == "number" then return true end
    -- B : le plugin Timeline de BigWigs re-emet les events C_EncounterTimeline (NOTRE
    -- source) avec module=nil et key=nil ; seul l'eventId, pose par CreateBar sur la
    -- barre, permet de les distinguer des barres utilitaires (pull/break/respawn...).
    if key == nil and module == nil and bar.Get and bar:Get("bigwigs:eventId") then
        return true
    end
    return false
end

-- Signature : (event, plugin, bar, module, key, text, time, icon, isApprox)
local function OnBigWigsBarCreated(_, _, bar, module, key)
    if not bar or not Enabled() then return end
    if not ShouldHideBWBar(bar, module, key) then return end
    HR:Debug("[fb] bigwigs bar hidden", tostring(key))
    pcall(bar.Stop, bar)
end

local function InitBigWigs()
    local loader = _G.BigWigsLoader
    if not loader or not loader.RegisterMessage then return end
    -- ATTENTION : avec un POINT, pas ":" -- le loader leve une erreur explicite sinon.
    -- BigWigs_Core est LoadOnDemand mais reutilise le registre du loader (present des
    -- le login) -> s'enregistrer maintenant suffit, meme avant chargement du core.
    pcall(loader.RegisterMessage, bwProxy, "BigWigs_BarCreated", OnBigWigsBarCreated)
end

--------------------------------------------------------------------------------
-- C : timeline native Blizzard
--------------------------------------------------------------------------------
-- Seul etat PERSISTANT du module -> doit etre (re)applique par FB.Apply().
-- On reparente la frame vers une frame cachee (technique de BigWigs). On NE touche PAS
-- au CVar encounterTimelineEnabled : reglage utilisateur persistant, et BigWigs le
-- pilote deja de son cote.

local hiddenParent      -- poubelle, creee a la demande
local blizzPrevParent   -- parent d'origine, pour restaurer

function FB.ApplyBlizzTimeline()
    local tl = _G.EncounterTimeline
    if not tl or not tl.GetParent then return end
    -- SetParent est protege en combat : on repassera au prochain Apply().
    if InCombatLockdown() then return end

    if Enabled() then
        if not hiddenParent then
            hiddenParent = CreateFrame("Frame")
            hiddenParent:Hide()
        end
        if tl:GetParent() ~= hiddenParent then
            blizzPrevParent = tl:GetParent()
            pcall(tl.SetParent, tl, hiddenParent)
            HR:Debug("[fb] blizzard timeline hidden")
        end
    elseif blizzPrevParent and tl:GetParent() == hiddenParent then
        pcall(tl.SetParent, tl, blizzPrevParent)
        blizzPrevParent = nil
        HR:Debug("[fb] blizzard timeline restored")
    end
end

--------------------------------------------------------------------------------
-- D : DBM
--------------------------------------------------------------------------------
-- Le callback historique DBM_TimerStart N'EXISTE PLUS (DBM-Core 12.0.55) : c'est
-- DBM_TimerBegin. Le dispatch fait securecall(fn, event, ...) -> `event` en 1er arg.
-- La barre est creee AVANT l'emission -> DBT:CancelBar(id) est synchrone et sans flash
-- (c'est le pattern que DBM utilise lui-meme pour les timers nameplate-only).

-- simpType des timers de CAPACITE. Volontairement exclus : "stage", "warmup", "pull",
-- "break", "berserk", "extratimer" (LFG/BG/respawn), "pizzatimer" (/dbm timer), et
-- "cdnp"/"castnp" (nameplate, pas de barre).
local DBM_ABILITY_TYPES = {
    cd     = true,
    cast   = true,
    target = true,
}

-- Ceinture + bretelles : ids codes en dur par le core DBM pour ses timers utilitaires.
local DBM_UTILITY_IDS = {
    DBMPullTimer    = true,
    DBMBreakTimer   = true,
    DBMPizzaTimer   = true,
    DBMLFGTimer     = true,
    DBMBFSTimer     = true,
    DBMRespawnTimer = true,
}

-- Signature : (event, id, msg, timer, icon, simpType, spellId, colorId, modId, ...)
local function OnDBMTimerBegin(_, id, _, _, _, simpType, spellId)
    if not id or not Enabled() then return end
    if DBM_UTILITY_IDS[id] then return end
    if not DBM_ABILITY_TYPES[simpType] then return end
    -- spellId vaut `waSpecialKey or spellId` cote DBM : il peut etre une string
    -- ("warmup"/"stages" sur les types de phase, "ej%d" sur une entree du journal).
    -- Les types porteurs de waSpecialKey sont deja hors allowlist ; on exige juste
    -- qu'un identifiant de capacite existe.
    if not spellId then return end
    local DBT = _G.DBT
    if not DBT or not DBT.CancelBar then return end
    HR:Debug("[fb] dbm bar hidden", tostring(spellId))
    pcall(DBT.CancelBar, DBT, id)
end

local function InitDBM()
    local DBM = _G.DBM
    if not DBM or not DBM.RegisterCallback then return end
    pcall(DBM.RegisterCallback, DBM, "DBM_TimerBegin", OnDBMTimerBegin)
end

--------------------------------------------------------------------------------
-- Point d'entree
--------------------------------------------------------------------------------

-- Re-applicable : option changee, changement de profil, sortie de combat.
function FB.Apply()
    pcall(FB.ApplyBlizzTimeline)
end

-- Une seule fois, a l'init (les handlers relisent l'option a chaque timer).
function FB.Init()
    if FB._inited then return end
    FB._inited = true
    pcall(InitBigWigs)
    pcall(InitDBM)
    FB.Apply()
end

-- Le reparent de la timeline Blizzard est protege en combat : si le joueur bascule
-- l'option en plein combat, on rattrape a la sortie de combat.
HR:RegisterEvent("PLAYER_REGEN_ENABLED", function() FB.Apply() end)
