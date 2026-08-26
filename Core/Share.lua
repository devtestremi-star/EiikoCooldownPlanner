-- HealPlanner - Core/Share.lua
-- Partage d'un plan (variante active) dans le jeu : diffusion par message addon
-- au groupe/raid + lien cliquable affiche LOCALEMENT chez chaque destinataire.
--
-- Pourquoi un lien local et non un vrai message de chat : le serveur retire les
-- hyperliens custom (|H...|h) des messages de chat reels (filtre securite). On
-- transmet donc le plan par C_ChatInfo.SendAddonMessage (canal addon) et chaque
-- destinataire AFFICHE le lien dans sa propre fenetre. Clic -> apercu -> import.
--
-- Payload minimal : la data statique (defID, encounterID, occKey) est commune aux
-- deux joueurs (meme addon), on ne transmet que { dID, name, comp, assignments }.
-- Encodage natif 12.0 (zero lib externe) : SerializeCBOR -> CompressString(Deflate)
-- -> EncodeBase64. Tout est garde sous pcall (entrees reseau = non fiables).
local addonName, HR = ...

HR.Share = HR.Share or {}
local Share = HR.Share

local PREFIX    = "HealPlanner"   -- prefixe de message addon (<= 16 car.)
local LINK_TYPE = "healplanner"   -- prefixe d'hyperlien custom
local PROTO     = 2               -- version du protocole de partage (2 = format variante V2)
local CHUNK     = 220             -- taille utile par message (marge sous 255 avec l'entete)

-- Page CurseForge de l'addon (lien de telechargement diffuse avec un partage).
-- Envoye en texte BRUT : les addons de chat (Prat / ElvUI) le rendent cliquable cote
-- destinataire, et le serveur retirerait de toute facon un hyperlien custom.
local ADDON_URL = "https://www.curseforge.com/wow/addons/eiikocooldownplanner"

-- Enums d'encodage (12.0). Locales : si absents, on passe nil (valeurs par defaut)
-- de facon coherente entre encodage et decodage.
local DEFLATE = (Enum and Enum.CompressionMethod and Enum.CompressionMethod.Deflate) or nil
local B64     = (Enum and Enum.Base64Variant and Enum.Base64Variant.StandardUrlSafe) or nil

--------------------------------------------------------------------------------
-- Encodage / decodage
--------------------------------------------------------------------------------

-- table -> chaine ASCII transportable. nil en cas d'echec.
local function Encode(value)
    if not C_EncodingUtil then return nil end
    local ok, cbor = pcall(C_EncodingUtil.SerializeCBOR, value)
    if not ok or type(cbor) ~= "string" then return nil end
    local ok2, comp = pcall(C_EncodingUtil.CompressString, cbor, DEFLATE)
    if not ok2 or type(comp) ~= "string" then return nil end
    local ok3, b64 = pcall(C_EncodingUtil.EncodeBase64, comp, B64)
    if not ok3 or type(b64) ~= "string" then return nil end
    return b64
end

-- Chaine d'export partageable d'une variante (MEME encodage que le Share : CBOR -> Deflate ->
-- Base64). Sert a l'export hors-groupe (copier/coller). nil si echec. `Share.BuildPayload` est
-- definie plus bas -> resolue a l'appel (runtime), pas a la definition.
function Share.EncodeVariant(dungeonID, variant)
    local payload = Share.BuildPayload(dungeonID, variant)
    if not payload then return nil end
    return Encode(payload)
end

-- chaine ASCII -> table. nil en cas d'echec (entree corrompue / malveillante).
local function Decode(str)
    if not C_EncodingUtil or type(str) ~= "string" then return nil end
    local ok, comp = pcall(C_EncodingUtil.DecodeBase64, str, B64)
    if not ok or type(comp) ~= "string" then return nil end
    local ok2, cbor = pcall(C_EncodingUtil.DecompressString, comp, DEFLATE)
    if not ok2 or type(cbor) ~= "string" then return nil end
    local ok3, value = pcall(C_EncodingUtil.DeserializeCBOR, cbor)
    if not ok3 then return nil end
    return value
end

-- Chaine d'import (copier/coller) -> payload VALIDE de variante. nil si echec (chaine
-- corrompue / forme invalide / donjon inconnu). Pendant de Share.EncodeVariant.
function Share.DecodeVariant(str)
    local payload = Decode(str)
    if not Share.ValidatePayload(payload) then return nil end
    return payload
