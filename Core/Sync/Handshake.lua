-- EiikoCooldownPlanner - Core/Sync/Handshake.lua
-- HELLO / HELLO_ACK : qui, dans le groupe, fait tourner l'addon, et en quelle version.
-- Premier message du canal de synchro (cf. docs plan-sync-vivante.md, section 2).
--
-- Deroule d'une passe :
--   /ecp handshake -> HR.EmitEvent(HANDSHAKE_REQUEST) -> Broadcast() diffuse HELLO au
--   groupe ; chaque client equipe repond HELLO_ACK sur le canal ADDON adresse a
--   l'emetteur (invisible dans le chat de qui que ce soit) ; l'emetteur IMPRIME chaque
--   reponse des son arrivee, puis Close() liste a T+5s ceux qui n'ont pas repondu.
--
-- AUCUNE ecriture en DB : l'etat d'une passe est volatile (HR.Sync.roster + `pass`).
-- Ce fichier n'enregistre AUCUN listener : c'est Core/Sync/Listeners.lua qui l'appelle.
local addonName, HR = ...

HR.Sync = HR.Sync or {}
HR.Sync.Handshake = HR.Sync.Handshake or {}
local Handshake = HR.Sync.Handshake
local Net = HR.Sync.Net

local WINDOW = 5    -- (s) duree d'une passe : au-dela, les reponses sont marquees (late)

-- Dernier etat connu du groupe : roster["Nom-Royaume"] = { version, at }. Volatile,
-- remis a zero a chaque passe. Consomme pour l'instant par le seul affichage chat ;
-- le panneau d'etat de l'emetteur (section 5 du plan) le lira tel quel.
HR.Sync.roster = HR.Sync.roster or {}

-- Passe en cours : { msgId, at, channel, selfEcho, seen = { [nom] = true } }. nil = aucune.
local pass = nil

-- Nom qualifie "Nom-Royaume". Les trois sources de nom (reponse addon qualifiee,
-- UnitName nu, UnitFullName) ne se comparent pas brutes -- piege deja documente dans
-- Core/Keystones.lua, dont on reutilise le normaliseur.
local function qualified(name, realm)
    if HR.Keys and HR.Keys.QualifiedName then return HR.Keys.QualifiedName(name, realm) end
    if not name or name == "" then return nil end
    if realm and realm ~= "" then return name .. "-" .. realm end
    if name:find("-", 1, true) then return name end
    return name .. "-" .. (GetNormalizedRealmName() or "")
end

--------------------------------------------------------------------------------
-- Emission
--------------------------------------------------------------------------------

-- Ouvre une passe : diffuse HELLO et arme la fermeture. `reason` = origine de la
-- demande (slash, futur bouton) -- purement informatif, journalise en debug.
function Handshake.Broadcast(reason)
    local channel, target = Net.GroupChannel()
    local selfEcho = (channel == "WHISPER")

    wipe(HR.Sync.roster)
    local msgId = Net.NewMsgId()
    pass = { msgId = msgId, at = GetTime(), channel = channel, selfEcho = selfEcho, seen = {} }

    if not Net.Send("HELLO", HR.VERSION, channel, target, msgId) then
        pass = nil
        HR:Print("Handshake failed to send.")
        return
    end

    HR.RebuildGroup()
    HR:Debug("[sync] handshake", tostring(reason), msgId)
    HR:Print(("Handshake sent to %s (%d member%s). Replies:")
        :format(selfEcho and "yourself (solo)" or channel,
                #HR.group, (#HR.group == 1) and "" or "s"))

    -- On ne recoit pas de reponse de SOI-MEME en groupe (nos propres messages addon sont
    -- ignores) -> sans ce seed, l'emetteur se listerait lui-meme en "no addon". En solo,
    -- au contraire, l'echo local fait le tour complet : on le laisse repondre.
    if not selfEcho then
        local me = qualified(UnitFullName("player"))
        if me then
            HR.Sync.roster[me] = { version = HR.VERSION, at = GetTime() }
            pass.seen[me] = true
            HR:Print(("  %-24s %sv%s%s"):format(me, HR.COLORS.GREEN, HR.VERSION, HR.COLORS.RESET))
        end
    end

    C_Timer.After(WINDOW, function() Handshake.Close(msgId) end)
end

--------------------------------------------------------------------------------
-- Reception
--------------------------------------------------------------------------------

-- Quelqu'un demande qui a l'addon : on repond a LUI SEUL, sur le canal addon
-- ("WHISPER" = adressage du message addon, pas un chuchotement visible). Jamais de
-- diffusion en reponse : les 3 autres membres n'ont rien a reassembler.
function Handshake.OnHello(from, body, msgId)
    if type(from) ~= "string" or from == "" then return end
    HR:Debug("[sync] HELLO from", from, "v" .. tostring(body))
    Net.Send("HELLO_ACK", HR.VERSION, "WHISPER", from, msgId)
end

-- Une reponse arrive : on l'imprime TOUT DE SUITE (pas de rapport differe) et on la
-- memorise. Une reponse hors passe courante (client lent, passe deja fermee) est
-- imprimee avec la mention (late) plutot que jetee.
function Handshake.OnAck(from, body, msgId)
    local name = qualified(from)
    if not name then return end

    -- Version = ce que l'autre DECLARE : on la borne a un motif inoffensif avant de
    -- l'afficher (entree reseau).
    local version = tostring(body or ""):match("^[%w%.%-_]+") or "?"
    if #version > 20 then version = version:sub(1, 20) end

    local late = not (pass and pass.msgId == msgId)
    if not late then
        if pass.seen[name] then return end   -- deuxieme ACK du meme joueur : une seule ligne
        pass.seen[name] = true
    end

    HR.Sync.roster[name] = { version = version, at = GetTime() }
    HR:Print(("  %-24s %sv%s%s%s")
        :format(name, HR.COLORS.GREEN, version, HR.COLORS.RESET,
                late and (" " .. HR.COLORS.YELLOW .. "(late)" .. HR.COLORS.RESET) or ""))
end

-- Fermeture de la passe (T+WINDOW) : liste ceux qui n'ont pas repondu. Rien n'est
-- re-imprime pour ceux qui ont deja repondu.
function Handshake.Close(msgId)
    if not pass or pass.msgId ~= msgId then return end
    pass = nil

    HR.RebuildGroup()
    local total, answered = 0, 0
    for _, m in ipairs(HR.group) do
        local qn = m.unit and qualified(UnitFullName(m.unit))
        if qn then
            total = total + 1
            if HR.Sync.roster[qn] then
                answered = answered + 1
            else
                HR:Print(("  %-24s %sno addon%s"):format(qn, HR.COLORS.RED, HR.COLORS.RESET))
            end
        end
    end
    HR:Print(("Handshake done: %d/%d with ECP."):format(answered, total))
end
