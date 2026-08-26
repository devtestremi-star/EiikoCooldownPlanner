-- HealPlanner - Core/DevLog.lua
-- JOURNAL DE DEV persistant, pour debug fin (active par /ecp devlog).
--
-- ⚠ WoW ne peut PAS ecrire dans le dossier de l'addon (aucune IO fichier dans le bac a sable
-- Lua). Le seul moyen de persister = une SavedVariable. Le log vit donc dans la SavedVariable
-- dediee `ECPDevLog` (declaree dans le .toc, SEPAREE de la DB de plans = on ne touche pas aux
-- donnees sacrees). Elle est ecrite sur le disque au /reload ou /logout, dans :
--     WTF\Account\<compte>\SavedVariables\EiikoCooldownPlannerDev.lua   (copie Dev)
-- -> workflow : /ecp devlog (ON, reset), reproduire le bug, /reload, puis lecture du fichier.
--
-- API :
--   HR.DevLog(cat, fmt, ...)   -> ajoute une ligne horodatee (GetTime) ; no-op si desactive.
--   HR.DevLogEnabled()         -> bool
--   HR.SetDevLog(on)           -> (dé)active ; a l'activation, VIDE le buffer.
--   HR.DevSafe(v)              -> string affichable meme si v est une Secret Value (pcall).
local addonName, HR = ...

local MAX_LINES = 20000   -- garde-fou : on ARRETE (pas de wrap) pour garder la chronologie.

local function ensure()
    if type(ECPDevLog) ~= "table" then ECPDevLog = {} end
    if type(ECPDevLog.lines) ~= "table" then ECPDevLog.lines = {} end
    return ECPDevLog
end

function HR.DevLogEnabled()
    return type(ECPDevLog) == "table" and ECPDevLog.enabled == true
end

-- Lit une valeur potentiellement SECRETE sans jamais lever ni la comparer.
function HR.DevSafe(v)
    local ok, s = pcall(function() return tostring(v) end)
    return ok and s or "<secret>"
end

function HR.SetDevLog(on)
    local L = ensure()
    L.enabled = on and true or false
    L._full = nil
    if L.enabled then
        L.lines = {}   -- buffer neuf a chaque activation
        L.startedAt = (date and date("%Y-%m-%d %H:%M:%S")) or "?"
        HR.DevLog("session", "=== DEVLOG START %s  addon=%s v%s ===",
            L.startedAt, tostring(addonName), tostring(HR.VERSION))
    end
    return L.enabled
end

-- Vide le buffer SANS changer l'etat actif (le log continue si `enabled`).
function HR.DevLogClear()
    local L = ensure()
    L.lines = {}
    L._full = nil
end

function HR.DevLog(cat, fmt, ...)
    if not (type(ECPDevLog) == "table" and ECPDevLog.enabled) then return end
    local lines = ECPDevLog.lines
    if not lines then return end
    if #lines >= MAX_LINES then
        if not ECPDevLog._full then
            ECPDevLog._full = true
            lines[#lines + 1] = "... [devlog plein, arrete] ..."
        end
        return
    end
    local msg
    if select("#", ...) > 0 then
        local ok, s = pcall(string.format, fmt, ...)
        msg = ok and s or ("<fmt err: " .. HR.DevSafe(fmt) .. ">")
    else
        msg = HR.DevSafe(fmt)
    end
    local t = (GetTime and GetTime()) or 0
    lines[#lines + 1] = string.format("%9.3f [%-8s] %s", t, tostring(cat or "?"), msg)
end

-- Vide une LISTE d'items dans le log : `lineFn(item, index)` renvoie une string (secret-safe
-- a la charge de l'appelant, via HR.DevSafe). Prefixe chaque ligne de `cat`.
function HR.DevLogList(cat, header, list, lineFn)
    if not HR.DevLogEnabled() then return end
    HR.DevLog(cat, "%s (n=%d)", header, #list)
    for i, it in ipairs(list) do
        HR.DevLog(cat, "  [%d] %s", i, lineFn(it, i))
    end
end

-- Apercu chat des N dernieres lignes (sans /reload).
function HR.DevLogShow(n)
    local L = ECPDevLog
    if type(L) ~= "table" or not L.lines or #L.lines == 0 then HR:Print("[devlog] buffer vide."); return end
    n = n or 30
    local from = math.max(1, #L.lines - n + 1)
    HR:Print(("|cff88ccff[devlog]|r %d dernieres / %d :"):format(#L.lines - from + 1, #L.lines))
    for i = from, #L.lines do HR:Print(L.lines[i]) end
end