end

--------------------------------------------------------------------------------
-- Payload + validation
--------------------------------------------------------------------------------

-- Donjon connu de HR.content ? (id de donjon)
local function IsKnownDungeon(dID)
    for _, d in ipairs(HR.content) do
        if d.id == dID then return true end
    end
    return false
end

-- Construit le payload partageable d'une variante (format V2 : healer + externals + plan).
-- NB : pour les boss multi-timelines (ex. L'ura), les plans des DEUX variantes sont DEJA
-- dans `asg` (cles d'occurrence prefixees par la variante). On ajoute `tlv` = la variante
-- JOUEE choisie par l'emetteur, par boss, pour la transmettre aussi.
function Share.BuildPayload(dungeonID, variant)
    if not dungeonID or not variant then return nil end
    local tlv
    for _, d in ipairs(HR.content) do
        if d.id == dungeonID then
            for _, b in ipairs(d.bosses) do
                if HR.GetTimelineVariants(b) then
                    tlv = tlv or {}
                    tlv[b.id] = HR.GetActiveTimelineVariantId(b)
                end
            end
        end
    end
    return {
        v      = PROTO,
        kind   = "variant",
        dID    = dungeonID,
        name   = variant.name,
        cls    = select(2, UnitClass("player")),  -- classe de l'emetteur (couleur du nom a la reception)
        healer = variant.healer,            -- profil de heal (jeton, ex. "MONK"/"PRIEST_HOLY")
        ext    = variant.externals,         -- { [defKey] = count } (externals de groupe)
        tsp    = variant.talentSpells,      -- { [spellID] = cle_de_variante_de_CD }
        asg    = variant.assignments,       -- [encounterID][occKey] = { {token,offset}, ... }
        tlv    = tlv,                        -- [encounterID] = variante de timeline JOUEE
    }
end

-- Le payload recu est-il exploitable ? (forme V2 + donjon connu)
function Share.ValidatePayload(p)
    if type(p) ~= "table" then return false end
    if p.kind ~= "variant" then return false end
    if type(p.dID) ~= "string" or not IsKnownDungeon(p.dID) then return false end
    -- V2 : profil de heal obligatoire. On exige une clef REELLE (profil connu, ou le
    -- pseudo-profil "No healer" d'une variante DPS/TANK) et pas un simple type string : une
    -- clef inconnue creerait chez le receveur une variante FANTOME, absente du selecteur
    -- (qui n'itere que HR.HEAL_PROFILES + NO_HEALER) donc ni selectionnable ni supprimable.
    if not HR.GetHealProfileOrNone(p.healer) then return false end
    if p.cls ~= nil and type(p.cls) ~= "string" then return false end
    if p.ext ~= nil and type(p.ext) ~= "table" then return false end
    if p.tsp ~= nil and type(p.tsp) ~= "table" then return false end
    if p.asg ~= nil and type(p.asg) ~= "table" then return false end
    if p.tlv ~= nil and type(p.tlv) ~= "table" then return false end
    return true
end

-- Recopie filtree des externals partages : ne garde que les defKey connus, count borne.
function Share.SanitizeExternals(ext)
    local out = {}
    if type(ext) ~= "table" then return out end
    for k, n in pairs(ext) do
        n = tonumber(n)
        if n and n > 0 and HR.defensives[HR.DefKeyOf(k)] then
            out[k] = math.min(20, math.floor(n))
        end
    end
    return out
end

-- Recopie filtree des assignments : on ne garde que les encounterID du donjon,
-- les occKey en chaine et les defID connus de HR.defensives. Tout le reste tombe.
function Share.SanitizeAssignments(dungeonID, asg)
    local out = {}
    if type(asg) ~= "table" then return out end
    local validEnc = {}
    for _, d in ipairs(HR.content) do
        if d.id == dungeonID then
            for _, b in ipairs(d.bosses) do validEnc[b.id] = true end
        end
    end
    for encID, occs in pairs(asg) do
        encID = tonumber(encID) or encID
        if validEnc[encID] and type(occs) == "table" then
            local encOut
            for occKey, defs in pairs(occs) do
                if type(occKey) == "string" and type(defs) == "table" then
                    local list = {}
                    for _, e in ipairs(defs) do
                        local token = HR.EntryToken(e)
                        if token and HR.defensives[HR.DefKeyOf(token)] then
                            local offMax = (HR.OFFSET_MAX_S or 8) * 1000
                            local off = math.max(-offMax, math.min(offMax, HR.EntryOffset(e)))
                            list[#list + 1] = (off ~= 0) and { token = token, offset = off } or { token = token }
                        end
                    end
                    if #list > 0 then
                        encOut = encOut or {}
                        encOut[occKey] = list
                    end
                end
            end
            if encOut then out[encID] = encOut end
        end
    end
    return out
end

-- Compte les defensifs places (pour l'apercu).
function Share.CountAssignments(asg)
    local n = 0
    if type(asg) == "table" then
        for _, occs in pairs(asg) do
            if type(occs) == "table" then
                for _, defs in pairs(occs) do
                    if type(defs) == "table" then n = n + #defs end
                end
            end
        end
    end
    return n
end

-- Compo positionnelle propre depuis un payload : tolere les cles numeriques OU
-- chaines ("1".."5", selon la representation CBOR) et ne garde que des jetons texte.
function Share.NormalizeComp(comp)
    local out = {}
    if type(comp) ~= "table" then return out end
    for i = 1, #HR.COMP_SLOTS do
        local cls = comp[i] or comp[tostring(i)]
        if type(cls) == "string" then out[i] = cls end
    end
    return out
end

-- Cree une variante V2 a partir d'un payload valide. `autodelete` => expire dans 24h (prune).
-- Renvoie (variante, dID) ou nil si invalide.
function Share.ImportPayload(payload, sender, autodelete)
    if not Share.ValidatePayload(payload) then return nil end
    local short = sender and sender:match("^[^-]+") or nil
    local name = payload.name or "Imported plan"
    if type(name) ~= "string" then name = "Imported plan" end
    if short then name = name .. " (" .. short .. ")" end
    local asg = Share.SanitizeAssignments(payload.dID, payload.asg)
    local ext = Share.SanitizeExternals(payload.ext)
    local tsp = (type(payload.tsp) == "table") and payload.tsp or {}
    local expires
    if autodelete then expires = ((GetServerTime and GetServerTime()) or time()) + 24 * 3600 end
    local v = HR.V2_ImportVariant(payload.dID, name, payload.healer, ext, tsp, asg, expires)
    if not v then return nil end
    -- Applique le choix de variante de timeline JOUEE de l'emetteur (par boss du donjon).
    if type(payload.tlv) == "table" then
        for encID, vid in pairs(payload.tlv) do
            encID = tonumber(encID) or encID
            if type(vid) == "string" then HR.SetActiveTimelineVariant(encID, vid) end
        end
    end
    return v, payload.dID
end

--------------------------------------------------------------------------------
-- Emission (file d'envoi : 1 message par frame pour menager le limiteur)
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

-- Canal de diffusion + cible eventuelle. En solo + debug : whisper a soi-meme
-- (echo local) pour tester toute la chaine encode -> decoupe -> reassemblage.
local function GroupChannel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    if HR.debug then return "WHISPER", UnitName("player") end
    return nil
end

-- Partage la variante active au groupe/raid.
function Share.ShareVariant(dungeonID, variant)
    local channel, target = GroupChannel()
    if not channel then
        HR:Print("You must be in a party or raid to share a plan.")
        return false
    end
    if not variant then return false end
    local data = Encode(Share.BuildPayload(dungeonID, variant))
    if not data then
        HR:Print("Failed to encode the plan (C_EncodingUtil unavailable?).")
        return false
    end
    -- Identifiant de partage unique cote emetteur : sel temporel + compteur.
    Share.counter = (Share.counter or 0) + 1
    local shareId = math.floor(GetTime()) .. "-" .. Share.counter
    local total = math.ceil(#data / CHUNK)
    for i = 1, total do
        local chunk = data:sub((i - 1) * CHUNK + 1, i * CHUNK)
        -- entete : proto \t shareId \t seq \t total \t chunk  (\t hors alphabet base64)
        local text = ("%d\t%s\t%d\t%d\t%s"):format(PROTO, shareId, i, total, chunk)
        sendQueue[#sendQueue + 1] = { text = text, channel = channel, target = target }
    end
    sender:Show()

    -- Annonce publique dans le canal de GROUPE (texte simple, prefixe addon). Le lien
    -- d'import cliquable, lui, reste LOCAL chez chaque destinataire (le serveur retire les
    -- liens custom du chat reel) -> cf. AnnounceIncoming.
    if channel == "PARTY" or channel == "RAID" then
        SendChatMessage(
            ("[EiikoCooldownPlanner - ECP] : %s shared a healing plan. Download ECP at %s")
                :format(UnitName("player"), ADDON_URL),
            channel)
    end

    return true
end

--------------------------------------------------------------------------------
-- Reception (reassemblage des morceaux) + lien cliquable local
--------------------------------------------------------------------------------

local inbox = {}          -- inbox[sender.."|"..shareId] = { parts, total, got }
Share.received = {}       -- received[idx] = { payload, sender }  (apres reassemblage)

-- Affiche un VRAI message de chat (prefixe addon) qui MIME une ligne de chat :
--   ECP: <Nom-Royaume en couleur de classe>  [Import: <plan>]
-- Clic -> modale d'import (cf. OnSetItemRef). Le lien custom ne survit pas au chat reel
-- (filtre serveur) -> message LOCAL chez chaque destinataire.
local function AnnounceIncoming(idx, payload, senderName)
    local who   = tostring(senderName or "?"):gsub("|", "")          -- "Nom-Royaume" (pas de | : casserait le lien)
    local name  = tostring(payload.name or "Plan"):gsub("|", "")
    if #name > 40 then name = name:sub(1, 40) end
    local who_c = ("|c%s%s|r"):format(HR.ClassColorHex(payload.cls), who)   -- nom en couleur de classe (blanc si inconnue)
    local link  = ("|H%s:%d|h|cff33ff99[Import: %s]|r|h"):format(LINK_TYPE, idx, name)
    DEFAULT_CHAT_FRAME:AddMessage(("%s%s  %s"):format(HR.CHAT_PREFIX, who_c, link))
end

local function OnAddonMsg(self, prefix, text, channel, senderName)
    if prefix ~= PREFIX or type(text) ~= "string" then return end
    -- Ignorer son propre partage (on recoit ses propres messages addon).
    -- En mode debug, on se laisse recevoir soi-meme pour tester en solo.
    if not HR.debug and senderName and senderName:match("^[^-]+") == UnitName("player") then return end

    local proto, shareId, seq, total, chunk =
        text:match("^(%d+)\t([^\t]+)\t(%d+)\t(%d+)\t(.*)$")
    if not proto or tonumber(proto) ~= PROTO then return end
    seq, total = tonumber(seq), tonumber(total)
    if not seq or not total or total < 1 or total > 500 or seq < 1 or seq > total then return end

    local key = (senderName or "?") .. "|" .. shareId
    local rec = inbox[key]
    if not rec then rec = { parts = {}, total = total, got = 0 }; inbox[key] = rec end
    if rec.parts[seq] == nil then
        rec.parts[seq] = chunk
        rec.got = rec.got + 1
    end
    if rec.got < rec.total then return end

    inbox[key] = nil
    local payload = Decode(table.concat(rec.parts))
    if not Share.ValidatePayload(payload) then return end

    local idx = #Share.received + 1
    Share.received[idx] = { payload = payload, sender = senderName }
    AnnounceIncoming(idx, payload, senderName)
end

-- Clic sur un lien custom : ouvre l'apercu d'import.
local function OnSetItemRef(link)
    if type(link) ~= "string" then return end
    local idx = link:match("^" .. LINK_TYPE .. ":(%d+)$")
    if not idx then return end
    local rec = Share.received[tonumber(idx)]
    if not rec then
        HR:Print("This shared plan is no longer available (ask for a new share).")
        return
    end
    if HR.UI and HR.UI.OpenImportPreview then
        HR.UI.OpenImportPreview(rec.payload, rec.sender)
    end
end

--------------------------------------------------------------------------------
-- Init (appele depuis Core.lua / OnInitialize)
--------------------------------------------------------------------------------

function HR.InitShare()
    if Share.initialized then return end
    Share.initialized = true
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    end
    HR:RegisterEvent("CHAT_MSG_ADDON", OnAddonMsg)
    hooksecurefunc("SetItemRef", OnSetItemRef)
end
