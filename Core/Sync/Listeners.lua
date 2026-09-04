-- EiikoCooldownPlanner - Core/Sync/Listeners.lua
-- SEUL site d'enregistrement de listeners du canal de synchro : evenements du JEU
-- (HR:RegisterEvent) comme evenements du BUS interne (HR.OnEvent). Aucun autre fichier
-- de Core/Sync/ n'enregistre quoi que ce soit, et aucun code metier non plus.
--
-- Ces listeners APPELLENT le code existant (HR.Sync.Net, HR.Sync.Handshake, HR:Debug) ;
-- l'inverse est interdit : rien ne doit appeler dans ce fichier. Le seul chemin vers
-- ici depuis le metier est HR.EmitEvent(HR.EV.*, payload).
local addonName, HR = ...

local Net = HR.Sync.Net
local Handshake = HR.Sync.Handshake
local PlanSync = HR.Sync.Plan
local Stats = HR.Sync.Stats

-- Ce message vient-il de nous ? On recoit ses PROPRES messages addon. Meme test (et
-- meme limite : un homonyme d'un autre royaume) que Core/Share.lua.
local function IsSelf(from)
    if type(from) ~= "string" then return false end
    return from:match("^[^-]+") == UnitName("player")
end

-- CHAT_MSG_ADDON : filtre le prefixe, reassemble, puis publie sur le bus. Ce handler ne
-- connait AUCUN type de message : l'aiguillage se fait plus bas.
local function OnAddonMessage(_, prefix, text, channel, from)
    if prefix ~= Net.PREFIX then return end
    local kind, body, msgId = Net.Ingest(text, from)
    if not kind then return end
    -- Nos propres messages sont ignores, SAUF quand c'est l'echo local d'un envoi qu'on
    -- vient de s'adresser (test en solo) ou en debug.
    if IsSelf(from) and not HR.debug and not Net.IsSelfEcho(msgId) then return end
    HR.EmitEvent(HR.EV.NET_MESSAGE, {
        kind    = kind,
        body    = body,
        msgId   = msgId,
        sender  = from,
        channel = channel,
    })
end

-- Aiguillage par type de message. Les nouveaux messages du plan de synchro (HAS?,
-- PAUTH?, UAUTH?, EDIT) s'ajoutent ici, une ligne chacun.
local function OnNetMessage(p)
    if type(p) ~= "table" then return end
    if p.kind == "HELLO" then
        Handshake.OnHello(p.sender, p.body, p.msgId)
    elseif p.kind == "PLAN" then
        PlanSync.OnPlan(p.sender, p.body, p.msgId)
    elseif p.kind == "SYNC_START" then
        PlanSync.OnPeerStart(p.sender, p.msgId, p.body)
    elseif p.kind == "SYNC_OVER" then
        PlanSync.OnPeerOver(p.sender, p.msgId, p.body)
    elseif p.kind == "HELLO_ACK" then
        Handshake.OnAck(p.sender, p.body, p.msgId)
    elseif p.kind == "STATS?" then
        Stats.OnRequest(p.sender, p.body, p.msgId)
    elseif p.kind == "STATS" then
        Stats.OnReply(p.sender, p.body, p.msgId)
    else
        HR:Debug("[sync] unknown kind", tostring(p.kind), "from", tostring(p.sender))
    end
end

-- Poussee d'un plan emise par le code metier (bouton Sync de la barre de variantes).
local function OnPlanShared(p)
    if type(p) ~= "table" then return end
    PlanSync.Push(p.dID, p.variant)
end

-- Accuses emis par le DESTINATAIRE d'un plan : renvoyes a l'emetteur SEUL, sur le canal
-- addon (invisible dans le chat), avec le msgId de la poussee pour la correlation.
local function SendAck(kind)
    return function(p)
        if type(p) ~= "table" or type(p.to) ~= "string" then return end
        -- Le corps porte l'ETAT (cf. HR.EV) : borne a un jeton simple, c'est une valeur
        -- affichee chez l'autre joueur.
        local status = (type(p.status) == "string") and p.status:match("^%u+") or ""
        Net.Send(kind, status, "WHISPER", p.to, p.msgId)
    end
end

-- Demande de handshake emise par le code metier (/ecp handshake, futur bouton).
local function OnHandshakeRequest(p)
    Handshake.Broadcast(type(p) == "table" and p.reason or nil)
end

-- Demande de collecte des stats emise par le code metier (/ecp stats).
local function OnStatsRequest(p)
    Stats.Broadcast(type(p) == "table" and p.reason or nil)
end

-- Peremption du snapshot local. Les stats defensives ne sont lisibles que HORS COMBAT
-- (predicat SecretWhenUnitStatsRestricted) : on ne recalcule donc pas a la demande, on
-- invalide sur les trois evenements qui peuvent les changer et le prochain Stats.Mine()
-- refait le travail. Comme tout le reste du canal, l'enregistrement vit ICI.
local function OnStatsDirty()
    Stats.Invalidate()
end

--------------------------------------------------------------------------------
-- Enregistrements (au chargement du fichier)
--
-- PLAYER_LOGIN est inutilisable comme point d'amorcage : Core/Events.lua le consomme
-- pour appeler OnInitialize et sort AVANT le dispatch -> un handler PLAYER_LOGIN ne
-- fire jamais.
--------------------------------------------------------------------------------

HR:RegisterEvent("CHAT_MSG_ADDON", OnAddonMessage)
HR.OnEvent(HR.EV.NET_MESSAGE, OnNetMessage)
HR.OnEvent(HR.EV.HANDSHAKE_REQUEST, OnHandshakeRequest)
HR.OnEvent(HR.EV.PLAN_SHARED, OnPlanShared)
HR.OnEvent(HR.EV.SYNC_START, SendAck("SYNC_START"))
HR.OnEvent(HR.EV.SYNC_OVER,  SendAck("SYNC_OVER"))

HR.OnEvent(HR.EV.STATS_REQUEST, OnStatsRequest)
HR:RegisterEvent("PLAYER_REGEN_ENABLED", OnStatsDirty)          -- sortie de combat
HR:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", OnStatsDirty)
HR:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", OnStatsDirty)
