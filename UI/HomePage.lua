-- HealPlanner - UI/HomePage.lua
-- Page d'ACCUEIL de la modale (viewMode == "home", bouton Home en HAUT de la sidebar).
--
-- Structure :
--   * barre haute `UI.homeBar` : bandeau VIDE (ni titre, ni boutons). Il n'est la que pour
--     que la grille demarre a la meme hauteur que le contenu des autres vues.
--   * grille de CARDS `UI.homePanel` (3 colonnes) : une card par donjon, dans le MEME ORDRE
--     que la sidebar (HR.content). Rien d'autre : les reglages restent le bouton dedie de
--     la sidebar.
--
-- Une card reutilise l'artwork de fond du donjon (cle d'asset "bg-<ABBR>", exactement
-- celui de la zone de timeline, cf. UI.UpdateContentBg) : chaque donjon a deja le sien.
local addonName, HR = ...

HR.UI = HR.UI or {}
local UI = HR.UI

local COLS      = 3       -- grille 3 colonnes (3 rangees avec les 8 donjons)
local CARD_GAP  = 12
local CARD_PAD  = 10      -- marge interne d'une card (titre / boutons)
local GRID_PAD  = 16      -- marge de la grille dans le body
local CHIP_H    = 24      -- PLANCHER de hauteur d'une chip (la hauteur reelle suit le padding)
local CHIP_GAP  = 4       -- ecart horizontal entre chips
local CHIP_ROW  = 4       -- ecart vertical entre rangees de chips

local LayoutChips         -- declaree ici : AcquireCard s'y refere avant sa definition

-- Cle d'asset du fond d'un donjon, avec le MEME garde-fou que UI.UpdateContentBg : une cle
-- absente du registre renverrait le fallback "?" de HR.Asset -> on prefere aucune texture.
local function dungeonArt(dungeon)
    local key = dungeon and dungeon.abbr and ("bg-" .. dungeon.abbr)
    return (key and HR.Assets.registry[key]) and HR.Asset(key) or nil
end

-- Anti-etirement : nos fonds sont CARRES et les cards rectangulaires. Meme traitement
-- "cover" que UI.LayoutContentBg / les modales : ratio conserve, excedent rogne.
local function LayoutCardArt(card)
    if not card.art then return end
    local w, h = card:GetWidth(), card:GetHeight()
    if not w or not h or w <= 0 or h <= 0 then return end
    local af = w / h
    if af >= 1 then
        local dv = 1 / af
        card.art:SetTexCoord(0, 1, (1 - dv) / 2, (1 + dv) / 2)
    else
        local du = af
        card.art:SetTexCoord((1 - du) / 2, (1 + du) / 2, 0, 1)
    end
end

--------------------------------------------------------------------------------
-- Cards (poolees : on MUTE, on ne recree jamais)
--------------------------------------------------------------------------------

