-- HealPlanner - Core/GroupScan.lua
-- Scan LIVE du groupe REEL, INDEPENDANT de la variante jouee.
--
-- Pourquoi : la "variante" est l'outil de planif du HEALER (lui seul a l'addon). Mais la
-- Communication bar doit lister TOUS les CD externes que le groupe peut REELLEMENT fournir
-- (les autres joueurs n'ont pas l'addon), quelle que soit la variante. On derive ca du vrai
-- groupe, SANS inspection (donc sans probleme de portee) :
--   * classe   -> UnitClass(unit)               (toujours lisible, meme en instance)
--   * role     -> UnitGroupRolesAssigned(unit)   (TANK/HEALER/DAMAGER, sans inspect)
-- Astuce spec : un sort spec-gate se deduit du ROLE quand la spe est la seule de ce role
--   pour la classe. Ex. Vampiric Embrace = Pretre "Shadow" = la SEULE spe DPS du pretre
--   -> "Pretre en role DAMAGER" suffit, pas besoin d'inspecter.
--
-- HR.group = snapshot { {guid, unit, name, class, role}, ... }, rebati sur les events
-- join/leave/role/spec. Consomme par la Communication bar via HR.GroupHasExternal.
local addonName, HR = ...

-- Snapshot du groupe reel (joueur inclus).
HR.group = HR.group or {}

-- Spe (nom EN, cf. HR.defensives.spec) -> role assigne qui la trahit sans inspection.
-- Uniquement les spes qui sont l'UNIQUE spe de ce role pour leur classe.
local SPEC_ROLE = {
    Shadow = "DAMAGER",   -- seule spe DPS du pretre -> Vampiric Embrace
}

local function addUnit(unit)
    if not UnitExists(unit) then return end
    local _, class = UnitClass(unit)
    if not class then return end
    HR.group[#HR.group + 1] = {
        guid  = UnitGUID(unit),
        unit  = unit,
        name  = UnitName(unit),
        class = class,
        role  = UnitGroupRolesAssigned(unit),
    }
end

-- Reconstruit HR.group depuis le groupe courant. Cheap (<=40 unites) -> appele a chaque
-- event pertinent ET en tete de RefreshCallButtons (fraicheur garantie, ordre indifferent).
function HR.RebuildGroup()
    wipe(HR.group)
    addUnit("player")
    local n = GetNumGroupMembers() or 0
    if IsInRaid() then
        for i = 1, n do addUnit("raid" .. i) end
    elseif IsInGroup() then
        for i = 1, n - 1 do addUnit("party" .. i) end
    end
    return HR.group
end

-- Au moins un membre de cette classe dans le groupe ?
local function hasClass(token)
    for _, m in ipairs(HR.group) do
        if m.class == token then return true end
    end
    return false
end

-- Au moins un membre de cette classe AVEC ce role assigne ?
function HR.GroupHasClassRole(class, role)
    for _, m in ipairs(HR.group) do
        if m.class == class and m.role == role then return true end
    end
    return false
end

-- Un CD externe (entree de HR.defensives, ou sa cle) est-il SUPPOSEMENT dispo dans le
-- groupe reel ? (Pas de certitude sur les talents/trinkets -> "suppose".)
--   * sans classe (trinket/generique)  -> indeterminable, on l'affiche (true).
--   * spec-gate connu (ex. Shadow)      -> il faut la classe AVEC le role correspondant.
--   * sinon (class-only)                -> il suffit que la classe soit presente.
function HR.GroupHasExternal(def)
    if type(def) ~= "table" then def = HR.ResolveDefEntry(def) end
    if not def then return false end
    if not def.class then return true end
    -- External reserve a un role (ex. Zephyr DPS role=DAMAGER) : exige la classe AVEC ce role
    -- (un Evoker heal ne "fournit" pas le Zephyr external -> son Zephyr est un CD de heal).
    if def.role then return HR.GroupHasClassRole(def.class, def.role) end
    if def.spec then
        local role = SPEC_ROLE[def.spec]
        if role then return HR.GroupHasClassRole(def.class, role) end
        -- spe non deductible du role -> repli prudent sur la classe seule.
    end
    return hasClass(def.class)
end

-- Membres du groupe qui FOURNISSENT ce CD (meme logique que GroupHasExternal, mais renvoie
-- la liste des entrees HR.group au lieu d'un booleen). Sert a cibler le ping natif au clic.
--   * sans def.class (SMALL_DEF, Empty bags, trinket generique) -> {} (pas de cible nommee).
--   * def.role present (ex. Zephyr DPS) -> classe AVEC ce role.
--   * def.spec deductible du role (SPEC_ROLE) -> classe + role deduit.
--   * sinon -> classe seule.
function HR.GroupUnitsFor(def)
    if type(def) ~= "table" then def = HR.ResolveDefEntry(def) end
    if not def or not def.class then return {} end
    local role = def.role or (def.spec and SPEC_ROLE[def.spec]) or nil
    local out = {}
    for _, m in ipairs(HR.group) do
        if m.class == def.class and (not role or m.role == role) then
            out[#out + 1] = m
        end
    end
    return out
end

-- Maintien du snapshot : join/leave (roster), changement de role, changement de spe (qui
-- peut basculer le role), et passe initiale au load (groupe deja forme).
local function refresh() HR.RebuildGroup() end
HR:RegisterEvent("GROUP_ROSTER_UPDATE", refresh)
HR:RegisterEvent("PLAYER_ROLES_ASSIGNED", refresh)
HR:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", refresh)
HR:RegisterEvent("PLAYER_ENTERING_WORLD", refresh)
