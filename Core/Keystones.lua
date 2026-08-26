-- HealPlanner - Core/Keystones.lua
-- CLES MYTHIQUE+ du groupe : QUI a QUELLE cle. Rien d'autre.
-- Seul consommateur d'affichage : les CHIPS des cards de la page d'accueil (UI/HomePage.lua).
-- Il n'y a ni fenetre dediee ni commande slash.
-- Tout ce qui touche au Group Finder (mapping d'activite, creation/suppression d'annonce)
-- vit dans le SERVICE PARTAGE Core/LFGService.lua (HR.LFG), utilise aussi par la homepage.
--
-- SOURCE DES CLES : LibKeystone (Libs/LibKeystone, v11 VERBATIM, embarquee aussi par
-- BigWigs/DBM/EllesmereUI -> LibStub dedoublonne). Seuls les membres qui font tourner un
-- addon embarquant la lib rapportent une cle : un membre sans rien restera vide, c'est
-- STRUCTUREL, pas un bug. Notre propre cle est lue localement par la lib et remonte par le
-- MEME callback (meme hors groupe).
local addonName, HR = ...

HR.Keys = HR.Keys or {}
local K = HR.Keys

local LKS = LibStub and LibStub("LibKeystone", true)

--------------------------------------------------------------------------------
-- 1. Collecte des cles du groupe
--------------------------------------------------------------------------------

-- reported["Nom-Royaume"] = { level, challengeMapID, rating }
local reported = {}

-- TROIS sources, TROIS formes de nom, et les comparer brutes = le bug qui vide la liste :
--   * la cle d'un membre arrive en Ambiguate(sender,"none") -> garde le royaume ("Eiiko-Hyjal")
--   * la notre arrive de UnitNameUnmodified("player") -> JAMAIS de royaume
--   * HR.group (Core/GroupScan.lua) stocke UnitName(unit) -> nu aussi
-- On ramene donc TOUT a la forme qualifiee. Le royaume est relu A CHAQUE APPEL : ce fichier
-- charge avant l'entree dans le monde, ou GetNormalizedRealmName n'a encore rien a dire.
local function qualifiedName(name, realm)
    if not name or name == "" then return nil end
    if realm and realm ~= "" then return name .. "-" .. realm end
    if name:find("-", 1, true) then return name end
    return name .. "-" .. (GetNormalizedRealmName() or "")
end
K.QualifiedName = qualifiedName

if LKS then
    -- LKS.Register exige une TABLE d'addon (differente de la lib elle-meme) : HR convient.
    LKS.Register(HR, function(level, challengeMapID, rating, sender, channel)
        if channel ~= "PARTY" then return end          -- on n'interroge jamais le canal GUILD
        local name = qualifiedName(sender)
        if not name then return end
        -- Une paire a zero = "plus de cle" (c'est aussi ainsi qu'une cle consommee est
        -- rapportee) -> on SUPPRIME l'entree au lieu d'en garder une perimee.
        if not level or level == 0 or not challengeMapID or challengeMapID == 0 then
            reported[name] = nil
        else
            reported[name] = { level = level, challengeMapID = challengeMapID, rating = rating }
        end
        if HR.UI and HR.UI.RefreshHome then HR.UI.RefreshHome() end
    end)
end

-- Demande les cles au groupe. Throttle INTERNE a la lib -> appelable librement (ouverture de
-- la fenetre, changement de roster). Rappelle aussi NOTRE cle par le meme callback, groupe ou non.
function K.Request()
    if LKS then LKS.Request("PARTY") end
end

function K.MapName(challengeMapID)
    return (challengeMapID and C_ChallengeMode.GetMapUIInfo(challengeMapID)) or "?"
end

