-- HealPlanner - UI/VariantBar.lua
-- Barre de variantes (sous les onglets) + modale de creation.
--   - Selecteur de classe heal (icones) : filtre le dropdown sur ce heal.
--   - Dropdown natif : variante par defaut du heal + variantes utilisateur de ce heal.
--   - Actions : Nouvelle / Dupliquer / Renommer / Supprimer / Utiliser (runtime ★).
-- Etat partage : UI.activeVariant (variante editee), UI.activeDungeonID, UI.selHealer.
local addonName, HR = ...

HR.UI = HR.UI or {}
local UI = HR.UI

-- Met a jour la surbrillance des onglets de heal selon UI.selHealer.
function UI.RefreshHealerTabs()
    for _, t in ipairs(UI.healerTabs or {}) do
        local active = (t.healer == UI.selHealer)
        t.border:SetShown(active)
        t.icon:SetDesaturated(not active)
        t.icon:SetAlpha(active and 1 or 0.5)
    end
end

-- Change le PROFIL de heal selectionne (clef : token de classe ou PRIEST_*) :
-- recharge les variantes correspondantes.
function UI.SelectHealer(key)
    UI.selHealer = key
    UI.RefreshHealerTabs()
    UI.OnDungeonSelected(UI.activeDungeonID)
    UI.RefreshRows()
end

-- Chaine d'icones de la compo (5 slots) : classe si remplie, sinon role grise.
local function CompIconsStr(comp, size)
    local s = ""
    for i = 1, #HR.COMP_SLOTS do
        local cls = comp and comp[i]
        s = s .. (cls and HR.ClassIconMarkup(cls, size)
            or HR.RoleIconMarkupGrey(HR.COMP_SLOTS[i], size))
    end
    return s
end

-- Libelle d'une variante : compo d'abord, puis nom (dore si variante "a utiliser").
local function VariantLabel(v, used, size)
    local name = v.name
    if used and used.id == v.id then name = "|cffffd100" .. name .. "|r" end
    return CompIconsStr(v.comp, size) .. "  " .. name
end

--------------------------------------------------------------------------------
-- Modale "Nouvelle variante"
--------------------------------------------------------------------------------

-- `spec` (optionnel, slot heal pretre) : memorise la spe heal et affiche l'icone
-- de spe au lieu de l'icone de classe pour distinguer Holy / Discipline.
local function SetModalSlot(slot, token, spec)
    slot.classToken = token
    slot.spec = spec
    if token then
        local p = spec and HR.GetHealProfile(HR.HealProfileKey(token, spec))
        if p then HR.ApplyHealProfileIcon(slot.icon, p) else HR.ApplyClassIcon(slot.icon, token) end
        slot.icon:Show()
        slot.plus:Hide()
    else
        slot.icon:Hide()
        slot.plus:Show()
    end
end

