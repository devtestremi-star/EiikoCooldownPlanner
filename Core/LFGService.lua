-- HealPlanner - Core/LFGService.lua
-- SERVICE PARTAGE "annonce Group Finder" (HR.LFG). Un seul endroit qui sait creer/retirer
-- une annonce ; les vues ne font que l'appeler. Consommateur actuel : UI/HomePage.lua (une
-- card = un donjon -> S.ListDungeon). L'API reste generique (S.ListKeystone existe pour
-- lister a partir d'une CLE), meme si l'UI ne s'en sert plus.
-- Aucune donnee de cle ici (ca reste Core/Keystones.lua) : ce fichier ne connait que le
-- Group Finder.
--
-- CONTRAINTE D'API (structurante) : `C_LFGList.CreateListing` n'a NI champ `title` NI champ
-- "niveau de cle", et le titre est PROTEGE en ecriture. Le "+15" ne peut donc venir que
-- d'une FRAPPE HUMAINE. Cible : 1 clic => annonce avec le BON DONJON et le BON PLAYSTYLE,
-- puis le joueur tape le niveau. Pre-remplir l'UI Blizzard est HORS SCOPE
-- (`LFGListEntryCreation_Select` depuis un addon = ADDON_ACTION_BLOCKED).
-- INTERDITS ICI : LFGListEntryCreation_Select, C_LFGList.SetEntryTitle,
-- C_LFGList.GetPlaystyleString (protegee -> lire les globales GROUP_FINDER_GENERAL_PLAYSTYLE*).
local addonName, HR = ...

HR.LFG = HR.LFG or {}
local S = HR.LFG

-- Playstyle FIXE "Relaxed" : le champ est obligatoire a la creation mais personne ne le lit
-- -> pas de selecteur, pas de reglage en DB.
-- Enum.LFGEntryGeneralPlaystyle = { Learning=1, FunRelaxed=2, FunSerious=3, Expert=4 }.
local PLAYSTYLE = (Enum and Enum.LFGEntryGeneralPlaystyle and Enum.LFGEntryGeneralPlaystyle.FunRelaxed) or 2

-- Prerequis TOUJOURS a 0 (score M+ / ilvl) : personne ne les remplit.
local REQUIRED_SCORE, REQUIRED_ILVL = 0, 0

--------------------------------------------------------------------------------
-- 0. Abonnement : "l'etat de l'annonce a change"
--------------------------------------------------------------------------------
-- Les vues s'abonnent (S.OnChange) au lieu d'ecouter les events LFG chacune de leur cote :
-- une seule source, et un bouton List/Delist qui reste juste partout.
local subscribers = {}