-- Membres du groupe (joueur inclus) AVEC leur cle si connue. Renvoie TOUS les membres : la
-- vue "Joueurs" doit aussi montrer ceux qui n'ont pas de cle (ou dont l'addon n'en publie pas).
--   { name, unit, class, level|nil, challengeMapID|nil, dungeon|nil }
-- Tri : porteurs d'abord (niveau decroissant), puis les autres par nom.
function K.GroupKeystones()
    HR.RebuildGroup()
    local out = {}
    for _, m in ipairs(HR.group) do
        local qn = m.unit and qualifiedName(UnitFullName(m.unit))
        local e  = qn and reported[qn]
        out[#out + 1] = {
            name           = m.name or qn or "?",
            unit           = m.unit,
            class          = m.class,
            level          = e and e.level,
            challengeMapID = e and e.challengeMapID,
            dungeon        = e and K.MapName(e.challengeMapID),
        }
    end
    table.sort(out, function(a, b)
        if (a.level or 0) ~= (b.level or 0) then return (a.level or 0) > (b.level or 0) end
        return (a.name or "") < (b.name or "")
    end)
    return out
end

-- challengeMapID -> meilleure cle du groupe pour ce donjon. Filtre sur les membres
-- REELLEMENT presents : une cle rapportee par quelqu'un qui a quitte le groupe ne peut pas
-- trainer. UN seul scan du roster (le rendu de la vue Donjons appelle sinon 8 fois de suite).
function K.BestByMap()
    local best = {}
    for _, e in ipairs(K.GroupKeystones()) do
        local cm = e.challengeMapID
        if cm and (not best[cm] or e.level > best[cm].level) then best[cm] = e end
    end
    return best
end

function K.BestForMap(challengeMapID)
    if not challengeMapID then return nil end
    return K.BestByMap()[challengeMapID]
end

