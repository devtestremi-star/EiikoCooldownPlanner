-- EiikoCooldownPlanner - UI/SyncFrame.lua
-- Modale de PROGRESSION d'une poussee de plan (bouton Sync). Une ligne par membre du
-- groupe, avec un spinner tant qu'on ne sait pas, puis un verdict :
--
--   Sync success   le client a repondu SYNC_OVER  (import termine a 100%)
--   Sync failed    il a repondu SYNC_START mais jamais SYNC_OVER (import casse en route)
--   Addon missing  aucune reponse du tout dans la fenetre de 5 s
--
-- Le spinner ne s'arrete que sur un verdict : reponse finale, ou expiration du delai.
-- Cote PROGRESSION la modale n'AFFICHE que : l'etat lui est pousse par Core/Sync/PlanSync.lua.
-- Seule action qu'elle porte : le bouton "Advertize" (annonce publique dans le chat de groupe,
-- pour les membres SANS l'addon, chez qui une poussee est muette). Cf. UI.AdvertizeAddon.
local addonName, HR = ...

HR.UI = HR.UI or {}
local UI = HR.UI

local WINDOW  = 5      -- (s) delai avant de trancher pour les silencieux
local ROW_H   = 30
local SPIN_SZ = 16

-- Page de telechargement, citee dans l'annonce publique du bouton "Advertize".
local ADDON_URL = "https://www.curseforge.com/wow/addons/eiikocooldownplanner"
-- Anti-spam : un seul message par ANTISPAM secondes. Le bouton reste cliquable -- on prefere
-- dire POURQUOI rien n'est parti plutot que de le griser sans explication.
local ANTISPAM = 30
local lastAdv  = 0

-- Etat de la passe affichee : { msgId, rows = { [nomQualifie] = row }, order = { row, ... } }
local pass = nil

-- Nom qualifie "Nom-Royaume". Le royaume DOIT etre transmis : un membre cross-realm arrive
-- en "Nom-AutreRoyaume" dans CHAT_MSG_ADDON, alors que UnitFullName le rend en deux valeurs.
local function qualified(name, realm)
    if HR.Keys and HR.Keys.QualifiedName then return HR.Keys.QualifiedName(name, realm) or name end
    return name
end

--------------------------------------------------------------------------------
-- Spinner : 8 points sur un cercle, dont l'opacite tourne. Zero fichier de texture
-- (donc jamais de carre rose si un asset manque) et zero dependance.
--------------------------------------------------------------------------------

local function MakeSpinner(parent, size)
    local s = CreateFrame("Frame", nil, parent)
    s:SetSize(size, size)
    s.dots = {}
    local r, dot = size / 2 - 2, math.max(2, size / 6)
    for i = 1, 8 do
        local a = (i - 1) * (math.pi * 2 / 8)
        local t = s:CreateTexture(nil, "OVERLAY")
        t:SetSize(dot, dot)
        t:SetColorTexture(1, 1, 1, 1)
        t:SetPoint("CENTER", s, "CENTER", math.sin(a) * r, math.cos(a) * r)
        s.dots[i] = t
    end
    -- Le tick est garde sur la frame : une ligne recyclee doit pouvoir RELANCER le spinner
    -- (SetScript(nil) puis GetScript() renverrait nil).
    s.Tick = function(self, dt)
        self.elapsed = self.elapsed + dt
        if self.elapsed < 0.09 then return end
        self.elapsed = 0
        self.head = self.head % 8 + 1
        for i = 1, 8 do
            -- distance au point de tete (0 = tete) -> opacite decroissante = trainee.
            local d = (i - self.head) % 8
            self.dots[i]:SetAlpha(1 - d * 0.11)
        end
    end
    function s:Start()
        self.head, self.elapsed = 1, 0
        self:SetScript("OnUpdate", self.Tick)
        self:Show()
    end
    function s:Stop()
        self:SetScript("OnUpdate", nil)
        self:Hide()
    end
    s:Start()
    return s
end

--------------------------------------------------------------------------------
-- Construction (une fois)
--------------------------------------------------------------------------------

