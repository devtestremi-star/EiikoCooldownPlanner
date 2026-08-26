-- HealPlanner - Core/Plans.lua
-- Variantes de plan par donjon + placements de defensifs.
--   HR.db.dungeons[dungeonID] = { usedVariant = <id>, variants = { variant, ... } }
--   variant = { id, name, comp = { [1..5] = classToken }, assignments }
--             comp aligne sur HR.COMP_SLOTS (1=tank, 2=heal, 3..5=dps)
--   assignments = { [encounterID] = { [occKey] = { defID, ... } } }
-- Une variante couvre TOUT le donjon (tous ses boss). On peut en avoir plusieurs
-- par composition. `usedVariant` = celle jouee par le runtime pour ce donjon.
local addonName, HR = ...

--------------------------------------------------------------------------------
-- Store / variantes
--------------------------------------------------------------------------------

local function GetStore(dungeonID)
    HR.db.dungeons[dungeonID] = HR.db.dungeons[dungeonID] or { usedVariant = nil, variants = {} }
    return HR.db.dungeons[dungeonID]
end

function HR.GetVariants(dungeonID)
    return GetStore(dungeonID).variants
end

function HR.GetVariantById(dungeonID, id)
    if not id then return nil end
    -- Variantes par defaut (data) : id "default:KEY" (KEY = profil de heal).
    -- Compat : un ancien "default:PRIEST" est resolu vers le profil pretre par defaut.
    if type(id) == "string" then
        local key = id:match("^default:(.+)$")
        if key and HR.healerDefaults then
            return HR.healerDefaults[key] or HR.healerDefaults[HR.HealProfileKey(key)]
        end
    end
    for _, v in ipairs(GetStore(dungeonID).variants) do
        if v.id == id then return v end
    end
end

local function NextVariantId()
    local id = HR.db.nextVariantId or 1
    HR.db.nextVariantId = id + 1
    return id
end