-- TOUS les porteurs d'une cle de CE donjon (pas seulement le meilleur), niveau decroissant.
-- Consomme par les chips de la homepage : une card = un donjon = N porteurs.
function K.HoldersForMap(challengeMapID)
    if not challengeMapID then return {} end
    local out = {}
    for _, e in ipairs(K.GroupKeystones()) do
        if e.challengeMapID == challengeMapID then out[#out + 1] = e end
    end
    table.sort(out, function(a, b)
        if a.level ~= b.level then return a.level > b.level end
        return (a.name or "") < (b.name or "")
    end)
    return out
end

--------------------------------------------------------------------------------
-- Helpers d'AFFICHAGE (partages par toutes les vues qui montrent une cle)
--------------------------------------------------------------------------------

-- Nom sans royaume : les noms circulent en "Nom-Royaume" (cf. qualifiedName) mais l'UI est
-- etroite -> on affiche le nom court, le nom complet reste dispo pour un tooltip.
function K.ShortName(name)
    if type(name) ~= "string" then return "?" end
    return name:match("^([^-]+)") or name
end

-- Rampe de couleur par niveau de cle (calque des raretes d'objet). Une SEULE definition,
-- utilisee par les chips des cards de la homepage.
function K.LevelColor(level)
    if not level then return 0.45, 0.45, 0.45 end
    if level >= 20 then return 0.64, 0.21, 0.93 end
    if level >= 15 then return 0.00, 0.44, 0.87 end
    if level >= 10 then return 0.12, 1.00, 0.00 end
    return 1, 1, 1
end

-- Meme rampe, en code inline "|cffRRGGBB" (pour un texte a couleurs MIXTES). Refermer par "|r".
function K.LevelHex(level)
    local r, g, b = K.LevelColor(level)
    -- math.floor : meme precaution que HR.Theme.Hex (pas de flottant passe a %x).
    return string.format("|cff%02x%02x%02x",
        math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end


--------------------------------------------------------------------------------
-- 2. JEU DE TEST STATIQUE (outil de DEV : `/run HR.Keys.SetTest(true)`)
--------------------------------------------------------------------------------
-- Plus de commande slash dediee (la feature est entierement pilotee par la homepage) : ce
-- jeu reste accessible a la main, pour re-verifier la mise en page des chips.
-- Verifier l'affichage des chips demande un groupe complet avec des cles du MEME donjon :
-- irreproductible a la demande. On injecte donc un jeu FIXE, en memoire, jamais persiste,
-- et on repartit les CAS SUR LES CARDS : une seule capture d'ecran couvre tout.
--   card 1 -> 5 porteurs (groupe plein)      card 5 -> 1
--   card 2 -> 4                              card 6 -> 0 (etat vide)
--   card 3 -> 3                              card 7 -> 6 (au-dela d'un groupe : debordement)
--   card 4 -> 2                              card 8 -> 5 noms LONGS (debordement en largeur)
-- Les noms reproduisent les DEUX formes que LibKeystone produit reellement (verifie dans la
-- lib) :
--   * cle d'un AUTRE membre -> Ambiguate(sender, "none") = "Nom-Royaume" TOUJOURS ("none" =
--     pas d'ambiguation, le royaume est conserve meme en same-realm ; la variable locale de
--     la lib s'appelle `shortName`, c'est trompeur) ;
--   * NOTRE cle             -> UnitNameUnmodified("player") = nom NU, jamais de royaume.
-- D'ou les royaumes inventes ci-dessous + une entree SANS royaume : les deux chemins passent
-- par K.ShortName, et aucun royaume ne doit fuir dans une chip.
local TEST_POOL = {
    { name = "Eiiko",               class = "MONK",         level = 18 },   -- nom NU = ma propre cle
    { name = "Remi-Sargeras",       class = "PRIEST",       level = 15 },
    { name = "Kaelis-Kirin Tor",    class = "EVOKER",       level = 22 },
    { name = "Nyxx-Illidan",        class = "DEMONHUNTER",  level = 9  },
    { name = "Torvus-Dalaran",      class = "WARRIOR",      level = 12 },
    { name = "Sylnara-Uldaman",     class = "DRUID",        level = 20 },
}
local TEST_POOL_LONG = {
    { name = "Bartholomewx-Conseil des Ombres", class = "PALADIN", level = 17 },
    { name = "Maximilliana-Confrerie du Thorium", class = "MAGE",  level = 14 },
    { name = "Chrysanthemum-Marecage de Zangar", class = "SHAMAN", level = 11 },
    { name = "XX-Archimonde",       class = "ROGUE",        level = 25 },
    { name = "Quicksilverblade-Les Sentinelles", class = "HUNTER", level = 8 },
}
-- Nombre de porteurs par index de card (au-dela : on boucle sur ce motif).
local TEST_COUNTS = { 5, 4, 3, 2, 1, 0, 6, 5 }

local testActive = false

function K.TestActive() return testActive end

function K.SetTest(on)
    testActive = on and true or false
    if HR.UI and HR.UI.RefreshHome then HR.UI.RefreshHome() end
    return testActive
end

-- Porteurs FICTIFS pour la card `index` (1-based). Renvoie {} hors mode test.
function K.TestHolders(index)
    if not testActive or not index then return {} end
    local slot  = ((index - 1) % #TEST_COUNTS) + 1
    local count = TEST_COUNTS[slot]
    local pool  = (slot == 8) and TEST_POOL_LONG or TEST_POOL
    local out = {}
    for i = 1, count do
        local e = pool[((i - 1) % #pool) + 1]
        out[#out + 1] = { name = e.name, class = e.class, level = e.level }
    end
    table.sort(out, function(a, b)
        if a.level ~= b.level then return a.level > b.level end
        return a.name < b.name
    end)
    return out
end

--------------------------------------------------------------------------------
-- 3. Evenements (dispatcher maison, cf. Core/Events.lua)
--------------------------------------------------------------------------------
-- Les events LFG (annonce active / liste d'activites) appartiennent au SERVICE
-- (Core/LFGService.lua) : les vues s'y abonnent via HR.LFG.OnChange. Ici, uniquement ce qui
-- fait bouger les CLES.
-- ⚠️ HR:RegisterEvent n'a pas d'unregister -> handlers volontairement cheap, et le
-- rafraichissement visuel sort tot si la page d'accueil n'est pas affichee.
local function refreshUI()
    if HR.UI and HR.UI.RefreshHome then HR.UI.RefreshHome() end   -- chips des cards
end

HR:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    if C_MythicPlus and C_MythicPlus.RequestMapInfo then C_MythicPlus.RequestMapInfo() end
    K.Request()
end)
HR:RegisterEvent("GROUP_ROSTER_UPDATE", function() K.Request(); refreshUI() end)
HR:RegisterEvent("CHALLENGE_MODE_MAPS_UPDATE", refreshUI)
HR:RegisterEvent("BAG_UPDATE_DELAYED", refreshUI)          -- ma propre cle a pu changer