local function BuildVariantModal()
    local m = CreateFrame("Frame", "HealPlannerVariantModal", UIParent, "BasicFrameTemplateWithInset")
    m:SetSize(420, 250)
    m:SetPoint("CENTER")
    m:SetFrameStrata("DIALOG")     -- sous les menus MenuUtil (sinon liste cachee)
    m:SetToplevel(true)
    m:EnableMouse(true)            -- capture les clics (sinon ils passent a la config derriere)
    tinsert(UISpecialFrames, "HealPlannerVariantModal")
    if HR.RegisterScaledFrame then HR.RegisterScaledFrame(m) end   -- option "Scale"
    local title = m.TitleText or _G["HealPlannerVariantModalTitleText"]
    if title then title:SetText("New variant") end

    local nameLabel = m:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameLabel:SetPoint("TOPLEFT", 16, -34)
    nameLabel:SetText("Name:")

    local edit = CreateFrame("EditBox", nil, m, "InputBoxTemplate")
    edit:SetSize(300, 24)
    edit:SetPoint("LEFT", nameLabel, "RIGHT", 10, 0)
    edit:SetAutoFocus(false)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEnterPressed", function() UI.SubmitVariantModal() end)
    m.nameEdit = edit

    local compLabel = m:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    compLabel:SetPoint("TOPLEFT", 16, -72)
    compLabel:SetText("Composition:")

    local import = CreateFrame("Button", nil, m, "UIPanelButtonTemplate")
    import:SetSize(150, 22)
    import:SetPoint("TOPRIGHT", -16, -68)
    import:SetText("Import group")
    import:SetScript("OnClick", function()
        local comp = HR.GetGroupComp()
        for i, slot in ipairs(m.slots) do SetModalSlot(slot, comp[i]) end
    end)

    m.slots = {}
    local SLOT = 36
    for i, role in ipairs(HR.COMP_SLOTS) do
        local b = CreateFrame("Button", nil, m)
        b:SetSize(SLOT, SLOT)
        b:SetPoint("TOPLEFT", 16 + (i - 1) * (SLOT + 12), -92)
        b.role = role

        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints()
        b.bg:SetColorTexture(0, 0, 0, 0.4)

        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetPoint("TOPLEFT", 1, -1)
        b.icon:SetPoint("BOTTOMRIGHT", -1, 1)
        b.icon:Hide()

        b.plus = b:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        b.plus:SetPoint("CENTER")
        b.plus:SetText("+")

        b.roleLabel = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        b.roleLabel:SetPoint("TOP", b, "BOTTOM", 0, -1)
        b.roleLabel:SetText(HR.RoleIconMarkup(role, 12) .. " " .. HR.RoleLabel(role))

        b:SetScript("OnClick", function(self) UI.OpenModalClassPicker(self) end)
        m.slots[i] = b
    end

    -- Importer le plan de base du heal choisi (sinon variante vide).
    local importDef = CreateFrame("CheckButton", nil, m, "UICheckButtonTemplate")
    importDef:SetSize(24, 24)
    importDef:SetPoint("TOPLEFT", 14, -150)
    importDef.label = importDef:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    importDef.label:SetPoint("LEFT", importDef, "RIGHT", 2, 0)
    importDef.label:SetText("Import heal base plan")
    m.importDefault = importDef

    local create = CreateFrame("Button", nil, m, "UIPanelButtonTemplate")
    create:SetSize(110, 24)
    create:SetPoint("BOTTOMRIGHT", -16, 16)
    create:SetText("Create")
    create:SetScript("OnClick", function() UI.SubmitVariantModal() end)

    local cancel = CreateFrame("Button", nil, m, "UIPanelButtonTemplate")
    cancel:SetSize(110, 24)
    cancel:SetPoint("RIGHT", create, "LEFT", -8, 0)
    cancel:SetText("Cancel")
    cancel:SetScript("OnClick", function() m:Hide() end)

    m:Hide()
    UI.variantModal = m
end

-- Choix de classe pour un slot de la modale (filtre par role). Le slot HEAL liste
-- les PROFILS de heal (le pretre y apparait en deux entrees : Discipline et Holy).
function UI.OpenModalClassPicker(slot)
    MenuUtil.CreateContextMenu(slot, function(owner, root)
        root:CreateTitle(HR.RoleIconMarkup(slot.role, 16) .. " " .. HR.RoleLabel(slot.role))
        if slot.role == "HEALER" then
            for _, p in ipairs(HR.HEAL_PROFILES) do
                local label = string.format("%s |c%s%s|r",
                    HR.HealProfileIconMarkup(p, 16), HR.ClassColorHex(p.class), p.name)
                root:CreateButton(label, function() SetModalSlot(slot, p.class, p.spec) end)
            end
        else
            for _, token in ipairs(HR.ROLE_CLASSES[slot.role] or {}) do
                local label = string.format("%s |c%s%s|r",
                    HR.ClassIconMarkup(token, 16), HR.ClassColorHex(token), HR.ClassName(token))
                root:CreateButton(label, function() SetModalSlot(slot, token) end)
            end
        end
        root:CreateDivider()
        root:CreateButton("Clear", function() SetModalSlot(slot, nil) end)
    end)
