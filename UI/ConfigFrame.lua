-- HealPlanner - UI/ConfigFrame.lua
-- Modale de configuration / planification.
--   B (haut)   : 8 onglets de donjon
--   A (gauche) : liste des boss du donjon selectionne
--   C (centre) : occurrences du boss sur 5 min, chaque ligne avec un [ + ]
--                pour assigner un defensif. Defensif pas pret => opacite 0.35.
local addonName, HR = ...

HR.UI = HR.UI or {}
local UI = HR.UI

local SEP_HEIGHT  = 22          -- separateur de phase (ligne + libelle "Phase N")
local BOSS_GAP    = 6           -- ecart horizontal entre boutons de boss

-- Sidebar de navigation (Phase 2) : donjons + Defs + Options, en boutons-image.
local SIDEBAR_W   = 64          -- largeur de la colonne de navigation a gauche
local NAV_ICON    = 35          -- taille d'un bouton-image de navigation (-20%)
local FOOTER_H    = 26          -- bandeau bas (version + bouton Join discord)
local DISCORD_URL = "https://discord.gg/NsxeFeV5x"
local NAV_GAP     = 8           -- espacement vertical entre boutons de nav
local SIDE_PAD    = 10          -- marge haute de la sidebar

-- Boss bar (horizontale) : on lui donne en HAUT/BAS le meme espacement que la marge
-- LATERALE (g/d) des icones de la sidebar (verticale) -> harmonise malgre le changement
-- d'axe. La marge laterale = (largeur sidebar - icone) / 2 ; les boutons (centres
-- verticalement) heritent donc de ce retrait.
local SIDE_LAT_PAD = (SIDEBAR_W - NAV_ICON) / 2     -- = 14.5
local BOSS_BTN_H   = 32                              -- hauteur d'un bouton de boss (texte + padY)
local BOSSROW_H    = BOSS_BTN_H + 2 * SIDE_LAT_PAD   -- = 61

UI.selDungeon = 1
UI.selBoss    = 1

-- Modale de confirmation du "Tout reinitialiser".
StaticPopupDialogs["HEALPLANNER_RESET_ALL"] = {
    text = "Reset ALL variants of all dungeons?\n\nThis action is irreversible.",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        HR.ResetAllPlans()
        local dungeon = HR.content[UI.selDungeon]
        UI.OnDungeonSelected(dungeon and dungeon.id)
        UI.RefreshRows()
        HR:Print("All variants have been reset.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    showAlert = true,
    preferredIndex = 3,     -- evite les conflits avec d'autres addons (taint)
}

-- (Profils : dialogs CUSTOM, pas de StaticPopup WoW. Cf. MakeSelect / BuildProfileNewModal
--  / ConfirmDeleteProfile plus bas, modeles sur le select de variante.)

--------------------------------------------------------------------------------
-- Section C : lignes d'occurrences
--------------------------------------------------------------------------------

-- Separateur de phase reutilisable : libelle "Phase N" + ligne doree a sa droite.
local function AcquireSep(i)
    local s = UI.phaseSeps[i]
    if not s then
        s = CreateFrame("Frame", nil, UI.listContent)
        s:SetHeight(SEP_HEIGHT)

        s.label = s:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        s.label:SetPoint("LEFT", 2, 0)

        s.line = s:CreateTexture(nil, "ARTWORK")
        s.line:SetColorTexture(1, 1, 1, 0.5)     -- dore semi-transparent
        s.line:SetHeight(1)
        s.line:SetPoint("LEFT", s.label, "RIGHT", 8, 0)
        s.line:SetPoint("RIGHT", s, "RIGHT", -4, 0)

        UI.phaseSeps[i] = s
    end
    s:Show()
    return s
end

--------------------------------------------------------------------------------
-- Section Trash Info : capacites de trash reduites par Zephyr (AoE)
--------------------------------------------------------------------------------

local TRASH_ROW_H = 30
local TRASH_ICON  = 26

-- Ligne de trash reutilisable : icone (tooltip du sort au survol) + nom.
local function AcquireTrashRow(i)
    local row = UI.trashRows[i]
    if not row then
        row = CreateFrame("Frame", nil, UI.listContent)
        row:SetHeight(TRASH_ROW_H)

        row.iconFrame = CreateFrame("Frame", nil, row)
        row.iconFrame:SetSize(TRASH_ICON, TRASH_ICON)
        row.iconFrame:SetPoint("LEFT", 2, 0)
        row.iconFrame:EnableMouse(true)
        row.iconFrame:SetScript("OnEnter", function(self)
            if not self.spellID then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetSpellByID(self.spellID)
            GameTooltip:Show()
        end)
        row.iconFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)

        row.icon = row.iconFrame:CreateTexture(nil, "ARTWORK")
        row.icon:SetAllPoints()
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.name:SetPoint("LEFT", row.iconFrame, "RIGHT", 8, 0)
        row.name:SetJustifyH("LEFT")

        UI.trashRows[i] = row
    end
    row:Show()
    return row
end

-- Affiche la liste des capacites de trash (AoE / Zephyr) du donjon.
function UI.RenderTrash(dungeon)
    local w = UI.scroll:GetWidth()
    if not w or w < 50 then w = 648 end
    UI.listContent:SetWidth(w)

    local list = (dungeon and dungeon.trash) or {}
    if #list == 0 then
        if not UI.trashEmpty then
            UI.trashEmpty = UI.listContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            UI.trashEmpty:SetPoint("TOPLEFT", 4, -4)
            UI.trashEmpty:SetJustifyH("LEFT")
        end
        UI.trashEmpty:SetText("|cff888888No trash ability set for this dungeon (to fill in).|r")
        UI.trashEmpty:Show()
        UI.listContent:SetHeight(TRASH_ROW_H)
        return
    end

    local y = 0
    for i, entry in ipairs(list) do
        local row = AcquireTrashRow(i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", 0, -y)
        row.iconFrame.spellID = entry.spellID
        row.icon:SetTexture(HR.GetSpellIcon(entry.spellID))
        row.name:SetText(entry.name or ("Spell " .. tostring(entry.spellID)))
        y = y + TRASH_ROW_H
    end
    UI.listContent:SetHeight(math.max(y, 1))
end

-- Met a jour la surbrillance de la liste de gauche (boss actif OU Trash Info).
function UI.UpdateListHighlight()
    for i, btn in ipairs(UI.bossButtons) do
        btn:SetSelected((not UI.viewTrash) and UI.selBoss == i)
    end
    if UI.trashButton then
        UI.trashButton:SetSelected(UI.viewTrash and true or false)
    end
end

--------------------------------------------------------------------------------
-- Section "Defensive list" : tous les CD enregistres dans l'addon, par classe
--------------------------------------------------------------------------------

local DEFLIST_ROW_H = 28
local DEFLIST_ICON  = 24

-- Ligne reutilisable de la liste des defensifs : icone (tooltip au survol) + texte.
local function AcquireDefListRow(i)
    local row = UI.defListRows[i]
    if not row then
        row = CreateFrame("Frame", nil, UI.listContent)
        row:SetHeight(DEFLIST_ROW_H)

        row.iconFrame = CreateFrame("Frame", nil, row)
        row.iconFrame:SetSize(DEFLIST_ICON, DEFLIST_ICON)
        row.iconFrame:SetPoint("LEFT", 8, 0)
        row.iconFrame:EnableMouse(true)
        row.iconFrame:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.itemId then
                GameTooltip:SetItemByID(self.itemId)
            elseif type(self.spellID) == "number" then
                GameTooltip:SetSpellByID(self.spellID)
            elseif self.tipText then
                GameTooltip:SetText(self.tipText)
            end
            GameTooltip:Show()
        end)
        row.iconFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)

        row.icon = row.iconFrame:CreateTexture(nil, "ARTWORK")
        row.icon:SetAllPoints()
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.name:SetPoint("LEFT", row.iconFrame, "RIGHT", 8, 0)
        row.name:SetJustifyH("LEFT")

        UI.defListRows[i] = row
    end
    row:Show()
    return row
end

-- Affiche TOUS les CD enregistres dans l'addon (raid HR.defensives + perso
-- HR.personalDefensives), groupes par classe (ordre alpha du nom de classe ;
-- "General" = sans classe en dernier), tries par nom dans chaque classe.
function UI.RenderDefList()
    local w = UI.scroll:GetWidth()
    if not w or w < 50 then w = 820 end
    UI.listContent:SetWidth(w)

    local byClass = {}
    local function add(key, d, personal)
        local cls = d.class or "GENERAL"
        byClass[cls] = byClass[cls] or {}
        local tag
        if d.specs then tag = table.concat(d.specs, "/")
        elseif d.spec then tag = d.spec
        elseif d.role then tag = d.role end
        table.insert(byClass[cls], {
            key      = key,
            name     = d.name or tostring(key),
            cooldown = d.cooldown or 0,
            spellID  = (type(key) == "number") and key or d.spellID,
            itemId   = d.itemId,
            tag      = tag,
            personal = personal,
        })
    end
    for k, d in pairs(HR.defensives) do add(k, d, false) end
    for k, d in pairs(HR.personalDefensives or {}) do add(k, d, true) end

    local function clsName(c) return (c == "GENERAL") and "General"
        or (HR.ClassName and HR.ClassName(c)) or c end
    local classes = {}
    for c in pairs(byClass) do classes[#classes + 1] = c end
    table.sort(classes, function(a, b)
        if (a == "GENERAL") ~= (b == "GENERAL") then return b == "GENERAL" end
        return clsName(a) < clsName(b)
    end)

    local y, ri, si = 0, 0, 0
    for _, cls in ipairs(classes) do
        si = si + 1
        local sep = AcquireSep(si)
        sep:ClearAllPoints()
        sep:SetPoint("TOPLEFT", 0, -y)
        sep:SetPoint("TOPRIGHT", 0, -y)
        sep.label:SetText(clsName(cls))
        y = y + SEP_HEIGHT

        local entries = byClass[cls]
        table.sort(entries, function(a, b) return a.name < b.name end)
        for _, e in ipairs(entries) do
            ri = ri + 1
            local row = AcquireDefListRow(ri)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -y)
            row:SetPoint("TOPRIGHT", 0, -y)
            row.iconFrame.spellID = e.spellID
            row.iconFrame.itemId  = e.itemId
            row.iconFrame.tipText = e.name
            row.icon:SetTexture(HR.GetDefensiveIcon(e.key))
            local cd  = (e.cooldown > 0) and (" |cffffd100(" .. e.cooldown .. "s)|r")
                or " |cff888888(no CD)|r"
            local tag = e.tag and ("   |cff888888" .. e.tag .. "|r") or ""
            local src = e.personal and "  |cff7f9fff[personal]|r" or ""
            row.name:SetText(e.name .. cd .. tag .. src)
            y = y + DEFLIST_ROW_H
        end
    end
    UI.listContent:SetHeight(math.max(y, 1))
end

--------------------------------------------------------------------------------
-- Vue Options (en ligne dans la modale, plus de fenetre separee)
--------------------------------------------------------------------------------

local function Opt()
    HR.db.options = HR.db.options or {}
    return HR.db.options
end