local function AcquireCard(i)
    local c = UI.homeCards[i]
    if c then return c end

    local C = UI.Components
    -- Container = fond + bordure themee (tokens CONTAINER_*) pour rester dans le style maison.
    c = C.Container(UI.homePanel, { content = false, padX = CARD_PAD, padY = CARD_PAD })

    -- Artwork du donjon PAR-DESSUS le fond uni du container, puis voile de lisibilite.
    c.art = c:CreateTexture(nil, "BACKGROUND", nil, 1)
    c.art:SetAllPoints()
    -- Filtre assombrissant LEGER par-dessus l'artwork : juste de quoi poser le titre et les
    -- CTA sans manger l'image. (Un seul voile : en empiler deux assombrirait au lieu d'alleger.)
    c.dim = c:CreateTexture(nil, "BACKGROUND", nil, 2)
    c.dim:SetAllPoints()
    c.dim:SetColorTexture(0, 0, 0, 0.5)
    c:HookScript("OnSizeChanged", LayoutCardArt)

    -- Titre : centre EN HAUT, en violet (token EMPHASIZE_TEXT_COLOR).
    -- TOPLEFT + TOPRIGHT (pas TOP + LEFT/RIGHT : LEFT/RIGHT contraignent aussi le centre
    -- vertical et entreraient en conflit avec TOP). Largeur pleine => JustifyH CENTER centre.
    c.title = c:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    c.title:SetPoint("TOPLEFT", CARD_PAD, -CARD_PAD)
    c.title:SetPoint("TOPRIGHT", -CARD_PAD, -CARD_PAD)
    c.title:SetJustifyH("CENTER")
    c.title:SetWordWrap(true)
    c.title:SetTextColor(HR.Theme.Unpack("EMPHASIZE_TEXT_COLOR"))

    -- Deux CTA en bas : Configure (ouvre le donjon, comme la sidebar) et List Group.
    c.btnConfigure = C.TextButton(c, { text = "Configure", autoWidth = true, minWidth = 96,
        padX = 12, padY = 7, onClick = function(self)
            local idx = self:GetParent()._dungeonIndex
            if idx then UI.SelectDungeon(idx) end      -- SelectDungeon appelle deja ExitViewMode
        end })
    c.btnConfigure:SetPoint("BOTTOMLEFT", CARD_PAD, CARD_PAD)

    -- On ne CREE plus l'annonce : on ouvre l'outil Blizzard positionne sur le donjon, et le
    -- joueur ecrit son titre puis liste lui-meme (le titre est inaccessible a un addon, cf.
    -- Core/LFGService.lua). Appel direct dans le OnClick : chaine sensible au taint.
    c.btnList = C.TextButton(c, { text = "List Group", autoWidth = true, minWidth = 96,
        padX = 12, padY = 7, onClick = function(self)
            local card = self:GetParent()
            local dungeon = HR.content[card._dungeonIndex or 0]
            if not dungeon then return end
            if HR.LFG.IsListedFor(HR.LFG.ActivityForDungeon(dungeon)) then
                HR.LFG.Delist()
            else
                -- On NE cree PAS l'annonce : on ouvre le formulaire Blizzard sur le bon donjon,
                -- le joueur ecrit son titre et liste lui-meme. Marche pour N'IMPORTE quel donjon,
                -- y compris ceux dont on ne possede pas la cle. SILENCIEUX (aucun message chat).
                HR.LFG.PrepareListing(dungeon)
            end
            UI.RefreshHomeButtons()
        end })
    c.btnList:SetPoint("BOTTOMRIGHT", -CARD_PAD, CARD_PAD)

    -- Zone des chips : entre le titre et les CTA. TOPLEFT + BOTTOMRIGHT uniquement (2 points
    -- opposes) -> aucun conflit de contrainte, et la zone suit la taille de la card.
    c.chipArea = CreateFrame("Frame", nil, c)
    c.chipArea:SetPoint("TOPLEFT", c.title, "BOTTOMLEFT", 0, -6)
    c.chipArea:SetPoint("BOTTOMRIGHT", c.btnList, "TOPRIGHT", 0, 6)
    c.chips = {}
    -- La taille reelle de la zone n'est connue qu'apres la passe de layout du client -> on
    -- reflow sur OnSizeChanged (c'est aussi ce qui rejoue le wrap quand la modale change de
    -- taille). D'ou la declaration ANTICIPEE de LayoutChips plus haut.
    c.chipArea:HookScript("OnSizeChanged", function() LayoutChips(c, c._holders or {}) end)

    UI.homeCards[i] = c
    return c
end

-- Chips poolees PAR CARD (une card = un donjon = ses porteurs).
local function AcquireChip(c, i)
    local chip = c.chips[i]
    if chip then return chip end
    chip = UI.Components.Chip(c.chipArea, { minHeight = CHIP_H, textSize = 11, padX = 12, padY = 6 })
    c.chips[i] = chip
    return chip
end

