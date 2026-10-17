-- EiikoCooldownPlanner - UI/SpellLibrary.lua
-- Section SPELLS (viewMode "spells", bouton de la sidebar) : la bibliotheque de sorts.
--   * a GAUCHE, les sorts NATIFS de la spe choisie -- lecture seule ;
--   * a DROITE, les sorts CUSTOM du joueur pour cette spe -- ajouter / editer / archiver.
-- Plus la modale d'ajout/edition d'un sort custom (UI.OpenCustomSpellEditor), ouverte aussi
-- depuis le `+` de la rangee « Custom spells » de la modale Edit plan (UI/HealerSpecs.lua).
--
-- C'est une section a part entiere, PAS un onglet des Settings : la bibliotheque est une
-- donnee de PLAN (au compte, hors profil d'affichage), cf. Core/CustomSpells.lua.
local addonName, HR = ...

HR.UI = HR.UI or {}
local UI = HR.UI

local PAD       = 12
local SPEC_ICON = 30
local ROW_H     = 34
local ROW_ICON  = 26
local HDR_ROW_H = 26
local SEC_PADX  = 8
local SEC_PADY  = 8
local HDR_H     = 16
local HDR_GAP   = 6
local Y_BODY    = -(HDR_H + HDR_GAP)

-- Etat de la vue (session). `profile` nil => celui du joueur au premier rendu.
local lib = { profile = nil, showArchived = false }

local function fmtCD(cd)
    return HR.FormatCooldown and HR.FormatCooldown(cd) or tostring(cd)
end

local function CS() return HR.CustomSpells end

--------------------------------------------------------------------------------
-- Construction de la section
--------------------------------------------------------------------------------

local function Section(parent, title)
    local C = UI.Components
    local f = C.Container(parent, { padX = SEC_PADX, padY = SEC_PADY,
                                    borderColor = HR.Theme.Color("SECTION_BORDER_COLOR") })
    f.hdr = f.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.hdr:SetPoint("TOPLEFT", 0, 0)
    f.hdr:SetText(title)
    f.hdr:SetTextColor(1, 1, 1)
    f.scroll = CreateFrame("ScrollFrame", nil, f.content, "UIPanelScrollFrameTemplate")
    f.scroll:SetPoint("TOPLEFT", 0, Y_BODY)
    f.scroll:SetPoint("BOTTOMRIGHT", -22, 0)
    f.list = CreateFrame("Frame", nil, f.scroll)
    f.list:SetSize(1, 1)
    f.scroll:SetScrollChild(f.list)
    f.scroll:SetScript("OnSizeChanged", function(_, w) if w and w > 0 then f.list:SetWidth(w) end end)
    f.rows, f.hdrs = {}, {}
    f.empty = f.content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    f.empty:SetPoint("TOPLEFT", f.scroll, "TOPLEFT", 4, -8)
    f.empty:SetPoint("RIGHT", f.scroll, "RIGHT", -4, 0)
    f.empty:SetJustifyH("LEFT")
    f.empty:Hide()
    return f
end

local function SpecButton(bar, i)
    local b = bar.specBtns[i]
    if b then return b end
    b = CreateFrame("Button", nil, bar)
    b:SetSize(SPEC_ICON, SPEC_ICON)
    b.icon = b:CreateTexture(nil, "ARTWORK"); b.icon:SetAllPoints()
    b.sel = b:CreateTexture(nil, "BACKGROUND")
    b.sel:SetPoint("TOPLEFT", -2, 2); b.sel:SetPoint("BOTTOMRIGHT", 2, -2)
    b.sel:SetColorTexture(HR.Theme.Unpack("IMAGE_BUTTON_BORDER_COLOR"))
    b.sel:Hide()
    b:SetHighlightTexture("Interface\\Buttons\\WHITE8x8", "ADD")
    local hl = b:GetHighlightTexture(); if hl then hl:SetVertexColor(1, 1, 1, 0.18) end
    b:SetScript("OnEnter", function(self)
        if not self._prof then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(self._prof.name or self._prof.key)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    bar.specBtns[i] = b
    return b
end

local function BuildPanel()
    if UI.spellLibPanel then return end
    local C = UI.Components

    -- Barre haute, calquee sur celle du Catalogue / des Settings.
    local bar = CreateFrame("Frame", nil, UI.body)
    bar:SetPoint("TOPLEFT", 0, 0); bar:SetPoint("TOPRIGHT", 0, 0)
    bar:SetHeight(61)
    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    bar.bg:SetColorTexture(HR.Theme.Unpack("ZONE_BACKGROUND"))
    bar.title = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    bar.title:SetPoint("LEFT", 16, 0)
    bar.title:SetText("Spells")
    bar.title:SetTextColor(1, 1, 1)
    bar.specBtns = {}
    bar.add = C.TextButton(bar, { text = "+ Add spell", autoWidth = true, padX = 15, padY = 9 })
    bar.add:SetPoint("RIGHT", bar, "RIGHT", -16, 0)
    bar.add:SetOnClick(function()
        UI.OpenCustomSpellEditor({ profile = lib.profile, onSaved = function() UI.RefreshSpellLibrary() end })
    end)
    bar:Hide()
    UI.spellLibBar = bar

    local p = CreateFrame("Frame", nil, UI.body)
    p:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, 0)
    p:SetPoint("BOTTOMRIGHT", UI.body, "BOTTOMRIGHT", 0, 0)
    p:Hide()
    UI.spellLibPanel = p

    p.info = C.InfoBox(p, { text = "Add the spells the addon doesn't know, with YOUR cooldown "
        .. "(a talent shortens it? set the real value). A custom spell belongs to one healer spec "
        .. "and shows up in that spec's plans, where it can be disabled per variant. You choose, per "
        .. "spell, whether it goes with your plan when you Sync it: share it only if your group needs "
        .. "to know you will use it. Export always includes every spell." })
    p.info:SetPoint("TOPLEFT", PAD, -PAD); p.info:SetPoint("TOPRIGHT", -PAD, -PAD)
    p:SetScript("OnSizeChanged", function(_, w) if w and w > 0 then p.info:Relayout(w - PAD * 2) end end)

    p.native = Section(p, "Native spells (read-only)")
    p.custom = Section(p, "My custom spells")
    p.native:SetPoint("TOPLEFT", p.info, "BOTTOMLEFT", 0, -PAD)
    p.native:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", PAD, PAD)
    p.native:SetPoint("RIGHT", p, "CENTER", -PAD / 2, 0)
    p.custom:SetPoint("TOPRIGHT", p.info, "BOTTOMRIGHT", 0, -PAD)
    p.custom:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -PAD, PAD)
    p.custom:SetPoint("LEFT", p, "CENTER", PAD / 2, 0)

    -- « Show archived » : dans l'en-tete de la colonne custom, a droite.
    local chk = CreateFrame("CheckButton", nil, p.custom.content, "UICheckButtonTemplate")
    chk:SetSize(22, 22)
    chk:SetPoint("TOPRIGHT", p.custom.content, "TOPRIGHT", -110, 4)
    chk.text = chk:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    chk.text:SetPoint("LEFT", chk, "RIGHT", 2, 0)
    chk.text:SetText("Show archived"); chk.text:SetTextColor(1, 1, 1)
    chk:SetScript("OnClick", function(self)
        lib.showArchived = self:GetChecked() and true or false
        UI.RenderSpellLibrary()
    end)
    C.AttachHelpTip(chk, "Show archived",
        "Archived spells are no longer offered in the library or the plan editor, but they stay "
        .. "in the plans where they are already placed. You can restore them from here.")
    p.archChk = chk
