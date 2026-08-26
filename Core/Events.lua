-- HealPlanner - Events.lua
-- Frame d'evenements unique qui declenche l'initialisation et relaie les
-- evenements de jeu vers les handlers de l'addon.
local addonName, HR = ...

local frame = CreateFrame("Frame", "HealPlannerEventFrame")
HR.eventFrame = frame

-- Table de dispatch : nom d'evenement -> liste de fonctions(self, ...).
-- Plusieurs modules peuvent ecouter le meme evenement (ex. ENCOUNTER_START est
-- utilise par la capture ET par le runtime).
HR.handlers = {}

function HR:RegisterEvent(event, handler)
    local list = self.handlers[event]
    if not list then
        list = {}
        self.handlers[event] = list
        self.eventFrame:RegisterEvent(event)
    end
    list[#list + 1] = handler
end

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local loaded = ...
        if loaded == addonName then
            -- Les SavedVariables sont disponibles ici, mais on attend
            -- PLAYER_LOGIN pour initialiser (monde charge).
            frame:UnregisterEvent("ADDON_LOADED")
        end
        return
    elseif event == "PLAYER_LOGIN" then
        HR:OnInitialize()
        return
    end

    local list = HR.handlers[event]
    if list then
        for _, handler in ipairs(list) do
            handler(HR, ...)
        end
    end
end)