-- Pose les chips en FLOW (gauche->droite, retour a la ligne, chaque rangee centree) dans la
-- place reellement disponible. Ce qui ne rentre pas est resume par une chip "+N" : une card
-- ne doit jamais deborder sur ses CTA, quel que soit le nombre de porteurs ou la longueur
-- des noms.
function LayoutChips(c, holders)
    for _, chip in ipairs(c.chips) do chip:Hide() end
    local W, H = c.chipArea:GetWidth(), c.chipArea:GetHeight()
    if not W or W <= 0 or not H or H <= 0 or #holders == 0 then return end

    -- Hauteur REELLE d'une chip (elle depend du padding et de la police) : on la mesure sur
    -- une chip sonde plutot que de la supposer, sinon le nombre de rangees serait faux des
    -- qu'on touche au padding. Cette chip est remise a son vrai texte juste apres, dans la boucle.
    local probe = AcquireChip(c, 1)
    probe:SetMaxWidth(W)
    probe:SetText("Ag+10")
    local chipH = probe:GetHeight()

    local maxRows = math.max(1, math.floor((H + CHIP_ROW) / (chipH + CHIP_ROW)))
    local rows, row, rowW = {}, {}, 0

    local function pushRow()
        if #row > 0 then rows[#rows + 1] = { items = row, width = rowW } end
        row, rowW = {}, 0
    end

    for i, e in ipairs(holders) do
        local chip = AcquireChip(c, i)
        chip:SetMaxWidth(W)             -- un nom tres long est tronque, jamais deborde
        -- Nom COURT en couleur de classe + niveau en couleur de rarete (K.LevelHex).
        chip:SetText(("|c%s%s|r %s+%d|r"):format(
            HR.ClassColorHex(e.class), HR.Keys.ShortName(e.name), HR.Keys.LevelHex(e.level), e.level))
        local w = chip:GetWidth()
        if #row > 0 and rowW + CHIP_GAP + w > W then pushRow() end
        if #rows >= maxRows then break end          -- plus de place en hauteur
        row[#row + 1] = chip
        rowW = rowW + (#row > 1 and CHIP_GAP or 0) + w
    end
    pushRow()
    while #rows > maxRows do rows[#rows] = nil end   -- la derniere rangee ne rentrait pas

    -- Ce qui n'est pas affiche est resume par "+N". Le compte se deduit des rangees RETENUES
    -- (et pas de la boucle) : une rangee tronquee juste au-dessus fausserait le total.
    local shown = 0
    for _, r in ipairs(rows) do shown = shown + #r.items end
    if shown < #holders and #rows > 0 then
        local left = #holders - shown
        local last = rows[#rows]
        local more = AcquireChip(c, #holders + 1)    -- index dedie, hors des porteurs
        more:SetText(("|cffb0b0b0+%d|r"):format(left))
        -- Faire de la place a la chip "+N" sur la derniere rangee (chaque chip retiree
        -- augmente le reste, donc son libelle).
        while #last.items > 0 and last.width + CHIP_GAP + more:GetWidth() > W do
            local dropped = table.remove(last.items)
            last.width = last.width - dropped:GetWidth() - CHIP_GAP
            dropped:Hide()
            left = left + 1
            more:SetText(("|cffb0b0b0+%d|r"):format(left))
        end
        last.items[#last.items + 1] = more
        last.width = last.width + (#last.items > 1 and CHIP_GAP or 0) + more:GetWidth()
    end

    -- Positionnement : rangees empilees depuis le haut, chacune CENTREE horizontalement.
    for ri, r in ipairs(rows) do
        local x = math.max(0, (W - r.width) / 2)
        local y = -(ri - 1) * (chipH + CHIP_ROW)
        for _, chip in ipairs(r.items) do
            chip:ClearAllPoints()
            chip:SetPoint("TOPLEFT", c.chipArea, "TOPLEFT", x, y)
            chip:Show()
            x = x + chip:GetWidth() + CHIP_GAP
        end
    end
end

-- Libelle du CTA : la card DEJA listee propose Delist, les autres ouvrent le formulaire
-- Blizzard sur leur donjon. Aucune garde de possession de cle : on ne cree pas l'annonce,
-- donc on peut preparer n'importe quel donjon (y compris pour en chercher la cle).
local function listLabel(dungeon)
    if HR.LFG.IsListedFor(HR.LFG.ActivityForDungeon(dungeon)) then return "Delist" end
    -- Le MODE TEST bypasse la garde de lead (comme le mode test du runtime bypasse la gate de zone).
    if not HR.LFG.CanList() and not HR.Keys.TestActive() then return "Leader only" end
    return "List Group"
end

-- Rafraichit les seuls libelles (pas de relayout) : appele au clic et sur HR.LFG.OnChange.
function UI.RefreshHomeButtons()
    if not (UI.homePanel and UI.homePanel:IsShown()) then return end
    for i, c in ipairs(UI.homeCards) do
        local dungeon = c._dungeonIndex and HR.content[c._dungeonIndex]
        if dungeon and c.btnList:IsShown() then c.btnList:SetText(listLabel(dungeon)) end
    end
end

--------------------------------------------------------------------------------
-- Construction / rendu
--------------------------------------------------------------------------------

local function BuildHomePanel()
    -- Barre haute, calquee sur la barre "Settings" (meme hauteur, meme fond de zone) mais
    -- SANS aucun bouton : c'est voulu.
    local bar = CreateFrame("Frame", nil, UI.body)
    bar:SetPoint("TOPLEFT", UI.body, "TOPLEFT", 0, 0)
    bar:SetPoint("TOPRIGHT", UI.body, "TOPRIGHT", 0, 0)
    bar:SetHeight((UI.bossRow and UI.bossRow:GetHeight()) or 61)
    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    bar.bg:SetColorTexture(HR.Theme.Unpack("ZONE_BACKGROUND"))
    bar:Hide()
    UI.homeBar = bar

    local grid = CreateFrame("Frame", nil, UI.body)
    grid:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", GRID_PAD, -GRID_PAD)
    grid:SetPoint("BOTTOMRIGHT", UI.body, "BOTTOMRIGHT", -GRID_PAD, GRID_PAD)
    grid:Hide()
    grid:HookScript("OnSizeChanged", function() UI.LayoutHome() end)
    UI.homePanel = grid
    UI.homeCards = {}

    -- L'annonce a change (ici ou depuis l'UI Blizzard) -> les CTA suivent.
    -- Abonnement ICI (1re construction) et pas au chargement du fichier : UI/ charge AVANT
    -- Core/, donc HR.LFG n'existe pas encore a ce moment-la.
    HR.LFG.OnChange(function() UI.RefreshHomeButtons() end)
end

-- (Re)pose les cards dans la grille : taille deduite de la place disponible, donc la page
-- suit un redimensionnement de la modale sans constante en dur.
function UI.LayoutHome()
    if not UI.homePanel or not UI.homeCards then return end
    local gw, gh = UI.homePanel:GetSize()
    if not gw or gw <= 0 or not gh or gh <= 0 then return end

    local n    = #HR.content                          -- une card par donjon
    local rows = math.max(1, math.ceil(n / COLS))
    local cw   = (gw - CARD_GAP * (COLS - 1)) / COLS
    local ch   = (gh - CARD_GAP * (rows - 1)) / rows

    for i = 1, n do
        local c   = UI.homeCards[i]
        if c then
            local col = (i - 1) % COLS
            local row = math.floor((i - 1) / COLS)
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", UI.homePanel, "TOPLEFT",
                col * (cw + CARD_GAP), -row * (ch + CARD_GAP))
            c:SetSize(cw, ch)
            LayoutChips(c, c._holders or {})   -- la largeur a change -> le wrap aussi
        end
    end
end

-- Re-rend la page si elle est REELLEMENT visible (changement de cles, bascule du mode test...).
-- IsVisible (et pas IsShown) : un enfant garde son flag "shown" quand la modale est fermee, on
-- re-rendrait donc une page invisible a chaque cle recue.
-- GARDE DE REENTRANCE : le rendu peut declencher des callbacks (cles, LFG) qui rappellent
-- RefreshHome ; sans ce verrou, un seul aller-retour suffit a figer le jeu.
local rendering = false
function UI.RefreshHome()
    if rendering then return end
    if UI.homePanel and UI.homePanel:IsVisible() then UI.RenderHome() end
end

-- Rendu de la page d'accueil (construite a la 1re fois).
function UI.RenderHome()
    if rendering then return end
    rendering = true
    if not UI.homePanel then BuildHomePanel() end
    UI.homeBar:Show()
    UI.homePanel:Show()
    HR.LFG.RequestActivities()      -- sans ca le mapping donjon -> activite peut etre vide
    -- ⚠️ NE JAMAIS appeler HR.Keys.Request() ICI : LibKeystone rejoue ses callbacks
    -- IMMEDIATEMENT (seul l'envoi reseau est throttle, pas le callback), et notre callback
    -- appelle RefreshHome -> RenderHome -> Request -> ... = recursion infinie, jeu fige a 0 fps.
    -- Le rescan se fait a l'OUVERTURE de la fenetre (UI.Toggle / UI.ShowHomePage), pas au rendu.

    for _, c in ipairs(UI.homeCards) do c:Hide() end

    -- Une card par donjon, dans l'ORDRE de la sidebar (et rien d'autre : pas de card Settings,
    -- les reglages restent le bouton dedie de la sidebar).
    for i, dungeon in ipairs(HR.content) do
        local c = AcquireCard(i)
        local art = dungeonArt(dungeon)
        c._dungeonIndex = i
        c.art:SetTexture(art)
        c.art:SetShown(art ~= nil)
        c.title:SetText(dungeon.name or "?")
        c.btnList:SetText(listLabel(dungeon))
        -- Porteurs de cle de CE donjon : jeu de test statique si actif, sinon le vrai groupe.
        c._holders = HR.Keys.TestActive() and HR.Keys.TestHolders(i)
            or HR.Keys.HoldersForMap(HR.LFG.ChallengeMapForDungeon(dungeon))
        c:Show()
        LayoutCardArt(c)
    end

    UI.LayoutHome()
    rendering = false
end
