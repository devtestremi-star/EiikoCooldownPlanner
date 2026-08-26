-- HealPlanner - UI/ShareFrame.lua
-- Apercu d'un plan recu (clic sur le lien de partage) + bouton d'import.
-- Le clic sur le lien custom arrive via Core/Share.lua (OnSetItemRef).
local addonName, HR = ...

HR.UI = HR.UI or {}
local UI = HR.UI

local function DungeonName(dID)
    for _, d in ipairs(HR.content) do
        if d.id == dID then return d.name end
    end
    return tostring(dID)
end

local function Build()
    local m = CreateFrame("Frame", "HealPlannerImportFrame", UIParent, "BasicFrameTemplateWithInset")
    m:SetSize(420, 200)
    m:SetPoint("CENTER")
    m:SetFrameStrata("FULLSCREEN_DIALOG")   -- au-dessus de la config
    m:SetToplevel(true)
    m:EnableMouse(true)
    m:SetMovable(true)
    m:RegisterForDrag("LeftButton")
    m:SetScript("OnDragStart", m.StartMoving)
    m:SetScript("OnDragStop", m.StopMovingOrSizing)
    tinsert(UISpecialFrames, "HealPlannerImportFrame")
    if HR.RegisterScaledFrame then HR.RegisterScaledFrame(m) end   -- option "Scale"

    local title = m.TitleText or _G["HealPlannerImportFrameTitleText"]
    if title then title:SetText("Import a plan") end

    -- Nom du plan (en-tete).
    m.planName = m:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    m.planName:SetPoint("TOPLEFT", 16, -34)
    m.planName:SetPoint("RIGHT", m, "RIGHT", -16, 0)
    m.planName:SetJustifyH("LEFT"); m.planName:SetWordWrap(false)

    -- Shared by.
    local byLbl = m:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    byLbl:SetPoint("TOPLEFT", 16, -62); byLbl:SetText("Shared by:")
    m.sender = m:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    m.sender:SetPoint("LEFT", byLbl, "RIGHT", 6, 0)

    -- Dungeon.
    local dgLbl = m:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dgLbl:SetPoint("TOPLEFT", 16, -84); dgLbl:SetText("Dungeon:")
    m.dungeon = m:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    m.dungeon:SetPoint("LEFT", dgLbl, "RIGHT", 6, 0)

    -- Autodelete in 24h (coche par defaut) : l'import expire et est purge apres 24h.
    m.autodel = CreateFrame("CheckButton", nil, m, "UICheckButtonTemplate")
    m.autodel:SetSize(24, 24); m.autodel:SetPoint("TOPLEFT", 14, -108)
    m.autodel:SetChecked(true)
    local adLbl = m:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    adLbl:SetPoint("LEFT", m.autodel, "RIGHT", 2, 0); adLbl:SetText("Autodelete in 24h")
    if UI.Components and UI.Components.AttachHelpTip then
        UI.Components.AttachHelpTip(m.autodel, "Autodelete in 24h", "This plan will be automatically removed in 24h.")
    end

    -- CTA : Close | Import | Import and use. (`use` => variante posee en active runtime.)
    local function doImport(use)
        local v, dID = HR.Share.ImportPayload(m.payload, m.senderName, m.autodel:GetChecked() and true or false)
        if not v then HR:Print("Import failed: invalid plan."); m:Hide(); return end
        if use then HR.SetV2Used(v.id, dID) end
        m:Hide()
        if UI.ShowDungeonVariant then UI.ShowDungeonVariant(dID, v) end   -- ouvre sur le donjon + plan
        HR:Print(("Plan \"%s\" imported%s."):format(v.name, use and " and set as active." or "."))
    end

    local impUse = CreateFrame("Button", nil, m, "UIPanelButtonTemplate")
    impUse:SetSize(120, 24); impUse:SetPoint("BOTTOMRIGHT", -12, 14); impUse:SetText("Import and use")
    impUse:SetScript("OnClick", function() doImport(true) end)
    local imp = CreateFrame("Button", nil, m, "UIPanelButtonTemplate")
    imp:SetSize(90, 24); imp:SetPoint("RIGHT", impUse, "LEFT", -6, 0); imp:SetText("Import")
    imp:SetScript("OnClick", function() doImport(false) end)
    local close = CreateFrame("Button", nil, m, "UIPanelButtonTemplate")
    close:SetSize(80, 24); close:SetPoint("RIGHT", imp, "LEFT", -6, 0); close:SetText("Close")
    close:SetScript("OnClick", function() m:Hide() end)

    m:Hide()
    UI.importFrame = m
end

-- Ouvre l'apercu pour un payload recu. Appele par Core/Share.lua au clic du lien.
-- On a deja PARSE le payload (Decode) ; ici on n'affiche que les meta (rien n'est importe
-- tant que l'utilisateur ne clique pas Import / Import and use).
function UI.OpenImportPreview(payload, senderName)
    if not payload then return end
    if not UI.importFrame then Build() end
    local m = UI.importFrame
    m.payload     = payload
    m.senderName  = senderName

    local short = senderName and senderName:match("^[^-]+") or "?"
    m.planName:SetText(tostring(payload.name or "Plan"))
    m.sender:SetText("|cffffd100" .. short .. "|r")
    m.dungeon:SetText(DungeonName(payload.dID))
    m.autodel:SetChecked(true)        -- Autodelete coche par defaut a chaque ouverture

    m:Show()
    m:Raise()
end
