-- EiikoCooldownPlanner - Core/Sync/PlanSync.lua
-- Message PLAN du canal de synchro : POUSSER la variante affichee au groupe. Chez chaque
-- destinataire, le plan est importe SANS RIEN DEMANDER et pose en variante ACTIVE (etoile).
--
-- Etape volontairement BRUTE : aucune autorisation, aucune invite, aucun apercu (les
-- garde-fous PAUTH?/UAUTH? et le verrou de lecture seule viennent apres). C'est en revanche
-- le PREMIER code qui ecrit dans la DB d'un autre joueur depuis le reseau, d'ou la cible
-- d'ecriture strictement bornee ci-dessous.
--
-- CIBLE D'ECRITURE -- les id de variante sont des COMPTEURS LOCAUX (db2.nextId,
-- Core/Plan2.lua) : la n7 de l'emetteur n'a aucun rapport avec la n7 du receveur. Ecrire a
-- l'id brut detruirait un plan personnel. L'identite partagee est donc (EXPEDITEUR, id
-- distant), l'expediteur etant TOUJOURS celui fourni par CHAT_MSG_ADDON :
--     db2.syncImports[dID]["Eiiko-Hyjal:7"] = 42     -- 42 = id de la variante LOCALE
-- Sans entree dans cet index, AUCUNE ecriture : une variante que le joueur a creee lui-meme
-- n'y figure jamais. Cle additive (creee a la volee), aucun bump de schema.
--
-- Ce fichier n'enregistre AUCUN listener : c'est Core/Sync/Listeners.lua qui l'appelle.
local addonName, HR = ...

HR.Sync = HR.Sync or {}
HR.Sync.Plan = HR.Sync.Plan or {}
local PlanSync = HR.Sync.Plan
local Net = HR.Sync.Net

local EXPIRE = 24 * 3600   -- (s) autodelete, comme l'import manuel coche par defaut

-- Nom qualifie "Nom-Royaume" (normaliseur partage, cf. Core/Keystones.lua).
local function qualified(name, realm)
    if HR.Keys and HR.Keys.QualifiedName then return HR.Keys.QualifiedName(name, realm) or name end
    return name
end

-- Nom lisible d'un donjon (pour le sous-titre de la modale de progression).
local function DungeonName(dID)
    for _, d in ipairs(HR.content or {}) do
        if d.id == dID then return d.name end
    end
    return nil
end

-- Nom court de l'emetteur, suffixe au nom du plan (meme forme que Share.ImportPayload).
local function shortName(sender)
    return (type(sender) == "string") and sender:match("^[^-]+") or nil
end

--------------------------------------------------------------------------------
-- Emission
--------------------------------------------------------------------------------

