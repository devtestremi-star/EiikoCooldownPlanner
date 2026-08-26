-- HealPlanner - Data/HealerDefaults.lua
-- Plan de BASE par healer (ce heal "tout seul"). Une variante par classe de heal,
-- NON supprimable, qui sert de base quand ce heal est dans la compo et de source
-- d'import a la creation d'une nouvelle variante.
-- Indexe par PROFIL de heal (cf. HR.HEAL_PROFILES) et non par classe : le pretre a
-- DEUX defauts (Discipline + Holy), un par spe.
--   healerDefaults[profileKey] = { id="default:KEY", isDefault, healer=KEY, spec,
--       comp={[2]=class}, assignments = { [encounterID] = { [occKey] = {defID,...} } } }
-- `assignments` est a enrichir (placements de base recommandes pour ce heal).
local addonName, HR = ...

HR.healerDefaults = {}
for _, p in ipairs(HR.HEAL_PROFILES) do
    HR.healerDefaults[p.key] = {
        id          = "default:" .. p.key,
        isDefault   = true,
        healer      = p.key,
        spec        = p.spec,            -- pretre : "Discipline"/"Holy" ; sinon nil
        name        = "Default " .. p.name,
        comp        = { [2] = p.class }, -- ce heal seul (slot heal)
        assignments = {},                -- TODO : placements de base du heal
    }
end
