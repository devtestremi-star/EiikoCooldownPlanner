-- EiikoCooldownPlanner - UI/CatalogPreview.lua
-- Apercu SIMPLIFIE d'un plan de catalogue, avant de l'adopter.
--
-- FORME : par boss, une frise CONDENSEE. Chaque occurrence planifiee est une colonne --
-- le sort du boss en base, les defensifs empiles au-dessus, cote a cote s'il y en a
-- plusieurs. Les colonnes se suivent : la largeur d'une colonne est celle de son contenu
-- le plus large, donc le sort de boss suivant commence APRES le dernier defensif du
-- precedent. Jamais de chevauchement, meme sur une occurrence a quatre CD.
--
-- Ce n'est PAS une frise proportionnelle au temps (celle-la existe deja : UI/PlanTimeline).
-- Ici on montre ce que le plan FAIT, pas quand -- d'ou l'absence des occurrences vides :
-- les afficher noierait le propos sous des dizaines de colonnes sans defensif.
local addonName, HR = ...

HR.UI = HR.UI or {}
local UI = HR.UI

local W, H     = 780, 560
local PAD      = 16
local ICON     = 26
local DEF_GAP  = 3        -- entre deux defensifs d'une meme occurrence
local COL_GAP  = 10       -- entre deux occurrences
local COL_H    = 78       -- hauteur d'une colonne (defensifs + boss + temps)
local BOSS_GAP = 14       -- entre deux blocs de boss

local m

--------------------------------------------------------------------------------

local function fmtTime(t) return ("%d:%02d"):format(math.floor(t / 60), t % 60) end

-- Une colonne = une occurrence planifiee.
local function AcquireCol(parent, i)
    m.cols = m.cols or {}
    local c = m.cols[i]
    if c then return c end
    c = CreateFrame("Frame", nil, parent)
    c:SetHeight(COL_H)
    c.boss = UI.Components.ImageText(c, { size = ICON })
    c.time = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    -- Separateur vertical, dans l'ECART a gauche de la colonne. Il marque ou finit un
    -- groupe et ou commence le suivant : sans lui, une occurrence a trois defensifs et
    -- trois occurrences a un defensif se ressemblent.
    c.sep = c:CreateTexture(nil, "ARTWORK")
    c.sep:SetWidth(1)
    c.sep:SetColorTexture(1, 1, 1, 0.18)
    c.sep:SetPoint("TOPRIGHT", c, "TOPLEFT", -math.floor(COL_GAP / 2), 0)
    c.sep:SetPoint("BOTTOMRIGHT", c, "BOTTOMLEFT", -math.floor(COL_GAP / 2), 6)
    c.sep:Hide()
    c.defs = {}
    m.cols[i] = c
    return c
end

local function AcquireBossHdr(parent, i)
    m.hdrs = m.hdrs or {}
    local h = m.hdrs[i]
    if h then return h end
    h = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    h:SetJustifyH("LEFT")
    m.hdrs[i] = h
    return h
end

-- Bouton « Export boss » de l'en-tete d'un bloc (memo §14). Un par boss : on exporte ce
-- qu'on regarde. Il n'existe donc que la ou il y a quelque chose a exporter, puisqu'un bloc
-- n'est rendu que si le boss porte au moins un placement.
local function AcquireBossBtn(parent, i)
    m.btns = m.btns or {}
    local b = m.btns[i]
    if b then return b end
    b = UI.Components.TextButton(parent, {
        text = "Export boss", autoWidth = true, minWidth = 0, padX = 10, height = 18,
    })
    m.btns[i] = b
    return b
end