local function Build()
    local m = UI.Components.Window(UIParent, {
        name = "ECPSyncProgress", title = "Syncing plan", width = 460, height = 320,
        bgTexture = (HR.Assets.registry["bg-variant"]) and HR.Asset("bg-variant") or nil,
    })
    m:SetFrameStrata("FULLSCREEN_DIALOG"); m:SetToplevel(true)
    tinsert(UISpecialFrames, "ECPSyncProgress")

    -- Fond d'ecran en mode "cover" + voile sombre (meme rendu que les modales de variante).
    if m.bgTex then
        local function LayoutModalBg()
            local w, h = m:GetWidth(), m:GetHeight()
            if not w or not h or w <= 0 or h <= 0 then return end
            local af = w / h
            if af >= 1 then local dv = 1 / af; m.bgTex:SetTexCoord(0, 1, (1 - dv) / 2, (1 + dv) / 2)
            else local du = af; m.bgTex:SetTexCoord((1 - du) / 2, (1 + du) / 2, 0, 1) end
        end
        m:HookScript("OnSizeChanged", LayoutModalBg)
        LayoutModalBg()
        m.bgDim = m:CreateTexture(nil, "BACKGROUND", nil, 3)
        m.bgDim:SetAllPoints()
        m.bgDim:SetColorTexture(0, 0, 0, 0.7)
    end

    local c = m.content

    m.subtitle = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    m.subtitle:SetPoint("TOPLEFT", 18, -16)
    m.subtitle:SetPoint("RIGHT", c, "RIGHT", -18, 0)
    m.subtitle:SetJustifyH("LEFT"); m.subtitle:SetWordWrap(false)
    m.subtitle:SetTextColor(1, 1, 1)

    m.rowHost = CreateFrame("Frame", nil, c)
    m.rowHost:SetPoint("TOPLEFT", 18, -44)
    m.rowHost:SetPoint("BOTTOMRIGHT", -18, 52)

    m.footer = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    m.footer:SetPoint("BOTTOMLEFT", 18, 20)
    m.footer:SetTextColor(0.7, 0.7, 0.7)

    m.close2 = UI.Components.TextButton(c, { text = "Close", autoWidth = true, minWidth = 0,
        padX = 15, padY = 9, onClick = function() m:Hide() end })
    m.close2:SetPoint("BOTTOMRIGHT", -18, 14)

    -- "Advertize" : annonce PUBLIQUE dans le canal de groupe, pour les membres qui n'ont pas
    -- l'addon (la poussee de plan, elle, est muette chez eux). Reprend mot pour mot le message
    -- que l'ancien partage par lien envoyait automatiquement.
    -- ⚠️ Ce n'est PAS une reintroduction du partage par lien (retire le 2026-08-26) : aucun
    -- hyperlien, aucune donnee de plan sur le fil, juste une phrase et l'URL de telechargement.
    m.advertize = UI.Components.TextButton(c, { text = "Advertize", autoWidth = true, minWidth = 0,
        padX = 15, padY = 9, onClick = function() UI.AdvertizeAddon() end })
    m.advertize:SetPoint("RIGHT", m.close2, "LEFT", -6, 0)
    UI.Components.AttachHelpTip(m.advertize, "Advertize", function()
        local ch = HR.Sync and HR.Sync.Net and HR.Sync.Net.GroupChannel()
        local body = "Post a public message in party/raid chat telling the group you sync your "
            .. "plans with ECP, with the download link. Nothing about the plan itself is sent."
        if ch ~= "PARTY" and ch ~= "RAID" then
            body = body .. "\n|cffff6060Unavailable:|r you are not in a party or raid."
        end
        return body
    end)

    m.rowPool = {}
    m:Hide()
    UI.syncFrame = m
    return m
end

-- Ligne (recyclee) : spinner + nom colore par classe + verdict a droite.
local function AcquireRow(m, i)
    local row = m.rowPool[i]
    if row then return row end
    row = CreateFrame("Frame", nil, m.rowHost)
    row:SetHeight(ROW_H)
    row:SetPoint("LEFT", m.rowHost, "LEFT", 0, 0)
    row:SetPoint("RIGHT", m.rowHost, "RIGHT", 0, 0)

    row.spin = MakeSpinner(row, SPIN_SZ)
    row.spin:SetPoint("LEFT", row, "LEFT", 2, 0)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("LEFT", row, "LEFT", SPIN_SZ + 12, 0)
    row.name:SetJustifyH("LEFT")

    row.status = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.status:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    row.status:SetJustifyH("RIGHT")

    m.rowPool[i] = row
    return row
end

local function SetStatus(row, text, r, g, b)
    if row.spin then row.spin:Stop() end
    row.status:SetText(text)
    row.status:SetTextColor(r, g, b)
end

--------------------------------------------------------------------------------
-- Verdict des silencieux (expiration du delai)
--------------------------------------------------------------------------------

