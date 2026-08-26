-- EiikoCooldownPlanner - Core/Share.lua
-- CODEC de plan : serialisation, validation et import d'une variante. Aucun transport
-- ici -- le partage par lien (diffusion PROTO 2 + hyperlien |Hhealplanner:|h + apercu)
-- a ete RETIRE au profit du canal de synchro (bouton Sync, cf. Core/Sync/). Ce fichier
-- ne garde que ce qui sert encore, a deux consommateurs :
--   * Core/Sync/PlanSync.lua  -- encode la poussee, valide et importe la reception ;
--   * UI/HealerSpecs.lua      -- modales Export / Import (chaine copiable).
--
-- Payload minimal : la data statique (defID, encounterID, occKey) est commune aux
-- deux joueurs (meme addon), on ne transmet que { dID, name, healer, assignments... }.
-- Encodage natif 12.0 (zero lib externe) : SerializeCBOR -> CompressString(Deflate)
-- -> EncodeBase64. Tout est garde sous pcall (entrees reseau = non fiables).
local addonName, HR = ...

HR.Share = HR.Share or {}
local Share = HR.Share

local PROTO = 2   -- version du format de PAYLOAD (2 = variante V2). Sans rapport avec le
                  -- protocole de transport de la synchro (Core/Sync/Net.lua, PROTO 1).

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
    if p.cls ~= nil and type(p.cls) ~= "string" then return false end   -- ancien champ : tolere a la lecture
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