-- Diffuse la variante au groupe. Reutilise TEL QUEL l'encodeur du partage par lien
-- (HR.Share.EncodeVariant : BuildPayload -> CBOR -> Deflate -> Base64) ; l'id distant
-- voyage dans le corps de la trame, PAS dans le CBOR, pour ne rien changer au format du
-- canal de partage deja deploye chez les joueurs.
function PlanSync.Push(dID, variant)
    if not dID or not variant then
        HR:Print("Open a dungeon and select a variant before syncing.")
        return
    end
    -- GATE D'EMISSION : on ne pousse que SON PROPRE plan. Sans ca, n'importe quel membre
    -- pourrait renvoyer au groupe la variante qu'il vient de recevoir -- avec lui comme
    -- expediteur, donc sous une autre identite de sync, donc en doublon chez tout le monde.
    if variant.synced then
        HR:Print(("This plan comes from %s -- duplicate it to make it yours before syncing.")
            :format((variant.syncFrom and shortName(variant.syncFrom.name)) or "another player"))
        return
    end
    local data = HR.Share and HR.Share.EncodeVariant(dID, variant)
    if not data then
        HR:Print("Failed to encode the plan (C_EncodingUtil unavailable?).")
        return
    end
    -- Personne a qui pousser : en solo, l'echo local se renvoyait le plan a soi-meme et le
    -- chemin de reception le RE-IMPORTAIT en variante "SYNC" -- un doublon de son propre plan
    -- dans sa propre DB. On refuse en amont plutot que de filtrer a l'arrivee.
    local channel, target = Net.GroupChannel()
    if not channel then
        HR:Print("You are not in a party or raid -- there is nobody to sync this plan with.")
        return
    end
    -- "|" est hors de l'alphabet base64 url-safe -> separateur sur.
    local msgId = Net.Send("PLAN", tostring(variant.id) .. "|" .. data, channel, target)
    if not msgId then
        HR:Print("Failed to send the plan.")
        return
    end
    HR:Debug("[sync] PLAN", msgId, #data, "bytes")

    -- Mise en scene : une ligne par membre du groupe, spinner jusqu'au verdict. La modale
    -- est pilotee par les accuses SYNC_START / SYNC_OVER (cf. OnPeerStart / OnPeerOver).
    if HR.UI and HR.UI.OpenSyncProgress then
        HR.UI.OpenSyncProgress(msgId, variant.name, DungeonName(dID))
    end
end

--------------------------------------------------------------------------------
-- Accuses de reception (cote EMETTEUR) : alimentent la modale de progression
--------------------------------------------------------------------------------

-- Un client a recu la demande -> il a l'addon. `status` = "PENDING" quand le plan lui est
-- inconnu et qu'il attend l'accord de son joueur (temps humain, sans commune mesure avec la
-- fenetre de 5 s -> la ligne echappe alors au verdict d'expiration).
function PlanSync.OnPeerStart(sender, msgId, status)
    if HR.UI and HR.UI.SyncProgressStarted then HR.UI.SyncProgressStarted(sender, msgId, status) end
end

-- C'est fini chez lui. `status` = "DENIED" si son joueur a refuse, sinon applique.
function PlanSync.OnPeerOver(sender, msgId, status)
    if HR.UI and HR.UI.SyncProgressDone then HR.UI.SyncProgressDone(sender, msgId, status) end
end

--------------------------------------------------------------------------------
-- Index (expediteur, id distant) -> variante locale
--------------------------------------------------------------------------------

-- Auteurs de CONFIANCE : leurs plans s'appliquent sans demander d'accord, y compris un plan
-- qu'on ne connait pas encore. Cle additive (creee a la volee), indexee par nom QUALIFIE --
-- celui de CHAT_MSG_ADDON, jamais un nom auto-declare.
local function trustStore()
    local db = HR.db2; if not db then return nil end
    db.syncTrust = db.syncTrust or {}
    return db.syncTrust
end

function PlanSync.IsTrusted(sender)
    local t = trustStore()
    return (t and t[tostring(qualified(sender) or "?")]) and true or false
end

function PlanSync.SetTrusted(sender, on)
    local t = trustStore(); if not t then return end
    t[tostring(qualified(sender) or "?")] = on and true or nil
end

local function indexStore(dID)
    local db = HR.db2
    if not db or dID == nil then return nil end
    db.syncImports = db.syncImports or {}
    db.syncImports[dID] = db.syncImports[dID] or {}
    return db.syncImports[dID]
end

-- Variante locale d'id `id` dans ce donjon, ou nil (le joueur a pu la supprimer).
local function localVariant(dID, id)
    if not id then return nil end
    local s = HR.db2 and HR.db2.dungeons and HR.db2.dungeons[dID]
    return s and s.variants and s.variants[id] or nil
end

-- Repousse l'echeance d'auto-suppression (donnee PERSONNELLE, hors variante : cf.
-- HR.V2_ImportVariant / HR.PruneExpiredVariants).
local function refreshExpiry(dID, id)
    local db = HR.db2; if not db then return end
    db.imports = db.imports or {}
    db.imports[dID] = db.imports[dID] or {}
    db.imports[dID][id] = ((GetServerTime and GetServerTime()) or time()) + EXPIRE
end

-- Marque une variante comme RECUE d'un tiers, et garde une trace de l'auteur. Champs
-- additifs : une variante sans `synced` est une variante normale du joueur. Le selecteur
-- masque les plans synces par defaut (case "Show sync plans", cf. UI/HealerSpecs.lua).
local function markSynced(v, sender)
    v.synced = true
    v.syncFrom = {
        name = qualified(sender) or tostring(sender),
        at   = (GetServerTime and GetServerTime()) or time(),
    }
end

-- Ecrase le CONTENU d'une variante deja indexee. Les assignments sont reecrits DANS LA
-- TABLE EXISTANTE (vidage + remplissage), jamais substitues -- meme precaution que
-- HR.ClearVariantBossPlan. Tout passe par les filtres du partage avant d'atteindre la DB.
local function overwrite(v, dID, payload, sender)
    local short = shortName(sender)
    local name = (type(payload.name) == "string") and payload.name or "Imported plan"
    if short then name = name .. " (" .. short .. ")" end

    v.name         = name
    v.healer       = payload.healer
    v.externals    = HR.Share.SanitizeExternals(payload.ext)
    v.talentSpells = (type(payload.tsp) == "table") and HR.DeepCopy(payload.tsp) or {}
    v.imported     = true

    local asg = HR.Share.SanitizeAssignments(dID, payload.asg)
    v.assignments = v.assignments or {}
    wipe(v.assignments)
    for encID, occs in pairs(asg) do v.assignments[encID] = occs end

    -- Choix de variante de timeline JOUEE de l'emetteur (par boss), comme a l'import.
    if type(payload.tlv) == "table" and HR.SetActiveTimelineVariant then
        for encID, vid in pairs(payload.tlv) do
            encID = tonumber(encID) or encID
            if type(vid) == "string" then HR.SetActiveTimelineVariant(encID, vid) end
        end
    end

    markSynced(v, sender)
    -- Le TTL est un CHOIX fait a l'acceptation : on ne le repousse que si la variante en a
    -- deja un. Une variante acceptee sans "Delete in 24h" reste permanente, poussee apres
    -- poussee -- on ne lui en invente pas une.
    local imports = HR.db2 and HR.db2.imports and HR.db2.imports[dID]
    if imports and imports[v.id] then refreshExpiry(dID, v.id) end
end

--------------------------------------------------------------------------------
-- Reception
--------------------------------------------------------------------------------

-- Un plan arrive : on l'importe (ou on ecrase celui qu'on avait deja de CE joueur pour CE
-- plan) et on le pose en variante active. Entree reseau -> chaque etape peut abandonner.
function PlanSync.OnPlan(sender, body, msgId)
    if type(body) ~= "string" then return end
    local vid, data = body:match("^(%d+)|(.+)$")
    if not vid then return end

    -- "J'ai recu la demande" : envoye AVANT tout decodage. C'est ce qui distingue, chez
    -- l'emetteur, un client sans addon (muet) d'un client dont l'import a echoue.
    HR.EmitEvent(HR.EV.SYNC_START, { to = sender, msgId = msgId })

    -- Payload deja VALIDE par DecodeVariant (ValidatePayload : donjon connu, profil de heal reel).
    local payload = HR.Share and HR.Share.DecodeVariant(data)
    if not payload then HR:Debug("[sync] PLAN rejected (invalid payload)") return end

    local dID = payload.dID
    local idx = indexStore(dID); if not idx then return end
    local key = tostring(qualified(sender) or "?") .. ":" .. vid

    -- GATE DE RECEPTION. L'entree d'index EST l'autorisation : elle ne nait que d'un accord
    -- explicite du joueur, et elle vaut pour ce plan-la venant de ce joueur-la. Presente ->
    -- on applique sans rien demander (c'est le cas courant : les mises a jour). Absente ->
    -- on ne touche a RIEN et on demande.
    if idx[key] == nil and not PlanSync.IsTrusted(sender) then
        -- Second SYNC_START, avec l'etat cette fois : "j'ai bien recu, mais j'attends mon
        -- joueur". Le premier (avant decodage) sert a prouver la presence de l'addon.
        HR.EmitEvent(HR.EV.SYNC_START, { to = sender, msgId = msgId, status = "PENDING" })
        PlanSync.Ask(sender, msgId, key, dID, payload)
        return
    end

    -- Auteur de confiance ou plan deja autorise : aucune question. Pas de TTL non plus --
    -- personne n'a demande d'auto-suppression pour ce plan-la.
    PlanSync.Apply(sender, msgId, key, dID, payload)
end

--------------------------------------------------------------------------------
-- Demande d'accord (premier plan d'un joueur donne)
--------------------------------------------------------------------------------

-- Demandes en attente, en MEMOIRE (une reponse tardive apres /reload n'ecrit rien).
local pending = {}

function PlanSync.Ask(sender, msgId, key, dID, payload)
    local rec = { sender = sender, msgId = msgId, key = key, dID = dID, payload = payload }
    pending[#pending + 1] = rec
    if HR.UI and HR.UI.AskSyncRequest then
        HR.UI.AskSyncRequest(rec)
    else
        HR:Debug("[sync] no UI to ask for", tostring(sender))
    end
end

-- Accepte : l'application CREE l'entree d'index, donc l'autorisation est acquise pour les
-- poussees suivantes de ce meme plan par ce meme joueur.
-- `opts` = les choix faits dans la modale : { autodelete = bool, trust = bool }.
function PlanSync.Accept(rec, opts)
    if type(rec) ~= "table" then return end
    for i, r in ipairs(pending) do if r == rec then table.remove(pending, i) break end end
    opts = opts or {}
    if opts.trust then
        PlanSync.SetTrusted(rec.sender, true)
        HR:Print(("%s is now a trusted plan author -- their plans apply without asking.")
            :format(shortName(rec.sender) or "?"))
    end
    PlanSync.Apply(rec.sender, rec.msgId, rec.key, rec.dID, rec.payload, opts)
end

-- Refuse : rien n'est ecrit, aucune autorisation n'est creee -- la prochaine poussee
-- redemandera.
function PlanSync.Decline(rec)
    if type(rec) ~= "table" then return end
    for i, r in ipairs(pending) do if r == rec then table.remove(pending, i) break end end
    HR.EmitEvent(HR.EV.SYNC_OVER, { to = rec.sender, msgId = rec.msgId, status = "DENIED" })
    HR:Print(("Declined the plan pushed by %s."):format(shortName(rec.sender) or "?"))
end

--------------------------------------------------------------------------------
-- Application (seul chemin qui ECRIT en DB)
--------------------------------------------------------------------------------

function PlanSync.Apply(sender, msgId, key, dID, payload, opts)
    local idx = indexStore(dID); if not idx then return end

    local v = localVariant(dID, idx[key])
    if v then
        overwrite(v, dID, payload, sender)                       -- ecrasement inconditionnel
    else
        -- Rien d'indexe (1er push, ou variante supprimee par le joueur) -> creation.
        -- Autodelete 24h SEULEMENT si le joueur l'a coche a l'acceptation (defaut : non).
        local nv = HR.Share.ImportPayload(payload, sender, (opts and opts.autodelete) and true or false)
        if not nv then return end
        markSynced(nv, sender)
        idx[key] = nv.id
        v = nv
    end

    HR.SetV2Used(v.id, dID)      -- variante ACTIVE (etoile)
    HR.SelectVariant(v.id, dID)  -- ... et affichee au prochain passage sur le donjon

    -- La fenetre n'est JAMAIS ouverte de force (un push en plein pull ne doit pas coller le
    -- planner a l'ecran) : on ne rafraichit que si elle est deja ouverte sur ce donjon.
    local UI = HR.UI
    if UI and UI.frame and UI.frame:IsShown() and UI.activeDungeonID == dID then
        if HR.GetHealProfile and HR.GetHealProfile(v.healer) then UI.selHealer = v.healer end
        if UI.SetActiveVariant then UI.SetActiveVariant(v) end
    end

    HR:Print(("%s pushed a plan: \"%s\" -- imported and set as active.")
        :format(shortName(sender) or "?", tostring(v.name)))

    -- Import termine a 100% : seul chemin qui emet SYNC_OVER (tout abandon plus haut laisse
    -- l'emetteur sur "Sync failed", ce qui est exactement l'information utile).
    HR.EmitEvent(HR.EV.SYNC_OVER, { to = sender, msgId = msgId, status = "OK" })
end
