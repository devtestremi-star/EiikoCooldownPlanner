-- EiikoCooldownPlanner - Core/Keybind.lua
-- Raccourci clavier d'ouverture de l'addon.
--
-- Trois morceaux, volontairement au meme endroit :
--   1. les GLOBALES exigees par le client (libelles du menu Touches + point d'entree appele
--      par Bindings.xml, qui ne voit que _G) ;
--   2. l'ACTION de la touche (la seule logique metier : ouvrir, ou sauter a l'accueil) ;
--   3. la pose du DEFAUT une seule fois, sans jamais ecraser un raccourci existant.
--
-- Charge APRES Core/Events.lua (contrainte du .toc) : c'est ce qui permet d'enregistrer les
-- listeners au scope du fichier. Le rafraichissement de la ligne d'options vit ici aussi,
-- pour la meme raison -- UI/ConfigFrame.lua est charge AVANT Core/Events.lua et ne peut pas
-- appeler HR:RegisterEvent au load.
local addonName, HR = ...

HR.Keybind = HR.Keybind or {}
local KB = HR.Keybind

KB.ACTION  = "ECPLANNER_OPEN"   -- nom de l'action, doit matcher Bindings.xml
KB.DEFAULT = "ALT-P"            -- touche proposee a la premiere installation

-- Libelle de la ligne dans Options > Touches. GLOBALE : le XML ne porte que des identifiants,
-- le client resout le texte par BINDING_NAME_<action>. Meme statut que
-- HealPlanner_OnAddonCompartmentClick (cf. la politique _G de CLAUDE.md).
-- Le GROUPE, lui, vient de l'attribut `category` de Bindings.xml (nom de l'addon en clair) :
-- pas de BINDING_HEADER_* ici, une seule entree n'a pas besoin d'un sous-titre.
_G["BINDING_NAME_ECPLANNER_OPEN"] = "Open planner / go to homepage"

--------------------------------------------------------------------------------
-- Action de la touche
--------------------------------------------------------------------------------

-- Fenetre FERMEE -> exactement /ecp (UI.Toggle : donjon courant, ou accueil hors donjon).
-- Fenetre OUVERTE hors accueil -> saut a la page d'accueil, quelle que soit la vue (plan,
-- options, FAQ, trash, settings du boss). Deja a l'accueil -> RIEN : fermer reste Echap ou
-- la croix, un appui repete ne doit pas refermer la fenetre par surprise.
--
-- On passe par UI.ShowHomePage et PAS par UI.SetViewMode : cette derniere est une BASCULE
-- (`if UI.viewMode == mode then mode = nil end`) et renverrait au plan.
function KB.Press()
    local UI = HR.UI
    if not (UI and UI.Toggle) then return end
    if not (UI.frame and UI.frame:IsShown()) then UI.Toggle() return end
    if UI.viewMode == "home" then return end
    UI.ShowHomePage()
end

-- Point d'entree de Bindings.xml (globale obligatoire : le corps du binding ne voit que _G).
function EiikoCooldownPlanner_OnKeybind()
    KB.Press()
end