local function Finalize(msgId)
    if not pass or pass.msgId ~= msgId then return end
    for _, row in ipairs(pass.order) do
        if row.awaiting then
            -- Le joueur d'en face n'a pas encore repondu a la demande d'accord : c'est du
            -- temps humain, sans commune mesure avec les 5 s. On n'invente pas de verdict.
        elseif not row.done then
            if row.started then
                SetStatus(row, "Sync failed", 1, 0.35, 0.35)     -- a recu, n'a jamais fini
            else
                SetStatus(row, "Addon missing", 0.65, 0.65, 0.65) -- muet : pas d'addon (ou hors portee)
            end
            row.done = true
        end
    end
    local m = UI.syncFrame
    if m then m.footer:SetText("Done.") end
    pass.closed = true
end

--------------------------------------------------------------------------------
-- API consommee par Core/Sync/PlanSync.lua
--------------------------------------------------------------------------------

-- Ouvre la modale pour la poussee `msgId`. Une ligne par AUTRE membre du groupe ; en solo
-- (aucun autre membre), une ligne pour soi -- l'echo local repond, la chaine se teste seule.
-- Annonce PUBLIQUE dans le canal de groupe. Message repris TEL QUEL de l'ancien partage par
-- lien : c'est la seule chose qui manque a un membre SANS l'addon, chez qui une poussee de plan
-- est totalement muette. On ne poste QUE dans un vrai groupe (PARTY/RAID) -- le canal WHISPER
-- que Net.GroupChannel renvoie en mode debug est un echo local, pas une annonce.
-- ⚠️ Ce n'est PAS une reintroduction du partage par lien (retire le 2026-08-26) : aucun
-- hyperlien, aucune donnee de plan sur le fil, juste une phrase et l'URL de telechargement.
function UI.AdvertizeAddon()
    local ch = HR.Sync and HR.Sync.Net and HR.Sync.Net.GroupChannel()
    if ch ~= "PARTY" and ch ~= "RAID" then
        HR:Print("You are not in a party or raid -- nobody would see the announcement.")
        return
    end
    local now = GetTime()
    if now - lastAdv < ANTISPAM then
        HR:Print(("Already announced %ds ago -- wait a moment before posting again.")
            :format(math.floor(now - lastAdv)))
        return
    end
    lastAdv = now
    SendChatMessage(
        ("[EiikoCooldownPlanner - ECP] : %s shared a healing plan. Download ECP at %s")
            :format(UnitName("player") or "?", ADDON_URL),
        ch)
end

