-- EiikoCooldownPlanner - Core/Sync/Net.lua
-- Transport du canal de SYNCHRO (prefixe "ECPSync"). Rien de metier ici : on encode
-- une trame, on la decoupe, on l'envoie, on la reassemble.
--
-- Pourquoi un SECOND prefixe et non l'extension de Core/Share.lua (prefixe
-- "HealPlanner", PROTO 2) : le partage par lien est deploye chez des joueurs. Toucher
-- a son entete casserait la compatibilite entre versions de l'addon pour un gain nul.
-- Deux prefixes coexistent sans difficulte (RegisterAddonMessagePrefix par prefixe).
--
-- La file d'envoi (1 message par frame, pour menager le limiteur du serveur) reprend
-- la FORME de celle de Share.lua sans la partager : exporter la file de Share
-- obligerait le code existant a dependre du nouveau code, ce que l'architecture
-- interdit (cf. Core/Sync/Bus.lua). ~15 lignes dupliquees, assumees.
local addonName, HR = ...

HR.Sync = HR.Sync or {}
HR.Sync.Net = HR.Sync.Net or {}
local Net = HR.Sync.Net

local PREFIX = "ECPSync"   -- prefixe de message addon (<= 16 car.)
local PROTO  = 1           -- version du protocole de synchro
local CHUNK  = 220         -- PLAFOND de taille utile (la taille reelle est calculee dans Send)
local MAX_MSG = 255        -- limite dure d'un message addon (au-dela : rejet silencieux)

Net.PREFIX = PREFIX
Net.PROTO  = PROTO

--------------------------------------------------------------------------------
-- Emission
--------------------------------------------------------------------------------

local sendQueue = {}
local sender = CreateFrame("Frame")
sender:Hide()
sender:SetScript("OnUpdate", function(self)
    local m = table.remove(sendQueue, 1)
    if not m then self:Hide() return end
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(PREFIX, m.text, m.channel, m.target)
    end
end)

