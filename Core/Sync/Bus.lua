-- EiikoCooldownPlanner - Core/Sync/Bus.lua
-- Bus d'evenements INTERNE de l'addon. A ne pas confondre avec Core/Events.lua, qui
-- route les evenements du JEU (HR:RegisterEvent) : ici il s'agit d'evenements que
-- l'addon s'envoie a lui-meme.
--
-- Deux regles d'architecture, tenues a partir d'ici :
--   1. AUCUN listener n'est ecrit dans le code metier. Ils vivent tous dans
--      Core/Sync/Listeners.lua, qui est le SEUL site d'enregistrement.
--   2. Le code metier n'a droit qu'a HR.EmitEvent(NOM, payload) ; un fichier de
--      fonctions prend le relais derriere.
-- Sens des dependances : Listeners -> Handshake -> Net -> Bus -> code existant.
-- Ce fichier ne connait AUCUN metier : il ne fait que distribuer.
local addonName, HR = ...

-- Noms d'evenements. Passer par cette table plutot que par des chaines litterales :
-- une faute de frappe sur une chaine est silencieuse (personne n'ecoute, rien ne
-- casse), une faute sur HR.EV.X vaut nil et se voit tout de suite.
HR.EV = {
    HANDSHAKE_REQUEST = "ECP_HANDSHAKE_REQUEST",  -- emis par le code metier (slash, futur bouton)
    NET_MESSAGE       = "ECP_NET_MESSAGE",        -- emis par le transport : message ECPSync complet
    PLAN_SHARED       = "ECP_PLAN_SHARED",        -- emis par l'UI (bouton Sync) : pousser la variante affichee
    -- Accuses emis par le DESTINATAIRE d'un plan, renvoyes a l'emetteur (mise en scene de
    -- la modale de progression) : { to = <emetteur>, msgId = <poussee>, status = <etat> }.
    -- Deux evenements SEULEMENT : l'etat est une INFORMATION dans la reponse, pas un
    -- evenement de plus. `status` : "" (recu) / "PENDING" (j'attends l'accord de mon joueur)
    -- pour START ; "OK" (applique) / "DENIED" (refuse) pour OVER.
    SYNC_START        = "ECP_SYNC_START",         -- "j'ai recu la demande de sync"
    SYNC_OVER         = "ECP_SYNC_OVER",          -- "c'est fini" (applique ou refuse)
    -- Collecte des stats du groupe (Core/Sync/Stats.lua) : chaque client lit les SIENNES
    -- (UnitArmor/UnitStat sont "player"-only) et les renvoie a l'emetteur seul.
    STATS_REQUEST     = "ECP_STATS_REQUEST",      -- emis par le code metier (/ecp stats)
}

-- handlers[nom] = { fn, ... }
local handlers = {}

-- Enregistre un handler. Reserve a Core/Sync/Listeners.lua (cf. regle 1).
function HR.OnEvent(name, fn)
    if type(name) ~= "string" or type(fn) ~= "function" then return end
    local list = handlers[name]
    if not list then
        list = {}
        handlers[name] = list
    end
    list[#list + 1] = fn
end

-- Distribue `payload` a tous les handlers de `name`. Renvoie le nombre de handlers
-- appeles sans erreur.
--
-- pcall PAR handler, non negociable : ces evenements sont alimentes par le RESEAU.
-- Un handler qui pete sur un message malforme ne doit ni couper la chaine (les
-- suivants doivent tourner) ni remonter une erreur Lua au joueur. L'erreur part dans
-- le debug, pas dans le chat.
function HR.EmitEvent(name, payload)
    local list = handlers[name]
    if not list then return 0 end
    local n = 0
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn, payload)
        if ok then
            n = n + 1
        else
            HR:Debug("[bus]", tostring(name), tostring(err))
        end
    end
    return n
end