-- Builder PARTAGE des options de composition (timeline/upcoming/comm). opts = { withText=bool,
-- toggles={{label,get,set}}, sliders={{label,min,max,step,get,set}} } (options FONCTIONNELLES
-- du module, rendues avant la composition). La composition lit/ecrit via HR.CompOpt(moduleKey).
-- AUCUN apercu : les reglages s'appliquent en direct sur le vrai module (le joueur le regarde en jeu).
local function BuildCompositionOptions(panel, moduleKey, opts)
    opts = opts or {}
    local pv = { Refresh = function() end }   -- pas d'apercu
    -- Gating : controles grises/desactives selon un predicat (ex. taille/couleur du nom de
    -- boss desactives quand "Hide Upcoming Boss Spell" est coche). Rempli dans la boucle items.
    local gated = {}
    local function refreshAvail()
        for _, g in ipairs(gated) do
            local disabled = g.pred and g.pred() or false
            local a = disabled and 0.35 or 1
            if g.ctrl then
                if g.ctrl.SetEnabled then g.ctrl:SetEnabled(not disabled) end
                g.ctrl:SetAlpha(a)
            end
            for _, fs in ipairs(g.labels or {}) do fs:SetAlpha(a) end
        end
    end
    local function refresh()
        pv.Refresh()
        local R = HR.Runtime
        if R and moduleKey == "timeline" and R.ApplyTimelineOptions then R.ApplyTimelineOptions()
        elseif R and moduleKey == "progress" and R.ApplyProgressOptions then R.ApplyProgressOptions()
        elseif R and moduleKey == "upcoming" and R.ApplyUpcomingOptions then R.ApplyUpcomingOptions()
        elseif R and moduleKey == "comm" and R.ApplyCommOptions then R.ApplyCommOptions()
        elseif R and moduleKey == "announce" and R.ApplyAnnounceOptions then R.ApplyAnnounceOptions() end
        refreshAvail()
    end
    local y = { -6 }
    local colX = 0   -- mono-colonne ici (colX + 12 == 12) ; le layout en colonnes est dans BuildGeneralTab

    -- Bloc d'info OPTIONNEL en tete de section (cadre explicatif, cf. C.InfoBox). Texte via
    -- opts.info (placeholder "" accepte). HAUTEUR AUTO : calee sur le texte (plus de vide en bas).
    if opts.info ~= nil and UI.Components and UI.Components.InfoBox then
        local ib = UI.Components.InfoBox(panel, { text = opts.info, minHeight = opts.infoHeight })
        ib:SetPoint("TOPLEFT", colX + 12, y[1])
        ib:SetPoint("RIGHT", panel, "RIGHT", -12, 0)
        -- Largeur du cadre pour le calcul de hauteur : GetWidth (modale deja affichee) sinon repli
        -- (~ largeur panneau : frame 1144 - sidebar 64 - marges). -24 = marges TOPLEFT 12 + RIGHT 12.
        local pw = panel:GetWidth(); if not pw or pw < 100 then pw = 1010 end
        ib:Relayout(pw - (colX + 12) - 12)
        y[1] = y[1] - (ib:GetHeight() + 12)
        panel.infoBox = ib
    end

    -- Tooltip au survol d'un controle : composant MAISON (UI.Components.AttachHelpTip),
    -- titre = label de l'option, corps = description (wrap auto, look de l'addon).
    local function addTip(frame, title, body)
        if not body or not frame then return end
        if UI.Components and UI.Components.AttachHelpTip then
            UI.Components.AttachHelpTip(frame, title, body)
        end
    end

    local function checkbox(label, get, set, tooltip)
        local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate"); cb:SetPoint("TOPLEFT", colX + 12, y[1])
        local lbl = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); lbl:SetPoint("LEFT", cb, "RIGHT", 2, 0); lbl:SetText(label)
        cb:SetChecked(get()); cb:SetScript("OnClick", function(s) set(s:GetChecked() and true or false); refresh() end)
        addTip(cb, label, tooltip)
        y[1] = y[1] - 28
    end
    local function swatch(label, key, tooltip)
        local cl = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); cl:SetPoint("TOPLEFT", colX + 12, y[1]); cl:SetText(label)
        local sw = CreateFrame("Button", nil, panel, "BackdropTemplate"); sw:SetSize(22, 22); sw:SetPoint("LEFT", cl, "RIGHT", 10, 0)
        sw:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10 }); sw:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
        sw.sbg = sw:CreateTexture(nil, "BACKGROUND"); sw.sbg:SetPoint("TOPLEFT", 2, -2); sw.sbg:SetPoint("BOTTOMRIGHT", -2, 2)
        local function rc() local c = HR.CompGet(moduleKey, key); sw.sbg:SetColorTexture(c[1], c[2], c[3], c[4] or 1) end
        rc()
        sw:SetScript("OnClick", function()
            local c = HR.CompGet(moduleKey, key)
            local function apply()
                local r, g, b = ColorPickerFrame:GetColorRGB()
                local a = (ColorPickerFrame.GetColorAlpha and ColorPickerFrame:GetColorAlpha()) or c[4] or 1
                HR.CompOpt(moduleKey)[key] = { r, g, b, a }; rc(); refresh()
            end
            ColorPickerFrame:SetupColorPickerAndShow({ r = c[1], g = c[2], b = c[3], hasOpacity = true, opacity = c[4] or 1, swatchFunc = apply, opacityFunc = apply })
        end)
        addTip(sw, label, tooltip)
        y[1] = y[1] - 28
        return sw, cl
    end
    local function slider(label, minv, maxv, step, getv, setv, tooltip)
        local l = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); l:SetPoint("TOPLEFT", colX + 12, y[1]); l:SetText(label)
        y[1] = y[1] - 16
        local s = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate"); s:SetPoint("TOPLEFT", colX + 16, y[1]); s:SetWidth(170)
        s:SetMinMaxValues(minv, maxv); s:SetValueStep(step); s:SetObeyStepOnDrag(true)
        if s.Low then s.Low:SetText("") end; if s.High then s.High:SetText("") end; if s.Text then s.Text:SetText("") end
        local val = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); val:SetPoint("LEFT", s, "RIGHT", 10, 0)
        local function fmt(v) return (step < 1) and ("%.2f"):format(v) or tostring(math.floor(v + 0.5)) end
        s:SetValue(getv() or minv); val:SetText(fmt(getv() or minv))
        s:SetScript("OnValueChanged", function(_, v) v = math.floor(v / step + 0.5) * step; val:SetText(fmt(v)); setv(v); refresh() end)
        addTip(s, label, tooltip)
        y[1] = y[1] - 22   -- trailing aligne sur checkbox/swatch (28) -> espacement de section regulier
        return s, l, val
    end
    -- Titre de section + separateur horizontal, tous deux en EMPHASIZE (token de theme).
    -- Ecart de section CONSTANT avant chaque titre (sauf le 1er) -> espacement regulier quel
    -- que soit le type du dernier controle de la section precedente.
    local SECTION_GAP = 16
    local firstHeader = true
    local function header(text)
        if not firstHeader then y[1] = y[1] - SECTION_GAP end
        firstHeader = false
        local h = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        h:SetPoint("TOPLEFT", colX + 12, y[1]); h:SetText(text)
        h:SetTextColor(HR.Theme.Unpack("EMPHASIZE_TEXT_COLOR"))
        y[1] = y[1] - 20
    end
    local function separator()
        local ln = panel:CreateTexture(nil, "ARTWORK")
        local r, g, b = HR.Theme.Unpack("EMPHASIZE_TEXT_COLOR")
        ln:SetColorTexture(r, g, b, 0.4)
        ln:SetHeight(1); ln:SetWidth(264); ln:SetPoint("TOPLEFT", 12, y[1] + 2)
        y[1] = y[1] - 10
    end

    if opts.items then
        -- Mise en page ORDONNEE explicite (header/separator/toggle/slider/swatch).
        for _, it in ipairs(opts.items) do
            if it.header then header(it.header)
            elseif it.separator then separator()
            elseif it.toggle then checkbox(it.toggle, it.get, it.set, it.tooltip)
            elseif it.swatch then
                local sw, cl = swatch(it.swatch, it.key, it.tooltip)
                if it.gatedBy then gated[#gated + 1] = { ctrl = sw, labels = { cl }, pred = it.gatedBy } end
            elseif it.slider then
                local s, l, val = slider(it.slider, it.min, it.max, it.step, it.get, it.set, it.tooltip)
                if it.gatedBy then gated[#gated + 1] = { ctrl = s, labels = { l, val }, pred = it.gatedBy } end
            end
        end
    else
        -- Chemin par defaut (Timeline) : options fonctionnelles puis composition partagee.
        for _, t in ipairs(opts.toggles or {}) do checkbox(t.label, t.get, t.set, t.tooltip) end
        for _, s in ipairs(opts.sliders or {}) do slider(s.label, s.min, s.max, s.step, s.get, s.set, s.tooltip) end
        swatch("Background color", "bgColor")
        swatch("Border color", "borderColor")
        slider("Border thickness", 0, 6, 1, function() return HR.CompGet(moduleKey, "borderThickness") end,
            function(v) HR.CompOpt(moduleKey).borderThickness = v end)
        slider("Scale", 0.5, 2.0, 0.05, function() return HR.CompGet(moduleKey, "scale") end,
            function(v) HR.CompOpt(moduleKey).scale = v end)
        if opts.withText then   -- Timeline : couleur/taille du texte de decompte
            swatch("Text color", "textColor")
            slider("Text size", 8, 24, 1, function() return HR.CompGet(moduleKey, "textSize") end,
                function(v) HR.CompOpt(moduleKey).textSize = v end)
        end
        -- (Le GLOW est GLOBAL : onglet "Glow", applique a tous les modules.)
    end

    refresh()
end

-- Onglet GENERAL : deux boutons en en-tete (Reset position + Start/Stop test) au-dessus de
-- DEUX colonnes -> Alert (col 1) | Glow (col 2). Le GLOW (reglage GLOBAL : type + couleur +
-- pixel, partage par tous les glows de l'addon) vit en colonne 2, apercu SOUS ses reglages
-- (colonne etroite). (Ancienne section "General" + "Hide out of combat" retirees.)
local function BuildGeneralTab(panel)
    local SECTION_GAP = 16
    local COL2_X = 360                       -- x de la 2e colonne (Alert | Glow cote a cote)
    -- Layout en COLONNES : `colX` = origine x de la colonne courante, `y` = son curseur vertical.
    -- setColumn() bascule de colonne -> permet une grille simple (vs mono-colonne).
    local colX, y, firstHeader = 0, { -6 }, true
    local function setColumn(x, startY) colX = x; y = { startY or -6 }; firstHeader = true end

    -- Apercu du glow (cree quand on connait la position verticale de la section Glow).
    local pv
    local function glowRefresh()
        if pv and pv.icon then HR.StopGlow(pv.icon); HR.StartGlow(pv.icon, HR.CompGlow()) end
    end

    -- ---- Helpers de mise en page (curseur `y` partage) -------------------------
    local function header(text)
        if not firstHeader then y[1] = y[1] - SECTION_GAP end
        firstHeader = false
        local h = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        h:SetPoint("TOPLEFT", colX + 12, y[1]); h:SetText(text)
        h:SetTextColor(HR.Theme.Unpack("EMPHASIZE_TEXT_COLOR"))
        y[1] = y[1] - 20
    end
    local function separator()
        local ln = panel:CreateTexture(nil, "ARTWORK")
        local r, g, b = HR.Theme.Unpack("EMPHASIZE_TEXT_COLOR")
        ln:SetColorTexture(r, g, b, 0.4); ln:SetHeight(1); ln:SetWidth(248); ln:SetPoint("TOPLEFT", colX + 12, y[1] + 2)
        y[1] = y[1] - 10
    end
    local function addTip(frame, title, body)
        if not body or not frame then return end
        if UI.Components and UI.Components.AttachHelpTip then UI.Components.AttachHelpTip(frame, title, body) end
    end
    local function checkbox(label, get, set, tooltip)
        local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate"); cb:SetPoint("TOPLEFT", colX + 12, y[1])
        local lbl = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); lbl:SetPoint("LEFT", cb, "RIGHT", 2, 0); lbl:SetText(label)
        cb:SetChecked(get()); cb:SetScript("OnClick", function(s) set(s:GetChecked() and true or false) end)
        addTip(cb, label, tooltip)
        y[1] = y[1] - 28
        return cb, lbl
    end
    local function button(label, onclick)
        local b = UI.Components.TextButton(panel, { text = label, autoWidth = true, padX = 15, padY = 7 })
        b:SetPoint("TOPLEFT", colX + 14, y[1])
        b:SetOnClick(onclick)
        y[1] = y[1] - ((b:GetHeight() or 24) + 8)
        return b
    end
    -- Swatch/slider du GLOW (lisent GlowOpt/GlowGet, rafraichissent l'apercu).
    local function glowSwatch(label, key)
        local cl = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); cl:SetPoint("TOPLEFT", colX + 12, y[1]); cl:SetText(label)
        local sw = CreateFrame("Button", nil, panel, "BackdropTemplate"); sw:SetSize(22, 22); sw:SetPoint("LEFT", cl, "RIGHT", 10, 0)
        sw:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10 }); sw:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
        sw.sbg = sw:CreateTexture(nil, "BACKGROUND"); sw.sbg:SetPoint("TOPLEFT", 2, -2); sw.sbg:SetPoint("BOTTOMRIGHT", -2, 2)
        local function rc() local c = HR.GlowGet(key); sw.sbg:SetColorTexture(c[1], c[2], c[3], c[4] or 1) end
        rc()
        sw:SetScript("OnClick", function()
            local c = HR.GlowGet(key)
            local function apply()
                local r, g, b = ColorPickerFrame:GetColorRGB()
                local a = (ColorPickerFrame.GetColorAlpha and ColorPickerFrame:GetColorAlpha()) or c[4] or 1
                HR.GlowOpt()[key] = { r, g, b, a }; rc(); glowRefresh()
            end
            ColorPickerFrame:SetupColorPickerAndShow({ r = c[1], g = c[2], b = c[3], hasOpacity = true, opacity = c[4] or 1, swatchFunc = apply, opacityFunc = apply })
        end)
        y[1] = y[1] - 28
        return sw, cl
    end
    local function glowSlider(label, minv, maxv, step, getv, setv)
        local l = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); l:SetPoint("TOPLEFT", colX + 12, y[1]); l:SetText(label)
        y[1] = y[1] - 16
        local s = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate"); s:SetPoint("TOPLEFT", colX + 16, y[1]); s:SetWidth(170)
        s:SetMinMaxValues(minv, maxv); s:SetValueStep(step); s:SetObeyStepOnDrag(true)
        if s.Low then s.Low:SetText("") end; if s.High then s.High:SetText("") end; if s.Text then s.Text:SetText("") end
        local val = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); val:SetPoint("LEFT", s, "RIGHT", 10, 0)
        local function fmt(v) return (step < 1) and ("%.2f"):format(v) or tostring(math.floor(v + 0.5)) end
        s:SetValue(getv() or minv); val:SetText(fmt(getv() or minv))
        s:SetScript("OnValueChanged", function(_, v) v = math.floor(v / step + 0.5) * step; val:SetText(fmt(v)); setv(v); glowRefresh() end)
        y[1] = y[1] - 22
        return s, l, val
    end
    -- Slider generique (sans effet de bord glow) : { label, min, max, step, get, set, tooltip }.
    local function slider(label, minv, maxv, step, getv, setv, tooltip)
        local l = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); l:SetPoint("TOPLEFT", colX + 12, y[1]); l:SetText(label)
        y[1] = y[1] - 16
        local s = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate"); s:SetPoint("TOPLEFT", colX + 16, y[1]); s:SetWidth(170)
        s:SetMinMaxValues(minv, maxv); s:SetValueStep(step); s:SetObeyStepOnDrag(true)
        if s.Low then s.Low:SetText("") end; if s.High then s.High:SetText("") end; if s.Text then s.Text:SetText("") end
        local val = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); val:SetPoint("LEFT", s, "RIGHT", 10, 0)
        local function fmt(v) return (step < 1) and ("%.2f"):format(v) or tostring(math.floor(v + 0.5)) end
        s:SetValue(getv() or minv); val:SetText(fmt(getv() or minv))
        s:SetScript("OnValueChanged", function(_, v) v = math.floor(v / step + 0.5) * step; val:SetText(fmt(v)); setv(v) end)
        addTip(s, label, tooltip)
        y[1] = y[1] - 22
        return s, l, val
    end
    -- Selecteur de son d'alerte (libelle + bouton maison -> menu radio : None + sons communs +
    -- l'option TTS du TYPE courant uniquement). `kind` = "def"|"ext" : on cache le TTS de l'autre
    -- type (la categorie defensive ne propose pas "TTS External", et inversement).
    local function soundDropdown(label, getId, setId, kind)
        local cl = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); cl:SetPoint("TOPLEFT", colX + 12, y[1]); cl:SetText(label)
        local btn = UI.Components.TextButton(panel, { text = HR.AlertSoundName(getId()), autoWidth = true, padX = 12, padY = 5, minWidth = 120 })
        btn:SetPoint("LEFT", cl, "RIGHT", 10, 0)
        btn:SetOnClick(function()
            MenuUtil.CreateContextMenu(btn, function(owner, menu)
                menu:CreateTitle("Sound")
                menu:CreateRadio("None", function() return getId() == nil end, function() setId(nil); btn:SetText("None") end)
                for _, c in ipairs(HR.ALERT_SOUND_CHOICES) do
                    -- sons communs (sans kind) partout ; TTS seulement dans le dropdown de SON type.
                    if (not c.kind) or c.kind == kind then
                        menu:CreateRadio(c.name, function() return getId() == c.id end, function()
                            setId(c.id); btn:SetText(c.name); HR.PreviewAlertSound(c.id)   -- apercu immediat
                        end)
                    end
                end
            end)
        end)
        y[1] = y[1] - 30
        return btn, cl
    end
    -- Selecteur de CANAL de sortie (commun a tous les sons d'alerte). get/set = chaine de canal.
    local function channelDropdown(label, get, set)
        local cl = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); cl:SetPoint("TOPLEFT", colX + 12, y[1]); cl:SetText(label)
        local btn = UI.Components.TextButton(panel, { text = get(), autoWidth = true, padX = 12, padY = 5, minWidth = 120 })
        btn:SetPoint("LEFT", cl, "RIGHT", 10, 0)
        btn:SetOnClick(function()
            MenuUtil.CreateContextMenu(btn, function(owner, menu)
                menu:CreateTitle("Channel")
                for _, ch in ipairs(HR.ALERT_CHANNELS) do
                    menu:CreateRadio(ch, function() return get() == ch end, function()
                        set(ch); btn:SetText(ch); PlaySound(8959, ch)   -- apercu (Raid Warning) sur ce canal
                    end)
                end
            end)
        end)
        y[1] = y[1] - 30
        return btn, cl
    end
    -- Selecteur de VOIX TTS (commun a tous les TTS). nil = Auto (anglais si dispo). Liste = voix
    -- installees cote OS. Apercu vocal a la selection.
    local function voiceDropdown(label, get, set)
        local cl = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); cl:SetPoint("TOPLEFT", colX + 12, y[1]); cl:SetText(label)
        local btn = UI.Components.TextButton(panel, { text = HR.AlertVoiceName(get()), autoWidth = true, padX = 12, padY = 5, minWidth = 120 })
        btn:SetPoint("LEFT", cl, "RIGHT", 10, 0)
        btn:SetOnClick(function()
            MenuUtil.CreateContextMenu(btn, function(owner, menu)
                menu:CreateTitle("TTS voice")
                menu:CreateRadio("Auto (English if available)", function() return get() == nil end, function()
                    set(nil); btn:SetText(HR.AlertVoiceName(nil)); HR.SpeakTTS("Defensive")
                end)
                for _, v in ipairs(HR.GetTtsVoices()) do
                    menu:CreateRadio(v.name, function() return get() == v.voiceID end, function()
                        set(v.voiceID); btn:SetText(v.name); HR.SpeakTTS("Defensive")   -- apercu avec la voix choisie
                    end)
                end
            end)
        end)
        y[1] = y[1] - 30
        return btn, cl
    end

    -- ===== En-tete : boutons (au-dessus des sections) =====
    setColumn(0)
    local resetBtn = button("Reset position",
        function() if HR.Runtime.ResetPositions then HR.Runtime.ResetPositions() end end)
    -- Curseur APRES le 1er bouton : le second se pose sur la MEME ligne, donc on restaure
    -- cette valeur ensuite (sinon `button` consommerait deux hauteurs pour une seule rangee).
    local rowY = y[1]
    local function testing() return HR.Runtime and HR.Runtime.state and HR.Runtime.state.mode == "test" end
    local testBtn
    testBtn = button("Start test", function()
        if testing() then HR.Runtime.Stop()
        elseif HR.Runtime and HR.Runtime.StartTestMode then HR.Runtime.StartTestMode() end
        testBtn:SetText(testing() and "Stop test" or "Start test")
    end)
    testBtn:ClearAllPoints()
    testBtn:SetPoint("LEFT", resetBtn, "RIGHT", 8, 0)
    y[1] = rowY
    if testing() then testBtn:SetText("Stop test") end
    local topEnd = y[1]

    -- ===== Colonne 1 : Alert (en premier) =====
    setColumn(0, topEnd)
    header("Alert"); separator()

    -- Gating : chaque dropdown de son est actif selon SON propre toggle (pred).
    local alertGated = {}
    local function alertRefreshAvail()
        for _, g in ipairs(alertGated) do
            local on = g.pred()
            local a = on and 1 or 0.35
            if g.ctrl then
                if g.ctrl.SetEnabled then g.ctrl:SetEnabled(on) end
                if g.ctrl.SetAlpha then g.ctrl:SetAlpha(a) end
            end
            for _, fs in ipairs(g.labels or {}) do fs:SetAlpha(a) end
        end
    end

    -- Defensifs (perso) : toggle + selecteur de son.
    local defOn = function() return Opt().alertDefEnabled == true end
    checkbox("Play sound when a defensive is required",
        defOn,
        function(v) Opt().alertDefEnabled = v; alertRefreshAvail() end,
        "Play a sound or voice when one of YOUR personal defensives is required.")
    local dSnd, dLbl = soundDropdown("Sound",
        function() return Opt().alertDefSound end,
        function(id) Opt().alertDefSound = id end, "def")
    alertGated[#alertGated + 1] = { ctrl = dSnd, labels = { dLbl }, pred = defOn }

    -- Externals (groupe) : toggle + selecteur de son.
    local extOn = function() return Opt().alertExtEnabled == true end
    checkbox("Play sound when an external is required",
        extOn,
        function(v) Opt().alertExtEnabled = v; alertRefreshAvail() end,
        "Play a sound or voice when one of YOUR group externals is required.")
    local eSnd, eLbl = soundDropdown("Sound",
        function() return Opt().alertExtSound end,
        function(id) Opt().alertExtSound = id end, "ext")
    alertGated[#alertGated + 1] = { ctrl = eSnd, labels = { eLbl }, pred = extOn }

    -- CD de heal (soigneur uniquement) : toggle + selecteur de son.
    local healOn = function() return Opt().alertHealEnabled == true end
    checkbox("Play sound when a healer cd is required (healer only)",
        healOn,
        function(v) Opt().alertHealEnabled = v; alertRefreshAvail() end,
        "Play a sound or voice when one of YOUR healer cooldowns is required (healers only).")
    local hSnd, hLbl = soundDropdown("Sound",
        function() return Opt().alertHealSound end,
        function(id) Opt().alertHealSound = id end, "heal")
    alertGated[#alertGated + 1] = { ctrl = hSnd, labels = { hLbl }, pred = healOn }

    -- Canal de sortie COMMUN a tous les sons d'alerte (actif si au moins une alerte est on).
    local anyOn = function() return defOn() or extOn() or healOn() end
    local chBtn, chLbl = channelDropdown("Sound channel",
        function() return Opt().alertChannel or "Master" end,
        function(ch) Opt().alertChannel = ch end)
    alertGated[#alertGated + 1] = { ctrl = chBtn, labels = { chLbl }, pred = anyOn }

    -- Voix TTS COMMUNE a tous les TTS (actif si au moins une alerte est on).
    local vBtn, vLbl = voiceDropdown("TTS voice",
        function() return Opt().alertVoice end,
        function(id) Opt().alertVoice = id end)
    alertGated[#alertGated + 1] = { ctrl = vBtn, labels = { vLbl }, pred = anyOn }

    -- Seuil SONORE = source de verite du systeme d'alerte autonome (Core/TTS.lua). Decouple
    -- des seuils Upcoming bar / Timeline / Announcement : ne joue le son que N s avant l'usage.
    local thrS, thrL, thrVal = slider("Alert threshold (s)", 0, 5, 1,
        function() return Opt().alertThreshold or 5 end,
        function(v) Opt().alertThreshold = v end,
        "How many seconds before a planned cooldown the alert sound plays. Independent from the Upcoming bar, Timeline and Announcement thresholds.")
    alertGated[#alertGated + 1] = { ctrl = thrS, labels = { thrL, thrVal }, pred = anyOn }

    alertRefreshAvail()   -- etat initial du gating

    -- ===== Colonne 2 : Glow (a cote d'Alert), reglage GLOBAL =====
    setColumn(COL2_X, topEnd)
    header("Glow"); separator()

    -- Gating : les sous-options se grisent selon le type de glow.
    local gated = {}
    local function refreshAvail()
        local t = HR.GlowGet("glowType")
        for _, g in ipairs(gated) do
            local on = g.types[t] and true or false
            local d = on and 0.9 or 0.4
            if g.ctrl.SetEnabled then g.ctrl:SetEnabled(on) end
            if g.label then g.label:SetTextColor(d, d, d) end
            if g.val then g.val:SetTextColor(d, d, d) end
        end
    end

    local gl = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); gl:SetPoint("TOPLEFT", colX + 12, y[1]); gl:SetText("Glow type (all glows)"); y[1] = y[1] - 22
    local tbtns, tx = {}, colX + 16
    for _, t in ipairs({ "pixel", "autocast", "button", "proc" }) do
        local b = UI.Components.TextButton(panel, { text = t, autoWidth = true, minWidth = 0, padX = 8, padY = 4 })
        b._t = t; b:SetPoint("TOPLEFT", tx, y[1]); b:SetSelected(HR.GlowGet("glowType") == t)
        b:SetOnClick(function()
            HR.GlowOpt().glowType = t
            for _, bb in ipairs(tbtns) do bb:SetSelected(bb._t == t) end
            refreshAvail(); glowRefresh()
        end)
        tbtns[#tbtns + 1] = b; tx = tx + b:GetWidth() + 4
    end
    y[1] = y[1] - 34
    local function pxGet(f) return function() return (HR.GlowGet("glowPixel") or {})[f] end end
    local function pxSet(f) return function(v)
        local o = HR.GlowOpt(); if not o.glowPixel then o.glowPixel = HR.DeepCopy(HR.GlowDefaults.glowPixel) end; o.glowPixel[f] = v
    end end
    local cSw, cCl = glowSwatch("Glow color", "glowColor")
    gated[#gated + 1] = { ctrl = cSw, label = cCl, types = { pixel = true, autocast = true, button = true } }
    local s1, l1, v1 = glowSlider("Glow lines / particles", 1, 16, 1, pxGet("lines"), pxSet("lines"))
    gated[#gated + 1] = { ctrl = s1, label = l1, val = v1, types = { pixel = true, autocast = true } }
    local s2, l2, v2 = glowSlider("Glow thickness", 1, 8, 1, pxGet("thickness"), pxSet("thickness"))
    gated[#gated + 1] = { ctrl = s2, label = l2, val = v2, types = { pixel = true } }
    local s3, l3, v3 = glowSlider("Glow frequency", 0.05, 1, 0.05, pxGet("frequency"), pxSet("frequency"))
    gated[#gated + 1] = { ctrl = s3, label = l3, val = v3, types = { pixel = true, autocast = true, button = true } }

    -- Apercu SOUS les reglages de glow (colonne 2 etroite -> pas de place a droite).
    pv = CreateFrame("Frame", nil, panel); pv:SetSize(108, 108)
    pv:SetPoint("TOPLEFT", colX + 12, y[1] - 4); y[1] = y[1] - (108 + 8)
    pv.icon = CreateFrame("Frame", nil, pv); pv.icon:SetSize(66, 66); pv.icon:SetPoint("CENTER")
    pv.icon.tex = pv.icon:CreateTexture(nil, "ARTWORK"); pv.icon.tex:SetAllPoints(); pv.icon.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    pv.icon.tex:SetTexture(HR.GetDefensiveIcon("SMALL_DEF"))   -- placeholder "Defensive" (coherence)

    refreshAvail(); glowRefresh()
end

-- ===== Profils : dialogs CUSTOM (modeles sur le SELECT DE VARIANTE) =====
local SEL_ROW_H = 26

-- Select CUSTOM reutilisable : trigger stylise (comme p.varTrigger) + C.ScrollPopup (le
-- composant prevu pour les selecteurs custom). opts = { width, getLabel()->string,
-- options()->{ {value,label}, ... }, onSelect(value), onDelete(value, pop) (optionnel : "x"/ligne) }.
local function MakeSelect(parent, opts)
    local W = opts.width or 220
    local trig = CreateFrame("Button", nil, parent, "BackdropTemplate")
    trig:SetSize(W, 26)
    trig:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = HR.Theme.Value("BUTTON_BORDER_ROUND_THICKNESS", 12), insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    trig:SetBackdropColor(0.15, 0.15, 0.15, 0.95)
    trig:SetBackdropBorderColor(HR.Theme.Unpack("POPUP_BORDER_COLOR"))
    trig.label = trig:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    trig.label:SetPoint("LEFT", 8, 0); trig.label:SetPoint("RIGHT", -18, 0)
    trig.label:SetJustifyH("LEFT"); trig.label:SetTextColor(1, 1, 1)
    trig.arrow = trig:CreateTexture(nil, "OVERLAY")
    trig.arrow:SetSize(12, 12); trig.arrow:SetPoint("RIGHT", -5, 0)
    trig.arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
    trig:SetHighlightTexture("Interface\\Buttons\\WHITE8x8", "ADD")
    local thl = trig:GetHighlightTexture()
    if thl then thl:SetVertexColor(1, 1, 1, 0.08); thl:SetPoint("TOPLEFT", 3, -3); thl:SetPoint("BOTTOMRIGHT", -3, 3) end

    local pop = UI.Components.ScrollPopup({ width = W }); pop.rows = {}
    local function refresh() trig.label:SetText(opts.getLabel() or "-") end
    local function render()
        for _, r in ipairs(pop.rows) do r:Hide() end
        local CW = pop:GetWidth() - 34
        pop.content:SetWidth(CW)
        local y, ri = 4, 0
        for _, o in ipairs(opts.options()) do
            ri = ri + 1
            local r = pop.rows[ri]
            if not r then
                r = CreateFrame("Button", nil, pop.content); r:SetHeight(SEL_ROW_H)
                r.t = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                r.t:SetPoint("LEFT", 8, 0); r.t:SetJustifyH("LEFT")
                r:SetHighlightTexture("Interface\\Buttons\\WHITE8x8", "ADD")
                local h = r:GetHighlightTexture(); if h then h:SetVertexColor(1, 1, 1, 0.12) end
                r.del = CreateFrame("Button", nil, r); r.del:SetSize(18, 18); r.del:SetPoint("RIGHT", -4, 0)
                r.del.t = r.del:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                r.del.t:SetPoint("CENTER"); r.del.t:SetText("x"); r.del.t:SetTextColor(1, 0.4, 0.4)
                r.del:SetHighlightTexture("Interface\\Buttons\\WHITE8x8", "ADD")
                pop.rows[ri] = r
            end
            r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, -y); r:SetWidth(CW)
            r.t:ClearAllPoints(); r.t:SetPoint("LEFT", 8, 0)
            r.t:SetPoint("RIGHT", r, "RIGHT", opts.onDelete and -26 or -8, 0)
            r.t:SetText(o.label)
            r:SetScript("OnClick", function() opts.onSelect(o.value); refresh(); pop:Close() end)
            if opts.onDelete then
                r.del:Show(); r.del:SetScript("OnClick", function() opts.onDelete(o.value, pop) end)
            else r.del:Hide() end
            r:Show()
            y = y + SEL_ROW_H
        end
        pop.content:SetHeight(math.max(y, 1))
        pop:SetHeight(math.min(y + 12, 320))
    end
    trig:SetScript("OnClick", function()
        if pop:IsShown() then pop:Close(); return end
        pop:SetWidth(trig:GetWidth()); render()
        pop:ClearAllPoints(); pop:SetPoint("TOPLEFT", trig, "BOTTOMLEFT", 0, -2)
        pop:Open()
    end)
    trig.Refresh = refresh; trig.pop = pop
    refresh()
    return trig
end

-- Confirmation CUSTOM de suppression d'un profil (fenetre maison, pas de StaticPopup).
local function ConfirmDeleteProfile(name)
    if not UI.profileConfirm then
        local m = UI.Components.Window(UIParent, { name = "ECPProfileConfirm", title = "Delete profile", width = 380, height = 170 })
        m:SetFrameStrata("FULLSCREEN_DIALOG"); m:SetToplevel(true)
        tinsert(UISpecialFrames, "ECPProfileConfirm")
        local c = m.content
        m.msg = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        m.msg:SetPoint("TOPLEFT", 16, -16); m.msg:SetPoint("RIGHT", c, "RIGHT", -16, 0); m.msg:SetJustifyH("LEFT")
        local yes = UI.Components.TextButton(c, { text = "Delete", width = 110, onClick = function()
            local res = HR.DeleteProfile(m._name); m:Hide()
            if res == "reload" then ReloadUI()
            elseif res == "deleted" then if UI.RefreshProfileTab then UI.RefreshProfileTab() end
            else HR:Print("Can't delete the last profile.") end
        end })
        yes:SetPoint("BOTTOMRIGHT", -16, 16)
        local no = UI.Components.TextButton(c, { text = "Cancel", width = 110, onClick = function() m:Hide() end })
        no:SetPoint("RIGHT", yes, "LEFT", -8, 0)
        UI.profileConfirm = m
    end
    local m = UI.profileConfirm
    m._name = name
    m.msg:SetText(("Delete profile \"%s\"?\nIts display settings will be lost. Plans are NOT affected."):format(name))
    m:Show(); m:Raise()
end

-- Modale CUSTOM "New profile" : texte explicatif + select du profil SOURCE + nom prerempli
-- (Joueur-Royaume-Spe) + CTA Cancel/Create. Le nouveau profil copie les valeurs de la source.
local function BuildProfileNewModal()
    local m = UI.Components.Window(UIParent, { name = "ECPProfileNewModal", title = "New profile", width = 460, height = 290 })
    m:SetFrameStrata("FULLSCREEN_DIALOG"); m:SetToplevel(true)
    tinsert(UISpecialFrames, "ECPProfileNewModal")
    local c = m.content

    local expl = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    expl:SetPoint("TOPLEFT", 16, -14); expl:SetPoint("RIGHT", c, "RIGHT", -16, 0); expl:SetJustifyH("LEFT")
    expl:SetText("The new profile is created from the profile of your choice, copying all of its settings into the new one.")
    expl:SetTextColor(0.8, 0.8, 0.8)

    local sl = c:CreateFontString(nil, "OVERLAY", "GameFontNormal"); sl:SetPoint("TOPLEFT", 16, -68); sl:SetText("Copy from"); sl:SetTextColor(1, 1, 1)
    m.source = HR.GetActiveProfileName()
    m.sourceSelect = MakeSelect(c, {
        width = 240,
        getLabel = function() return m.source or "-" end,
        options = function()
            local out = {}
            for _, n in ipairs(HR.ListProfiles()) do out[#out + 1] = { value = n, label = n } end
            return out
        end,
        onSelect = function(v) m.source = v end,
    })
    m.sourceSelect:SetPoint("TOPLEFT", sl, "BOTTOMLEFT", 0, -6)

    local nl = c:CreateFontString(nil, "OVERLAY", "GameFontNormal"); nl:SetPoint("TOPLEFT", 16, -148); nl:SetText("Name"); nl:SetTextColor(1, 1, 1)
    local edit = CreateFrame("EditBox", nil, c, "InputBoxTemplate")
    edit:SetSize(300, 24); edit:SetPoint("TOPLEFT", nl, "BOTTOMLEFT", 4, -6); edit:SetAutoFocus(false)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEnterPressed", function() UI.SubmitNewProfile() end)
    m.edit = edit

    local create = UI.Components.TextButton(c, { text = "Create", width = 110, onClick = function() UI.SubmitNewProfile() end })
    create:SetPoint("BOTTOMRIGHT", -16, 16)
    local cancel = UI.Components.TextButton(c, { text = "Cancel", width = 110, onClick = function() m:Hide() end })
    cancel:SetPoint("RIGHT", create, "LEFT", -8, 0)

    m:Hide()
    UI.profileNewModal = m
end

function UI.OpenProfileNewModal()
    if not UI.profileNewModal then BuildProfileNewModal() end
    local m = UI.profileNewModal
    m.source = HR.GetActiveProfileName()
    if m.sourceSelect.Refresh then m.sourceSelect.Refresh() end
    -- Nom prerempli : Joueur-Royaume-Spe.
    local player = UnitName("player") or "Profile"
    local realm  = GetRealmName() or ""
    local spec   = (HR.GetPlayerSpecName and HR.GetPlayerSpecName()) or ""
    local def = player
    if realm ~= "" then def = def .. "-" .. realm end
    if spec ~= "" then def = def .. "-" .. spec end
    m.edit:SetText(def)
    m:Show(); m:Raise(); m.edit:SetFocus(); m.edit:HighlightText()
end

function UI.SubmitNewProfile()
    local m = UI.profileNewModal; if not m then return end
    local name = strtrim(m.edit:GetText() or "")
    if name == "" then HR:Print("Give the profile a name."); return end
    if HR.CreateProfile(name, m.source) then
        m:Hide()
        HR.SwitchProfile(name)   -- bascule dessus (ReloadUI)
    else
        HR:Print("Profile name invalid or already used.")
    end
end

-- Onglet "Profile" : select CUSTOM du profil actif (suppression par ligne) + bouton New profile.
local function BuildProfileTab(panel)
    local intro = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", 6, -6); intro:SetPoint("RIGHT", panel, "RIGHT", -10, 0); intro:SetJustifyH("LEFT")
    intro:SetText("A profile stores ALL display settings (options, window positions, boss-spell bar colors). "
        .. "Plans (variants) are shared and NOT part of a profile. The active profile is per character.")
    intro:SetTextColor(0.7, 0.7, 0.7)

    local cl = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cl:SetPoint("TOPLEFT", 12, -56); cl:SetText("Current profile")
    UI.profileSelect = MakeSelect(panel, {
        width = 240,
        getLabel = function() return HR.GetActiveProfileName() end,
        options = function()
            local out = {}
            for _, n in ipairs(HR.ListProfiles()) do out[#out + 1] = { value = n, label = n } end
            return out
        end,
        onSelect = function(v) HR.SwitchProfile(v) end,   -- ReloadUI si different
        onDelete = function(v, pop) pop:Close(); ConfirmDeleteProfile(v) end,
    })
    UI.profileSelect:SetPoint("LEFT", cl, "RIGHT", 12, 0)

    local newBtn = UI.Components.TextButton(panel, { text = "New profile", autoWidth = true, padX = 14, padY = 6,
        onClick = function() UI.OpenProfileNewModal() end })
    newBtn:SetPoint("TOPLEFT", cl, "BOTTOMLEFT", 0, -24)
end

-- Rafraichit le libelle du select de profil (apres suppression sans reload).
function UI.RefreshProfileTab()
    if UI.profileSelect and UI.profileSelect.Refresh then UI.profileSelect.Refresh() end
end

local function BuildOptionsPanel()
    -- Barre "Settings" EN HAUT, comme la barre de boss (fond sombre + titre + onglets boutons).
    local bar = CreateFrame("Frame", nil, UI.body)
    bar:SetPoint("TOPLEFT", UI.body, "TOPLEFT", 0, 0)
    bar:SetPoint("TOPRIGHT", UI.body, "TOPRIGHT", 0, 0)
    bar:SetHeight(BOSSROW_H)
    bar.bg = bar:CreateTexture(nil, "BACKGROUND"); bar.bg:SetAllPoints()
    bar.bg:SetColorTexture(HR.Theme.Unpack("ZONE_BACKGROUND"))
    bar:Hide()
    UI.settingsBar = bar

    local pad = HR.Theme.Value("ZONE_PADDING", 10)
    local title = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetTextColor(HR.Theme.Unpack("BASE_TEXT_COLOR")); title:SetText("Settings")
    title:SetPoint("LEFT", bar, "LEFT", pad, 0)

    -- Contenu (panneaux d'options) SOUS la barre.
    local container = CreateFrame("Frame", nil, UI.body)
    container:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 16, -16)
    container:SetPoint("BOTTOMRIGHT", UI.body, "BOTTOMRIGHT", -34, 16)
    container:Hide()
    UI.optionsPanel = container

    -- Ordre : General / Announcements / Personal Timeline / Communication Bar / Bars and Timeline / Profiles.
    -- Le CONTENU est attache par index -> Announcements = panels[2], Bars and Timeline = panels[5] (swappes).
    local TAB_NAMES = { "General", "Announcements", "Personal Timeline", "Communication Bar", "Bars and Timeline", "Profiles" }
    local panels, tabs = {}, {}

    local function selectTab(idx)
        for i, pnl in ipairs(panels) do pnl:SetShown(i == idx) end
        for i, tb in ipairs(tabs) do tb:SetSelected(i == idx) end
    end

    -- Onglets = boutons STYLE BOSS (UI Kit), dans la barre, apres le titre "Settings".
    local x = pad + title:GetStringWidth() + 14
    for i, label in ipairs(TAB_NAMES) do
        local tb = UI.Components.TextButton(bar, { autoWidth = true, padX = 15, padY = 9, text = label })
        tb:SetOnClick(function() selectTab(i) end)
        tb:SetPoint("LEFT", bar, "LEFT", x, 0)
        tabs[i] = tb
        x = x + tb:GetWidth() + BOSS_GAP

        local pnl = CreateFrame("Frame", nil, container)
        pnl:SetPoint("TOPLEFT", 0, 0)
        pnl:SetPoint("BOTTOMRIGHT", 0, 0)
        pnl:Hide()
        panels[i] = pnl
    end

    -- General (+ sections Glow et Alert migrees ici)
    BuildGeneralTab(panels[1])

    -- "Bars and Timeline" : DEUX colonnes cote a cote -> gauche = timeline d'icones,
    -- droite = progress bars. Deux instances de BuildCompositionOptions dans des sous-panneaux.
    -- Les deux representations sont INDEPENDANTES (chacune son Enable, look-ahead et fond) : on
    -- peut afficher les deux en meme temps.
    do
        -- Bloc d'info en tete (pleine largeur, au-dessus des 2 colonnes). Hauteur AUTO.
        local info2 = UI.Components.InfoBox(panels[5], { text = "Eiiko Cooldown Planner features a lightweight bossmod. Each important boss timer will be visually paired with the response you plan for it." })
        info2:SetPoint("TOPLEFT", 12, -6); info2:SetPoint("TOPRIGHT", -12, -6)
        local pw2 = panels[5]:GetWidth(); if not pw2 or pw2 < 100 then pw2 = 1010 end
        info2:Relayout(pw2 - 24)
        panels[5].infoBox = info2

        -- Case PLEINE LARGEUR au-dessus des 2 colonnes : masquage des timers des AUTRES
        -- bossmods (cf. Core/ForeignBars.lua). Elle ne pilote aucun de nos modules, d'ou
        -- sa position hors des deux BuildCompositionOptions.
        local fbCb = CreateFrame("CheckButton", nil, panels[5], "UICheckButtonTemplate")
        fbCb:SetPoint("TOPLEFT", info2, "BOTTOMLEFT", 0, -8)
        local fbLbl = panels[5]:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fbLbl:SetPoint("LEFT", fbCb, "RIGHT", 2, 0)
        fbLbl:SetText("Hide other boss mod timers")
        fbCb:SetChecked(Opt().hideOtherBossMods == true)
        if UI.Components and UI.Components.AttachHelpTip then
            UI.Components.AttachHelpTip(fbCb, "Hide other boss mod timers",
                "Hides boss ability timers coming from BigWigs, LittleWigs, DBM and Blizzard's "
                .. "encounter timeline, so they don't duplicate this addon's own timers.\n\n"
                .. "Only inside Mythic+ dungeons. Raids, world bosses and "
                .. "everything else are never touched.\n\n"
                .. "Pull timers, break timers, respawn timers, stage timers and custom bars are "
                .. "left alone.\n\n"
                .. "Only affects timers started after the option is enabled, and Blizzard's "
                .. "timeline is only restored out of combat.")
        end

        -- Case EXCLUSIVE de la precedente : au lieu de masquer les barres BigWigs, on y
        -- accroche les icones des defensifs planifies (cf. Core/BossModAttach.lua).
        local bmaCb = CreateFrame("CheckButton", nil, panels[5], "UICheckButtonTemplate")
        bmaCb:SetPoint("TOPLEFT", fbCb, "BOTTOMLEFT", 0, -4)
        local bmaLbl = panels[5]:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        bmaLbl:SetPoint("LEFT", bmaCb, "RIGHT", 2, 0)
        bmaLbl:SetText("Attach planned cooldowns to BigWigs bars")
        bmaCb:SetChecked(Opt().attachDefsToBossMods == true)
        if UI.Components and UI.Components.AttachHelpTip then
            UI.Components.AttachHelpTip(bmaCb, "Attach planned cooldowns to BigWigs bars",
                "Shows the defensives you planned as icons at the right edge of the matching "
                .. "BigWigs, LittleWigs and DBM bars.\n\n"
                .. "Only inside Mythic+ dungeons. Raids, world bosses and "
                .. "everything else are never touched.\n\n"
                .. "Exclusive with \"Hide other boss mod timers\": enabling one disables the other.")
        end

        -- Les deux options sont MUTUELLEMENT EXCLUSIVES : cocher l'une decoche l'autre.
        -- Etat derive uniquement, aucune migration de DB.
        local function ApplyBossModOptions()
            fbCb:SetChecked(Opt().hideOtherBossMods == true)
            bmaCb:SetChecked(Opt().attachDefsToBossMods == true)
            if HR.ForeignBars and HR.ForeignBars.Apply then HR.ForeignBars.Apply() end
            if HR.BossModAttach and HR.BossModAttach.Apply then HR.BossModAttach.Apply() end
        end

        fbCb:SetScript("OnClick", function(s)
            local on = s:GetChecked() and true or false
            Opt().hideOtherBossMods = on
            if on then Opt().attachDefsToBossMods = false end
            ApplyBossModOptions()
        end)
        bmaCb:SetScript("OnClick", function(s)
            local on = s:GetChecked() and true or false
            Opt().attachDefsToBossMods = on
            if on then Opt().hideOtherBossMods = false end
            ApplyBossModOptions()
        end)

        if UI.Components and UI.Components.AttachHelpTip then
            UI.Components.AttachHelpTip(bmaCb, "Attach planned cooldowns to BigWigs bars",
                "Keeps BigWigs / LittleWigs bars visible and pins the defensives you planned "
                .. "for that ability right next to the bar, so the reminder shows up where you "
                .. "are already looking.\n\n"
                .. "Your own cooldowns are highlighted with a glow.\n\n"
                .. "Mutually exclusive with \"Hide other boss mod timers\": enabling one turns "
                .. "the other off.\n\n"
                .. "Requires BigWigs or LittleWigs. Only affects bars started after the option "
                .. "is enabled.")
        end

        local left = CreateFrame("Frame", nil, panels[5])
        left:SetPoint("TOPLEFT", bmaCb, "BOTTOMLEFT", -12, -10); left:SetPoint("BOTTOMLEFT", 0, 0); left:SetWidth(300)
        local right = CreateFrame("Frame", nil, panels[5])
        right:SetPoint("TOPLEFT", left, "TOPRIGHT", 30, 0); right:SetPoint("BOTTOMRIGHT", 0, 0)

        -- Colonne GAUCHE : timeline d'icones (composition "timeline" complete).
        BuildCompositionOptions(left, "timeline", {
            noPreview = true,
            items = {
                { header = "Timeline" }, { separator = true },
                { toggle = "Enable timeline",
                  tooltip = "Show the fight as a scrolling icon timeline.",
                  get = function() return Opt().timelineMode == true end,
                  set = function(v) Opt().timelineMode = v; if HR.Runtime.UpdateVisibility then HR.Runtime.UpdateVisibility() end end },
                { toggle = "Hide boss spell name",
                  get = function() return Opt().timelineHideBossName == true end,
                  set = function(v) Opt().timelineHideBossName = v end },
                { slider = "Look-ahead (s)", min = 10, max = 60, step = 5,
                  get = function() return Opt().timelineWindow or 30 end, set = function(v) Opt().timelineWindow = v end },
                { swatch = "Background color", key = "bgColor" },
                { swatch = "Border color", key = "borderColor" },
                { slider = "Border thickness", min = 0, max = 6, step = 1,
                  get = function() return HR.CompGet("timeline", "borderThickness") end,
                  set = function(v) HR.CompOpt("timeline").borderThickness = v end },
                { slider = "Scale", min = 0.5, max = 2.0, step = 0.05,
                  get = function() return HR.CompGet("timeline", "scale") end,
                  set = function(v) HR.CompOpt("timeline").scale = v end },
                { swatch = "Text color", key = "textColor" },
                { slider = "Text size", min = 8, max = 24, step = 1,
                  get = function() return HR.CompGet("timeline", "textSize") end,
                  set = function(v) HR.CompOpt("timeline").textSize = v end },
            },
        })

        -- Colonne DROITE : progress bars (composition "progress"). Pas de bordure ; la taille du
        -- texte s'ajuste dynamiquement a la hauteur de barre -> pas d'option Text size.
        BuildCompositionOptions(right, "progress", {
            noPreview = true,
            items = {
                { header = "Bars" }, { separator = true },
                { toggle = "Enable bars",
                  tooltip = "Show the fight as progress bars instead of the icon timeline.",
                  get = function() return Opt().timelineProgressBars == true end,
                  set = function(v) Opt().timelineProgressBars = v; if HR.Runtime.UpdateVisibility then HR.Runtime.UpdateVisibility() end end },
                { toggle = "Grow bars upward",
                  tooltip = "When extra bars appear, stack them above the anchored bar instead of below it. The first bar stays in place.",
                  get = function() return Opt().progressGrow == "up" end,
                  set = function(v) Opt().progressGrow = v and "up" or "down" end },
                { slider = "Look-ahead (s)", min = 10, max = 60, step = 5,
                  get = function() return Opt().progressWindow or 30 end, set = function(v) Opt().progressWindow = v end },
                { slider = "Text size", min = 6, max = 30, step = 1,
                  get = function() return Opt().progressTextSize or 12 end, set = function(v) Opt().progressTextSize = v end },
                { swatch = "Background color", key = "bgColor" },
                { swatch = "Text color", key = "textColor" },
            },
        })
    end

    -- Personal Timeline : la liste des CD du joueur pour tout le combat (ex-"My Tasks"/"My
    -- Timeline" ; le "what's next" a ete supprime). Options : Enable / Border / Background / Scale.
    do
        BuildCompositionOptions(panels[3], "upcoming", {
            noPreview = true,
            info = "The Personal Timeline shows when your personals or externals are expected to be used during the entire fight, helping you anticipate whether you should hold for a specific boss ability or if you can use them at will.",
            items = {
                { header = "Personal Timeline" },
                { separator = true },
                { toggle = "Enable Personal Timeline",
                  get = function() return Opt().upcomingEnabled ~= false end,
                  set = function(v) Opt().upcomingEnabled = v; if HR.Runtime.UpdateVisibility then HR.Runtime.UpdateVisibility() end end },
                { toggle = "Vertical layout",
                  get = function() return Opt().upcomingVertical == true end,
                  set = function(v) Opt().upcomingVertical = v end },   -- lu en direct par RenderUpcoming (rendu au tick)
                { toggle = "Show heal cooldowns (healer)",
                  get = function() return Opt().upcomingHeals == true end,
                  set = function(v) Opt().upcomingHeals = v end },      -- lu en direct par PlayerPlanCDs (rendu au tick)
                { slider = "Maximum upcoming spells", min = 0, max = 12, step = 1,
                  tooltip = "How many upcoming cooldowns the Personal Timeline shows at once. "
                      .. "With 4, you only ever see the next 4; if only 3 are left, you see 3. "
                      .. "Set it to 0 to switch the limit off and show the whole fight.",
                  get = function() return Opt().upcomingMax or 0 end,
                  set = function(v) Opt().upcomingMax = v end },        -- lu en direct par RenderUpcoming (rendu au tick)
                { swatch = "Border color", key = "borderColor" },
                { swatch = "Background color", key = "bgColor" },
                { slider = "Scale", min = 0.5, max = 4.0, step = 0.05,
                  get = function() return HR.CompGet("upcoming", "scale") end,
                  set = function(v) HR.CompOpt("upcoming").scale = v end },
            },
        })
    end

    -- Communication bar : composition partagee (bg/bordure/scale) + APERCU = vraie comm bar
    -- dockee (boutons d'appel reels, soigneur). Toggles fonctionnels = layout/ordre/filtre.
    do
        BuildCompositionOptions(panels[4], "comm", {
            noPreview = true,    -- pas d'apercu (la vraie comm bar reste dans l'UI globale)
            toggles = {
                { label = "Enable Communication Bar",
                  tooltip = "Show the Communication bar (healer feature).",
                  get = function() return Opt().commDisabled ~= true end,
                  set = function(v)
                      Opt().commDisabled = not v
                      if HR.Runtime.UpdateVisibility then HR.Runtime.UpdateVisibility() end
                  end },
                { label = "Enable for non-healer role",
                  tooltip = "Communication bar is a healer feature. Check this option to enable the bar even when playing a non-healer role.",
                  get = function() return Opt().commNonHealer == true end,
                  set = function(v)
                      Opt().commNonHealer = v
                      if HR.Runtime.UpdateVisibility then HR.Runtime.UpdateVisibility() end
                      if HR.Runtime.RefreshCallButtons then HR.Runtime.RefreshCallButtons() end
                  end },
                { label = "Ping CD owner on call",
                  tooltip = "When you click a cooldown call, also send a native ping (assist) to the group member who owns it, on top of the /p chat message.",
                  get = function() return Opt().commPing ~= false end,
                  set = function(v)
                      Opt().commPing = v
                      -- Rescan du groupe + reecriture des macros (avec ou sans la ligne /ping) a chaque bascule.
                      if HR.RebuildGroup then HR.RebuildGroup() end
                      if HR.RefreshMacroPings then HR.RefreshMacroPings() end
                  end },
                { label = "Reverse order",
                  get = function() return Opt().commReverse == true end,
                  set = function(v) Opt().commReverse = v end },
                { label = "Show only available spells",
                  get = function() return Opt().commAvailOnly == true end,
                  set = function(v) Opt().commAvailOnly = v end },
            },
            sliders = {
                { label = "Columns", min = 1, max = 9, step = 1,
                  tooltip = "Number of columns used to lay out the call buttons. 1 = single vertical column; 9 = single horizontal row.",
                  get = function() return HR.Runtime.CommColumns() end,
                  set = function(v) Opt().commColumns = v end },
            },
        })
    end

    -- Announcement : message centre a l'ecran (alternative a l'Upcoming bar, meme detection).
    do
        BuildCompositionOptions(panels[2], "announce", {
            items = {
                { header = "Announcements" },
                { separator = true },
                { toggle = "Enable announcements",
                  get = function() return Opt().announceDisabled ~= true end,
                  set = function(v)
                      Opt().announceDisabled = not v
                      if HR.Runtime.UpdateVisibility then HR.Runtime.UpdateVisibility() end
                  end },
                { toggle = "Show all spells",
                  get = function() return Opt().announceShowAll == true end,
                  set = function(v) Opt().announceShowAll = v end,
                  tooltip = "Display all spells from the plan, including healer spells and group externals such as AMZ or Zephyr.",
                  gatedBy = function() return Opt().announceDisabled == true end },
                { slider = "Threshold (s)", min = 3, max = 15, step = 1,
                  get = function() return Opt().announceThreshold or 5 end,
                  set = function(v) Opt().announceThreshold = v end,
                  tooltip = "Choose how long before the spell the icons pop up on screen.",
                  gatedBy = function() return Opt().announceDisabled == true end },
                { slider = "Icon size", min = 16, max = 400, step = 2,
                  get = function() return Opt().announceIconSize or 32 end,
                  set = function(v) Opt().announceIconSize = v end,
                  tooltip = "Size of the announcement icons (the timer scales with them).",
                  gatedBy = function() return Opt().announceDisabled == true end },
                { swatch = "Timer color", key = "textColor",
                  gatedBy = function() return Opt().announceDisabled == true end },
                { toggle = "Glow mine",
                  get = function() return Opt().announceGlowMine == true end,
                  set = function(v) Opt().announceGlowMine = v end,
                  tooltip = "Will add glow effect on your spells.",
                  gatedBy = function() return Opt().announceDisabled == true end },
            },
        })
    end

    -- Profile (selecteur + gestion).
    BuildProfileTab(panels[6])

    selectTab(1)
end

-- Affiche le panneau d'options (le construit a la 1re fois).
function UI.RenderOptions()
    if not UI.optionsPanel then BuildOptionsPanel() end
    if UI.settingsBar then UI.settingsBar:Show() end
    UI.optionsPanel:Show()
end

--------------------------------------------------------------------------------
-- Modes d'affichage (plan / Defensive list / Options)
--------------------------------------------------------------------------------

-- Disposition NORMALE (etat donjon) : rangee de boss EN HAUT, zone compo (Summary +
-- Variantes) dessous, puis le plan (titre + scroll) en pleine largeur sous la compo.
local function RestorePlanLayout()
    if UI.settingsBar then UI.settingsBar:Hide() end     -- quitte la vue Settings
    if UI.homeBar then UI.homeBar:Hide() end             -- ... et la page d'accueil
    if UI.bossRow then UI.bossRow:Show() end
    if UI.specsPanel then UI.specsPanel:Show() end
    UI.bossTitle:ClearAllPoints()
    UI.bossTitle:SetPoint("TOPLEFT", UI.specsPanel, "BOTTOMLEFT", 4, -8)
    UI.scroll:ClearAllPoints()
    UI.scroll:SetPoint("TOPLEFT", UI.specsPanel, "BOTTOMLEFT", 4, -34)
    UI.scroll:SetPoint("BOTTOMRIGHT", UI.body, "BOTTOMRIGHT", -34, 16)
end

-- Disposition LARGE (etats Defs / Options) : zone compo + rangee de boss masquees,
-- titre + scroll etales sur toute la largeur.
local function WideLayout()
    UI.SetVariantBarShown(false)
    if UI.specsPanel then UI.specsPanel:Hide() end
    if UI.bossRow then UI.bossRow:Hide() end
    UI.bossTitle:ClearAllPoints()
    UI.bossTitle:SetPoint("TOPLEFT", 16, -16)
    UI.scroll:ClearAllPoints()
    UI.scroll:SetPoint("TOPLEFT", 16, -40)
    UI.scroll:SetPoint("BOTTOMRIGHT", UI.body, "BOTTOMRIGHT", -34, 16)
end

-- Surbrillance des boutons de vue selon le mode actif (liseré doré, comme un onglet).
function UI.UpdateViewButtons()
    if not UI.viewButtons then return end
    for _, b in ipairs(UI.viewButtons) do
        if b.mode then b:SetSelected(UI.viewMode == b.mode) end
    end
end

-- Change de mode (nil = plan / "deflist"). Re-cliquer le
-- mode actif revient au plan.
function UI.SetViewMode(mode)
    if UI.viewMode == mode then mode = nil end
    UI.viewMode = mode
    UI.bossSettings = false         -- changer de vue large quitte les settings du boss
    if mode then
        UI.viewTrash = false
        WideLayout()
    else
        RestorePlanLayout()
        UI.RefreshVariantBar()
    end
    UI.UpdateViewButtons()
    UI.RefreshRows()
end

-- Restaure la disposition plan SANS rafraichir (appele par SelectDungeon, qui
-- enchaine deja avec RefreshBossList/RefreshRows).
function UI.ExitViewMode()
    if not UI.viewMode then return end
    UI.viewMode = nil
    RestorePlanLayout()
    UI.UpdateViewButtons()
end

--------------------------------------------------------------------------------
-- Reglages par sort de boss (vue "Settings" du boss : masque le plan)
--   Pour chaque sort (deduplique par spellID) : case Activer (allowInTimeline),
--   nom editable (defaut = nom du sort), case Play sound + selecteur de son Blizzard.
--   Persiste dans la DB via Core/BossSettings.lua (matching par id).
--------------------------------------------------------------------------------

local BS_ROW_H = 34
local BS_ICON  = 24

-- Construit (une fois) le panneau defilant des reglages de boss, sur la zone du
-- plan (a droite de la liste des boss). Parente a la modale comme optionsPanel.
local function BuildBossSettingsPanel()
    local container = CreateFrame("Frame", nil, UI.body)
    container:SetPoint("TOPLEFT", UI.specsPanel, "BOTTOMLEFT", 4, -34)   -- sous la compo (= comme le scroll)
    container:SetPoint("BOTTOMRIGHT", UI.body, "BOTTOMRIGHT", -34, 16)
    container:SetFrameLevel(UI.body:GetFrameLevel() + 10)   -- au-dessus du scroll du plan
    container:Hide()

    local sf = CreateFrame("ScrollFrame", nil, container, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 0, 0)
    sf:SetPoint("BOTTOMRIGHT", -26, 0)
    local p = CreateFrame("Frame", nil, sf)
    p:SetSize(620, 1)
    sf:SetScrollChild(p)
    container.scroll = sf
    container.content = p

    -- Texte d'intro (le titre "Configuration" emphase = le titre du boss, cf. RefreshBossPlan).
    local intro = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", 6, -6)
    intro:SetPoint("RIGHT", p, "RIGHT", -10, 0)
    intro:SetJustifyH("LEFT")
    intro:SetText("This only affects the timeline feature. If you are not using the timeline, you can ignore this section.")
    intro:SetTextColor(0.7, 0.7, 0.7)
    container.intro = intro

    UI.bossSettingsRows = {}
    UI.bossSettingsPanel = container
end

-- Ligne reutilisable : icone + case Activer + champ nom + case son + bouton son.
local function AcquireBossSettingRow(i)
    local rows = UI.bossSettingsRows
    local row = rows[i]
    if row then row:Show(); return row end

    local p = UI.bossSettingsPanel.content
    row = CreateFrame("Frame", nil, p)
    row:SetHeight(BS_ROW_H)

    -- Icone du sort (tooltip = sort d'origine, pour retrouver le sort apres renommage).
    row.iconFrame = CreateFrame("Frame", nil, row)
    row.iconFrame:SetSize(BS_ICON, BS_ICON)
    row.iconFrame:SetPoint("LEFT", 6, 0)
    row.iconFrame:EnableMouse(true)
    row.iconFrame:SetScript("OnEnter", function(self)
        if not self.spellID then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetSpellByID(self.spellID)
        GameTooltip:Show()
    end)
    row.iconFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.icon = row.iconFrame:CreateTexture(nil, "ARTWORK")
    row.icon:SetAllPoints()
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- Case Activer (allowInTimeline).
    row.enable = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.enable:SetSize(24, 24)
    row.enable:SetPoint("LEFT", 36, 0)

    -- Champ de nom editable (defaut = nom du sort).
    row.nameBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    row.nameBox:SetSize(200, 20)
    row.nameBox:SetPoint("LEFT", 100, 0)
    row.nameBox:SetAutoFocus(false)

    -- Couleur de barre : libelle + swatch (clic gauche = ColorPicker, clic droit = reset defaut).
    row.colorLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.colorLabel:SetPoint("LEFT", 320, 0); row.colorLabel:SetText("Bar color")
    row.colorSwatch = CreateFrame("Button", nil, row, "BackdropTemplate")
    row.colorSwatch:SetSize(22, 22); row.colorSwatch:SetPoint("LEFT", row.colorLabel, "RIGHT", 8, 0)
    row.colorSwatch:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.colorSwatch:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10 })
    row.colorSwatch:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    row.colorSwatch.sbg = row.colorSwatch:CreateTexture(nil, "BACKGROUND")
    row.colorSwatch.sbg:SetPoint("TOPLEFT", 2, -2); row.colorSwatch.sbg:SetPoint("BOTTOMRIGHT", -2, 2)

    rows[i] = row
    return row
end

-- Affiche les reglages du boss courant (1 ligne par sort deduplique).
function UI.RenderBossSettings(boss)
    if not UI.bossSettingsPanel then BuildBossSettingsPanel() end
    local container = UI.bossSettingsPanel
    local p = container.content

    -- Largeur du contenu = celle du scroll (repli avant 1er layout).
    local w = container.scroll:GetWidth()
    if not w or w < 50 then w = 600 end
    p:SetWidth(w)

    local spells  = HR.GetBossSpells(boss)
    local encID   = boss.id
    local introH  = (container.intro and container.intro:GetStringHeight()) or 14
    local y = -(introH + 24)      -- sous le texte d'intro

    for i, ab in ipairs(spells) do
        local row = AcquireBossSettingRow(i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, y)
        row:SetPoint("TOPRIGHT", 0, y)

        local sid = ab.spellID
        local r   = HR.ResolveBossSpell(encID, ab, sid)

        row.iconFrame.spellID = sid
        row.icon:SetTexture(HR.GetSpellIcon(sid))

        -- Activer (allowInTimeline).
        row.enable:SetChecked(r.enabled)
        row.enable:SetScript("OnClick", function(self)
            HR.SetBossSpellOverride(encID, sid, "enabled", self:GetChecked() and true or false)
        end)

        -- Nom custom : vide ou == defaut => efface l'override (revient au defaut).
        row.nameBox:SetText(r.name)
        row.nameBox:SetCursorPosition(0)
        local function commitName(self)
            local txt = strtrim(self:GetText() or "")
            if txt == "" or txt == r.defaultName then
                HR.SetBossSpellOverride(encID, sid, "name", nil)
                self:SetText(r.defaultName)
            else
                HR.SetBossSpellOverride(encID, sid, "name", txt)
            end
            self:ClearFocus()
            self:SetCursorPosition(0)
        end
        row.nameBox:SetScript("OnEnterPressed", commitName)
        row.nameBox:SetScript("OnEditFocusLost", commitName)
        row.nameBox:SetScript("OnEscapePressed", function(self)
            self:SetText(HR.ResolveBossSpell(encID, ab, sid).name)
            self:ClearFocus()
            self:SetCursorPosition(0)
        end)

        -- Couleur de barre : swatch peint avec la couleur sauvegardee (ou le defaut), clic
        -- gauche = ColorPicker (ecrit l'override), clic droit = efface l'override (revient au defaut).
        local function curColor()
            return HR.ResolveBossSpell(encID, ab, sid).barColor or HR.DEFAULT_BAR_COLOR
        end
        local function paintSwatch()
            local c = curColor()
            row.colorSwatch.sbg:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
        end
        paintSwatch()
        row.colorSwatch:SetScript("OnClick", function(_, button)
            if button == "RightButton" then
                HR.SetBossSpellOverride(encID, sid, "barColor", nil)   -- reset au defaut
                paintSwatch()
                return
            end
            local c = curColor()
            local function apply()
                local rr, gg, bb = ColorPickerFrame:GetColorRGB()
                local aa = (ColorPickerFrame.GetColorAlpha and ColorPickerFrame:GetColorAlpha()) or c[4] or 1
                HR.SetBossSpellOverride(encID, sid, "barColor", { rr, gg, bb, aa })
                paintSwatch()
            end
            ColorPickerFrame:SetupColorPickerAndShow({
                r = c[1], g = c[2], b = c[3], hasOpacity = true, opacity = c[4] or 1,
                swatchFunc = apply, opacityFunc = apply,
            })
        end)
        row.colorSwatch:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Bar color")
            GameTooltip:AddLine("Left-click: pick a color   Right-click: reset", 0.8, 0.8, 0.8)
            GameTooltip:Show()
        end)
        row.colorSwatch:SetScript("OnLeave", function() GameTooltip:Hide() end)

        y = y - BS_ROW_H
    end

    -- Masque les lignes inutilisees du pool.
    for j = #spells + 1, #UI.bossSettingsRows do UI.bossSettingsRows[j]:Hide() end

    if #spells == 0 then
        if not container.empty then
            container.empty = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            container.empty:SetPoint("TOPLEFT", 6, -32)
        end
        container.empty:SetText("|cff888888No registered spell for this boss.|r")
        container.empty:Show()
    elseif container.empty then
        container.empty:Hide()
    end

    p:SetHeight(math.max(-y + 8, 1))
    container:Show()
end

-- Variantes de TIMELINE (ex. L'ura). On distingue DEUX notions :
--   * VISUALISEE : la variante qu'on regarde/edite (onglets ; n'affecte PAS le combat).
--   * JOUEE : la variante qui tourne en combat (bouton "Play this variant", persistee).

-- Variante de timeline VISUALISEE d'un boss (etat UI ; defaut = la variante JOUEE).
function UI.GetViewedTlVariant(boss)
    local variants = HR.GetTimelineVariants(boss)
    if not variants then return nil end
    UI.tlView = UI.tlView or {}
    local viewed = UI.tlView[boss.id]
    if viewed then
        for _, v in ipairs(variants) do if v.id == viewed then return viewed end end
    end
    return HR.GetActiveTimelineVariantId(boss)
end

-- Message central a la place du plan (ex. boss desactive : "Plan unavailable").
-- Message d'etat dans la zone de plan. `centered` => grand message au CENTRE du panneau
-- de contenu (ex. donjon sans data) ; sinon ancrage haut (defaut, retro-compatible).
function UI.ShowPlanMessage(text, centered)
    if not UI.planMsg then
        UI.planMsg = UI.body:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
    end
    UI.planMsg:ClearAllPoints()
    if centered then
        UI.planMsg:SetPoint("CENTER", UI.body, "CENTER", 0, 0)
    else
        UI.planMsg:SetPoint("TOP", UI.scroll, "TOP", 0, -60)
    end
    UI.planMsg:SetText(text)
    UI.planMsg:Show()
end

function UI.RefreshRows()
    -- Cacher tous les enfants de la liste avant de choisir le mode d'affichage.
    for _, r in ipairs(UI.rows) do r:Hide() end
    for _, s in ipairs(UI.phaseSeps) do s:Hide() end
    for _, t in ipairs(UI.trashRows) do t:Hide() end
    for _, r in ipairs(UI.defListRows) do r:Hide() end
    for _, t in ipairs(UI.varTabs or {}) do t:Hide() end
    if UI.tlPlayBtn then UI.tlPlayBtn:Hide() end
    if UI.planMsg then UI.planMsg:Hide() end
    if UI.trashEmpty then UI.trashEmpty:Hide() end
    if UI.viewEmpty then UI.viewEmpty:Hide() end
    if UI.optionsPanel then UI.optionsPanel:Hide() end
    if UI.settingsBar then UI.settingsBar:Hide() end
    if UI.homeBar then UI.homeBar:Hide() end
    if UI.homePanel then UI.homePanel:Hide() end
    if UI.bossSettingsPanel then UI.bossSettingsPanel:Hide() end
    if UI.planTimeline then UI.planTimeline:Hide() end
    if UI.specsPanel then UI.specsPanel:Hide() end
    if UI.CloseVariantPopup then UI.CloseVariantPopup() end
    if UI.CloseCDPicker then UI.CloseCDPicker() end
    if UI.scroll then UI.scroll:Show() end      -- rendu par defaut ; masque seulement en vue Settings
    -- Bouton "Settings" du boss : present dans la rangee en vues plan ET Trash. En vue large
    -- (Defs/Options) la rangee de boss est masquee -> le bouton l'est aussi (c'est son enfant).
    if UI.bossSettingsBtn then
        UI.bossSettingsBtn:SetText(UI.bossSettings and "Plan" or "Configuration")
        UI.bossSettingsBtn:Show()
    end

    -- Page d'ACCUEIL : barre "Homepage" (sans boutons) + grille de cards (cf. UI/HomePage.lua).
    if UI.viewMode == "home" then
        UI.bossTitle:SetText("")
        if UI.scroll then UI.scroll:Hide() end
        UI.UpdateContentBg()                                  -- bg-settings (viewMode == home)
        if UI.contentBg then UI.contentBg:Show() end
        if UI.contentDim then UI.contentDim:Show() end
        UI.RenderHome()
        return
    end

    -- Modes "vue liste" plein largeur (pas de plan) : Defensive list / Options.
    if UI.viewMode == "deflist" then
        UI.bossTitle:SetText("All defensive cooldowns by class")
        UI.RenderDefList()
        return
    elseif UI.viewMode == "options" then
        -- Vue Settings "comme un donjon" : barre Settings en haut + fond dedie, le titre
        -- libre et le scroll du plan sont masques (la barre porte le titre + les onglets).
        UI.bossTitle:SetText("")
        if UI.scroll then UI.scroll:Hide() end
        UI.UpdateContentBg()                                  -- bg-settings (viewMode == options)
        if UI.contentBg then UI.contentBg:Show() end
        if UI.contentDim then UI.contentDim:Show() end
        UI.RenderOptions()
        return
    elseif UI.viewMode == "faq" then
        -- Vue FAQ (section dediee) : MEME fond que Settings (bg-settings) mais SANS la
        -- barre superieure (settingsBar reste masquee). Contenu a venir -> placeholder centre.
        UI.bossTitle:SetText("")
        if UI.scroll then UI.scroll:Hide() end
        UI.UpdateContentBg()                                  -- bg-settings (viewMode == faq)
        if UI.contentBg then UI.contentBg:Show() end
        if UI.contentDim then UI.contentDim:Show() end
        UI.ShowPlanMessage("FAQ - coming soon.", true)
        return
    end

    local dungeon = HR.content[UI.selDungeon]
    HR.SetCurrentV2Dungeon(dungeon and dungeon.id)   -- variantes V2 = PAR DONJON (donjon courant)

    -- Pool de donjons VIDE pour cette version du client (ex. data 12.1.0 pas encore
    -- renseignee) : aucun donjon => aucun plan/specs, juste un message. Le sidemenu est
    -- deja absent (boucle de tabs sur {} = no-op).
    if not dungeon then
        UI.bossTitle:SetText("")
        if UI.bossSettingsBtn then UI.bossSettingsBtn:Hide() end
        UI.ShowPlanMessage("No content available for this game version yet.")
        UI.listContent:SetHeight(1)
        return
    end

    -- Panneau de gauche : toutes les spe heal du jeu (visible en contexte donjon).
    UI.RenderHealerSpecs()

    -- Mode "Trash Info" : liste des capacites AoE du donjon (pas d'occurrences).
    if UI.viewTrash then
        UI.bossTitle:SetText("Trash Info - abilities reduced by Zephyr (AoE)")
        UI.RenderTrash(dungeon)
        UI.UpdateListHighlight()
        return
    end

    local boss = dungeon and dungeon.bosses[UI.selBoss]
    UI.bossTitle:SetText("")                        -- le nom du boss est affiche dans la boite variante
    UI.UpdateListHighlight()

    if not boss then
        UI.bossSettings = false
        -- Donjon sans AUCUN boss (data de timeline pas encore renseignee, ex. pool en
        -- cours de remplissage) : message explicite CENTRE, pas de plan ni de selecteur.
        if #dungeon.bosses == 0 then
            if UI.bossSettingsBtn then UI.bossSettingsBtn:Hide() end
            if UI.specsPanel then UI.specsPanel:Hide() end
            UI.ShowPlanMessage("This dungeon is not available yet.", true)
        end
        UI.listContent:SetHeight(1)
        return
    end

    -- Boss desactive : selectionnable et Settings accessibles, mais PAS de plan.
    local enabled = HR.BossEnabled(boss)
    if not enabled then
        UI.bossTitle:SetText("|cff888888(disabled)|r")
    end

    -- Le bouton "Settings" (deja affiche/libelle en haut) bascule plan <-> reglages.
    -- En mode reglages, on masque le plan.
    if UI.bossSettings then
        UI.bossTitle:SetText(HR.Theme.Hex("EMPHASIZE_TEXT_COLOR") .. "Configuration" .. "|r")
        UI.listContent:SetHeight(1)     -- vide le plan derriere le panneau
        UI.scroll:Hide()                -- la vue Settings remplace le scroll du plan
        UI.RenderBossSettings(boss)
        return
    end

    -- Boss desactive en vue PLAN : pas de planification -> message dedie.
    if not enabled then
        UI.ShowPlanMessage("Plan unavailable")
        UI.listContent:SetHeight(1)
        return
    end

    -- Variantes de TIMELINE (ex. L'ura) : la timeline effective = celle de la variante
    -- active. Indicateur PERSISTANT dans le titre (anti-misconfig, visible meme en scroll).
    local tlVariants = HR.GetTimelineVariants(boss)
    if tlVariants then
        local playId = HR.GetActiveTimelineVariantId(boss)
        local playName = playId
        for _, v in ipairs(tlVariants) do if v.id == playId then playName = v.name end end
        -- Indicateur PERSISTANT de la variante JOUEE (vert) : visible meme en scroll (anti-misconfig).
        UI.bossTitle:SetText("|cff33ff99\226\150\182 Playing: " .. tostring(playName) .. "|r")
    end

    -- NOUVELLE interface de planification : frise chronologique statique 0..300 s.
    -- Chaque capacite planifiable est placee sur l'axe au temps exact, avec un "+"
    -- au-dessus pour ajouter un defensif. (L'ancienne liste verticale d'occurrences
    -- est archivee dans Archive/ConfigFrame_pre_timeline.lua.)
    UI.scroll:Hide()
    UI.RenderPlanTimeline(boss)
end

-- Fond de la zone de contenu (Summary + Variantes + Timeline) selon le DONJON courant :
-- texture Media\backgrounds\<ABBR>.tga (cle asset "bg-<ABBR>", par shortname). Cle non
-- enregistree ou fichier absent => transparent (le fond du cadre reste visible).
function UI.UpdateContentBg()
    if not UI.contentBg then return end
    local key
    if UI.viewMode == "options" or UI.viewMode == "faq" or UI.viewMode == "home" then
        key = "bg-settings"                                  -- vues Settings/FAQ/Home : meme fond dedie
    else
        local dungeon = HR.content[UI.selDungeon]
        key = dungeon and dungeon.abbr and ("bg-" .. dungeon.abbr)
    end
    UI.contentBg:SetTexture((key and HR.Assets.registry[key]) and HR.Asset(key) or nil)
    -- FAQ : aucune barre superieure -> le fond couvre TOUTE la zone (haut du body inclus),
    -- sinon (Settings/donjon) il demarre sous la boss bar / settingsBar. Reancrage idempotent.
    local topAnchor, topRel = UI.bossRow, "BOTTOMLEFT"
    if UI.viewMode == "faq" then topAnchor, topRel = UI.body, "TOPLEFT" end
    for _, tex in ipairs({ UI.contentBg, UI.contentDim, UI.contentDimSettings }) do
        if tex then
            tex:ClearAllPoints()
            tex:SetPoint("TOPLEFT", topAnchor, topRel, 0, 0)
            tex:SetPoint("BOTTOMRIGHT", UI.body, "BOTTOMRIGHT", 0, 0)
        end
    end
    if UI.contentDimSettings then
        -- voile renforce partage par Settings, FAQ et Home (meme fond)
        UI.contentDimSettings:SetShown(UI.viewMode == "options" or UI.viewMode == "faq" or UI.viewMode == "home")
    end
    UI.LayoutContentBg()
end

-- Anti-etirement : une Texture WoW est ETIREE pour remplir son rectangle (aucun respect
-- du ratio). Nos fonds etant CARRES (512x512) et la zone large, on recadre en mode
-- "cover" via SetTexCoord : ratio conserve, l'excedent depasse (rogne, centre).
-- A rappeler quand la taille du cadre change (OnSizeChanged) car le ratio en depend.
function UI.LayoutContentBg()
    if not UI.contentBg then return end
    local w, h = UI.contentBg:GetWidth(), UI.contentBg:GetHeight()
    if not w or not h or w <= 0 or h <= 0 then return end
    local af = w / h                 -- ratio du cadre (texture supposee carree 1:1)
    if af >= 1 then
        local dv = 1 / af            -- cadre large => on rogne haut/bas
        UI.contentBg:SetTexCoord(0, 1, (1 - dv) / 2, (1 + dv) / 2)
    else
        local du = af                -- cadre haut => on rogne gauche/droite
        UI.contentBg:SetTexCoord((1 - du) / 2, (1 + du) / 2, 0, 1)
    end
end

--------------------------------------------------------------------------------
-- Section A : liste des boss
--------------------------------------------------------------------------------

function UI.RefreshBossList()
    local dungeon = HR.content[UI.selDungeon]
    local bosses  = dungeon and dungeon.bosses or {}

    for _, b in ipairs(UI.bossButtons) do b:Hide() end

    -- Nom du donjon en TETE de rangee (avant les boutons de boss).
    if not UI.dungeonLabel then
        UI.dungeonLabel = UI.bossRow:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        UI.dungeonLabel:SetTextColor(1, 1, 1)
    end
    local pad = HR.Theme.Value("ZONE_PADDING", 10)   -- harmonise avec la sidebar
    UI.dungeonLabel:SetText(dungeon and dungeon.name or "")
    UI.dungeonLabel:ClearAllPoints()
    UI.dungeonLabel:SetPoint("LEFT", UI.bossRow, "LEFT", pad, 0)

    -- Rangee HORIZONTALE : un bouton-texte (variante arrondie, UI Kit) par boss, apres le nom.
    local x = pad + UI.dungeonLabel:GetStringWidth() + 14
    for i, boss in ipairs(bosses) do
        local btn = UI.bossButtons[i]
        if not btn then
            btn = UI.Components.TextButton(UI.bossRow, { autoWidth = true, padX = 15, padY = 9 })
            UI.bossButtons[i] = btn
        end
        btn:SetText(boss.name)
        btn:SetStruck(not HR.BossEnabled(boss))   -- boss desactive = texte barre
        btn:SetOnClick(function()
            UI.selBoss      = i
            UI.viewTrash    = false
            UI.bossSettings = false     -- selectionner un boss revient a son plan
            UI.RefreshRows()
        end)
        btn:ClearAllPoints()
        btn:SetPoint("LEFT", UI.bossRow, "LEFT", x, 0)
        btn:Show()
        x = x + btn:GetWidth() + BOSS_GAP
    end

    -- selBoss : n'importe quel boss est selectionnable (desactives inclus).
    if #bosses == 0 or not bosses[UI.selBoss] then
        UI.selBoss = 1
    end

    UI.UpdateContentBg()   -- fond de la zone selon le donjon (shortname)

    -- Bouton "Configuration" custom en fin de rangee (le bouton "Trash Info" a ete retire).
    UI.bossSettingsBtn:ClearAllPoints()
    UI.bossSettingsBtn:SetPoint("LEFT", UI.bossRow, "LEFT", x + 14, 0)

    UI.UpdateListHighlight()
end

--------------------------------------------------------------------------------
-- Section B : onglets de donjon
--------------------------------------------------------------------------------

local function SelectDungeon(index)
    UI.selDungeon = index
    -- Aller directement au premier boss eligible a la planification (active).
    -- Repli sur le 1er boss si aucun n'est active.
    UI.selBoss = 1
    local dungeon0 = HR.content[index]
    if dungeon0 and dungeon0.bosses then
        for i, boss in ipairs(dungeon0.bosses) do
            if HR.BossEnabled(boss) then
                UI.selBoss = i
                break
            end
        end
    end
    UI.viewTrash = false        -- changer de donjon revient en vue boss
    UI.bossSettings = false     -- ... et au plan (pas aux settings du boss)
    UI.ExitViewMode()           -- sortir d'une vue liste (Defs/Zephyr/Shadowmeld)
    for i, tab in ipairs(UI.tabs) do
        tab:SetSelected(i == index)         -- liseré dore + desaturation des inactifs
    end
    UI.RefreshBossList()
    local dungeon = HR.content[index]
    -- Etat partage lu par le panneau V2 (UI/HealerSpecs.lua). Posé ici en direct : c'etait
    -- auparavant un effet de bord de UI.OnDungeonSelected (V1, barre de variantes masquee).
    -- Le donjon courant V2 est pose separement par HR.SetCurrentV2Dungeon (dans RefreshRows).
    UI.activeDungeonID = dungeon and dungeon.id
    UI.RefreshRows()
end
UI.SelectDungeon = SelectDungeon   -- expose (ex. import : aller sur le donjon de la variante)

--------------------------------------------------------------------------------
-- Construction de la modale
--------------------------------------------------------------------------------

-- Titre "Eiiko Cooldown Planner" avec E/C/P teintes aux couleurs de classe (vert moine,
-- orange druide, bleu chaman) ; le reste en blanc (couleur par defaut du titre). Couleurs
-- tirees de RAID_CLASS_COLORS (exactes) ; repli sur la lettre brute si indispo.
local function classLetter(letter, classToken)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
    if c and c.colorStr then return "|c" .. c.colorStr .. letter .. "|r" end
    return letter
end

-- Petit utilitaire de copie : modale avec le lien Discord dans un EditBox surligne (WoW ne peut
-- pas ecrire dans le presse-papier -> on affiche le texte selectionne, le joueur fait Ctrl+C).
-- L'EditBox est en lecture seule effective (toute edition re-remet l'URL + resurligne).
function UI.ShowDiscordLink()
    if not (UI.Components and UI.Components.Window) then return end
    local m = UI.discordModal
    if not m then
        m = UI.Components.Window(UIParent, { name = "ECPDiscordLink", title = "Join our Discord", width = 380, height = 150 })
        m:SetFrameStrata("FULLSCREEN_DIALOG"); m:SetToplevel(true)
        tinsert(UISpecialFrames, "ECPDiscordLink")
        local c = m.content
        local lbl = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl:SetPoint("TOPLEFT", 16, -16); lbl:SetPoint("RIGHT", c, "RIGHT", -16, 0); lbl:SetJustifyH("LEFT")
        lbl:SetText("Copy the link (Ctrl+C) and open it in your browser:")

        local eb = CreateFrame("EditBox", nil, c, "InputBoxTemplate")
        eb:SetSize(300, 24)
        eb:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 6, -18)
        eb:SetAutoFocus(false)
        eb:SetFontObject("GameFontHighlight")
        eb:SetText(DISCORD_URL)
        eb:SetCursorPosition(0)
        eb:SetScript("OnTextChanged", function(self)
            if self:GetText() ~= DISCORD_URL then self:SetText(DISCORD_URL); self:HighlightText() end
        end)
        eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        eb:SetScript("OnEnterPressed",  function(self) self:ClearFocus() end)
        eb:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
        m.edit = eb

        local close = UI.Components.TextButton(c, { text = "Close", width = 90, onClick = function() m:Hide() end })
        close:SetPoint("BOTTOM", 0, 14)
        UI.discordModal = m
    end
    m.edit:SetText(DISCORD_URL)
    m:Show(); m:Raise()
    m.edit:SetFocus(); m.edit:HighlightText()
end

-- Modale GENERIQUE de copie (texte multi-lignes, defilant, lecture seule). Meme astuce que
-- ShowDiscordLink : toute edition remet le texte stocke (WoW ne peut pas ecrire le presse-papier
-- -> le joueur fait Ctrl+A / Ctrl+C). Utilisee par /ecp devscan copy (export de la data captee).
function UI.ShowCopyText(title, text)
    if not (UI.Components and UI.Components.Window) then return end
    local m = UI.copyTextModal
    if not m then
        m = UI.Components.Window(UIParent, { name = "ECPCopyText", title = title or "Copy", width = 680, height = 500 })
        m:SetFrameStrata("FULLSCREEN_DIALOG"); m:SetToplevel(true)
        tinsert(UISpecialFrames, "ECPCopyText")
        local c = m.content

        local scroll = CreateFrame("ScrollFrame", "ECPCopyTextScroll", c, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 16, -16)
        scroll:SetPoint("BOTTOMRIGHT", -34, 52)          -- place pour la scrollbar + bouton Close

        local eb = CreateFrame("EditBox", nil, scroll)
        eb:SetMultiLine(true)
        eb:SetAutoFocus(false)
        eb:SetFontObject("GameFontHighlightSmall")
        eb:SetWidth(610)
        eb:SetScript("OnTextChanged", function(self)
            if self:GetText() ~= (m._text or "") then self:SetText(m._text or ""); self:HighlightText() end
        end)
        eb:SetScript("OnEscapePressed", function(self) self:ClearFocus(); m:Hide() end)
        eb:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
        scroll:SetScrollChild(eb)
        m.edit = eb

        local close = UI.Components.TextButton(c, { text = "Close", width = 90, onClick = function() m:Hide() end })
        close:SetPoint("BOTTOM", 0, 14)
        UI.copyTextModal = m
    end
    if m.SetTitle then m:SetTitle(title or "Copy") end
    m._text = text or ""
    m.edit:SetText(m._text)
    m:Show(); m:Raise()
    m.edit:SetFocus(); m.edit:HighlightText()
end

local function Build()
    -- Titre "Eiiko Cooldown Planner" : E/C/P aux couleurs de classe (vert moine, orange
    -- druide, bleu chaman), le reste en blanc. Construit au runtime -> RAID_CLASS_COLORS sur.
    local titleStr = classLetter("E", "MONK") .. "iiko "
        .. classLetter("C", "DRUID") .. "ooldown "
        .. classLetter("P", "SHAMAN") .. "lanner"
    -- Frame principale custom (grid + bordure noire + gros titre centre).
    local f = UI.Components.Window(UIParent, {
        name      = "HealPlannerConfigFrame",
        title     = titleStr,
        width     = 1144,
        height    = 759,
        grid      = false,                                 -- pas de grille (fond uni)
        bg        = HR.Theme.Color("GLOBAL_BACKGROUND"),   -- fond global du cadre principal
        bgTexture = HR.Asset("mainframe-bg"),
        onMoved   = function(self) HR.SaveFramePos("config", self) end,
    })
    f:Hide()

    -- Layout deux zones (Phase 2) : sidebar de navigation a gauche, contenu a droite.
    local content = f.content

    UI.sidebar = CreateFrame("Frame", nil, content)
    UI.sidebar:SetPoint("TOPLEFT", 0, 0)
    UI.sidebar:SetPoint("BOTTOMLEFT", 0, FOOTER_H)   -- laisse la place au bandeau bas
    UI.sidebar:SetWidth(SIDEBAR_W)
    UI.sidebar.bg = UI.sidebar:CreateTexture(nil, "BACKGROUND")
    UI.sidebar.bg:SetAllPoints()
    UI.sidebar.bg:SetColorTexture(HR.Theme.Unpack("ZONE_BACKGROUND"))

    UI.rightPanel = CreateFrame("Frame", nil, content)
    UI.rightPanel:SetPoint("TOPLEFT", UI.sidebar, "TOPRIGHT", 0, 0)
    UI.rightPanel:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, FOOTER_H)   -- au-dessus du bandeau bas

    -- Bandeau bas : "ECP - {version}" a gauche + bouton "Join discord" a droite.
    local footer = CreateFrame("Frame", nil, content)
    footer:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 0)
    footer:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
    footer:SetHeight(FOOTER_H)
    footer.bg = footer:CreateTexture(nil, "BACKGROUND")
    footer.bg:SetAllPoints()
    footer.bg:SetColorTexture(HR.Theme.Unpack("ZONE_BACKGROUND"))
    footer.ver = footer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer.ver:SetPoint("LEFT", 12, 0)
    footer.ver:SetText("ECP - " .. tostring(HR.VERSION))
    local discBtn = UI.Components.TextButton(footer, { text = "Join discord", width = 120, height = 20,
        onClick = function() UI.ShowDiscordLink() end })
    discBtn:SetPoint("RIGHT", -10, 0)

    -- Tout le contenu (hors navigation) s'ancre dans le panneau de droite.
    local body = UI.rightPanel
    UI.body = body

    -- fermeture par Echap
    tinsert(UISpecialFrames, "HealPlannerConfigFrame")

    -- Fermer le popup de variante si la fenetre se ferme (sinon son capteur plein
    -- ecran resterait et bloquerait tous les clics).
    f:HookScript("OnHide", function()
        if UI.CloseVariantPopup then UI.CloseVariantPopup() end
        if UI.CloseCDPicker then UI.CloseCDPicker() end
    end)

    -- Helper : bouton de navigation (image + tooltip) dans la sidebar.
    local function NavButton(opts, tipText)
        local b = UI.Components.ImageButton(UI.sidebar, opts)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(tipText)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return b
    end

    -- Traitement de selection DEDIE aux boutons d'OUTILS (icones blanches custom : Home,
    -- Options, FAQ) : ni liseré colore (le vert/violet du theme transparaitrait derriere
    -- l'icone), ni desaturation. Etat actif = pleine luminosite ; inactif = attenue.
    -- Override par instance -> les onglets de donjon gardent le SetSelected partage.
    local function StyleToolButton(b)
        if b.selBorder then b.selBorder:Hide() end
        -- Fond NOIR derriere l'icone blanche (sinon elle se fond dans la sidebar sombre =
        -- illisible). Survol = leger gris (highlight du bouton par-dessus le fond noir).
        if not b.toolBg then
            b.toolBg = b:CreateTexture(nil, "BACKGROUND", nil, 1)
            b.toolBg:SetAllPoints()
            b.toolBg:SetColorTexture(0, 0, 0, 1)
        end
        local hl = b:GetHighlightTexture()
        if hl then hl:SetVertexColor(1, 1, 1, 0.18) end          -- survol = gris leger sur le noir
        b.SetSelected = function(self, on)
            self._selected = on and true or false
            if self.selBorder then self.selBorder:Hide() end     -- jamais de cadre colore
            self.image:SetDesaturated(false)                     -- icone telle quelle (blanche)
            self.image:SetAlpha(self._selected and 1 or 0.5)     -- actif = plein, inactif = attenue
        end
    end

    UI.viewButtons = {}
    local sy = HR.Theme.Value("ZONE_PADDING", SIDE_PAD)

    -- HOME : tout en HAUT de la sidebar, AU-DESSUS du premier donjon. Ouvre la page
    -- d'accueil (viewMode "home", cf. UI/HomePage.lua), separee des donjons par un divider.
    local homeBtn = NavButton({
        image   = HR.Asset("icon-home"),
        size    = NAV_ICON,
        onClick = function() UI.SetViewMode("home") end,
    }, "Homepage")
    homeBtn.mode = "home"
    HR.Assets.ApplyHomeIcon(homeBtn.image)   -- maison du Housing (atlas resolu a l'execution)
    StyleToolButton(homeBtn)
    homeBtn:SetPoint("TOP", UI.sidebar, "TOP", 0, -sy)
    UI.viewButtons[#UI.viewButtons + 1] = homeBtn
    sy = sy + NAV_ICON + NAV_GAP

    local homeDiv = UI.sidebar:CreateTexture(nil, "ARTWORK")
    homeDiv:SetPoint("TOPLEFT", UI.sidebar, "TOPLEFT", 8, -sy)
    homeDiv:SetPoint("TOPRIGHT", UI.sidebar, "TOPRIGHT", -8, -sy)
    homeDiv:SetHeight(1)
    homeDiv:SetColorTexture(HR.Theme.Unpack("SEPARATOR_COLOR"))
    sy = sy + NAV_GAP

    -- Navigation : liste des donjons (boutons-image verticaux dans la sidebar).
    UI.tabs = {}
    for i, dungeon in ipairs(HR.content) do
        local tab = NavButton({
            image   = HR.GetDungeonIcon(dungeon),
            text    = dungeon.abbr or "",
            size    = NAV_ICON,
            onClick = function() SelectDungeon(i) end,
        }, dungeon.name)
        tab:SetPoint("TOP", UI.sidebar, "TOP", 0, -sy)
        UI.tabs[i] = tab
        sy = sy + NAV_ICON + NAV_GAP

        -- Separateur horizontal apres le DERNIER donjon : separe la liste des donjons
        -- des outils (bouton Options). Independant du pool (marche a chaque saison).
        if i == #HR.content then
            local div = UI.sidebar:CreateTexture(nil, "ARTWORK")
            div:SetPoint("TOPLEFT", UI.sidebar, "TOPLEFT", 8, -sy)
            div:SetPoint("TOPRIGHT", UI.sidebar, "TOPRIGHT", -8, -sy)
            div:SetHeight(1)
            div:SetColorTexture(HR.Theme.Unpack("SEPARATOR_COLOR"))
            sy = sy + NAV_GAP
        end
    end

    -- Outils : Options (roue) + FAQ, sous le separateur. Icones custom, SANS texte.
    -- (StyleToolButton et UI.viewButtons sont definis plus haut : le bouton Home, en tete
    -- de sidebar, est le premier a s'en servir.)
    -- Onglet "Defs" (liste des defensifs) ARCHIVE : bouton retire de la barre d'outils
    -- (le code de la vue "deflist" reste mais n'est plus accessible).
    local optBtn = NavButton({
        image   = HR.Asset("icon-wheel"),
        size    = NAV_ICON,                                       -- pas de texte (settings)
        onClick = function() UI.SetViewMode("options") end,       -- icone Blizzard : bordure rognee (crop defaut)
    }, "Options")
    optBtn.mode = "options"
    StyleToolButton(optBtn)
    optBtn:SetPoint("TOP", UI.sidebar, "TOP", 0, -sy)
    UI.viewButtons[#UI.viewButtons + 1] = optBtn
    sy = sy + NAV_ICON + NAV_GAP

    -- Bouton FAQ (icone custom) juste SOUS Options : ouvre une vue dediee (contenu a venir).
    local faqBtn = NavButton({
        image   = HR.Asset("icon-faq"),
        size    = NAV_ICON,
        onClick = function() UI.SetViewMode("faq") end,           -- icone Blizzard : bordure rognee (crop defaut)
    }, "FAQ")
    faqBtn.mode = "faq"
    StyleToolButton(faqBtn)
    faqBtn:SetPoint("TOP", UI.sidebar, "TOP", 0, -sy)
    UI.viewButtons[#UI.viewButtons + 1] = faqBtn

    UI.UpdateViewButtons()      -- etat initial (aucune vue active -> attenues)

    -- Barre de variantes : construite pour sa couche DONNEES (init selHealer +
    -- activeVariant), mais son UI est MASQUEE -> remplacee par le panneau "Healer specs".
    UI.BuildVariantBar(body)
    UI.SetVariantBarShown(false)

    -- Rangee HORIZONTALE de selection (nom du donjon + boss + Trash Info + Settings),
    -- TOUT EN HAUT du panneau.
    UI.bossRow = CreateFrame("Frame", nil, body)
    UI.bossRow:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)        -- flush (bandeau, rejoint la sidebar)
    UI.bossRow:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, 0)
    UI.bossRow:SetHeight(BOSSROW_H)
    UI.bossRow.bg = UI.bossRow:CreateTexture(nil, "BACKGROUND")
    UI.bossRow.bg:SetAllPoints()
    UI.bossRow.bg:SetColorTexture(HR.Theme.Unpack("ZONE_BACKGROUND"))
    UI.bossButtons = {}

    -- Fond commun de la zone Summary + Variantes + Timeline : texture en couche
    -- BACKGROUND de `body`, SOUS la boss bar. Dessinee derriere tout le contenu (les
    -- panneaux/frames et le titre, qui sont au-dessus). Fichier absent => transparent
    -- (le fond du cadre reste visible). Depose Media/content-bg.tga pour l'activer.
    UI.contentBg = body:CreateTexture(nil, "BACKGROUND")
    UI.contentBg:SetPoint("TOPLEFT", UI.bossRow, "BOTTOMLEFT", 0, 0)
    UI.contentBg:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
    body:HookScript("OnSizeChanged", function() UI.LayoutContentBg() end)  -- recadrage cover

    -- Voile sombre PAR-DESSUS la texture (sublevel 1 > 0) mais SOUS le contenu (frames
    -- enfants + titre OVERLAY restent au-dessus) -> assombrit le fond, garde la lisibilite.
    UI.contentDim = body:CreateTexture(nil, "BACKGROUND", nil, 1)
    UI.contentDim:SetPoint("TOPLEFT", UI.bossRow, "BOTTOMLEFT", 0, 0)
    UI.contentDim:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
    -- Degrade vertical (texture blanche teintee par SetGradient) : haut clair -> bas sombre.
    -- VERTICAL => 1er color = BAS, 2e = HAUT. CreateColor inclut l'alpha.
    UI.contentDim:SetColorTexture(1, 1, 1, 1)
    UI.contentDim:SetGradient("VERTICAL",
        CreateColor(HR.Theme.Unpack("CONTENT_DIM_BOTTOM_COLOR")),
        CreateColor(HR.Theme.Unpack("CONTENT_DIM_TOP_COLOR")))

    -- Voile SUPPLEMENTAIRE reserve a la vue Settings (par-dessus contentDim, sublevel 2) :
    -- assombrit davantage le fond bg-1 SANS toucher aux fonds de donjon. Affiche/masque
    -- par UI.UpdateContentBg selon viewMode.
    UI.contentDimSettings = body:CreateTexture(nil, "BACKGROUND", nil, 2)
    UI.contentDimSettings:SetPoint("TOPLEFT", UI.bossRow, "BOTTOMLEFT", 0, 0)
    UI.contentDimSettings:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
    UI.contentDimSettings:SetColorTexture(0, 0, 0, 0.45)
    UI.contentDimSettings:Hide()

    UI.UpdateContentBg()    -- texture selon le donjon courant (par shortname)

    -- Bouton "Configuration" CUSTOM dans la rangee : bascule plan <-> reglages du boss.
    -- Positionne dans RefreshBossList ; visibilite/libelle geres par RefreshRows.
    UI.bossSettingsBtn = UI.Components.TextButton(UI.bossRow, { autoWidth = true, padX = 15, padY = 9, text = "Configuration" })
    UI.bossSettingsBtn:SetOnClick(function()
        UI.viewTrash = false                    -- quitter Trash si on y etait (sinon RefreshRows reste en Trash)
        UI.bossSettings = not UI.bossSettings
        UI.RefreshRows()
    end)
    UI.bossSettingsBtn:Hide()

    -- Section "Composition" (Summary + Variantes) : SOUS la rangee de boss.
    UI.BuildHealerSpecs(body)
    UI.specsPanel:SetPoint("TOPLEFT", UI.bossRow, "BOTTOMLEFT", 12, -16)    -- padding du contenu sous le bandeau
    UI.specsPanel:SetPoint("TOPRIGHT", UI.bossRow, "BOTTOMRIGHT", -12, -16)

    -- Titre du boss + zone scrollable (plan), full-width sous la Composition.
    UI.bossTitle = body:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    UI.bossTitle:SetTextColor(HR.Theme.Unpack("BASE_TEXT_COLOR"))
    UI.bossTitle:SetPoint("TOPLEFT", UI.specsPanel, "BOTTOMLEFT", 4, -8)

    UI.scroll = CreateFrame("ScrollFrame", "HealPlannerConfigScroll", body, "UIPanelScrollFrameTemplate")
    UI.scroll:SetPoint("TOPLEFT", UI.specsPanel, "BOTTOMLEFT", 4, -34)
    UI.scroll:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -34, 16)

    UI.listContent = CreateFrame("Frame", nil, UI.scroll)
    UI.listContent:SetSize(1, 1)
    UI.scroll:SetScrollChild(UI.listContent)

    UI.rows = {}
    UI.phaseSeps = {}
    UI.trashRows = {}
    UI.defListRows = {}

    UI.frame = f
    HR.RestoreFramePos("config", f)     -- restaure la position memorisee
end

-- Ouvre/ferme la modale (cree a la demande).
function UI.Toggle()
    if not UI.frame then
        Build()
    end
    if UI.frame:IsShown() then
        UI.frame:Hide()
    else
        UI.frame:Show()                 -- afficher d'abord pour que le layout calcule les tailles
        HR.ClampToScreen(UI.frame)      -- garde-fou : recadre si position memorisee hors ecran
        -- RESCAN des cles du groupe a CHAQUE ouverture (throttle interne a LibKeystone) : les
        -- chips de l'accueil doivent etre fraiches meme si la fenetre reste ouverte longtemps.
        if HR.Keys and HR.Keys.Request then HR.Keys.Request() end
        -- A l'ouverture, sauter sur le donjon courant (instanceID) si on y est. HORS d'un
        -- donjon connu, aucune selection n'a de sens -> on ouvre la PAGE D'ACCUEIL (le
        -- SelectDungeon reste necessaire pour initialiser l'etat derriere : selBoss, onglets,
        -- liste de boss). SetViewMode("home") est sur ici : SelectDungeon vient de remettre
        -- viewMode a nil, donc l'appel ne peut pas se comporter comme une bascule.
        local index = HR.GetCurrentDungeonIndex()
        SelectDungeon(index or UI.selDungeon or 1)
        if not index then UI.SetViewMode("home") end
        -- Puis scanner le groupe pour activer la variante la plus proche.
        UI.AutoSelectForGroup()
    end
end

-- Ouvre la modale DIRECTEMENT sur la page d'accueil. Jamais une bascule (contrairement a
-- UI.SetViewMode) : un appelant qui demande l'accueil doit toujours l'obtenir.
function UI.ShowHomePage()
    local fresh = not UI.frame
    if fresh then Build() end
    if not UI.frame:IsShown() then
        UI.frame:Show()
        HR.ClampToScreen(UI.frame)
    end
    -- 1re construction : initialiser l'etat derriere (selBoss, onglets, liste de boss) comme
    -- le fait UI.Toggle, sinon la sortie de l'accueil tomberait sur une vue non initialisee.
    if fresh then SelectDungeon(HR.GetCurrentDungeonIndex() or UI.selDungeon or 1) end
    if HR.Keys and HR.Keys.Request then HR.Keys.Request() end   -- rescan des cles a l'ouverture
    if UI.viewMode ~= "home" then UI.SetViewMode("home") else UI.RefreshRows() end
    UI.frame:Raise()
end

-- Ouvre la config sur un donjon precis et AFFICHE une variante (import de plan partage).
-- Aligne l'onglet de heal sur le profil de la variante puis la rend visible (lastSeen).
function UI.ShowDungeonVariant(dID, variant)
    if not UI.frame then Build() end
    if not UI.frame:IsShown() then
        UI.frame:Show()
        HR.ClampToScreen(UI.frame)
    end
    local index
    for i, d in ipairs(HR.content) do if d.id == dID then index = i; break end end
    if index then SelectDungeon(index) end
    if variant then
        -- Onglet de heal du plan importe. Uniquement pour un VRAI profil : une variante sans
        -- heal (HR.NO_HEALER) ne correspond a aucun onglet -> on garde l'onglet courant.
        if HR.GetHealProfile(variant.healer) then UI.selHealer = variant.healer end
        HR.SelectVariant(variant.id, dID)                          -- lastSeen = variante importee
    end
    if UI.RefreshHealerTabs then UI.RefreshHealerTabs() end
    UI.RefreshRows()
    UI.frame:Raise()
end