-- `spec` (optionnel) = spe heal du pretre ("Holy"/"Discipline"). Ignore si le heal
-- n'est pas pretre. Discrimine les deux profils de heal pretre (sorts + plan).
function HR.CreateVariant(dungeonID, name, comp, spec)
    local store = GetStore(dungeonID)
    local sorted = HR.SortComp(comp or {})       -- tank, heal, dps (alpha) a l'enregistrement
    local v = {
        id          = NextVariantId(),
        name        = (name and name ~= "") and name or "Variant",
        comp        = sorted,
        spec        = (sorted[2] == "PRIEST") and spec or nil,
        assignments = {},
    }
    store.variants[#store.variants + 1] = v
    return v
end

function HR.DuplicateVariant(dungeonID, id)
    local src = HR.GetVariantById(dungeonID, id)
    if not src then return nil end
    local store = GetStore(dungeonID)
    local v = {
        id          = NextVariantId(),
        name        = (src.name or "Variant") .. " (copy)",
        comp        = HR.DeepCopy(src.comp),
        spec        = src.spec,
        assignments = HR.DeepCopy(src.assignments),
    }
    store.variants[#store.variants + 1] = v
    return v
end

function HR.RenameVariant(dungeonID, id, name)
    local v = HR.GetVariantById(dungeonID, id)
    if v and name and name ~= "" then v.name = name end
end

function HR.DeleteVariant(dungeonID, id)
    local v = HR.GetVariantById(dungeonID, id)
    if v and v.isDefault then return end       -- les variantes par defaut ne se suppriment pas
    local store = GetStore(dungeonID)
    for i, v in ipairs(store.variants) do
        if v.id == id then
            table.remove(store.variants, i)
            break
        end
    end
    if store.usedVariant == id then store.usedVariant = nil end
end

-- Reapplique le plan de base du heal de la variante (ecrase ses assignments).
function HR.ResetVariantToDefault(variant)
    if not variant then return false end
    local d = HR.healerDefaults and HR.healerDefaults[HR.VariantHealKey(variant)]
    if not d then return false end
    variant.assignments = HR.DeepCopy(d.assignments)
    return true
end

function HR.SetUsedVariant(dungeonID, id)
    GetStore(dungeonID).usedVariant = id
end

function HR.GetUsedVariant(dungeonID)
    return HR.GetVariantById(dungeonID, GetStore(dungeonID).usedVariant)
end

--------------------------------------------------------------------------------
-- Selection automatique de variante a l'ouverture (scan du groupe)
--------------------------------------------------------------------------------

-- Le slot heal pese tres lourd : un plan de defensifs heal n'a de sens que pour
-- le bon healer. A heal egal, on departage sur le tank puis les dps.
local HEAL_WEIGHT = 10

-- Score de proximite entre la compo d'une variante et la compo live du groupe.
-- Les deux compos sont triees (role puis classe) : la comparaison positionnelle
-- equivaut alors a l'intersection multi-ensemble par role.
local function CompMatchScore(variantComp, groupComp)
    local a = HR.SortComp(variantComp or {})
    local b = HR.SortComp(groupComp or {})
    local score = 0
    for i = 1, #HR.COMP_SLOTS do
        if a[i] and a[i] == b[i] then
            score = score + (HR.COMP_SLOTS[i] == "HEALER" and HEAL_WEIGHT or 1)
        end
    end
    return score
end

-- Variante la plus adaptee au contexte actuel pour ce donjon. Cascade :
--   1. En groupe : variante utilisateur dont la compo matche le mieux la compo
--      live (compo exacte => score maximal => choisie ; sinon la plus proche).
--   2. En groupe sans aucune variante : repli sur le plan de base du heal du
--      groupe (a defaut celui du joueur, a defaut le 1er).
--   3. Joueur seul + classe de heal : son plan de base de heal.
--   4. Joueur seul sans spe heal : la premiere chose trouvee (1re variante, sinon
--      1er plan de base).
function HR.FindBestVariant(dungeonID)
    local _, playerClass = UnitClass("player")
    local variants = HR.GetVariants(dungeonID)

    -- (3)(4) Joueur seul : pas de vraie compo a matcher.
    if not IsInGroup() then
        local key = HR.HealProfileKey(playerClass, HR.GetPlayerSpecName())
        if key and HR.healerDefaults[key] then
            return HR.healerDefaults[key]                    -- (3) plan de base du heal du joueur (spe pretre)
        end
        return variants[1] or HR.GetHealerDefaults()[1]      -- (4) premiere chose trouvee
    end

    -- (1)(2) En groupe : matcher la compo live contre les variantes utilisateur.
    local comp = HR.GetGroupComp()
    local best, bestScore
    for _, v in ipairs(variants) do
        local s = CompMatchScore(v.comp, comp)
        if not bestScore or s > bestScore then
            best, bestScore = v, s
        end
    end
    if best then return best end                             -- (1) exact ou (2) plus proche

    -- En groupe mais aucune variante : repli sur le plan de base du heal du groupe.
    -- La spe du heal du groupe n'est pas lisible (UnitClass seul) -> pretre = Disc par defaut.
    local groupKey  = HR.HealProfileKey(comp[2])
    local playerKey = HR.HealProfileKey(playerClass, HR.GetPlayerSpecName())
    return (groupKey and HR.healerDefaults[groupKey])
        or (playerKey and HR.healerDefaults[playerKey])
        or HR.GetHealerDefaults()[1]
end

--------------------------------------------------------------------------------
-- Placements dans une variante
--------------------------------------------------------------------------------
-- HR.GetAssignments a DEMENAGE dans Core/Plan2.lua : elle est generique (variante
-- explicite) et le runtime l'appelle sur des variantes V2, pas sur du V1.

--------------------------------------------------------------------------------
-- Reset / stats
--------------------------------------------------------------------------------

-- Efface TOUTES les variantes de tous les donjons. Irreversible.
function HR.ResetAllPlans()
    if HR.db then
        HR.db.dungeons = {}
        HR.db.plans = {}
    end
end

-- Nombre total de variantes (tous donjons), pour /hp status.
function HR.CountPlans()
    local n = 0
    if HR.db and HR.db.dungeons then
        for _, store in pairs(HR.db.dungeons) do
            n = n + #(store.variants or {})
        end
    end
    return n
end