end

--------------------------------------------------------------------------------
-- Lignes
--------------------------------------------------------------------------------

local function HeaderRow(sec, i)
    local h = sec.hdrs[i]
    if h then return h end
    h = sec.list:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h:SetTextColor(1, 0.82, 0)
    h:SetJustifyH("LEFT")
    sec.hdrs[i] = h
    return h
end

local function SpellRow(sec, i)
    local r = sec.rows[i]
    if r then return r end
    local C = UI.Components
    r = CreateFrame("Frame", nil, sec.list)
    r:SetHeight(ROW_H)
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints(); r.bg:SetColorTexture(1, 1, 1, 0.03)
    r.iconBtn = CreateFrame("Button", nil, r)
    r.iconBtn:SetSize(ROW_ICON, ROW_ICON)
    r.iconBtn:SetPoint("LEFT", 4, 0)
    r.icon = r.iconBtn:CreateTexture(nil, "ARTWORK"); r.icon:SetAllPoints()
    r.iconBtn:SetScript("OnEnter", function(self)
        local d = r._key and HR.defensives[r._key]
        if not d then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if d.itemId then GameTooltip:SetItemByID(d.itemId)
        else GameTooltip:SetSpellByID(HR.GetDefensiveSpellID(r._key)) end
        GameTooltip:AddLine(("Cooldown used by the addon: %s%s"):format(fmtCD(d.cooldown),
            (d.charges and d.charges > 1) and (" (" .. d.charges .. " charges)") or ""), 0.6, 0.9, 1, true)
        GameTooltip:Show()
    end)
    r.iconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.name:SetPoint("TOPLEFT", r.iconBtn, "TOPRIGHT", 8, 0)
    r.name:SetJustifyH("LEFT")
    r.sub = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    r.sub:SetPoint("BOTTOMLEFT", r.iconBtn, "BOTTOMRIGHT", 8, 0)
    r.sub:SetJustifyH("LEFT")
    r.cd = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    r.cd:SetJustifyH("RIGHT")
    r.arch = C.TextButton(r, { text = "Archive", width = 76, height = 22 })
    r.arch:SetPoint("RIGHT", -4, 0)
    r.edit = C.TextButton(r, { text = "Edit", width = 56, height = 22 })
    r.edit:SetPoint("RIGHT", r.arch, "LEFT", -6, 0)
    -- MODE DEV seulement (RenderCustom) : suppression definitive, apres confirmation.
    r.del = C.TextButton(r, { text = "Delete", width = 62, height = 22 })
    r.del:SetPoint("RIGHT", r.edit, "LEFT", -6, 0)
    r.del:Hide()
    sec.rows[i] = r
    return r