end

-- Ouvre la modale, compo pre-remplie depuis le groupe actuel.
function UI.OpenVariantModal()
    if not UI.activeDungeonID then return end
    if not UI.variantModal then BuildVariantModal() end
    local m = UI.variantModal
    m.nameEdit:SetText("")
    for _, slot in ipairs(m.slots) do SetModalSlot(slot, nil) end  -- pas d'autocompletion
    m.importDefault:SetChecked(true)   -- proposer l'import du plan de base par defaut
    m:Show()
    m:Raise()
    m.nameEdit:SetFocus()
end

function UI.SubmitVariantModal()
    local m = UI.variantModal
    if not m or not UI.activeDungeonID then return end
    local name = m.nameEdit:GetText() or ""
    if name:gsub("%s", "") == "" then
        HR:Print("Give the variant a name.")
        return
    end
    local comp = {}
    for i, slot in ipairs(m.slots) do comp[i] = slot.classToken end
    -- Spe heal (slot HEALER = index 2 dans HR.COMP_SLOTS) : pretre Holy/Discipline.
    local healSpec = m.slots[2] and m.slots[2].spec
    local v = HR.CreateVariant(UI.activeDungeonID, name, comp, healSpec)
    -- Import du plan de base du PROFIL de heal (classe + spe) si coche.
    if m.importDefault:GetChecked() then
        local d = HR.healerDefaults and HR.healerDefaults[HR.VariantHealKey(v)]
        if d then v.assignments = HR.DeepCopy(d.assignments) end
    end
    m:Hide()
    UI.SetActiveVariant(v)
end

--------------------------------------------------------------------------------
-- Popups renommer / supprimer
--------------------------------------------------------------------------------