--------------------------------------------------------------------------------
-- Lecture / ecriture du raccourci (l'UI ne touche a aucune API de binding)
--------------------------------------------------------------------------------

-- Touche actuellement liee a l'action, ou nil.
function KB.CurrentKey()
    return (GetBindingKey(KB.ACTION))
end

-- Libelle lisible de la touche courante ("Not bound" si aucune).
function KB.CurrentLabel()
    local key = KB.CurrentKey()
    if not key then return "Not bound" end
    return (GetBindingText and GetBindingText(key)) or key
end

-- Ecriture commune : SaveBindings est REFUSE en combat -> on previent au lieu de laisser
-- remonter une erreur. Renvoie true si la sauvegarde a eu lieu.
local function commit()
    if InCombatLockdown() then
        HR:Print("Keybindings cannot be saved while in combat.")
        return false
    end
    SaveBindings(GetCurrentBindingSet())
    return true
end

-- Lie `key` a l'action, apres avoir DELIE les touches qu'elle portait deja (une action peut
-- en avoir deux ; on veut un seul raccourci, celui que le joueur vient de choisir).
function KB.Set(key)
    if type(key) ~= "string" or key == "" then return false end
    if InCombatLockdown() then
        HR:Print("Keybindings cannot be saved while in combat.")
        return false
    end
    local k1, k2 = GetBindingKey(KB.ACTION)
    if k1 then SetBinding(k1, nil) end
    if k2 then SetBinding(k2, nil) end
    if not SetBinding(key, KB.ACTION) then
        if k1 then SetBinding(k1, KB.ACTION) end     -- echec : on remet ce qu'on avait
        return false
    end
    return commit()
end

-- Retire le raccourci : l'action reste listee dans Touches, sans touche.
function KB.Clear()
    if InCombatLockdown() then
        HR:Print("Keybindings cannot be saved while in combat.")
        return false
    end
    local k1, k2 = GetBindingKey(KB.ACTION)
    if k1 then SetBinding(k1, nil) end
    if k2 then SetBinding(k2, nil) end
    return commit()
end

--------------------------------------------------------------------------------
-- Pose du defaut (une seule fois, jamais d'ecrasement)
--------------------------------------------------------------------------------

-- ALT-P a la premiere installation, et SEULEMENT si la touche est libre. Une touche deja
-- prise (jeu ou autre addon) est laissee intacte : l'action reste sans raccourci et le joueur
-- la reglera dans Touches ou dans Options > General. Le drapeau est account-wide (racine de
-- la DB, hors profil, comme whatsNewVersion) -> un joueur qui efface volontairement le
-- raccourci ne le voit jamais revenir, y compris sur un autre personnage.
-- Renvoie true quand la question a ete TRANCHEE (pose, ou renoncement delibere). false = on
-- n'a pas pu decider maintenant (DB pas prete, combat) -> l'appelant reessaiera.
function KB.SeedDefault()
    local db = HR.db
    if not db then return false end
    if db.keybindSeeded then return true end
    if InCombatLockdown() then return false end      -- /reload en plein pull : on reessaie au prochain PEW

    db.keybindSeeded = true                          -- decide : on ne repassera plus jamais ici
    if GetBindingKey(KB.ACTION) then return true end -- deja liee (set de touches partage entre persos)

    local taken = GetBindingAction(KB.DEFAULT)
    if taken and taken ~= "" then                    -- occupee -> on ne touche a rien
        HR:Print(("%s is already taken (%s) -- the planner was left unbound. Set your own key in Settings > General, or in the game's Key Bindings menu.")
            :format(KB.DEFAULT, (GetBindingName and GetBindingName(taken)) or taken))
        return true
    end

    if SetBinding(KB.DEFAULT, KB.ACTION) then
        SaveBindings(GetCurrentBindingSet())
        HR:Print(("%s now opens the planner. Rebind it in Settings > General or in the game's Key Bindings menu.")
            :format(KB.DEFAULT))
    end
    return true
end

--------------------------------------------------------------------------------
-- Listeners
--------------------------------------------------------------------------------

-- PLAYER_ENTERING_WORLD et pas OnInitialize : les raccourcis sont charges a ce moment, et
-- l'evenement rejoue a chaque changement de zone -> un /reload fait EN COMBAT (SeedDefault
-- refuse alors d'ecrire) retrouve naturellement une occasion de trancher. On se desamorce
-- des que la question est tranchee.
local seeded = false
HR:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    if seeded then return end
    seeded = KB.SeedDefault()
end)

-- Le joueur peut aussi changer la touche dans le menu Touches de Blizzard : la ligne de nos
-- options doit suivre. (Enregistre ici et pas dans UI/ConfigFrame.lua, charge avant Events.)
HR:RegisterEvent("UPDATE_BINDINGS", function()
    if HR.UI and HR.UI.RefreshKeybindRow then HR.UI.RefreshKeybindRow() end
end)