function S.OnChange(fn)
    if type(fn) == "function" then subscribers[#subscribers + 1] = fn end
end

local function notify()
    for _, fn in ipairs(subscribers) do pcall(fn) end
end

--------------------------------------------------------------------------------
-- 1. Mapping vers l'activityID du Group Finder
--------------------------------------------------------------------------------
-- CLE DE JOINTURE = le mapID d'INSTANCE. `GroupFinderActivityInfo.mapID`, le 6e retour de
-- `C_ChallengeMode.GetMapUIInfo` et notre `dungeon.zoneID` (instanceID de GetInstanceInfo)
-- designent le meme donjon -> on joint la-dessus sans jamais approcher un nom.
-- Le nom (`info.fullName`) n'est qu'un SECOND RECOURS, au cas ou les mapID divergeraient.
local byInstance, byName

-- Les parametres de queue de GetAvailableActivities ont bouge entre clients : forme complete
-- d'abord, repli sur la forme a un seul argument.
local function availableActivities(categoryId)
    local ok, activities = pcall(C_LFGList.GetAvailableActivities, categoryId, nil, 0)
    if not ok or not activities then
        ok, activities = pcall(C_LFGList.GetAvailableActivities, categoryId)
    end
    return (ok and activities) or {}
end

local function buildActivityMap()
    local inst, nm = {}, {}
    for _, categoryId in ipairs(C_LFGList.GetAvailableCategories() or {}) do
        for _, activityId in ipairs(availableActivities(categoryId)) do
            local info = C_LFGList.GetActivityInfoTable(activityId)
            if info and info.isMythicPlusActivity then
                if info.mapID then inst[info.mapID] = activityId end
                if info.fullName then nm[info.fullName] = activityId end
            end
        end
    end
    return inst, nm
end

function S.ResetActivityMap() byInstance, byName = nil, nil end

-- activityID depuis un mapID d'INSTANCE (nom en second recours). Construit a la demande, avec
-- UN SEUL rebuild si la resolution echoue (liste d'activites pas encore arrivee cote client,
-- ou rotation de saison).
function S.ActivityForInstance(instanceMapID, name, rebuilt)
    if not instanceMapID and not name then return nil end
    if not byInstance then byInstance, byName = buildActivityMap() end
    local activityId = (instanceMapID and byInstance[instanceMapID]) or (name and byName[name])
    if activityId or rebuilt then return activityId end
    S.ResetActivityMap()
    return S.ActivityForInstance(instanceMapID, name, true)
end

-- ... depuis un challengeMapID (une CLE).
function S.ActivityForChallengeMap(challengeMapID)
    if not challengeMapID then return nil end
    local name, _, _, _, _, instanceMapID = C_ChallengeMode.GetMapUIInfo(challengeMapID)
    return S.ActivityForInstance(instanceMapID, name)
end

-- ... depuis un donjon de HR.content (les cards de la homepage n'ont que ca).
function S.ActivityForDungeon(dungeon)
    if not dungeon then return nil end
    local a = S.ActivityForInstance(dungeon.zoneID, dungeon.name)
    if a then return a end
    -- 2e chance : passer par la table des donjons de la saison (si zoneID et mapID d'activite
    -- ne s'alignaient pas, GetMapUIInfo fournit le mapID que le Group Finder utilise).
    return S.ActivityForChallengeMap(S.ChallengeMapForDungeon(dungeon))
end

-- challengeMapID correspondant a un donjon de HR.content (ou nil). Sert aussi a retrouver la
-- meilleure cle du groupe pour ce donjon (cf. HR.Keys.BestForMap).
function S.ChallengeMapForDungeon(dungeon)
    if not dungeon then return nil end
    for _, cmID in ipairs(C_ChallengeMode.GetMapTable() or {}) do
        local name, _, _, _, _, instanceMapID = C_ChallengeMode.GetMapUIInfo(cmID)
        if (dungeon.zoneID and instanceMapID == dungeon.zoneID) or (name and name == dungeon.name) then
            return cmID
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- 2. Etat de l'annonce
--------------------------------------------------------------------------------

function S.IsListed() return C_LFGList.HasActiveEntryInfo() end

-- Lister exige d'etre SEUL ou LEADER.
function S.CanList() return (not IsInGroup()) or UnitIsGroupLeader("player") end

function S.ActiveActivityID()
    local info = C_LFGList.GetActiveEntryInfo and C_LFGList.GetActiveEntryInfo()
    if not info then return nil end
    return info.activityID or (info.activityIDs and info.activityIDs[1])
end

-- L'annonce en cours porte-t-elle CETTE activite ? (=> le bouton affiche "Delist".)
function S.IsListedFor(activityID)
    return activityID ~= nil and S.IsListed() and S.ActiveActivityID() == activityID
end

-- Niveau de la cle que TU POSSEDES pour cette activite (nil = tu ne l'as pas).
-- ⚠️ REGLE SERVEUR (constatee en jeu) : une annonce Mythique+ n'est acceptee que pour une
-- activite dont on possede REELLEMENT la cle. Sans cle, `CreateListing` repond "ok" puis
-- l'annonce n'apparait jamais, sans le moindre message -- d'ou ce test EN AMONT du clic.
-- Consequence produit : on ne peut PAS lister la cle d'un autre membre ; seul son porteur le
-- peut (et il doit etre leader).
function S.OwnedKeystoneLevel(activityID)
    if not activityID or not C_LFGList.GetKeystoneForActivity then return nil end
    local ok, level = pcall(C_LFGList.GetKeystoneForActivity, activityID)
    if not ok or type(level) ~= "number" or level <= 0 then return nil end
    return level
end

--------------------------------------------------------------------------------
-- 3. Creation / suppression
--------------------------------------------------------------------------------

-- Le titre ne peut PAS etre pose par un addon : on le dit UNE fois par session.
local titleNoticeShown = false
local function noticeTitle()
    if titleNoticeShown then return end
    titleNoticeShown = true
    HR:Print("|cffff8000WoW API limit|r: only Blizzard's own group finder can set a listing title. Type the key level yourself, then press Update.")
end

-- Le Group Finder charge a la demande. En COMBAT on ne force AUCUN panneau (ouvrir un UIPanel
-- en combat provoque des "Interface action failed because of an AddOn") -> juste le message.
local function openGroupFinder()
    if InCombatLockdown() then return false end
    if not PVEFrame_ShowFrame and C_AddOns and C_AddOns.LoadAddOn then
        C_AddOns.LoadAddOn("Blizzard_GroupFinder")
    end
    if not PVEFrame_ShowFrame then return false end
    return pcall(PVEFrame_ShowFrame, "GroupFinderFrame", "LFGListPVEStub")
end

-- Ouvre l'edition de l'annonce creee. SEUL endroit ou un taint est possible -> tout sous
-- pcall, repli silencieux.
local function openListingEdit()
    if not openGroupFinder() then return false end
    local viewer = LFGListFrame and LFGListFrame.ApplicationViewer
    local editButton = viewer and viewer.EditButton
    if editButton and pcall(editButton.Click, editButton) then return true end
    local panel = LFGListFrame and LFGListFrame.EntryCreation
    if not (panel and LFGListEntryCreation_SetEditMode and LFGListFrame_SetActivePanel) then return false end
    return pcall(LFGListEntryCreation_SetEditMode, panel, true)
       and pcall(LFGListFrame_SetActivePanel, LFGListFrame, panel)
end

-- Repli quand la creation echoue : le Group Finder n'a jamais ete amorce cette session.
-- `cause` distingue les DEUX echecs possibles, qui se diagnostiquent differemment :
--   "refused" = CreateListing a renvoye false (refus immediat du client : champ manquant,
--               conditions non remplies, deja en file...) ;
--   "empty"   = elle a accepte mais aucune annonce n'existe 0,5 s plus tard (cas typique du
--               Group Finder jamais amorce cette session).
-- Sans cette distinction, les deux produisaient le MEME message et le bug etait indebuggable.
local function fallBackToGroupFinder(cause, activityID)
    if S.IsListed() then return end
    local why = (cause == "refused") and "the client refused the listing"
             or "the listing did not appear"
    -- L'activityID utilise est LA piece a comparer avec celui que Blizzard donne pour ta
    -- propre cle : c'est ce qui distingue "mauvaise activite" de
    -- "creation refusee pour une autre raison".
    if activityID then why = why .. ", activity " .. tostring(activityID) end
    if openGroupFinder() then
        local selection = LFGListFrame and LFGListFrame.CategorySelection
        if selection and LFGListCategorySelection_SelectCategory then
            pcall(LFGListCategorySelection_SelectCategory, selection,
                  rawget(_G, "GROUP_FINDER_CATEGORY_ID_DUNGEONS") or 2, 0)
        end
        HR:Print(("|cffff8000Could not create the listing|r (%s). Opened the group finder with |cffffd100Dungeons|r pre-selected; click |cffffd100Start a Group|r once, then try again."):format(why))
    else
        HR:Print(("|cffff8000Could not create the listing|r (%s). Open the group finder and click |cffffd100Start a Group|r once (not possible during combat)."):format(why))
    end
end

-- Annonce en ATTENTE de confirmation serveur (nil = aucune). Consommee soit par
-- LFG_LIST_ACTIVE_ENTRY_UPDATE, soit par le butoir de S.List -- le premier des deux.
local pending
local CONFIRM_TIMEOUT = 3      -- s : large, on ne fait qu'attendre un aller-retour serveur

-- Message + ouverture de l'edition, une fois l'annonce REELLEMENT creee.
local function AnnounceCreated(opts)
    HR:Print(("Listing created for |cffffd100%s|r. Add the level to the title yourself: |cffffd100+%s|r")
        :format(tostring(opts.label or "?"), opts.level and tostring(opts.level) or "N"))
    -- Blizzard amorce le titre depuis TA cle : si on liste un AUTRE donjon, le titre
    -- pre-rempli peut annoncer le tien. On previent explicitement.
    local owned = C_MythicPlus.GetOwnedKeystoneChallengeMapID and C_MythicPlus.GetOwnedKeystoneChallengeMapID()
    if owned and owned > 0 and opts.challengeMapID and owned ~= opts.challengeMapID then
        HR:Print("|cffff8000Careful:|r the pre-filled title may show |cffffd100your own|r keystone. Check it before pressing Update.")
    end
    openListingEdit()
    noticeTitle()
end

-- Cree l'annonce. opts = { activityID, label, level, challengeMapID }
--   label          : nom affiche dans le message (donjon)
--   level          : niveau de cle a taper dans le titre (nil => "+N")
--   challengeMapID : si fourni, on previent quand le titre pre-rempli risque d'annoncer TA
--                    propre cle plutot que celle qu'on liste.
-- ⚠️ APPELER DIRECTEMENT DANS LE OnClick : CreateListing est RESTREINTE et exige un hardware
-- event ; tout C_Timer intercale le perd. Le remplacement d'une annonce active enchaine donc
-- RemoveListing + CreateListing DANS LE MEME CLIC, sans rien entre les deux.
function S.List(opts)
    opts = opts or {}
    local activityID = opts.activityID
    if not S.CanList() then
        HR:Print("Only the group leader can list a group.")
        return false
    end
    if not activityID then
        HR:Print("|cffff5555That dungeon is not in the group finder.|r")
        return false
    end
    -- Sans la cle en poche, le serveur jettera l'annonce en silence : on le dit AVANT.
    if not S.OwnedKeystoneLevel(activityID) then
        HR:Print(("|cffff8000You don't own that keystone.|r Only the player carrying the %s key can list it, and they must be the group leader.")
            :format(tostring(opts.label or "dungeon")))
        return false
    end

    if S.IsListed() then C_LFGList.RemoveListing() end     -- remplacement direct (meme clic)

    local ok = C_LFGList.CreateListing({
        activityIDs           = { activityID },
        -- DEUX champs de playstyle, et les DEUX sont attendus : `playstyle` (specifique a
        -- l'activite, None ici) ET `generalPlaystyle`. Omettre le premier fait echouer la
        -- creation en silence -> ne pas "simplifier" cette ligne.
        playstyle             = (Enum and Enum.LFGEntryPlaystyle and Enum.LFGEntryPlaystyle.None) or 0,
        generalPlaystyle      = PLAYSTYLE,
        isCrossFactionListing = true,
        isAutoAccept          = false,
        isPrivateGroup        = false,
        requiredDungeonScore  = REQUIRED_SCORE,
        requiredItemLevel     = REQUIRED_ILVL,
    })
    if not ok then
        -- Refus IMMEDIAT du client (a distinguer du cas "acceptee mais rien n'apparait").
        fallBackToGroupFinder("refused", activityID)
        notify()
        return false
    end

    -- La creation est un ALLER-RETOUR SERVEUR : `HasActiveEntryInfo` ne devient vrai qu'a la
    -- confirmation, annoncee par LFG_LIST_ACTIVE_ENTRY_UPDATE. On ATTEND donc cet evenement
    -- (cf. handler plus bas) au lieu de sonder apres un delai fixe : un simple 0,5 s declarait
    -- l'echec alors que la reponse etait encore en vol. Le timer ne sert plus que de BUTOIR.
    pending = opts
    C_Timer.After(CONFIRM_TIMEOUT, function()
        if not pending then return end          -- deja confirme par l'evenement
        local p = pending
        pending = nil
        if S.IsListed() then AnnounceCreated(p) else fallBackToGroupFinder("empty", p.activityID) end
        notify()
    end)
    return true
end

-- Lister une CLE du groupe. Plus aucun appelant (l'UI ne cree plus d'annonce).
function S.ListKeystone(challengeMapID, level)
    return S.List({
        activityID     = S.ActivityForChallengeMap(challengeMapID),
        label          = (challengeMapID and C_ChallengeMode.GetMapUIInfo(challengeMapID)) or "?",
        level          = level,
        challengeMapID = challengeMapID,
    })
end

-- Lister un DONJON de HR.content (cards de la homepage). Le niveau affiche dans le message
-- vient, si elle existe, de la meilleure cle du groupe pour ce donjon.
function S.ListDungeon(dungeon)
    if not dungeon then return false end
    local cmID = S.ChallengeMapForDungeon(dungeon)
    local best = (cmID and HR.Keys and HR.Keys.BestForMap) and HR.Keys.BestForMap(cmID) or nil
    return S.List({
        activityID     = S.ActivityForDungeon(dungeon),
        label          = dungeon.name,
        level          = best and best.level or nil,
        challengeMapID = cmID,
    })
end

--------------------------------------------------------------------------------
-- 3bis. OUVERTURE de l'outil Blizzard (cle qu'on ne possede pas)
--------------------------------------------------------------------------------
-- Ouvre le formulaire de creation Blizzard DEJA POSITIONNE sur le bon donjon (+ playstyle).
-- Le joueur ecrit son titre et clique "List Group" lui-meme : on ne cree rien, donc la regle
-- "il faut posseder la cle" ne nous concerne pas -- n'importe quel donjon peut etre prepare.
--
-- ⚠️ ADDON_ACTION_BLOCKED ATTENDU, ET SANS GRAVITE : `LFGListEntryCreation_Select` appelle
-- `SetTitleFromActivityInfo` -> `C_LFGList.SetEntryTitle`, qui est PROTEGEE. L'auto-titre est
-- donc refuse quand l'appel vient de nous. VERIFIE EN JEU : le donjon, lui, est bien
-- selectionne -- seul le titre reste a la charge du joueur. Ne pas "corriger" ce blocage en
-- retirant _Select : ce serait perdre la selection du donjon, qui est tout l'interet.
--   Trace : SetEntryTitle <- LFGList.lua:1420 SetTitleFromActivityInfo <- LFGList.lua:1189 _Select
function S.PrepareListing(dungeon)
    -- Preparer le formulaire ne CREE rien : la garde de lead ne s'applique donc pas ici
    -- (elle reste sur l'affichage du CTA, hors mode test). Cf. UI/HomePage.lua.
    -- SILENCIEUX : aucun message de chat sur ce chemin (ni succes, ni echec). Le resultat est
    -- visible a l'ecran -- la fenetre s'ouvre sur le bon donjon, ou ne s'ouvre pas.
    local activityID = S.ActivityForDungeon(dungeon)
    if not activityID then return false end
    if InCombatLockdown() then return false end
    if not openGroupFinder() then return false end

    local info       = C_LFGList.GetActivityInfoTable(activityID)
    local categoryID = (info and info.categoryID) or rawget(_G, "GROUP_FINDER_CATEGORY_ID_DUNGEONS") or 2
    local groupID    = info and info.groupFinderActivityGroupID
    local filters    = (info and info.filters) or 0
    local panel      = LFGListFrame and LFGListFrame.EntryCreation

    -- Sequence CALQUEE sur celle de Blizzard (noms releves en jeu sur ce client).
    -- Chaque etape sous pcall : le refus de l'auto-titre remonte comme une erreur Lua et ne
    -- doit pas interrompre les suivantes.
    local sel = LFGListFrame and LFGListFrame.CategorySelection
    if sel and LFGListCategorySelection_SelectCategory then
        pcall(LFGListCategorySelection_SelectCategory, sel, categoryID, filters)
    end
    -- OUVRIR le formulaire sur cette categorie : sans ca, _Select s'applique a un formulaire
    -- jamais initialise -> dropdowns vides.
    if panel and LFGListEntryCreation_Show then
        pcall(LFGListEntryCreation_Show, panel, LFGListFrame.baseFilters or 0, categoryID, filters)
    end
    -- Groupe + activite. On N'APPELLE PAS `LFGListEntryCreation_Select` : elle appelle
    -- l'auto-titre (ligne 1189) qui tape dans la fonction PROTEGEE SetEntryTitle, ce qui
    -- (a) spamme ADDON_ACTION_BLOCKED et (b) INTERROMPT _Select -- donc tout ce qu'elle fait
    -- ensuite, notamment la mise en place du dropdown de playstyle, ne s'execute jamais
    -- (symptome observe : le select de playstyle reste vide).
    -- On refait donc son travail nous-memes : poser l'etat, puis appeler les memes briques
    -- Blizzard (toutes presentes, aucune ne touche au titre).
    if panel then
        panel.selectedCategory = categoryID
        panel.selectedGroup    = groupID
        panel.selectedActivity = activityID
        panel.selectedFilters  = filters
        for _, fn in ipairs({ "LFGListEntryCreation_SetupActivityDropdown",
                              "LFGListEntryCreation_SetupGroupDropdown",
                              "LFGListEntryCreation_SetupPlayStyleDropdown" }) do
            local f = rawget(_G, fn)
            if f then pcall(f, panel) end
        end
        local ok = (panel.selectedActivity == activityID)
        -- Repli : si l'etat n'a pas pris, on retombe sur _Select (le donjon prime sur le
        -- confort -- au prix de l'erreur bloquee).
        if not ok and LFGListEntryCreation_Select then
            pcall(LFGListEntryCreation_Select, panel, filters, categoryID, groupID, activityID)
        end
    end
    if panel and LFGListFrame_SetActivePanel then
        pcall(LFGListFrame_SetActivePanel, LFGListFrame, panel)
    end
    -- ⚠️ PLAYSTYLE : VOLONTAIREMENT NON INJECTE.
    -- Le `PlayStyleDropdown` du formulaire n'est PAS le "general playstyle" (Learning /
    -- Relaxed / Competitive / Carry) qu'on passe a CreateListing : c'est le playstyle
    -- D'ACTIVITE (`Enum.LFGEntryPlaystyle`), dont les libelles M+ sont du type
    -- "Completion" / "Timed" / "Farm". Y injecter notre valeur generale (Relaxed = 2)
    -- selectionnait donc un item qui n'a rien a voir -- et l'auto-titre de Blizzard le
    -- recopie, d'ou les titres du genre "+10 Completion" observes en jeu.
    -- On laisse donc ce champ au joueur tant qu'on n'a pas choisi explicitement une des
    -- valeurs M+ (elles ne sont pas lisibles : C_LFGList.GetPlaystyleString est protegee).
    -- ⛔ LE TITRE EST INACCESSIBLE A UN ADDON -- demontre en jeu, ne pas retenter.
    -- Les DEUX voies sont verrouillees, pour deux raisons differentes :
    --   * C_LFGList.SetEntryTitle          -> fonction PROTEGEE (ADDON_ACTION_BLOCKED) ;
    --   * EntryCreation.Name:SetText(...)  -> EditBox SECURISEE :
    --       "EditBox:SetText(): Call is illegal when disabled by security settings"
    --     (verifie aussi via /run, donc ce n'est pas propre a notre addon : tout code tainte
    --      est refuse, y compris hors annonce active -- on est pourtant AVANT tout listing).
    -- Blizzard verrouille le titre des deux cotes, volontairement. Le niveau de cle ne peut
    -- donc etre communique que par une FRAPPE HUMAINE. Le titre auto de Blizzard, lui, se base
    -- sur TA cle possedee et PAS sur le donjon choisi : il peut donc afficher "+10" alors qu'on
    -- prepare un tout autre donjon -> a corriger a la main avant de lister.
    if panel and LFGListEntryCreation_UpdateValidState then
        pcall(LFGListEntryCreation_UpdateValidState, panel)
    end

    return true
end

-- SILENCIEUX comme PrepareListing : le CTA des cards ne doit rien ecrire dans le chat.
function S.Delist()
    if not S.IsListed() or not S.CanList() then return end
    C_LFGList.RemoveListing()
end

-- Bascule utilisee par les boutons : la ligne/card DEJA listee retire l'annonce, une autre la
-- REMPLACE. `lister` = fonction qui cree l'annonce (appelee dans le meme clic).
function S.Toggle(activityID, lister)
    if S.IsListedFor(activityID) then
        S.Delist()
        return
    end
    lister()
end

--------------------------------------------------------------------------------
-- 4. Evenements + sonde
--------------------------------------------------------------------------------

HR:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    if C_LFGList and C_LFGList.RequestAvailableActivities then C_LFGList.RequestAvailableActivities() end
end)
-- Confirmation SERVEUR d'une annonce en attente : c'est ici que la creation est validee
-- (le butoir de S.List ne sert que si cet evenement n'arrive jamais).
HR:RegisterEvent("LFG_LIST_ACTIVE_ENTRY_UPDATE", function()
    if pending and S.IsListed() then
        local p = pending
        pending = nil
        AnnounceCreated(p)
    end
    notify()
end)
HR:RegisterEvent("LFG_LIST_AVAILABILITY_UPDATE", function()
    S.ResetActivityMap()          -- le mapping n'est plus valide
    notify()
end)

-- REFUS SERVEUR : CreateListing peut repondre "ok" (= requete envoyee) puis le serveur
-- rejeter la creation. C'est le SEUL endroit ou la raison est donnee -> on la relaie telle
-- quelle. Silencieux hors tentative en cours (aucun bruit si un autre addon liste).
HR:RegisterEvent("LFG_LIST_ENTRY_CREATION_FAILED", function(_, ...)
    if not pending then return end
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    HR:Print("|cffff5555Server refused the listing|r"
        .. ((#parts > 0) and (" (" .. table.concat(parts, ", ") .. ")") or "")
        .. " - activity " .. tostring(pending.activityID))
end)

-- Sans au moins un RequestAvailableActivities, le mapping est VIDE : a appeler a l'ouverture
-- d'une vue qui liste (en plus de PLAYER_ENTERING_WORLD).
function S.RequestActivities()
    if C_LFGList and C_LFGList.RequestAvailableActivities then C_LFGList.RequestAvailableActivities() end
end

--------------------------------------------------------------------------------
-- 4. Evenements + sonde
--------------------------------------------------------------------------------

HR:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    if C_LFGList and C_LFGList.RequestAvailableActivities then C_LFGList.RequestAvailableActivities() end
end)
-- Confirmation SERVEUR d'une annonce en attente : c'est ici que la creation est validee
-- (le butoir de S.List ne sert que si cet evenement n'arrive jamais).
HR:RegisterEvent("LFG_LIST_ACTIVE_ENTRY_UPDATE", function()
    if pending and S.IsListed() then
        local p = pending
        pending = nil
        AnnounceCreated(p)
    end
    notify()
end)
HR:RegisterEvent("LFG_LIST_AVAILABILITY_UPDATE", function()
    S.ResetActivityMap()          -- le mapping n'est plus valide
    notify()
end)

-- REFUS SERVEUR : CreateListing peut repondre "ok" (= requete envoyee) puis le serveur
-- rejeter la creation. C'est le SEUL endroit ou la raison est donnee -> on la relaie telle
-- quelle. Silencieux hors tentative en cours (aucun bruit si un autre addon liste).
HR:RegisterEvent("LFG_LIST_ENTRY_CREATION_FAILED", function(_, ...)
    if not pending then return end
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    HR:Print("|cffff5555Server refused the listing|r"
        .. ((#parts > 0) and (" (" .. table.concat(parts, ", ") .. ")") or "")
        .. " - activity " .. tostring(pending.activityID))
end)

-- Sans au moins un RequestAvailableActivities, le mapping est VIDE : a appeler a l'ouverture
-- d'une vue qui liste (en plus de PLAYER_ENTERING_WORLD).
function S.RequestActivities()
    if C_LFGList and C_LFGList.RequestAvailableActivities then C_LFGList.RequestAvailableActivities() end
end