-- Petite modale de renommage (l'EditBox d'un StaticPopup s'avere peu fiable ici).
local function BuildRenameModal()
    local m = CreateFrame("Frame", "HealPlannerRenameModal", UIParent, "BasicFrameTemplateWithInset")
    m:SetSize(320, 110)
    m:SetPoint("CENTER")
    m:SetFrameStrata("DIALOG")
    m:SetToplevel(true)
    tinsert(UISpecialFrames, "HealPlannerRenameModal")
    if HR.RegisterScaledFrame then HR.RegisterScaledFrame(m) end   -- option "Scale"
    local title = m.TitleText or _G["HealPlannerRenameModalTitleText"]
    if title then title:SetText("Rename variant") end

    local edit = CreateFrame("EditBox", nil, m, "InputBoxTemplate")
    edit:SetSize(270, 24)
    edit:SetPoint("TOP", 0, -40)
    edit:SetAutoFocus(false)
    edit:SetScript("OnEscapePressed", function() m:Hide() end)
    edit:SetScript("OnEnterPressed", function() UI.SubmitRename() end)
    m.edit = edit

    local ok = CreateFrame("Button", nil, m, "UIPanelButtonTemplate")
    ok:SetSize(100, 24)
    ok:SetPoint("BOTTOMRIGHT", -14, 14)
    ok:SetText("OK")
    ok:SetScript("OnClick", function() UI.SubmitRename() end)

    local cancel = CreateFrame("Button", nil, m, "UIPanelButtonTemplate")
    cancel:SetSize(100, 24)
    cancel:SetPoint("RIGHT", ok, "LEFT", -8, 0)
    cancel:SetText("Cancel")
    cancel:SetScript("OnClick", function() m:Hide() end)

    m:Hide()
    UI.renameModal = m
end

function UI.OpenRenameModal()
    if not UI.activeVariant or not UI.activeDungeonID then return end
    if not UI.renameModal then BuildRenameModal() end
    local m = UI.renameModal
    m.edit:SetText(UI.activeVariant.name or "")
    m:Show()
    m:Raise()
    m.edit:SetFocus()
    m.edit:HighlightText()
end

function UI.SubmitRename()
    local m = UI.renameModal
    if not m or not UI.activeVariant or not UI.activeDungeonID then return end
    local name = m.edit:GetText() or ""
    if name:gsub("%s", "") == "" then
        HR:Print("Give the variant a name.")
        return
    end
    HR.RenameVariant(UI.activeDungeonID, UI.activeVariant.id, name)
    m:Hide()
    UI.RefreshVariantBar()
end

StaticPopupDialogs["HEALPLANNER_RESET_VARIANT"] = {
    text = "Reapply the heal base plan to this variant?\n\nCurrent placements will be overwritten.",
    button1 = YES, button2 = NO,
    OnAccept = function()
        if UI.activeVariant and HR.ResetVariantToDefault(UI.activeVariant) then
            UI.RefreshRows()
            HR:Print("Variant reset to the heal base plan.")
        end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, showAlert = true, preferredIndex = 3,
}

StaticPopupDialogs["HEALPLANNER_DELETE_VARIANT"] = {
    text = "Delete variant \"%s\"?",
    button1 = YES, button2 = NO,
    OnAccept = function()
        if UI.activeVariant and UI.activeDungeonID then
            HR.DeleteVariant(UI.activeDungeonID, UI.activeVariant.id)
            UI.OnDungeonSelected(UI.activeDungeonID)
            UI.RefreshRows()
        end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, showAlert = true, preferredIndex = 3,
}

--------------------------------------------------------------------------------
-- Selection des variantes visibles + actives
--------------------------------------------------------------------------------

-- Variantes affichees dans le menu : par defaut celles dont la compo == compo du
-- groupe actuel ; toutes si "Afficher toutes" est coche.
-- Variantes affichees : la variante par defaut du heal selectionne, puis les
-- variantes utilisateur dont le heal (slot 2) correspond.
function UI.GetVisibleVariants(dungeonID)
    local out = {}
    local key = UI.selHealer                       -- clef de profil de heal
    if key and HR.healerDefaults[key] then
        out[#out + 1] = HR.healerDefaults[key]
    end
    for _, v in ipairs(HR.GetVariants(dungeonID)) do
        if HR.VariantHealKey(v) == key then
            out[#out + 1] = v
        end
    end
    return out
end

-- Choisit la variante active du donjon (celle "a utiliser", sinon 1re visible,
-- sinon 1re tout court) et rafraichit la barre.
function UI.OnDungeonSelected(dungeonID)
    UI.activeDungeonID = dungeonID
    UI.activeVariant = nil
    if dungeonID then
        local visible = UI.GetVisibleVariants(dungeonID)
        local used = HR.GetUsedVariant(dungeonID)
        if used then       -- garder la variante "a utiliser" si elle est dans le set affiche
            for _, v in ipairs(visible) do
                if v == used then UI.activeVariant = used break end
            end
        end
        UI.activeVariant = UI.activeVariant or visible[1]
    end
    UI.RefreshVariantBar()
end

function UI.SetActiveVariant(variant)
    UI.activeVariant = variant
    UI.RefreshVariantBar()
    UI.RefreshRows()
end

-- A l'ouverture : scanne le groupe et active la variante la plus adaptee
-- (cf. HR.FindBestVariant). Aligne le selecteur de heal sur cette variante pour
-- qu'elle apparaisse dans le dropdown.
function UI.AutoSelectForGroup()
    local dungeonID = UI.activeDungeonID
    if not dungeonID then return end
    local v = HR.FindBestVariant(dungeonID)
    if not v then return end
    local key = HR.VariantHealKey(v)
    if key and HR.healerDefaults[key] then
        UI.selHealer = key
    end
    UI.activeVariant = v
    UI.RefreshHealerTabs()
    UI.RefreshVariantBar()
    UI.RefreshRows()
end

-- Generateur du menu deroulant (pour le DropdownButton natif). Affiche, par variante :
-- ● (active) / ★ (runtime), le nom, puis les 5 slots de compo (icone de classe si
-- rempli, sinon icone de role grisee). Liste scrollable au-dela d'une hauteur max.
function UI.PopulateVariantMenu(root)
    local dungeonID = UI.activeDungeonID
    if not dungeonID then return end
    if root.SetScrollMode then root:SetScrollMode(GetScreenHeight() * 0.5) end
    local list = UI.GetVisibleVariants(dungeonID)
    local used = HR.GetUsedVariant(dungeonID)
    if #list == 0 then
        root:CreateButton("(none - New variant button)", function() end)
        return
    end
    for _, v in ipairs(list) do
        -- Radio natif : l'entree selectionnee a la surbrillance par defaut.
        -- Meme taille d'icone (20) que le champ ferme, sinon la valeur affichee
        -- change de taille quand le dropdown recopie le texte du radio selectionne.
        root:CreateRadio(VariantLabel(v, used, 20),
            function(data) return UI.activeVariant == data end,
            function(data) UI.SetActiveVariant(data) end,
            v)
    end
end

--------------------------------------------------------------------------------
-- Construction et rafraichissement de la barre
--------------------------------------------------------------------------------

function UI.BuildVariantBar(f)
    -- Liste deroulante (style select natif) des variantes : la valeur selectionnee
    -- (compo + nom) s'affiche directement dans le champ.
    local dd = CreateFrame("DropdownButton", nil, f, "WowStyle1DropdownTemplate")
    dd:SetSize(320, 30)
    dd:SetPoint("TOPLEFT", 12, -16)     -- haut du panneau de droite (sidebar = navigation)
    dd:SetDefaultText("Variant")
    dd:SetupMenu(function(_, root) UI.PopulateVariantMenu(root) end)
    UI.variantDropdown = dd

    -- Boutons d'action.
    local function actionBtn(text, x, onclick)
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(80, 22)
        b:SetPoint("TOPLEFT", x, -48)
        b:SetText(text)
        b:SetScript("OnClick", onclick)
        return b
    end
    UI.varNew = actionBtn("New", 12, function() UI.OpenVariantModal() end)
    UI.varDup = actionBtn("Duplicate", 96, function()
        if UI.activeVariant then
            local v = HR.DuplicateVariant(UI.activeDungeonID, UI.activeVariant.id)
            if v then UI.SetActiveVariant(v) end
        end
    end)
    UI.varRename = actionBtn("Rename", 180, function()
        if UI.activeVariant then UI.OpenRenameModal() end
    end)
    UI.varDelete = actionBtn("Delete", 264, function()
        if UI.activeVariant then StaticPopup_Show("HEALPLANNER_DELETE_VARIANT", UI.activeVariant.name) end
    end)
    UI.varUse = actionBtn("Use", 348, function()
        if UI.activeVariant then
            HR.SetUsedVariant(UI.activeDungeonID, UI.activeVariant.id)
            UI.RefreshVariantBar()
            HR:Print(("Variant \"%s\" set as active in combat."):format(UI.activeVariant.name))
        end
    end)

    -- Bouton "Reset defaut" (plus large) : reapplique le plan de base du heal.
    UI.varReset = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    UI.varReset:SetSize(100, 22)
    UI.varReset:SetPoint("TOPLEFT", 432, -48)
    UI.varReset:SetText("Reset default")
    UI.varReset:SetScript("OnClick", function()
        if UI.activeVariant and not UI.activeVariant.isDefault then
            StaticPopup_Show("HEALPLANNER_RESET_VARIANT")
        end
    end)

    -- Selecteur de PROFIL de heal (icones, facon onglets de donjon) : un onglet par
    -- profil (le pretre en a deux : Discipline + Holy, avec icone de spe). Filtre les
    -- variantes affichees et la variante par defaut proposee.
    UI.healerTabs = {}
    local HEAL_ICON = 28
    for i, p in ipairs(HR.HEAL_PROFILES) do
        local t = CreateFrame("Button", nil, f)
        t:SetSize(HEAL_ICON, HEAL_ICON)
        if i == 1 then
            t:SetPoint("LEFT", UI.variantDropdown, "RIGHT", 16, 0)
        else
            t:SetPoint("LEFT", UI.healerTabs[i - 1], "RIGHT", 4, 0)
        end
        t.healer = p.key

        t.border = t:CreateTexture(nil, "BACKGROUND")
        t.border:SetPoint("TOPLEFT", -2, 2)
        t.border:SetPoint("BOTTOMRIGHT", 2, -2)
        t.border:SetColorTexture(1, 1, 1, 1)
        t.border:Hide()

        t.icon = t:CreateTexture(nil, "ARTWORK")
        t.icon:SetAllPoints()
        t.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        HR.ApplyHealProfileIcon(t.icon, p)

        t:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        t:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText(p.name)
            GameTooltip:Show()
        end)
        t:SetScript("OnLeave", function() GameTooltip:Hide() end)
        t:SetScript("OnClick", function() UI.SelectHealer(p.key) end)
        UI.healerTabs[i] = t
    end

    -- Profil selectionne par defaut : celui du joueur si c'est un heal (pretre =
    -- selon sa spe active), sinon le 1er profil.
    local _, pc = UnitClass("player")
    UI.selHealer = HR.HEAL_PROFILES[1].key
    for _, p in ipairs(HR.HEAL_PROFILES) do
        if p.class == pc then
            UI.selHealer = (pc == "PRIEST")
                and HR.HealProfileKey("PRIEST", HR.GetPlayerSpecName()) or p.key
            break
        end
    end

    -- Tous les widgets de la barre de variantes, pour les masquer/afficher en bloc
    -- (vue "Defensive list" : on remplace variantes + plan par la liste des CD).
    UI.varWidgets = {
        UI.variantDropdown, UI.varNew, UI.varDup, UI.varRename, UI.varDelete,
        UI.varUse, UI.varReset,
    }
    for _, t in ipairs(UI.healerTabs) do UI.varWidgets[#UI.varWidgets + 1] = t end
end

-- Affiche/masque toute la barre de variantes d'un coup.
function UI.SetVariantBarShown(show)
    if not UI.varWidgets then return end
    for _, w in ipairs(UI.varWidgets) do if w then w:SetShown(show) end end
end

function UI.RefreshVariantBar()
    if not UI.variantDropdown then return end
    UI.RefreshHealerTabs()
    local v = UI.activeVariant
    local used = UI.activeDungeonID and HR.GetUsedVariant(UI.activeDungeonID)

    if v then
        UI.variantDropdown:SetDefaultText(VariantLabel(v, used, 20))
    else
        UI.variantDropdown:SetDefaultText("Variant: -")
    end
    if UI.variantDropdown.GenerateMenu then UI.variantDropdown:GenerateMenu() end

    local has = v ~= nil
    local isDefault = has and v.isDefault
    UI.varDup:SetEnabled(has)                       -- dupliquer un defaut => variante editable
    UI.varRename:SetEnabled(has and not isDefault)  -- defaut : non renommable
    UI.varDelete:SetEnabled(has and not isDefault)  -- defaut : non supprimable
    UI.varUse:SetEnabled(has)
    -- Reset : variante editable dont le profil de heal a un plan de base.
    local canReset = has and not isDefault
        and HR.healerDefaults[HR.VariantHealKey(v)] ~= nil
    UI.varReset:SetEnabled(canReset and true or false)
end
