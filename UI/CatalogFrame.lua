-- EiikoCooldownPlanner - UI/CatalogFrame.lua
-- Vue CATALOGUE : chercher, parmi les packs recus, un plan pour un donjon (memo §13).
--
-- C'est une RECHERCHE, pas une bibliotheque. Le point de depart est le DONJON, jamais
-- l'auteur -- la question du joueur est « qu'est-ce que la communaute a pour CE donjon ? »
-- et non « qu'y a-t-il dans mon catalogue ? ». Le donjon EST donc le filtre par defaut.
--
-- CHAINE DE FILTRES : donjon -> spe -> sorts -> createur. Chaque niveau ne propose que ce
-- qui donne des resultats -- SAUF le donjon, seul endroit ou « 0 » repond a une question
-- (« personne n'a rien ici »). Ailleurs, offrir une option sans resultat est une impasse.
local addonName, HR = ...

HR.UI = HR.UI or {}
local UI = HR.UI

local PAD       = 12
local COL_DUNG  = 168      -- colonne de gauche : les donjons (-20 % : l'abbr suffit largement,
                           -- l'espace gagne va aux resultats, qui en manquent)
local D_ROW_H   = 30
local DUNG_ICON = 22
local SPEC_ICON = 30
local ROW_H     = 56       -- + d'air : « by <auteur> » mordait sur Preview/Use
local CHIP_ICON = 18
local CHIP_GAP  = 3
local MAX_ICONS = 10

-- QUATRE SECTIONS materialisees (fond + bordure, C.Container) : Dungeon a gauche, puis
-- Spec / Creator / Variants empilees a droite. Chacune porte son titre en BLANC -- le jaune
-- Blizzard signalait un lien ou une valeur, pas une rubrique.
--
-- La pile est NOMMEE plutot que calculee a chaque ancrage. Les offsets etaient ecrits a la
-- main (`-PAD - SPEC_ICON - 16`...) et « Creator » retombait a -58 alors que les icones de
-- spe descendent a -62 : ils se chevauchaient. Les hauteurs se DEDUISENT maintenant du
-- contenu de chaque section, donc la collision ne peut plus revenir.
local SEC_GAP    = 10                      -- air entre deux sections
local SEC_PADX   = 8                       -- padding interne (horizontal)
local SEC_PADY   = 8                       -- padding interne (vertical)
local HDR_H      = 16                      -- hauteur d'un titre de section
local HDR_GAP    = 6                       -- titre -> son contenu
local CREAT_H    = 26                      -- hauteur d'un bouton createur
local SEC_CHROME = 2 + SEC_PADY * 2        -- bordure (1 px x2) + padding vertical
local Y_BODY     = -(HDR_H + HDR_GAP)      -- contenu, sous le titre, DANS la section

local SPEC_SEC_H  = SEC_CHROME + HDR_H + HDR_GAP + SPEC_ICON
local CREAT_SEC_H = SEC_CHROME + HDR_H + HDR_GAP + CREAT_H
local RIGHT_X     = PAD + COL_DUNG + SEC_GAP

-- Etat de la recherche. Persiste tant que la session dure : le bouton generique de la
-- barre laterale RESTAURE cet etat, la ou une entree pre-reglee l'ECRASE (memo §13.3).
local q = { dID = nil, spec = nil, spells = nil, creatorId = nil }

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function DungeonRow(parent, i)
    local p = UI.catalogPanel
    local r = p.dungRows[i]
    if r then return r end
    r = CreateFrame("Button", nil, parent)
    r:SetHeight(D_ROW_H)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(DUNG_ICON, DUNG_ICON)
    r.icon:SetPoint("LEFT", 4, 0)
    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
    r.name:SetJustifyH("LEFT")
    r.count = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    r.count:SetPoint("RIGHT", -6, 0)
    r:SetHighlightTexture("Interface\\Buttons\\WHITE8x8", "ADD")
    local hl = r:GetHighlightTexture(); if hl then hl:SetVertexColor(1, 1, 1, 0.10) end
    r.sel = r:CreateTexture(nil, "BACKGROUND")
    r.sel:SetAllPoints(); r.sel:SetColorTexture(1, 0.82, 0, 0.16); r.sel:Hide()
    p.dungRows[i] = r
    return r
end

local function SpecButton(parent, i)
    local p = UI.catalogPanel
    local b = p.specBtns[i]
    if b then return b end
    b = CreateFrame("Button", nil, parent)
    b:SetSize(SPEC_ICON, SPEC_ICON)
    b.icon = b:CreateTexture(nil, "ARTWORK"); b.icon:SetAllPoints()
    b.sel = b:CreateTexture(nil, "BACKGROUND")
    b.sel:SetPoint("TOPLEFT", -2, 2); b.sel:SetPoint("BOTTOMRIGHT", 2, -2)
    b.sel:SetColorTexture(1, 0.82, 0, 0.9); b.sel:Hide()
    b:SetHighlightTexture("Interface\\Buttons\\WHITE8x8", "ADD")
    local hl = b:GetHighlightTexture(); if hl then hl:SetVertexColor(1, 1, 1, 0.18) end
    p.specBtns[i] = b
    return b
end

-- Une ligne de resultat : nom + compo en pastilles + auteur + action.
local function ResultRow(parent, i)
    local p = UI.catalogPanel
    local r = p.rows[i]
    if r then return r end
    local C = UI.Components
    r = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    r:SetHeight(ROW_H)
    r:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8",
                    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
                    insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    r:SetBackdropColor(0.16, 0.16, 0.18, 0.92)
    r:SetBackdropBorderColor(0.40, 0.40, 0.45, 1)

    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.name:SetPoint("TOPLEFT", 10, -8)
    r.name:SetPoint("RIGHT", r, "RIGHT", -160, 0)   -- s'arrete avant Preview + Use
    r.name:SetJustifyH("LEFT")

    r.by = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    -- Ligne du HAUT, a droite ; les boutons vivent en bas. Avec l'ancienne hauteur de
    -- rangee les deux se touchaient -- d'ou ROW_H, qui degage la bande entre les deux.
    r.by:SetPoint("TOPRIGHT", -12, -8)
    r.by:SetJustifyH("RIGHT")

    -- PROMOTION : catalogue -> variante jouable (memo §10.9). La variante obtenue est en
    -- LECTURE SEULE et suit les mises a jour de son auteur ; dupliquer est la sortie.
    r.promote = C.TextButton(r, { text = "Use", width = 64, height = 24 })
    r.promote:SetPoint("BOTTOMRIGHT", -10, 8)
    r.promote:SetOnClick(function()
        if not r._entry then return end
        local v, how = HR.Catalog.Promote(r._entry, r._creator)
        if not v then HR:Print("Could not add this plan."); return end
        -- ⚠️ Nom ECHAPPE meme au CHAT : la fenetre de discussion interprete le markup tout
        -- autant qu'un FontString, donc un nom de catalogue contenant `|H...|h` y afficherait
        -- un faux lien cliquable. Meme regle qu'a l'ecran (memo §7.4), simplement moins
        -- evidente ici -- c'est pour ca qu'elle avait ete oubliee.
        local nm = HR.EscapeMarkup(v.name or "?")
        if how == "exists" then
            HR:Print(("\"%s\" is already in your plans."):format(nm))
        else
            HR:Print(("\"%s\" added to your plans -- read-only, and it will follow its "
                .. "author's updates. Duplicate it to make it yours."):format(nm))
        end
        UI.RenderCatalog()
    end)

    -- Apercu : montre ce que le plan FAIT avant de l'adopter (cf. UI/CatalogPreview.lua).
    -- L'entree affichee est memorisee sur la ligne (`r._entry`) plutot que capturee dans
    -- la fermeture : les lignes sont POOLEES et reutilisees d'un rendu a l'autre, donc une
    -- fermeture posee une fois pointerait a jamais la premiere entree affichee.
    r.preview = C.TextButton(r, { text = "Preview", width = 76, height = 24 })
    r.preview:SetPoint("RIGHT", r.promote, "LEFT", -6, 0)
    r.preview:SetOnClick(function()
        if r._entry then UI.ShowCatalogPreview(r._entry, r._creator) end
    end)

    r.icons = {}
    p.rows[i] = r
    return r
end

local function BuildPanel()
    if UI.catalogPanel then return end
    local C = UI.Components

    -- Barre haute, calquee sur celle des Settings (meme hauteur, meme fond).
    local bar = CreateFrame("Frame", nil, UI.body)
    bar:SetPoint("TOPLEFT", 0, 0); bar:SetPoint("TOPRIGHT", 0, 0)
    bar:SetHeight(61)
    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    bar.bg:SetColorTexture(HR.Theme.Unpack("ZONE_BACKGROUND"))
    bar.title = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    bar.title:SetPoint("LEFT", 16, 0)
    bar.title:SetText("Catalogue")
    bar.title:SetTextColor(1, 1, 1)   -- rubrique, pas valeur : blanc (cf. les titres de section)
    bar:Hide()
    UI.catalogBar = bar

    local p = CreateFrame("Frame", nil, UI.body)
    p:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, 0)
    p:SetPoint("BOTTOMRIGHT", UI.body, "BOTTOMRIGHT", 0, 0)
    p:Hide()
    UI.catalogPanel = p

    p.dungRows, p.specBtns, p.rows, p.creatorBtns = {}, {}, {}, {}

    -- Une section = un C.Container (fond + bordure 1 px, tokens du theme) dont `.content`
    -- est deja insette de la bordure et du padding. On ancre donc tout dans `.content`, et
    -- plus rien ne se calcule par rapport au panneau.
    local function Section(title)
        -- Bordure VIOLETTE (token SECTION_BORDER_COLOR) : une section structure la page,
        -- elle porte donc l'identite d'ECP -- la ou le gris de `CONTAINER_BORDER_COLOR`
        -- convient a un conteneur quelconque. Le token suit le theme actif : le theme
        -- alternatif rend du vert sans qu'on touche a ce fichier. (Lu a la CONSTRUCTION,
        -- comme tous les C.Container de l'addon : un changement de theme se voit au reload.)
        local f = C.Container(p, { padX = SEC_PADX, padY = SEC_PADY,
                                   borderColor = HR.Theme.Color("SECTION_BORDER_COLOR") })
        f.hdr = f.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        f.hdr:SetPoint("TOPLEFT", 0, 0)
        f.hdr:SetText(title)
        f.hdr:SetTextColor(1, 1, 1)     -- BLANC : c'est une rubrique, pas une valeur
        return f
    end

    p.secDung = Section("Dungeon")
    p.secDung:SetPoint("TOPLEFT", PAD, -PAD)
    p.secDung:SetPoint("BOTTOMLEFT", PAD, PAD)
    p.secDung:SetWidth(COL_DUNG)

    p.secSpec = Section("Spec")
    p.secSpec:SetPoint("TOPLEFT", RIGHT_X, -PAD)
    p.secSpec:SetPoint("TOPRIGHT", -PAD, -PAD)
    p.secSpec:SetHeight(SPEC_SEC_H)

    p.secCreat = Section("Creator")
    p.secCreat:SetPoint("TOPLEFT", p.secSpec, "BOTTOMLEFT", 0, -SEC_GAP)
    p.secCreat:SetPoint("TOPRIGHT", p.secSpec, "BOTTOMRIGHT", 0, -SEC_GAP)
    p.secCreat:SetHeight(CREAT_SEC_H)

    -- Variantes : prend tout ce qui reste jusqu'en bas.
    p.secVar = Section("Variants")
    p.secVar:SetPoint("TOPLEFT", p.secCreat, "BOTTOMLEFT", 0, -SEC_GAP)
    p.secVar:SetPoint("TOPRIGHT", p.secCreat, "BOTTOMRIGHT", 0, -SEC_GAP)
    p.secVar:SetPoint("BOTTOM", p, "BOTTOM", 0, PAD)

    -- RETOUR : au bout de la rangee de spes, colle a droite. Le catalogue s'ouvre souvent
    -- DEPUIS une variante (bouton « Browse catalogue »), et sans sortie explicite il faut
    -- deviner qu'on reclique l'icone de la barre laterale pour revenir.
    -- ⚠️ Exactement le MEME geste que ce reclic : `SetViewMode` bascule (« si on redemande
    -- le mode courant, mode = nil »), donc on retombe sur la page de donjon d'ou l'on vient,
    -- par le meme chemin. Rien a memoriser : la selection du plan (UI.selDungeon /
    -- activeDungeonID) n'a jamais ete touchee, le catalogue a son etat a lui (`q`).
    p.back = C.TextButton(p.secSpec.content, { text = "Back", autoWidth = true, minWidth = 0,
                                               padX = 12, height = SPEC_ICON - 4 })
    p.back:SetPoint("TOPRIGHT", p.secSpec.content, "TOPRIGHT", 0, Y_BODY - 2)
    p.back:SetOnClick(function() UI.SetViewMode("catalog") end)
    C.AttachHelpTip(p.back, "Back",
        "Return to the dungeon page you came from. Same thing as clicking the Catalogue "
        .. "icon again in the sidebar.")

    -- Zone defilante des resultats, DANS la section Variants.
    p.scroll = CreateFrame("ScrollFrame", nil, p.secVar.content, "UIPanelScrollFrameTemplate")
    p.scroll:SetPoint("TOPLEFT", 0, Y_BODY)
    p.scroll:SetPoint("BOTTOMRIGHT", -22, 0)      -- place pour l'ascenseur
    p.list = CreateFrame("Frame", nil, p.scroll)
    p.list:SetSize(1, 1)
    p.scroll:SetScrollChild(p.list)
    -- La largeur d'un ScrollChild n'est pas heritee : sans elle, les lignes ancrees a
    -- droite se retrouvent sans largeur (et un FontString a largeur negative n'affiche rien).
    p.scroll:SetScript("OnSizeChanged", function(self, w)
        if w and w > 0 then p.list:SetWidth(w) end
    end)

    p.empty = p:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
    p.empty:SetPoint("CENTER", p.scroll, "CENTER", 0, 0)
    p.empty:Hide()
end

--------------------------------------------------------------------------------
-- Rendu
--------------------------------------------------------------------------------

local function ChipIcons(row, entry)
    for _, it in ipairs(row.icons) do it:Hide() end
    -- Les descripteurs viennent d'ECP lui-meme : c'est LA definition de « ce que contient
    -- une variante » en images. Une entree de catalogue a la meme forme qu'une variante
    -- (memo §2.3), donc la meme fonction s'applique telle quelle.
    local items = HR.VariantIconItems and HR.VariantIconItems(entry) or {}
    local x = 10
    for i = 1, math.min(#items, MAX_ICONS) do
        local item = items[i]
        local it = row.icons[i]
        if not it then
            it = UI.Components.ImageText(row, { size = CHIP_ICON, banner = true, textSize = 8 })
            row.icons[i] = it
        end
        if item.spec then
            HR.Icons.Apply(it.image, "healer", item.spec)
            it:SetText(""); if it.banner then it.banner:Hide() end
        else
            HR.Icons.Apply(it.image, "defensive", item.key)
            local show = item.banner and item.cd and item.cd > 0
            it:SetText(show and HR.FormatCooldown(item.cd) or "")
            if it.banner then it.banner:SetShown(show and true or false) end
        end
        it:ClearAllPoints(); it:SetPoint("BOTTOMLEFT", x, 6)
        it:Show()
        x = x + CHIP_ICON + CHIP_GAP
    end
end

function UI.RenderCatalog()
    BuildPanel()
    UI.catalogBar:Show()
    UI.catalogPanel:Show()
    local p = UI.catalogPanel

    for _, r in ipairs(p.dungRows)    do r:Hide() end
    for _, b in ipairs(p.specBtns)    do b:Hide() end
    for _, b in ipairs(p.creatorBtns) do b:Hide() end
    for _, r in ipairs(p.rows)        do r:Hide() end

    -- NIVEAU 1 : les donjons. TOUS, avec leur compte -- ici « 0 » est une INFORMATION.
    local counts = HR.Catalog.CountsByDungeon()
    local y = Y_BODY
    for i, d in ipairs(HR.content or {}) do
        local r = DungeonRow(p.secDung.content, i)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", 0, y)
        r:SetPoint("RIGHT", p.secDung.content, "RIGHT", 0, 0)
        HR.Icons.Apply(r.icon, "dungeon", d)
        r.name:SetText(d.abbr or d.name or "?")
        local n = counts[d.id] or 0
        r.count:SetText(n > 0 and ("|cff33ff99%d|r"):format(n) or "|cff707070-|r")
        r.sel:SetShown(q.dID == d.id)
        r:SetScript("OnClick", function()
            q.dID = d.id
            q.spec, q.creatorId = nil, nil     -- changer de donjon invalide les niveaux suivants
            UI.RenderCatalog()
        end)
        r:Show()
        y = y - D_ROW_H
    end

    if not q.dID then
        p.empty:SetText("Pick a dungeon.")
        p.empty:Show(); p.scroll:Hide()
        return
    end

    -- NIVEAU 2 : les spes REELLEMENT presentes dans ce donjon (liste derivee).
    -- Defaut : la mienne SI elle y figure ; sinon on laisse choisir plutot que d'afficher
    -- une liste vide alors que du contenu existe juste a cote.
    local specs = HR.Catalog.SpecsForDungeon(q.dID)
    if q.spec and not tContains(specs, q.spec) then q.spec = nil end
    if not q.spec then
        local mine = HR.MyHealKey()
        if mine and tContains(specs, mine) then q.spec = mine end
    end

    local x = 0
    for i, key in ipairs(specs) do
        local prof = HR.GetHealProfileOrNone(key)
        local b = SpecButton(p.secSpec.content, i)
        b:ClearAllPoints(); b:SetPoint("TOPLEFT", x, Y_BODY)
        HR.Icons.Apply(b.icon, "healer", prof or key)
        b.sel:SetShown(q.spec == key)
        b:SetScript("OnClick", function()
            q.spec = (q.spec == key) and nil or key
            q.creatorId = nil                  -- le createur derive du resultat : il se recalcule
            UI.RenderCatalog()
        end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText((prof and prof.name) or key)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        b:Show()
        x = x + SPEC_ICON + 6
    end

    -- NIVEAU 3 : la recherche. `spells` nil = AUCUNE contrainte (filtre encore inerte,
    -- sa semantique n'est pas tranchee -- cf. Core/Catalog.lua).
    local results = HR.Catalog.Search(q)

    -- NIVEAU 4 : les createurs, DERIVES du resultat deja filtre. Un auteur sans
    -- correspondance ne s'affiche pas : ce serait une impasse.
    local facet = HR.Catalog.CreatorFacet(HR.Catalog.Search({ dID = q.dID, spec = q.spec }))
    x = 0
    for i, f in ipairs(facet) do
        local C = UI.Components
        local b = p.creatorBtns[i]
        if not b then
            b = C.TextButton(p.secCreat.content, { text = "", autoWidth = true, minWidth = 0,
                                                   padX = 10, height = CREAT_H })
            p.creatorBtns[i] = b
        end
        b:SetText(("%s |cff808080(%d)|r"):format(
            HR.EscapeMarkup((f.creator and f.creator.name) or "?"), f.count))
        b:SetSelected(q.creatorId == f.creatorId)
        b:SetOnClick(function()
            q.creatorId = (q.creatorId == f.creatorId) and nil or f.creatorId
            UI.RenderCatalog()
        end)
        b:ClearAllPoints(); b:SetPoint("TOPLEFT", x, Y_BODY)
        b:Show()
        x = x + (b:GetWidth() or 60) + 6
    end

    -- RESULTATS
    if #results == 0 then
        p.scroll:Hide()
        p.empty:SetText("Nothing here yet.")
        p.empty:Show()
        return
    end
    p.empty:Hide(); p.scroll:Show()

    local ly = 0
    for i, it in ipairs(results) do
        local r = ResultRow(p.list, i)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", 0, ly)
        r:SetPoint("RIGHT", p.list, "RIGHT", 0, 0)
        r._entry, r._creator = it.entry, it.creator
        r.name:SetText(HR.EscapeMarkup(it.entry.name or "?"))
        -- Deja adoptee ? Etat DERIVE (on cherche la variante portant ce cid), jamais
        -- stocke : rien a poser au bon moment, rien qui puisse se desynchroniser.
        local owned = HR.Catalog.PromotedVariant(it.entry.cid, it.entry.dID) ~= nil
        r.promote:SetText(owned and "Added" or "Use")
        r.promote:SetEnabled(not owned)
        r.promote:SetAlpha(owned and 0.45 or 1)
        r.by:SetText(("|cff808080by|r %s"):format(
            HR.EscapeMarkup((it.creator and it.creator.name) or "?")))
        ChipIcons(r, it.entry)
        r:Show()
        ly = ly - (ROW_H + 6)
    end
    p.list:SetHeight(math.max(-ly, 1))
end

--------------------------------------------------------------------------------
-- Entrees publiques
--------------------------------------------------------------------------------

-- Spe a pre-selectionner pour un donjon, quand on ouvre le catalogue DEPUIS un contexte
-- (bouton « Browse catalogue » d'une variante). Deux replis, dans cet ordre :
--   1. la MIENNE, si elle a du contenu dans ce donjon ;
--   2. sinon la PREMIERE disponible.
-- Le second repli couvre les deux cas d'un coup : le joueur n'est pas sur une spe de soin
-- (HR.MyHealKey renvoie nil), ou il l'est mais personne n'a publie pour elle ici. Dans les
-- deux cas, atterrir sur une liste vide alors que du contenu existe juste a cote serait le
-- pire resultat (memo §13.2).
-- nil si le donjon n'a aucune entree -- il n'y a alors rien a pre-selectionner.
function UI.CatalogueDefaultSpec(dID)
    local specs = HR.Catalog.SpecsForDungeon(dID)
    local mine  = HR.MyHealKey and HR.MyHealKey()
    if mine and tContains(specs, mine) then return mine end
    return specs[1]
end

-- Ouvre le catalogue. `query` PRE-REGLE la recherche ; sans argument, on RESTAURE l'etat
-- precedent (memo §13.3).
--
-- ⚠️ Les deux comportements sont volontairement differents. Une entree contextuelle
-- (« plans pour ce donjon ») doit REAPPLIQUER sa requete a chaque fois -- c'est tout son
-- interet. Le bouton generique, lui, doit rendre au joueur la recherche qu'il avait en
-- cours, sinon il la perd des qu'il ferme la fenetre par megarde.
function UI.OpenCatalogue(query)
    if query then
        q.dID       = query.dID
        q.spec      = query.spec
        q.spells    = query.spells
        q.creatorId = query.creatorId
    elseif not q.dID then
        -- Premiere ouverture : on part du donjon courant, comme la fenetre principale le
        -- fait deja a son ouverture (HR.GetCurrentDungeonIndex).
        local idx = HR.GetCurrentDungeonIndex and HR.GetCurrentDungeonIndex()
        local d = idx and HR.content[idx]
        q.dID = d and d.id or nil
    end
    if UI.SetViewMode then UI.SetViewMode("catalog") end
end

-- Re-rendu si la vue est affichee (appele apres un import).
function UI.RefreshCatalog()
    if UI.catalogPanel and UI.catalogPanel:IsVisible() then UI.RenderCatalog() end
end