-- Canal de diffusion + cible eventuelle, ou nil quand il n'y a PERSONNE a qui parler.
-- SOLO = nil, et c'est delibere : l'echo local (message addon adresse a soi-meme) faisait
-- suivre a la poussee tout le chemin de RECEPTION, donc l'auto-import -- on se creait une
-- variante "SYNC" en double dans sa propre DB pour un plan qu'on possede deja. L'echo
-- reste disponible, mais SEULEMENT sous HR.debug (HealPlannerDB.debug, restaure au load
-- par Core/Database.lua) : c'est un outil de dev -- exercer la chaine trame/decoupe/
-- reassemblage/aiguillage sans second client --, pas un mode de jeu.
-- Chaque appelant doit donc traiter le nil (cf. PlanSync.Push, Handshake.Broadcast).
function Net.GroupChannel()
    -- Categorie HOME UNIQUEMENT (le groupe qu'on a FORME : invitations, guilde, premade M+).
    -- Un groupe d'INSTANCE (donjon aleatoire, LFR : LE_PARTY_CATEGORY_INSTANCE, canal
    -- INSTANCE_CHAT) est deliberement hors perimetre -- on ne pousse pas un plan, qui plus
    -- est importe d'office, a des inconnus mis la par une file.
    -- Passer la categorie explicitement compte : sans argument, IsInGroup() repond "oui" pour
    -- un groupe de file, on prendrait la branche PARTY et le serveur jetterait le message
    -- sans erreur (canal auquel on n'appartient pas). Ici, pas de groupe HOME = rien a pousser
    -- -> nil (ou l'echo local si le mode debug est actif).
    local HOME = LE_PARTY_CATEGORY_HOME or 1
    if IsInRaid(HOME) then return "RAID" end
    if IsInGroup(HOME) then return "PARTY" end
    if HR.debug then return "WHISPER", UnitName("player") end   -- echo local : dev uniquement
    return nil
end

-- Y a-t-il quelqu'un a qui pousser quelque chose ? (l'UI s'en sert pour griser le bouton
-- Sync ; la decision qui fait foi reste celle de GroupChannel, cote emission)
function Net.HasAudience()
    return Net.GroupChannel() ~= nil
end

-- msgId envoyes a NOUS-MEMES (echo local en solo). Le listener s'en sert pour accepter nos
-- PROPRES messages addon, normalement ignores. Borne : purge au-dela de 50 entrees.
local selfEcho, selfEchoN = {}, 0

-- Ce message est-il l'echo local d'un envoi que NOUS venons de faire a nous-memes ?
function Net.IsSelfEcho(msgId)
    return msgId ~= nil and selfEcho[msgId] == true
end

-- Racine d'identite du joueur, derivee du GUID : STABLE entre sessions, la ou GetTime() et
-- un compteur memoire repartent a zero a chaque lancement (deux /reload pouvaient donc
-- refrapper le meme id). On ne transporte PAS le GUID entier : l'entete voyage sur CHAQUE
-- morceau et un message addon est plafonne a 255 octets -- 16 (entete) + 20 (GUID) + 220
-- (charge) = 256, soit un rejet silencieux. On garde royaume + 5 derniers hex de l'id de
-- perso : 1 chance sur ~1e6 de collision, pour un groupe de 5.
local sessionTag
local function SessionTag()
    if sessionTag then return sessionTag end
    local guid = UnitGUID("player")
    if not guid then return "0" end                      -- pas encore dans le monde : pas de cache
    local realm, cid = guid:match("^Player%-(%d+)%-(%x+)$")
    sessionTag = (realm and cid) and (realm .. cid:sub(-5)) or (guid:gsub("%W", "")):sub(-8)
    return sessionTag
end

-- Identifiant de poussee : <racine GUID>:<compteur PERSISTANT>. Le compteur distingue deux
-- poussees successives du MEME joueur -- sans lui, l'accuse d'une poussee marquerait la
-- suivante comme reussie. Persiste dans la DB (cle additive) pour survivre au /reload.
local memCounter = 0
function Net.NewMsgId()
    local n
    local db = HR.db2
    if db then
        db.syncCounter = (db.syncCounter or 0) + 1
        n = db.syncCounter
    else
        memCounter = memCounter + 1                      -- repli : DB pas encore initialisee
        n = memCounter
    end
    return SessionTag() .. ":" .. n
end

-- Envoie `body` (chaine) sous le type `kind`, decoupe en morceaux de CHUNK octets.
-- Trame : proto \t kind \t msgId \t seq \t total \t body   (\t hors alphabet base64,
-- comme le canal de partage existant -> un corps encode ne peut pas casser l'entete).
-- Renvoie le msgId utilise (utile pour correler une reponse), nil si l'envoi est refuse.
function Net.Send(kind, body, channel, target, msgId)
    if type(kind) ~= "string" or kind == "" or kind:find("\t", 1, true) then return nil end
    if type(channel) ~= "string" then return nil end
    body = tostring(body or "")
    msgId = msgId or Net.NewMsgId()
    if channel == "WHISPER" and target and target == UnitName("player") then
        if selfEchoN > 50 then wipe(selfEcho); selfEchoN = 0 end
        selfEcho[msgId] = true
        selfEchoN = selfEchoN + 1
    end
    -- Taille utile CALCULEE depuis l'entete reel : `kind` et `msgId` sont de longueur
    -- variable, et un message addon est rejete au-dela de 255 octets. CHUNK devient donc
    -- un PLAFOND, pas une constante -- la trame ne peut plus deborder, quel que soit l'id.
    local overhead = #(("%d\t%s\t%s\t\t\t"):format(PROTO, kind, msgId)) + 8   -- +8 : seq/total + marge
    local size = math.max(32, math.min(CHUNK, MAX_MSG - overhead))

    local total = math.max(1, math.ceil(#body / size))
    for i = 1, total do
        local chunk = body:sub((i - 1) * size + 1, i * size)
        local text = ("%d\t%s\t%s\t%d\t%d\t%s"):format(PROTO, kind, msgId, i, total, chunk)
        sendQueue[#sendQueue + 1] = { text = text, channel = channel, target = target }
    end
    sender:Show()
    return msgId
end

--------------------------------------------------------------------------------
-- Reception (reassemblage des morceaux)
--------------------------------------------------------------------------------

-- inbox[expediteur.."|"..msgId] = { parts, total, got }
local inbox = {}

-- Consomme un message brut. Renvoie (kind, body, msgId) quand le message est COMPLET,
-- nil sinon (morceau intermediaire, trame etrangere, ou entree malformee).
-- Le corps recu est traite comme hostile : parse par motif, bornes strictes, aucune
-- indexation de table sans validation. L'expediteur est TOUJOURS celui fourni par
-- CHAT_MSG_ADDON, jamais un nom auto-declare dans le corps.
function Net.Ingest(text, from)
    if type(text) ~= "string" then return nil end
    local proto, kind, msgId, seq, total, chunk =
        text:match("^(%d+)\t([^\t]+)\t([^\t]+)\t(%d+)\t(%d+)\t(.*)$")
    if not proto or tonumber(proto) ~= PROTO then return nil end
    seq, total = tonumber(seq), tonumber(total)
    if not seq or not total or total < 1 or total > 500 or seq < 1 or seq > total then return nil end

    -- Cas courant (handshake et toutes les requetes courtes) : un seul morceau.
    if total == 1 then return kind, chunk, msgId end

    local key = (from or "?") .. "|" .. msgId
    local rec = inbox[key]
    if not rec then
        rec = { parts = {}, total = total, got = 0, kind = kind }
        inbox[key] = rec
    end
    if rec.parts[seq] == nil then
        rec.parts[seq] = chunk
        rec.got = rec.got + 1
    end
    if rec.got < rec.total then return nil end

    inbox[key] = nil
    return rec.kind, table.concat(rec.parts), msgId
end

--------------------------------------------------------------------------------
-- Amorcage
--------------------------------------------------------------------------------

-- Au chargement du fichier : pas d'appel depuis Core/Core.lua, pour que OnInitialize
-- reste ignorant de ce canal (le code existant ne pointe pas vers Core/Sync/*).
if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
end