local function Build()
    if m then return m end
    local C = UI.Components
    m = C.Window(UIParent, {
        name = "ECPCatalogPreview", title = "Plan preview", width = W, height = H,
        bgTexture = C.ModalBackgroundTexture(),
    })
    C.ModalBackground(m)
    m:SetFrameStrata("FULLSCREEN_DIALOG"); m:SetToplevel(true)
    tinsert(UISpecialFrames, "ECPCatalogPreview")
    m:Hide()

    local c = m.content
    m.head = c:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    m.head:SetPoint("TOPLEFT", PAD, -PAD)
    m.head:SetPoint("RIGHT", c, "RIGHT", -PAD, 0)
    m.head:SetJustifyH("LEFT")

    m.sub = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    m.sub:SetPoint("TOPLEFT", PAD, -PAD - 22)

    m.scroll = CreateFrame("ScrollFrame", nil, c, "UIPanelScrollFrameTemplate")
    m.scroll:SetPoint("TOPLEFT", PAD, -PAD - 46)
    m.scroll:SetPoint("BOTTOMRIGHT", -PAD - 26, PAD + 40)
    m.list = CreateFrame("Frame", nil, m.scroll)
    m.list:SetSize(1, 1)
    m.scroll:SetScrollChild(m.list)
    -- Largeur non heritee par un ScrollChild : sans elle, tout ce qui s'y ancre a droite
    -- se retrouve sans largeur.
    m.scroll:SetScript("OnSizeChanged", function(self, w)
        if w and w > 0 then m.list:SetWidth(w) end
    end)

    m.empty = c:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
    m.empty:SetPoint("CENTER", m.scroll, "CENTER")
    m.empty:Hide()

    local close = C.TextButton(c, { text = "Close", width = 120,
                                    onClick = function() m:Hide() end })
    close:SetPoint("BOTTOMRIGHT", -PAD, PAD)
    return m
end

--------------------------------------------------------------------------------

-- Dispose une colonne et renvoie sa largeur.
-- La largeur est celle du contenu LE PLUS LARGE (le bloc de defensifs, ou l'icone de
-- boss) : c'est elle qui garantit que la colonne suivante ne mordra pas sur celle-ci.
--
-- Tout est ALIGNE A GAUCHE : l'icone du boss se pose sous le PREMIER defensif, jamais au
-- centre du groupe. Centrer la faisait glisser vers la droite a mesure que l'occurrence
-- gagnait des CD, et on perdait le repere « ce sort commence ici ».
local function LayoutCol(col, occ, entries)
    local n = #entries
    local defsW = (n > 0) and (n * ICON + (n - 1) * DEF_GAP) or 0
    local w = math.max(ICON, defsW)
    col:SetWidth(w)

    for _, d in ipairs(col.defs) do d:Hide() end
    local dx = 0                                    -- bloc de defensifs cale a GAUCHE
    for i, e in ipairs(entries) do
        local token  = HR.EntryToken(e)
        local defKey = HR.DefKeyOf(token)
        local d = col.defs[i]
        if not d then
            d = UI.Components.ImageText(col, { size = ICON, banner = true, textSize = 8 })
            col.defs[i] = d
        end
        HR.Icons.Apply(d.image, "defensive", defKey)
        -- Le suffixe d'instance (« #2 ») distingue deux exemplaires du meme external :
        -- sans lui, deux icones identiques cote a cote seraient illisibles.
        local suf = HR.TokenSuffix(token)
        d:SetText(suf or "")
        if d.banner then d.banner:SetShown(suf ~= nil) end
        d:ClearAllPoints(); d:SetPoint("TOPLEFT", dx, 0)
        d:Show()
        dx = dx + ICON + DEF_GAP
    end

    -- Sous le PREMIER defensif, pas au centre du groupe.
    col.boss:ClearAllPoints()
    col.boss:SetPoint("TOPLEFT", 0, -(ICON + 8))
    HR.Icons.Apply(col.boss.image, "spell", occ.spellID)
    col.boss:Show()

    col.time:ClearAllPoints()
    col.time:SetPoint("TOP", col.boss, "BOTTOM", 0, -3)
    col.time:SetText(fmtTime(occ.time or 0))
    return w
end