function UI.OpenSyncProgress(msgId, planName, dungeonName)
    local m = UI.syncFrame or Build()

    HR.RebuildGroup()
    local me = qualified(UnitFullName("player"))
    local members = {}
    for _, g in ipairs(HR.group) do
        local qn = g.unit and qualified(UnitFullName(g.unit))
        if qn and qn ~= me then members[#members + 1] = { qname = qn, name = g.name, class = g.class } end
    end
    if #members == 0 then
        local _, cls = UnitClass("player")
        members[1] = { qname = me, name = UnitName("player") .. " (you)", class = cls, solo = true }
    end

    pass = { msgId = msgId, rows = {}, order = {}, closed = false }

    for i, mem in ipairs(members) do
        local row = AcquireRow(m, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", m.rowHost, "TOPLEFT", 0, -(i - 1) * ROW_H)
        row:SetPoint("RIGHT", m.rowHost, "RIGHT", 0, 0)
        row.name:SetText(("|c%s%s|r"):format(HR.ClassColorHex(mem.class), mem.name or "?"))
        row.status:SetText("Waiting...")
        row.status:SetTextColor(0.7, 0.7, 0.7)
        row.spin:Start()                         -- recyclage : relance propre
        row.done, row.started, row.awaiting = false, false, false
        row:Show()
        pass.rows[mem.qname] = row
        pass.order[#pass.order + 1] = row
    end
    for i = #members + 1, #m.rowPool do m.rowPool[i]:Hide() end

    m.subtitle:SetText(("Pushing \"%s\"%s to %d player%s...")
        :format(tostring(planName or "plan"),
                dungeonName and (" (" .. dungeonName .. ")") or "",
                #members, (#members == 1) and "" or "s"))
    m.footer:SetText(("Waiting up to %d seconds for replies..."):format(WINDOW))
    m:Show()
    m:Raise()

    C_Timer.After(WINDOW, function() Finalize(msgId) end)
end

-- Ligne concernee par un accuse. Une passe FERMEE n'accepte plus rien, SAUF pour une ligne
-- en attente d'accord : sa reponse arrive forcement apres les 5 s.
local function RowFor(sender, msgId)
    if not pass or pass.msgId ~= msgId then return nil end
    local row = pass.rows[qualified(sender)]
    if not row or row.done then return nil end
    if pass.closed and not row.awaiting then return nil end
    return row
end

-- Le client a RECU la demande (il a l'addon). Le STATUT vient dans la reponse, pas dans un
-- evenement de plus : "PENDING" = son joueur doit d'abord accepter (temps humain), la ligne
-- echappe alors au verdict d'expiration (cf. Finalize) et le spinner continue de tourner.
function UI.SyncProgressStarted(sender, msgId, status)
    local row = RowFor(sender, msgId); if not row then return end
    row.started = true
    if status == "PENDING" then
        row.awaiting = true
        row.status:SetText("Pending approval...")
    else
        row.status:SetText("Receiving...")
    end
    row.status:SetTextColor(1, 0.82, 0)
end

-- C'est fini chez lui. "DENIED" = son joueur a refuse : ce n'est pas un echec technique, on
-- le dit autrement. Sinon, import applique a 100%.
function UI.SyncProgressDone(sender, msgId, status)
    local row = RowFor(sender, msgId); if not row then return end
    row.started, row.done, row.awaiting = true, true, false
    if status == "DENIED" then
        SetStatus(row, "Declined", 0.85, 0.6, 0.2)
    else
        SetStatus(row, "Sync success", 0.2, 1, 0.5)
    end
end

--------------------------------------------------------------------------------
-- Demande d'accord (cote RECEVEUR) : premier plan d'un joueur donne
--------------------------------------------------------------------------------

local function DungeonName(dID)
    for _, dg in ipairs(HR.content or {}) do
        if dg.id == dID then return dg.name end
    end
    return tostring(dID)
end

-- Fenetre MAISON (meme Window / meme fond que les autres modales) plutot qu'une StaticPopup
-- native : c'est une decision qui engage la DB du joueur, elle doit avoir l'air d'appartenir
-- a l'addon. Une seule demande a l'ecran a la fois, les suivantes attendent leur tour.
local askQueue, askFrame = {}, nil

local function BuildAsk()
    local m = UI.Components.Window(UIParent, {
        name = "ECPSyncRequest", title = "Sync request", width = 440, height = 330,
        bgTexture = (HR.Assets.registry["bg-variant"]) and HR.Asset("bg-variant") or nil,
        onClose = function() UI.AnswerSyncRequest(false) end,   -- fermer = refuser (rien n'est ecrit)
    })
    m:SetFrameStrata("FULLSCREEN_DIALOG"); m:SetToplevel(true)

    if m.bgTex then
        local function LayoutModalBg()
            local w, h = m:GetWidth(), m:GetHeight()
            if not w or not h or w <= 0 or h <= 0 then return end
            local af = w / h
            if af >= 1 then local dv = 1 / af; m.bgTex:SetTexCoord(0, 1, (1 - dv) / 2, (1 + dv) / 2)
            else local du = af; m.bgTex:SetTexCoord((1 - du) / 2, (1 + du) / 2, 0, 1) end
        end
        m:HookScript("OnSizeChanged", LayoutModalBg)
        LayoutModalBg()
        m.bgDim = m:CreateTexture(nil, "BACKGROUND", nil, 3)
        m.bgDim:SetAllPoints()
        m.bgDim:SetColorTexture(0, 0, 0, 0.7)
    end

    local c = m.content
    m.who = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    m.who:SetPoint("TOPLEFT", 18, -18)
    m.who:SetPoint("RIGHT", c, "RIGHT", -18, 0)
    m.who:SetJustifyH("LEFT"); m.who:SetTextColor(1, 1, 1)

    m.plan = c:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    m.plan:SetPoint("TOPLEFT", 18, -46)
    m.plan:SetPoint("RIGHT", c, "RIGHT", -18, 0)
    m.plan:SetJustifyH("LEFT"); m.plan:SetWordWrap(false)

    m.where = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    m.where:SetPoint("TOPLEFT", 18, -72)
    m.where:SetJustifyH("LEFT"); m.where:SetTextColor(0.75, 0.75, 0.75)

    m.note = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    m.note:SetPoint("TOPLEFT", 18, -104)
    m.note:SetPoint("RIGHT", c, "RIGHT", -18, 0)
    m.note:SetJustifyH("LEFT"); m.note:SetTextColor(0.75, 0.75, 0.75)
    m.note:SetText("Accepting also applies this player's later updates to THIS plan, with no "
        .. "further question. It never touches a plan you wrote yourself.")

    -- Option 1 : TTL. Meme mecanisme que l'import manuel (db2.imports[dID][id] + purge par
    -- HR.PruneExpiredVariants au chargement). DECOCHE par defaut : un plan qu'on accepte est
    -- en general le plan de la cle en cours, pas un essai.
    m.autodel = CreateFrame("CheckButton", nil, c, "UICheckButtonTemplate")
    m.autodel:SetSize(24, 24)
    m.autodel:SetPoint("TOPLEFT", 16, -156)
    m.autodel.label = m.autodel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    m.autodel.label:SetPoint("LEFT", m.autodel, "RIGHT", 2, 0)
    m.autodel.label:SetText("Delete this variant in 24h")
    UI.Components.AttachHelpTip(m.autodel, "Delete this variant in 24h",
        "The plan is removed on its own 24 hours from now, at a later login or reload -- like "
        .. "any imported plan with autodelete on. Handy for a one-off key with a group you "
        .. "will not play again: you keep the plan for tonight without letting your list grow. "
        .. "Leave it unchecked to keep the plan until you delete it yourself.")

    -- Option 2 : whitelist d'auteurs. Porte sur le JOUEUR, pas sur ce plan-la.
    m.trust = CreateFrame("CheckButton", nil, c, "UICheckButtonTemplate")
    m.trust:SetSize(24, 24)
    m.trust:SetPoint("TOPLEFT", m.autodel, "BOTTOMLEFT", 0, -4)
    m.trust.label = m.trust:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    m.trust.label:SetPoint("LEFT", m.trust, "RIGHT", 2, 0)
    m.trust.label:SetText("Trust this author")
    UI.Components.AttachHelpTip(m.trust, "Trust this author",
        "Stop asking for THIS player: every plan they push, including ones you have never "
        .. "seen, applies straight away. Convenient with a regular healer, but it is a "
        .. "standing permission to write plans into your saved variables -- it never touches "
        .. "a plan you wrote yourself, and it lasts until you remove them from the trusted list.")

    m.accept = UI.Components.TextButton(c, { text = "Accept", autoWidth = true, minWidth = 90,
        padX = 15, padY = 9, onClick = function() UI.AnswerSyncRequest(true) end })
    m.accept:SetPoint("BOTTOMRIGHT", -18, 16)
    m.decline = UI.Components.TextButton(c, { text = "Decline", autoWidth = true, minWidth = 90,
        padX = 15, padY = 9, onClick = function() UI.AnswerSyncRequest(false) end })
    m.decline:SetPoint("RIGHT", m.accept, "LEFT", -8, 0)

    m:Hide()
    UI.syncAskFrame = m
    askFrame = m
    return m
end

-- Affiche la demande en tete de file (ou ferme la fenetre s'il n'y en a plus).
local function ShowNextAsk()
    local m = askFrame or BuildAsk()
    local rec = askQueue[1]
    if not rec then m:Hide() return end
    local who = (type(rec.sender) == "string") and rec.sender:match("^[^-]+") or "?"
    m.who:SetText(("|cffffd100%s|r wants to sync a plan with you:"):format(who))
    m.plan:SetText(tostring(rec.payload and rec.payload.name or "plan"))
    m.where:SetText(DungeonName(rec.dID))
    -- Remise a zero : les choix faits pour une demande ne doivent pas fuiter sur la suivante.
    m.autodel:SetChecked(false)
    m.trust:SetChecked(false)
    m:Show(); m:Raise()
end

-- Reponse du joueur a la demande AFFICHEE. Fermer la fenetre vaut refus : rien n'est ecrit,
-- et l'emetteur est prevenu (sinon sa modale resterait bloquee sur "Pending approval").
function UI.AnswerSyncRequest(accepted)
    local rec = table.remove(askQueue, 1)
    if rec and HR.Sync and HR.Sync.Plan then
        if accepted then
            local m = askFrame
            HR.Sync.Plan.Accept(rec, {
                autodelete = m and m.autodel:GetChecked() and true or false,
                trust      = m and m.trust:GetChecked() and true or false,
            })
        else
            HR.Sync.Plan.Decline(rec)
        end
    end
    ShowNextAsk()
end

-- Appelee par Core/Sync/PlanSync.lua quand un plan INCONNU arrive. Rien n'est ecrit tant
-- que le joueur n'a pas repondu.
function UI.AskSyncRequest(rec)
    if type(rec) ~= "table" then return end
    askQueue[#askQueue + 1] = rec
    if not (askFrame and askFrame:IsShown()) then ShowNextAsk() end
end
