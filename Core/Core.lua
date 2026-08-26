-- HealPlanner - Core.lua
-- Point d'entree : sequence d'initialisation de l'addon.
local addonName, HR = ...

HR.initialized = false

-- Appele une seule fois, apres ADDON_LOADED + PLAYER_LOGIN.
function HR:OnInitialize()
    if self.initialized then return end

    self:InitDB()

    -- Purge des plans IMPORTES expires (option "Autodelete in 24h" du partage).
    if HR.PruneExpiredVariants then HR.PruneExpiredVariants() end

    -- Auto-chargement de la variante par defaut de MA spe a l'entree d'un donjon.
    -- Gate par TTL persistant (cf. HR.AutoLoadDefaultVariant / HR.db2.autoLoad) : un choix
    -- manuel survit a une sortie/re-entree < 2h. Rechargement force au changement de spe.
    if HR.AutoLoadDefaultVariant then
        -- PAS de `force` : le gate (donjon, spe, TTL) detecte lui-meme un vrai changement de spe
        -- (contexte different). Forcer ici re-appliquerait le defaut a chaque event spurious
        -- (PLAYER_SPECIALIZATION_CHANGED fire souvent a l'entree d'instance) -> ecraserait le choix manuel.
        HR:RegisterEvent("PLAYER_ENTERING_WORLD",         function() HR.AutoLoadDefaultVariant() end)
        HR:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", function() HR.AutoLoadDefaultVariant() end)
    end

    -- Variante de test (boss invente) : regeneree a chaque init, jamais persistee.
    if HR.BuildTestVariant then HR.BuildTestVariant() end

    -- Macros /yell des CD externes (hors combat ; sinon via /hp macros).
    if HR.SetupMacros then HR.SetupMacros() end

    -- Masquage des timers des autres bossmods (BigWigs/LittleWigs, DBM, timeline
    -- Blizzard) quand ils font doublon avec les notres. No-op si l'option est OFF.
    if HR.ForeignBars and HR.ForeignBars.Init then HR.ForeignBars.Init() end

    -- Accroche des defensifs planifies aux barres BigWigs/LittleWigs (exclusif avec le
    -- masquage ci-dessus). No-op si l'option est OFF ou si BigWigs est absent.
    if HR.BossModAttach and HR.BossModAttach.Init then HR.BossModAttach.Init() end

    -- Construit la boite runtime HORS COMBAT : ses boutons d'appel securises ne
    -- peuvent recevoir leurs attributs qu'a ce moment (cf. UI/RuntimeBox.lua).
    if HR.Runtime and HR.Runtime.PreBuild then HR.Runtime.PreBuild() end

    -- Entree dans Options > AddOns (menu WoW).
    if HR.RegisterBlizzOptions then HR.RegisterBlizzOptions() end

    -- "What's new" : modale a l'init si la version courante n'a pas ete masquee (cf. UI/WhatsNew).
    -- DIFFEREE : ouvrir une frame pile a PLAYER_LOGIN (ecran de chargement encore actif) ne
    -- l'affiche pas -> C_Timer.After la montre une fois la boucle de jeu active.
    if HR.UI and HR.UI.MaybeShowWhatsNew then
        C_Timer.After(1, HR.UI.MaybeShowWhatsNew)
    end

    if self.db.enabled then
        self:Print(("v%s loaded. Type %s/hp%s for commands.")
            :format(HR.VERSION, HR.COLORS.YELLOW, HR.COLORS.RESET))
    end

    self.initialized = true
end

-- Fonction du menu deroulant de la compartiment d'addons (champ
-- AddonCompartmentFunc du .toc). Doit etre une globale.
function HealPlanner_OnAddonCompartmentClick(addonNameArg, buttonName)
    HR.UI.Toggle()
end

-- Entree dans le menu WoW Options > AddOns (Settings API, 10.0+/Midnight). La config reelle
-- est une modale custom -> ce panneau n'est qu'un LANCEUR (titre + description + bouton qui
-- ouvre la modale). Idempotent ; no-op si l'API Settings est absente.
function HR.RegisterBlizzOptions()
    if HR._blizzCategory then return end
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end

    local panel = CreateFrame("Frame")
    panel.name = "EiikoCooldownPlanner"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("EiikoCooldownPlanner")

    local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    desc:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
    desc:SetJustifyH("LEFT")
    desc:SetText("Plan healer defensive cooldowns against boss abilities.")

    local btn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    btn:SetSize(200, 26)
    btn:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -16)
    btn:SetText("Open planner")
    btn:SetScript("OnClick", function()
        if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
        HR.UI.Toggle()
    end)

    -- Section "Scale" : echelle de la fenetre principale + toutes les modales (PAS le HUD
    -- runtime : timeline / upcoming bar / etc. ont leurs propres echelles).
    local function uiScale() return (HR.db and HR.db.options and HR.db.options.uiScale) or 1 end

    local scaleLbl = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    scaleLbl:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -28)
    scaleLbl:SetText("Scale")

    local scaleDesc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    scaleDesc:SetPoint("TOPLEFT", scaleLbl, "BOTTOMLEFT", 0, -6)
    scaleDesc:SetText("Scale of the main window and all modals (does not affect the in-combat HUD).")
    scaleDesc:SetTextColor(0.7, 0.7, 0.7)

    local sl = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
    sl:SetPoint("TOPLEFT", scaleDesc, "BOTTOMLEFT", 6, -18)
    sl:SetWidth(240)
    sl:SetMinMaxValues(0.7, 1.5)
    sl:SetValueStep(0.05)
    sl:SetObeyStepOnDrag(true)
    if sl.Low  then sl.Low:SetText("70%")  end
    if sl.High then sl.High:SetText("150%") end
    if sl.Text then sl.Text:SetText("") end
    local slVal = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    slVal:SetPoint("LEFT", sl, "RIGHT", 12, 0)
    local function fmtPct(v) return ("%d%%"):format(math.floor(v * 100 + 0.5)) end
    sl:SetValue(uiScale()); slVal:SetText(fmtPct(uiScale()))
    sl:SetScript("OnValueChanged", function(_, v)
        v = math.floor(v / 0.05 + 0.5) * 0.05
        slVal:SetText(fmtPct(v))
        if HR.db then HR.db.options = HR.db.options or {}; HR.db.options.uiScale = v end
        if HR.ApplyUIScale then HR.ApplyUIScale() end
    end)

    local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
    Settings.RegisterAddOnCategory(category)
    HR._blizzCategory = category
end