-- `entry` = une entree de catalogue (meme forme qu'une variante, memo §2.3).
function UI.ShowCatalogPreview(entry, creator)
    Build()
    local c = m.content
    m.cols = m.cols or {}; m.hdrs = m.hdrs or {}; m.btns = m.btns or {}
    m.entry = entry
    for _, col in ipairs(m.cols) do col:Hide() end
    for _, h in ipairs(m.hdrs) do h:Hide() end
    for _, b in ipairs(m.btns) do b:Hide() end

    m.head:SetText(HR.EscapeMarkup(entry.name or "?"))
    local prof = HR.GetHealProfileOrNone(entry.healer)
    m.sub:SetText(("%s   |cff808080by|r %s"):format(
        (prof and prof.name) or tostring(entry.healer),
        HR.EscapeMarkup((creator and creator.name) or "?")))

    -- Le donjon de l'entree -> ses boss, dans l'ordre du contenu.
    local dungeon
    for _, d in ipairs(HR.content or {}) do if d.id == entry.dID then dungeon = d end end
    if not dungeon then
        m.scroll:Hide(); m.empty:SetText("Unknown dungeon."); m.empty:Show()
        m:Show(); m:Raise(); return
    end

    local availW = (m.list:GetWidth() or (W - PAD * 2 - 26))
    if availW < 200 then availW = W - PAD * 2 - 26 end

    local y, ci, hi, any = 0, 0, 0, false
    for _, boss in ipairs(dungeon.bosses or {}) do
        local asg = (entry.assignments or {})[boss.id]
        if asg and next(asg) then
            -- Occurrences du boss, dans l'ordre du temps. On ne garde que celles que le
            -- plan touche : c'est ce qui rend la frise CONDENSEE.
            local occs = HR.GenerateOccurrences(HR.ResolveBossTimeline(boss), HR.FIGHT_LENGTH) or {}
            local planned = {}
            for _, o in ipairs(occs) do
                local list = asg[o.key]
                if list and #list > 0 then planned[#planned + 1] = { occ = o, defs = list } end
            end

            if #planned > 0 then
                any = true
                hi = hi + 1
                local h = AcquireBossHdr(m.list, hi)
                h:ClearAllPoints(); h:SetPoint("TOPLEFT", 0, y)
                h:SetText(("|cffffd100%s|r"):format(boss.name or "?"))
                h:Show()

                -- Export du plan de CE boss seul. La chaine est au format NATIF de variante
                -- (memo §14.1), avec `asg` reduit a ce boss et le drapeau `bossOnly` : le
                -- lecteur l'appliquera a la variante qu'il a sous les yeux, sans en creer.
                local encID = boss.id
                local btn = AcquireBossBtn(m.list, hi)
                btn:ClearAllPoints(); btn:SetPoint("LEFT", h, "RIGHT", 10, 0)
                btn:SetScript("OnClick", function()
                    local e = m.entry
                    local str = e and HR.Share and HR.Share.EncodeBossPlan
                                  and HR.Share.EncodeBossPlan(e.dID, e, encID) or nil
                    if not str then HR:Print("Export failed: this boss has no plan."); return end
                    UI.ShowExportString(str, "Export boss plan")
                end)
                btn:Show()
                y = y - 20

                -- Flux horizontal avec RETOUR A LA LIGNE : une colonne large (plusieurs
                -- defensifs) pousse simplement la suivante, et le rang passe a la ligne
                -- plutot que de deborder du cadre.
                local x, rows = 0, 1
                for _, pl in ipairs(planned) do
                    ci = ci + 1
                    local col = AcquireCol(m.list, ci)
                    local w = LayoutCol(col, pl.occ, pl.defs)
                    if x > 0 and x + w > availW then
                        x = 0; y = y - COL_H; rows = rows + 1
                    end
                    -- Separateur a GAUCHE, sauf en debut de rang : on ne le sait qu'ICI,
                    -- une fois le retour a la ligne tranche.
                    col.sep:SetShown(x > 0)
                    col:ClearAllPoints()
                    col:SetPoint("TOPLEFT", x, y)
                    col:Show()
                    x = x + w + COL_GAP
                end
                y = y - COL_H - BOSS_GAP
            end
        end
    end

    if not any then
        m.scroll:Hide()
        m.empty:SetText("This plan has no cooldown placed.")
        m.empty:Show()
    else
        m.empty:Hide(); m.scroll:Show()
        m.list:SetHeight(math.max(-y, 1))
    end
    m:Show(); m:Raise()
end