end

--------------------------------------------------------------------------------
-- Rendu
--------------------------------------------------------------------------------

-- Liste plate a afficher : { hdr = "..." } | { key = defKey }.
local function NativeItems(profile)
    local out = {}
    local spells = HR.GetHealerTalentSpells(profile)
    if #spells > 0 then
        out[#out + 1] = { hdr = "Healer cooldowns" }
        for _, sp in ipairs(spells) do
            for _, key in ipairs(sp.variants) do out[#out + 1] = { key = key } end
        end
    end
    local generic = {}
    for _, k in ipairs({ "RAMP", "SMALL_DEF", "EMPTY_BAG" }) do
        if HR.defensives[k] then generic[#generic + 1] = { key = k } end
    end
    if #generic > 0 then
        out[#out + 1] = { hdr = "Generic calls" }
        for _, it in ipairs(generic) do out[#out + 1] = it end
    end
    local ext = HR.GetExternals()
    if #ext > 0 then
        out[#out + 1] = { hdr = "Group externals (any spec)" }
        for _, e in ipairs(ext) do out[#out + 1] = { key = e.key } end
    end
    return out
end

local function RenderNative(sec, profile)
    for _, r in ipairs(sec.rows) do r:Hide() end
    for _, h in ipairs(sec.hdrs) do h:Hide() end
    local y, ri, hi = 0, 0, 0
    for _, it in ipairs(NativeItems(profile)) do
        if it.hdr then
            hi = hi + 1
            local h = HeaderRow(sec, hi)
            h:ClearAllPoints(); h:SetPoint("TOPLEFT", 4, -(y + 8)); h:SetText(it.hdr); h:Show()
            y = y + HDR_ROW_H
        else
            local d = HR.defensives[it.key]
            ri = ri + 1
            local r = SpellRow(sec, ri)
            r._key = it.key
            r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, -y); r:SetPoint("RIGHT", sec.list, "RIGHT", 0, 0)
            r.icon:SetTexture(HR.GetDefensiveIcon(it.key)); r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            r.icon:SetDesaturated(false)
            r.name:SetText(d and d.name or tostring(it.key)); r.name:SetTextColor(1, 1, 1)
            r.name:ClearAllPoints(); r.name:SetPoint("LEFT", r.iconBtn, "RIGHT", 8, 0)
            r.name:SetPoint("RIGHT", r, "RIGHT", -70, 0)
            r.sub:SetText("")
            r.cd:ClearAllPoints(); r.cd:SetPoint("RIGHT", -10, 0)
            r.cd:SetText((d and d.cooldown and d.cooldown > 0) and fmtCD(d.cooldown) or "")
            r.edit:Hide(); r.arch:Hide(); r.del:Hide()
            r:Show()
            y = y + ROW_H + 2
        end
    end
    sec.list:SetHeight(math.max(1, y))
    sec.empty:SetShown(ri == 0)
    sec.empty:SetText("No native spell for this spec.")
end

local function RenderCustom(sec, profile)
    for _, r in ipairs(sec.rows) do r:Hide() end
    local items = CS().List(profile, lib.showArchived)
    local dev = HR.IsDevMode and HR.IsDevMode()
    local textRight = dev and -278 or -210            -- place des boutons (+ Delete en mode dev)
    local y = 0
    for i, it in ipairs(items) do
        local key, e = it.key, it.entry
        local r = SpellRow(sec, i)
        r._key = key
        r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, -y); r:SetPoint("RIGHT", sec.list, "RIGHT", 0, 0)
        r.icon:SetTexture(HR.GetDefensiveIcon(key)); r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        r.icon:SetDesaturated(e.archived and true or false)
        r.name:ClearAllPoints(); r.name:SetPoint("TOPLEFT", r.iconBtn, "TOPRIGHT", 8, 0)
        r.name:SetPoint("RIGHT", r, "RIGHT", textRight, 0)
        r.name:SetText((e.name or "?") .. (e.archived and "  |cff808080(archived)|r" or ""))
        if e.archived then r.name:SetTextColor(0.6, 0.6, 0.6) else r.name:SetTextColor(1, 1, 1) end
        local used = CS().UsageCount(key)
        r.sub:SetPoint("RIGHT", r, "RIGHT", textRight, 0) -- borne : sinon passe sous le CD/boutons
        r.sub:SetWordWrap(false)
        r.sub:SetText(("#%d  -  %s  -  %s"):format(e.spellID or 0,
            e.shared and "|cff33dd66shared|r" or "private",
            used == 0 and "unused" or ("in %d plan%s"):format(used, used > 1 and "s" or "")))
        r.cd:ClearAllPoints(); r.cd:SetPoint("RIGHT", dev and r.del or r.edit, "LEFT", -12, 0)
        r.cd:SetText(fmtCD(e.cooldown) .. ((e.charges and e.charges > 1) and (" x" .. e.charges) or ""))
        r.edit:Show(); r.arch:Show()
        r.edit:SetOnClick(function()
            UI.OpenCustomSpellEditor({ key = key, onSaved = function() UI.RefreshSpellLibrary() end })
        end)
        r.arch:SetText(e.archived and "Restore" or "Archive")
        r.arch:SetOnClick(function()
            CS().SetArchived(key, not e.archived)
            UI.RenderSpellLibrary()
        end)
        r.del:SetShown(dev and true or false)
        r.del:SetOnClick(function() UI.ConfirmDeleteCustomSpell(key) end)
        r:Show()
        y = y + ROW_H + 2
    end
    sec.list:SetHeight(math.max(1, y))
    sec.empty:SetShown(#items == 0)
    if #items == 0 then
        local prof = HR.GetHealProfile(profile)
        sec.empty:SetText(("No custom spell for %s yet. Click \"+ Add spell\" to add one.")
            :format(prof and prof.name or "this spec"))
    end
end

function UI.RenderSpellLibrary()
    BuildPanel()
    local bar, p = UI.spellLibBar, UI.spellLibPanel
    bar:Show(); p:Show()

    if not (lib.profile and HR.GetHealProfile(lib.profile)) then
        local mine = HR.MyHealKey and HR.MyHealKey()
        lib.profile = (mine and HR.GetHealProfile(mine)) and mine or HR.HEAL_PROFILES[1].key
    end

    -- Rangee de spes, apres le titre.
    local x = 16 + bar.title:GetStringWidth() + 24
    for i, prof in ipairs(HR.HEAL_PROFILES) do
        local b = SpecButton(bar, i)
        b._prof = prof
        b:ClearAllPoints(); b:SetPoint("LEFT", bar, "LEFT", x, 0)
        HR.Icons.Apply(b.icon, "healer", prof)
        b.sel:SetShown(lib.profile == prof.key)
        b:SetScript("OnClick", function() lib.profile = prof.key; UI.RenderSpellLibrary() end)
        b:Show()
        x = x + SPEC_ICON + 8
    end

    p.archChk:SetChecked(lib.showArchived)
    p.info:Relayout((p:GetWidth() or 0) - PAD * 2)
    local prof = HR.GetHealProfile(lib.profile)
    p.native.hdr:SetText(("Native spells - %s (read-only)"):format(prof and prof.name or "?"))
    p.custom.hdr:SetText(("My custom spells - %s"):format(prof and prof.name or "?"))
    RenderNative(p.native, lib.profile)
    RenderCustom(p.custom, lib.profile)
end

-- Re-rendu si la section est affichee (apres une sauvegarde depuis la modale).
function UI.RefreshSpellLibrary()
    if UI.spellLibPanel and UI.spellLibPanel:IsVisible() then UI.RenderSpellLibrary() end
end

function UI.HideSpellLibrary()
    if UI.spellLibBar then UI.spellLibBar:Hide() end
    if UI.spellLibPanel then UI.spellLibPanel:Hide() end
end

--------------------------------------------------------------------------------
-- Modale d'ajout / edition d'un sort custom
--------------------------------------------------------------------------------

local ED_W, ED_H = 470, 690

local function NumberBox(parent, w)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(w, 24); e:SetAutoFocus(false); e:SetNumeric(true)
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return e
end

-- Echap ferme CETTE modale seulement. Surtout PAS UISpecialFrames : nos modales s'ouvrent
-- par-dessus la modale Edit plan et la fenetre principale, qui y sont aussi -> un Echap les
-- fermait toutes (et le brouillon de variante etait perdu). On mange la touche Echap, on laisse
-- passer le reste. SetPropagateKeyboardInput est protege en combat : la on laisse passer.
local function EscapeClosesOnlyMe(m)
    m:EnableKeyboard(true)
    m:SetPropagateKeyboardInput(true)
    m:SetScript("OnKeyDown", function(self, key)
        if InCombatLockdown() then return end
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            self:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)
end

local function BuildEditor()
    local C = UI.Components
    local m = C.Window(UIParent, {
        name = "ECPCustomSpellModal", title = "Add custom spell", width = ED_W, height = ED_H,
    })
    m:SetFrameStrata("FULLSCREEN_DIALOG"); m:SetToplevel(true)
    m:SetFrameLevel(50)
    EscapeClosesOnlyMe(m)
    local c = m.content

    local function Label(text, y)
        local fs = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("TOPLEFT", 16, y); fs:SetText(text); fs:SetTextColor(1, 1, 1)
        return fs
    end

    -- 1. spellID
    Label("Spell ID", -14)
    m.idBox = NumberBox(c, 120)
    m.idBox:SetPoint("TOPLEFT", 22, -34)
    m.idBox:SetMaxLetters(8)
    m.idBox:SetScript("OnTextChanged", function(self, userInput)
        if userInput then UI.CustomSpellEditorLookup() end
    end)
    m.idHint = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    m.idHint:SetPoint("LEFT", m.idBox, "RIGHT", 10, 0)
    m.idHint:SetText("Find it on Wowhead (the number in the spell URL).")

    -- 2. apercu du sort
    m.prev = C.Container(c, { padX = 10, padY = 10 })
    m.prev:SetPoint("TOPLEFT", 16, -68); m.prev:SetPoint("TOPRIGHT", -16, -68)
    m.prev:SetHeight(68)
    m.prevIconBtn = CreateFrame("Button", nil, m.prev)
    m.prevIconBtn:SetSize(46, 46); m.prevIconBtn:SetPoint("LEFT", 11, 0)
    m.prevIcon = m.prevIconBtn:CreateTexture(nil, "ARTWORK"); m.prevIcon:SetAllPoints()
    m.prevIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    m.prevIconBtn:SetScript("OnEnter", function(self)
        if not m.info then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetSpellByID(m.info.spellID); GameTooltip:Show()
    end)
    m.prevIconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    m.prevName = m.prev:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    m.prevName:SetPoint("TOPLEFT", m.prevIconBtn, "TOPRIGHT", 12, -4)
    m.prevName:SetPoint("RIGHT", m.prev, "RIGHT", -10, 0)
    m.prevName:SetJustifyH("LEFT")
    m.prevSub = m.prev:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    m.prevSub:SetPoint("BOTTOMLEFT", m.prevIconBtn, "BOTTOMRIGHT", 12, 4)
    m.prevSub:SetJustifyH("LEFT")

    -- 3. spe
    Label("Healer spec", -152)
    m.specBtns = {}
    for i, prof in ipairs(HR.HEAL_PROFILES) do
        local b = C.ImageButton(c, { size = 30 })
        b:SetPoint("TOPLEFT", 16 + (i - 1) * 38, -174)
        HR.Icons.Apply(b.image, "healer", prof)
        b._prof = prof
        b:SetOnClick(function()
            if m.specLocked then return end
            m.profile = prof.key
            UI.CustomSpellEditorRefresh()
        end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(prof.name)
            if m.specLocked and m.specLockReason then GameTooltip:AddLine(m.specLockReason, 1, 0.5, 0.5, true) end
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        m.specBtns[i] = b
    end
    m.specNote = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    m.specNote:SetPoint("TOPLEFT", 16, -210)
    m.specNote:SetPoint("RIGHT", c, "RIGHT", -16, 0)
    m.specNote:SetJustifyH("LEFT")

    -- 4. cooldown + charges
    Label("Cooldown (seconds)", -236)
    m.cdBox = NumberBox(c, 80)
    m.cdBox:SetPoint("TOPLEFT", 22, -256)
    m.cdBox:SetMaxLetters(4)
    m.cdBox:SetScript("OnTextChanged", function() UI.CustomSpellEditorRefresh() end)
    m.cdFmt = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    m.cdFmt:SetPoint("LEFT", m.cdBox, "RIGHT", 8, 0)

    local chLbl = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    chLbl:SetPoint("TOPLEFT", 240, -236); chLbl:SetText("Charges"); chLbl:SetTextColor(1, 1, 1)
    m.chBox = NumberBox(c, 40)
    m.chBox:SetPoint("TOPLEFT", 246, -256)
    m.chBox:SetMaxLetters(1)
    m.chBox:SetScript("OnTextChanged", function() UI.CustomSpellEditorRefresh() end)

    m.cdNote = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    m.cdNote:SetPoint("TOPLEFT", 16, -288)
    m.cdNote:SetPoint("RIGHT", c, "RIGHT", -16, 0)
    m.cdNote:SetJustifyH("LEFT")

    -- 5. partage avec le groupe (non par defaut) -- cf. Core/CustomSpells.lua, PARTAGE.
    -- ENCADRE a part : c'est la seule decision qui engage les AUTRES joueurs, elle ne doit pas
    -- se lire comme un reglage de plus. L'aide est une FAQ (question -> Yes if / No if) ; la
    -- hauteur du cadre suit le texte (UI.CustomSpellEditorRefresh).
    local box = C.Container(c, { content = false, borderColor = HR.Theme.Color("SECTION_BORDER_COLOR") })
    box:SetPoint("TOPLEFT", 16, -312); box:SetPoint("TOPRIGHT", -16, -312)
    m.shareBox = box
    m.shareChk = CreateFrame("CheckButton", nil, box, "UICheckButtonTemplate")
    m.shareChk:SetSize(24, 24)
    m.shareChk:SetPoint("TOPLEFT", 8, -8)
    m.shareChk.text = m.shareChk:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    m.shareChk.text:SetPoint("LEFT", m.shareChk, "RIGHT", 2, 0)
    m.shareChk.text:SetText("Share with my group"); m.shareChk.text:SetTextColor(1, 1, 1)
    local function Para(font)
        local fs = box:CreateFontString(nil, "OVERLAY", font)
        fs:SetJustifyH("LEFT"); fs:SetJustifyV("TOP"); fs:SetWordWrap(true)
        return fs
    end
    m.shareQ = Para("GameFontNormal")
    m.shareQ:SetPoint("TOPLEFT", 14, -42)
    m.shareQ:SetText("Should I check this box?")
    m.shareYes = Para("GameFontHighlightSmall")
    m.shareYes:SetPoint("TOPLEFT", m.shareQ, "BOTTOMLEFT", 0, -6)
    m.shareYes:SetText("|cff33dd66Yes|r if your group needs to know you will use this spell, and "
        .. "will play differently because of it. It goes with your plan when you Sync it, and shows "
        .. "on their timeline.")
    m.shareNo = Para("GameFontHighlightSmall")
    m.shareNo:SetPoint("TOPLEFT", m.shareYes, "BOTTOMLEFT", 0, -6)
    m.shareNo:SetText("|cffff6060No|r if it only matters to you. Your Syncs leave it out: your "
        .. "group never sees it.")
    -- L'Export emporte TOUT, coche ou non (Core/Share.lua) : on le dit, sinon le joueur croit
    -- qu'un sort decoche ne sort jamais de chez lui.
    m.shareExport = Para("GameFontDisableSmall")
    m.shareExport:SetPoint("TOPLEFT", m.shareNo, "BOTTOMLEFT", 0, -6)
    m.shareExport:SetText("Export always includes it, either way: an export is meant for another "
        .. "healer of your spec.")
    m.shareNote = Para("GameFontDisableSmall")
    m.shareNote:SetPoint("TOPLEFT", m.shareExport, "BOTTOMLEFT", 0, -6)
    m.shareNote:SetText("Changing this applies from your next Sync.")

    -- 6. avertissements (non bloquants) / erreurs
    m.warn = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    m.warn:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -10)
    m.warn:SetPoint("RIGHT", c, "RIGHT", -16, 0)
    m.warn:SetJustifyH("LEFT"); m.warn:SetJustifyV("TOP")
    m.warn:SetTextColor(1, 0.82, 0)

    m.save = C.TextButton(c, { text = "Save", width = 110, onClick = function() UI.SubmitCustomSpell() end })
    m.save:SetPoint("BOTTOMRIGHT", -16, 16)
    local cancel = C.TextButton(c, { text = "Cancel", width = 110, onClick = function() m:Hide() end })
    cancel:SetPoint("RIGHT", m.save, "LEFT", -8, 0)

    m:Hide()
    UI.customSpellModal = m
end

-- Recalcule l'etat affiche (apercu, spe, CD, avertissements, bouton Save). Ne lit que `m`.
function UI.CustomSpellEditorRefresh()
    local m = UI.customSpellModal; if not m then return end
    local info = m.info

    if m.lookupState == "loading" then
        m.prevIcon:SetTexture(134400); m.prevName:SetText("Loading...")
        m.prevSub:SetText("")
    elseif not info then
        m.prevIcon:SetTexture(134400)
        m.prevName:SetText(m.lookupState == "unknown" and "|cffff6060Unknown spell ID|r" or "|cff808080Enter a spell ID|r")
        m.prevSub:SetText("")
    else
        m.prevIcon:SetTexture(info.icon or 134400)
        m.prevName:SetText(info.name or "?")
        m.prevSub:SetText(("Spell %d  -  base cooldown: %s"):format(info.spellID,
            (info.baseCooldown or 0) > 0 and fmtCD(info.baseCooldown) or "unknown"))
    end

    for _, b in ipairs(m.specBtns) do
        b:SetSelected(m.profile == b._prof.key)
        b.image:SetDesaturated(m.specLocked and m.profile ~= b._prof.key or false)
    end
    m.specNote:SetText(m.specLocked and (m.specLockReason or "") or
        "The spell will only be offered in plans of this healer spec.")

    local cd = tonumber(m.cdBox:GetText() or "")
    local cs = HR.CustomSpells
    local cdOk = cd and cd >= cs.MIN_COOLDOWN and cd <= cs.MAX_COOLDOWN
    m.cdFmt:SetText(cdOk and ("= " .. fmtCD(cd)) or "|cffff6060min 1 s, max 3600 s|r")
    local ch = tonumber(m.chBox:GetText() or "")
    local chOk = ch == nil or (ch >= 1 and ch <= cs.MAX_CHARGES)
    m.cdNote:SetText(m.editKey and "Changing the cooldown updates every plan that uses this spell."
        or "Set the cooldown you really have (talents included): the addon cannot read it.")

    -- Encadre de partage : largeur de texte FIXEE (GetStringHeight fiable), hauteur = contenu.
    local tw = (m.shareBox:GetWidth() or 0) - 28
    if tw < 100 then tw = ED_W - 32 - 28 end
    local h = 42
    for _, fs in ipairs({ m.shareQ, m.shareYes, m.shareNo, m.shareExport }) do
        fs:SetWidth(tw); h = h + fs:GetStringHeight() + 6
    end
    m.shareNote:SetWidth(tw)
    m.shareNote:SetShown(m.editKey ~= nil)
    if m.editKey then h = h + m.shareNote:GetStringHeight() + 6 end
    m.shareBox:SetHeight(h + 6)

    -- Avertissements : on informe, on ne bloque pas.
    local w = {}
    if info then
        if info.passive then w[#w + 1] = "This is a passive spell: it cannot be cast." end
        if not info.known then w[#w + 1] = "This character does not know this spell (fine if it's for another character)." end
        for _, t in ipairs(HR.CustomSpells.NativeTwins(info.spellID, m.profile)) do
            w[#w + 1] = ("The addon already knows %s (%s). This custom spell will use your own cooldown.")
                :format(t.name, fmtCD(t.cooldown))
            break
        end
    end
    if not chOk then w[#w + 1] = ("|cffff6060Charges: 1 to %d.|r"):format(cs.MAX_CHARGES) end
    m.warn:SetText(table.concat(w, "\n"))

    local ok = info and m.profile and HR.GetHealProfile(m.profile) and cdOk and chOk
    m.save:SetEnabled(ok and true or false); m.save:SetAlpha(ok and 1 or 0.4)
end

-- Lecture du sort saisi. Asynchrone : `seq` ecarte une reponse arrivee apres une nouvelle saisie.
function UI.CustomSpellEditorLookup()
    local m = UI.customSpellModal; if not m then return end
    m.seq = (m.seq or 0) + 1
    local seq = m.seq
    local id = tonumber(m.idBox:GetText() or "")
    m.info = nil
    if not id then m.lookupState = nil; UI.CustomSpellEditorRefresh(); return end
    m.lookupState = "loading"
    UI.CustomSpellEditorRefresh()
    HR.CustomSpells.LookupSpell(id, function(info)
        if m.seq ~= seq or not m:IsShown() then return end
        m.info = info
        m.lookupState = info and "ok" or "unknown"
        -- Prerempli le CD (et les charges) a la PREMIERE resolution, jamais par-dessus une saisie.
        if info and not m.editKey and not m.cdTouched then
            if (info.baseCooldown or 0) > 0 then m.cdBox:SetText(tostring(info.baseCooldown)) end
            m.chBox:SetText(tostring(info.charges or 1))
        end
        UI.CustomSpellEditorRefresh()
    end)
end

-- opts = { key = <cle custom a editer> | nil, profile = <cle de profil>, lockProfile = bool,
--          onSaved = function(key) }
function UI.OpenCustomSpellEditor(opts)
    opts = opts or {}
    if not UI.customSpellModal then BuildEditor() end
    local m = UI.customSpellModal
    m.onSaved = opts.onSaved
    m.editKey = opts.key
    m.info, m.lookupState, m.cdTouched = nil, nil, false
    m.specLocked, m.specLockReason = false, nil

    if m.editKey then
        local e = HR.CustomSpells.Get(m.editKey)
        if not e then return end
        m:SetTitle("Edit custom spell")
        m.profile = e.profile
        m.idBox:SetText(tostring(e.spellID)); m.idBox:Disable()
        m.idHint:SetText("To use another spell, add a new one.")
        m.cdBox:SetText(tostring(e.cooldown)); m.chBox:SetText(tostring(e.charges or 1))
        m.shareChk:SetChecked(e.shared and true or false)
        -- Apercu depuis la bibliotheque (fonctionne meme si le client n'a pas le sort en cache),
        -- puis lecture du client pour la duree de base et les avertissements.
        m.info = { spellID = e.spellID, name = e.name, icon = e.icon, baseCooldown = 0, charges = 1, known = true }
        m.lookupState = "ok"
        local used = HR.CustomSpells.UsageCount(m.editKey)
        if used > 0 then
            m.specLocked = true
            m.specLockReason = ("Spec locked: this spell is placed in %d plan%s. To use it for another spec, add it again.")
                :format(used, used > 1 and "s" or "")
        end
        local key = m.editKey
        HR.CustomSpells.LookupSpell(e.spellID, function(info)
            if m.editKey ~= key or not m:IsShown() or not info then return end
            m.info = info
            UI.CustomSpellEditorRefresh()
        end)
    else
        m:SetTitle("Add custom spell")
        local prof = opts.profile and HR.GetHealProfile(opts.profile) and opts.profile
        if not prof then
            local mine = HR.MyHealKey and HR.MyHealKey()
            prof = (mine and HR.GetHealProfile(mine)) and mine or nil
        end
        m.profile = prof
        if opts.lockProfile and prof then
            m.specLocked = true
            m.specLockReason = "Spec of the variant you are editing."
        end
        m.idBox:Enable(); m.idBox:SetText("")
        m.idHint:SetText("Find it on Wowhead (the number in the spell URL).")
        m.cdBox:SetText(""); m.chBox:SetText("1")
        m.shareChk:SetChecked(false)          -- non partage par defaut : le joueur choisit
    end
    -- Le CD saisi a la main n'est plus ecrase par une resolution tardive.
    m.cdBox:SetScript("OnEditFocusGained", function() m.cdTouched = true end)

    UI.CustomSpellEditorRefresh()
    m:Show(); m:Raise()
    if not m.editKey then m.idBox:SetFocus() end
end

function UI.SubmitCustomSpell()
    local m = UI.customSpellModal; if not m then return end
    local cs = HR.CustomSpells
    local data = {
        cooldown = tonumber(m.cdBox:GetText() or ""),
        charges  = tonumber(m.chBox:GetText() or "") or 1,
        profile  = m.profile,
        shared   = m.shareChk:GetChecked() and true or false,
    }
    local key, why
    if m.editKey then
        key, why = cs.Update(m.editKey, data)
    else
        if not m.info then return end
        data.spellID, data.name, data.icon = m.info.spellID, m.info.name, m.info.icon
        key, why = cs.Create(data)
    end
    if not key then HR:Print(("Could not save the spell (%s)."):format(why or "?")); return end
    HR:Print(("Custom spell \"%s\" %s."):format(HR.EscapeMarkup and HR.EscapeMarkup(HR.defensives[key].name) or HR.defensives[key].name,
        m.editKey and "updated" or "added"))
    m:Hide()
    if m.onSaved then m.onSaved(key) end
    if UI.RefreshRows then UI.RefreshRows() end
end

--------------------------------------------------------------------------------
-- Suppression DEFINITIVE d'un sort custom -- MODE DEV (HR.IsDevMode)
--------------------------------------------------------------------------------

-- Modale MAISON (pas de StaticPopup) : la decision ecrit dans les plans du joueur. Elle annonce
-- le nombre de placements retires avant qu'on clique.
function UI.ConfirmDeleteCustomSpell(key)
    if not (HR.IsDevMode and HR.IsDevMode()) then return end
    local e = CS().Get(key); if not e then return end
    local m = UI.customSpellDelete
    if not m then
        local C = UI.Components
        m = C.Window(UIParent, { name = "ECPCustomSpellDelete", title = "Delete custom spell",
            width = 400, height = 200, bgTexture = C.ModalBackgroundTexture() })
        C.ModalBackground(m)
        m:SetFrameStrata("FULLSCREEN_DIALOG"); m:SetToplevel(true); m:SetFrameLevel(60)
        EscapeClosesOnlyMe(m)
        local c = m.content
        m.msg = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        m.msg:SetPoint("TOPLEFT", 16, -16); m.msg:SetPoint("RIGHT", c, "RIGHT", -16, 0)
        m.msg:SetJustifyH("LEFT"); m.msg:SetJustifyV("TOP"); m.msg:SetSpacing(3)
        m.yes = C.TextButton(c, { text = "Delete", width = 110, onClick = function()
            local n = CS().Delete(m._key)
            m:Hide()
            if n == nil then HR:Print("Could not delete the spell (dev mode off?)."); return end
            HR:Print(("Custom spell deleted (%d placement%s removed)."):format(n, n == 1 and "" or "s"))
            UI.RenderSpellLibrary()
            if UI.RefreshRows then UI.RefreshRows() end
        end })
        m.yes:SetPoint("BOTTOMRIGHT", -16, 16)
        local no = C.TextButton(c, { text = "Cancel", width = 110, onClick = function() m:Hide() end })
        no:SetPoint("RIGHT", m.yes, "LEFT", -8, 0)
        m:Hide()
        UI.customSpellDelete = m
    end
    m._key = key
    local n = CS().PlacementCount(key)
    m.msg:SetText(("|cffff6060Dev mode.|r Delete \"%s\" for good?\n\n%s\nThis cannot be undone.")
        :format(e.name or "?", n == 0 and "It is not placed in any plan."
            or ("Its %d placement%s will be removed from your plans."):format(n, n == 1 and "" or "s")))
    m:Show(); m:Raise()
end
