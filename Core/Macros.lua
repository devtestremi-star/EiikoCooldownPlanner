-- HealPlanner - Core/Macros.lua
-- Macros joueur pour annoncer les CD EXTERNES (non-heal) en /p (canal groupe) : un addon
-- ne peut pas parler en combat, mais une macro pressee par le joueur (event materiel)
-- oui. Nom : EHP_<SHORT>. Corps : /p <nom complet>.
-- A l'init : on SUPPRIME toutes les macros gerees (prefixe EHP_) puis on (re)cree
-- celles de la liste -> aucun flood de macros chez le joueur.
-- CreateMacro/DeleteMacro = hors combat uniquement (#nocombat).
local addonName, HR = ...

local MACRO_PREFIX = "EHP_"

-- Macros a creer : CD externes ne provenant PAS d'une classe de heal + le generique.
-- Expose en HR.externalMacros : la boite runtime (UI/RuntimeBox.lua) cree une
-- rangee de boutons securises, un par entree, lie a sa macro EHP_ (clic -> /p).
-- Entree : { name, key } pour un defensif (corps "/p Next Cooldown : <nom>",
--           icone = celle du defensif), OU { name, body, label, icon } pour une
--           macro custom (corps `body` tel quel, `label`/`icon` pour le bouton).
HR.externalMacros = {
    { name = "EHP_ZEPHYR",   key = 374227 },    -- Zephyr (Evoker)
    { name = "EHP_AMZ",      key = 51052 },     -- Anti-Magic Zone (Chevalier de la mort)
    { name = "EHP_DARKNESS", key = 196718 },    -- Darkness (Chasseur de demons)
    { name = "EHP_CRY",      key = 97462 },      -- Rallying Cry (Guerrier)
    { name = "EHP_VAMP",     key = 15286 },      -- Vampiric Embrace (Pretre Shadow ; gate par role DPS)
    { name = "EHP_SMALLDEF", key = "SMALL_DEF" }, -- Defensif perso generique (unique)
    { name  = "EHP_EMPTYBAG",                     -- Appel "tout lacher" (tete de mort)
      body  = "/p Empty the bags - use everything!",
      label = "Empty the bags",
      icon  = "Interface\\Icons\\inv_misc_bone_skull_02" },
}
local TO_CREATE = HR.externalMacros

-- Supprime toutes les macros gerees par l'addon (prefixe EHP_).
local function DeleteManaged()
    local names = {}
    for i = 1, 150 do                       -- 1..120 = compte, 121..150 = perso
        local n = GetMacroInfo(i)
        if n and n:sub(1, #MACRO_PREFIX) == MACRO_PREFIX then
            names[#names + 1] = n
        end
    end
    for _, n in ipairs(names) do
        local idx = GetMacroIndexByName(n)
        if idx and idx > 0 then DeleteMacro(idx) end
    end
end

-- Nom ciblable "Nom-Royaume" d'une unite (toujours avec le royaume, pour /ping cross-royaume).
-- GetUnitName(unit, true) = "Nom-Royaume" en cross-royaume, "Nom" seul en meme royaume -> on
-- complete alors avec le royaume courant normalise (sans espaces, format ciblage).
local function UnitFullName(unit)
    local full = GetUnitName(unit, true)
    if not full then return nil end
    if not full:find("-", 1, true) then
        local realm = GetNormalizedRealmName()
        if realm and realm ~= "" then full = full .. "-" .. realm end
    end
    return full
end

-- Corps de macro pour une entree `m` (defensif resolu `d`, nilable) :
--   base = "/p Next Cooldown: <nom>" (ou m.body tel quel pour une macro custom) ;
--   + "/ping [@Nom-Royaume] assist" ciblant le 1er membre du groupe qui fournit ce CD
--     (system de ping natif ; @cible ne change pas la cible reelle du joueur -> 1 seul clic).
-- Sans cible (classe absente, SMALL_DEF/Empty bags) => base seule (retro-compatible).
function HR.BuildMacroBody(m, d)
    if m.body then return m.body end                     -- macro custom (Empty bags)
    if not d then return nil end
    local nm = d.name:gsub("%s*%b()", "")                -- sans le suffixe de variante " (3 min)"
    local body = "/p Next Cooldown: " .. nm
    -- Ping natif du proprietaire, gate par l'option commPing (defaut ON ; seul `false` explicite coupe).
    local o = HR.db and HR.db.options
    if not (o and o.commPing == false) then
        local units = HR.GroupUnitsFor and HR.GroupUnitsFor(d)
        if units and units[1] then
            local target = UnitFullName(units[1].unit)
            if target then body = body .. "\n/ping [@" .. target .. "] assist" end
        end
    end
    return body
end

-- Hors combat : nettoie les macros gerees puis (re)cree celles necessaires.
-- Renvoie le nombre cree, ou nil si impossible (combat).
function HR.SetupMacros()
    if InCombatLockdown() then return nil end
    DeleteManaged()
    local n = 0
    for _, m in ipairs(TO_CREATE) do
        local d = m.key and HR.ResolveDefEntry(m.key)   -- gere les cles brutes (AMZ/Darkness)
        local body = HR.BuildMacroBody(m, d)
        local icon = m.icon or (m.key and HR.GetDefensiveIcon(m.key)) or 134400
        if body then
            CreateMacro(m.name, icon, body, nil)        -- compte (perCharacter=nil)
            n = n + 1
        end
    end
    return n
end

-- Recalcule le corps (cible de ping a jour) de chaque macro geree EXISTANTE. Hors combat
-- uniquement (EditMacro protege en combat). Appele apres HR.RebuildGroup (RefreshCallButtons)
-- pour que le /ping suive les changements de composition.
function HR.RefreshMacroPings()
    if InCombatLockdown() then return end
    for _, m in ipairs(TO_CREATE) do
        local idx = GetMacroIndexByName(m.name)
        if idx and idx > 0 then
            local d = m.key and HR.ResolveDefEntry(m.key)
            local body = HR.BuildMacroBody(m, d)
            if body then
                local icon = m.icon or (m.key and HR.GetDefensiveIcon(m.key)) or 134400
                EditMacro(idx, m.name, icon, body)
            end
        end
    end
end
