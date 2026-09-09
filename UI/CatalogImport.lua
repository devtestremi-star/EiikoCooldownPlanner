-- EiikoCooldownPlanner - UI/CatalogImport.lua
-- Ecran de RECAPITULATIF d'un catalogue, avant ecriture (memo §13.4).
--
-- Rien n'est ecrit tant que le joueur n'a pas confirme. C'est le pendant, cote lecteur,
-- du point de controle qu'a le createur avant de publier : on montre CE QUI VA CHANGER,
-- donjon par donjon, plutot qu'un « importe » opaque.
local addonName, HR = ...

HR.UI = HR.UI or {}
local UI = HR.UI

local W, H    = 560, 470
local PAD     = 16
local ROW_H   = 30
local ICON    = 24

local m, pending      -- modale + rapport en attente de confirmation

--------------------------------------------------------------------------------

local function AcquireRow(parent, i)
    m.rows = m.rows or {}
    local r = m.rows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, parent)
    r:SetHeight(ROW_H)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(ICON, ICON)
    r.icon:SetPoint("LEFT", 0, 0)
    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 8, 0)
    r.name:SetJustifyH("LEFT")
    r.detail = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    r.detail:SetPoint("RIGHT", 0, 0)
    r.detail:SetJustifyH("RIGHT")
    m.rows[i] = r
    return r
end

local function Build()
    if m then return m end
    local C = UI.Components
    m = C.Window(UIParent, {
        name = "ECPCatalogImport", title = "Import catalogue", width = W, height = H,
        bgTexture = C.ModalBackgroundTexture(),
    })
    C.ModalBackground(m)
    m:SetFrameStrata("FULLSCREEN_DIALOG"); m:SetToplevel(true)
    tinsert(UISpecialFrames, "ECPCatalogImport")
    m:Hide()

    local c = m.content

    m.who = c:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    m.who:SetPoint("TOPLEFT", PAD, -PAD)
    m.who:SetPoint("RIGHT", c, "RIGHT", -PAD, 0)
    m.who:SetJustifyH("LEFT")

    m.sub = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    m.sub:SetPoint("TOPLEFT", PAD, -PAD - 24)
    m.sub:SetPoint("RIGHT", c, "RIGHT", -PAD, 0)
    m.sub:SetJustifyH("LEFT")

    -- Avertissement de version perimee : CONSULTATIF, jamais bloquant (memo §12.2). Un
    -- refus mal calibre rendrait un pack inimportable sans que personne comprenne.
    m.warn = C.InfoBox(c, {})
    m.warn:SetWidth(W - PAD * 2 - 8)
    m.warn:SetPoint("TOPLEFT", PAD, -PAD - 46)
    m.warn:Hide()

    m.listHdr = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    m.listHdr:SetText("Content")

    m.list = CreateFrame("Frame", nil, c)
    m.rows = {}

    m.rejected = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    m.rejected:SetJustifyH("LEFT"); m.rejected:SetWordWrap(true)

    m.ok = C.TextButton(c, { text = "Import", width = 130, onClick = function()
        if not pending then return end
        local _, touched = HR.Catalog.Apply(pending)
        local n, d, gone = pending.total, #pending.dungeons, pending.removals or 0
        pending = nil
        m:Hide()
        -- On annonce aussi ce qui a ete RETIRE : sur une retractation d'auteur (pack vide,
        -- §10.6) « 0 variante » serait le seul retour, et ne dirait rien de ce qui vient de
        -- disparaitre du catalogue.
        HR:Print(("Catalogue imported: %d variant(s) across %d dungeon(s)%s."):format(
            n, d, gone > 0 and (", %d removed"):format(gone) or ""))
        -- L'import a pu modifier des plans DEJA adoptes : le dire. Une variante jouable
        -- qui change sous les pieds du joueur sans un mot serait la pire des surprises.
        if touched and touched > 0 then
            HR:Print(("%d plan(s) you already added were updated."):format(touched))
        end
        -- Redessin GENERAL, pas une notification « le catalogue a change » : la barre
        -- laterale et le bandeau de variante rederivent seuls leur acces au catalogue, donc
        -- le PREMIER import le deverrouille sans que personne ait a prevenir de quoi que ce soit.
        if UI.RefreshRows then UI.RefreshRows() end
        if UI.RefreshCatalog then UI.RefreshCatalog() end
    end })
    m.ok:SetPoint("BOTTOMRIGHT", -PAD, PAD)

    local cancel = C.TextButton(c, { text = "Cancel", width = 110, onClick = function()
        pending = nil; m:Hide()
    end })
    cancel:SetPoint("RIGHT", m.ok, "LEFT", -8, 0)

    return m
end

--------------------------------------------------------------------------------

-- Affiche le rapport. `rep` vient de HR.Catalog.Analyse -- rien n'a encore ete ecrit.
function UI.ShowCatalogImport(rep)
    Build()
    pending = rep
    local c = m.content

    local cname = (rep.creator and rep.creator.name) or "?"
    m.who:SetText(("|cffffd100%s|r"):format(HR.EscapeMarkup(cname)))
    m.sub:SetText(rep.creatorKnown and "You already have catalogues from this creator."
                                    or "New creator.")

    local y = -PAD - 46
    if rep.older then
        m.warn:Show()
        m.warn:SetText("This catalogue looks OLDER than the one you already have from this "
            .. "creator. Importing it will roll their plans back. Continue only if you "
            .. "meant to.")
        y = y - (m.warn:GetHeight() or 40) - 10
    else
        m.warn:Hide()
    end

    m.listHdr:ClearAllPoints(); m.listHdr:SetPoint("TOPLEFT", PAD, y)
    y = y - 22

    for _, r in ipairs(m.rows) do r:Hide() end

    -- UNE LIGNE PAR DONJON, avec son icone. La facade d'ECP resout l'icone (Core/Icons.lua) :
    -- elle sait qu'un donjon se rend par son `icon` ou, a defaut, par son sort embleme.
    for i, d in ipairs(rep.dungeons) do
        local r = AcquireRow(c, i)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", PAD, y)
        r:SetPoint("RIGHT", c, "RIGHT", -PAD, 0)
        HR.Icons.Apply(r.icon, "dungeon", d.dungeon or d.dID)
        r.name:SetText((d.dungeon and (d.dungeon.name or d.dungeon.abbr)) or d.dID)

        -- On montre ce qui CHANGE, pas seulement un total : c'est la seule facon de voir
        -- qu'un import va aussi RETIRER des entrees.
        local bits = {}
        if d.added   > 0 then bits[#bits + 1] = ("|cff33ff99+%d new|r"):format(d.added) end
        if d.updated > 0 then bits[#bits + 1] = ("%d updated"):format(d.updated) end
        if d.removed > 0 then bits[#bits + 1] = ("|cffff5555-%d removed|r"):format(d.removed) end
        if #bits == 0 then bits[1] = "|cff808080nothing|r" end
        r.detail:SetText(("%d variant(s)   %s"):format(d.count, table.concat(bits, "  ")))
        r:Show()
        y = y - ROW_H
    end

    -- Ce qui a ete ECARTE, avec son motif. Un rejet silencieux ferait croire a un import
    -- complet alors qu'il manque des entrees (memo §13.4).
    if #rep.rejected > 0 then
        y = y - 8
        m.rejected:ClearAllPoints()
        m.rejected:SetPoint("TOPLEFT", PAD, y)
        m.rejected:SetPoint("RIGHT", c, "RIGHT", -PAD, 0)
        local head = ("|cffff5555%d entr%s skipped:|r "):format(#rep.rejected,
                        #rep.rejected > 1 and "ies" or "y")
        local list = {}
        for i = 1, math.min(#rep.rejected, 5) do list[#list + 1] = rep.rejected[i] end
        if #rep.rejected > 5 then list[#list + 1] = ("(+%d more)"):format(#rep.rejected - 5) end
        m.rejected:SetText(head .. table.concat(list, ", "))
        m.rejected:Show()
    else
        m.rejected:Hide()
    end

    -- ⚠️ « rien a ecrire » n'est PAS « rien a faire ». Un pack vide est le geste de
    -- suppression de l'auteur (memo §10.6 : publier 0 entree = tout retirer dans ce donjon,
    -- le geste le plus destructif du systeme, accepte explicitement). Ne gater que sur
    -- `total` rendait une retractation IMPOSSIBLE a appliquer.
    local acts = rep.total > 0 or (rep.removals or 0) > 0
    m.ok:SetEnabled(acts)
    m.ok:SetAlpha(acts and 1 or 0.4)
    m:Show(); m:Raise()
end

-- Point d'entree depuis l'aiguillage d'import. Renvoie true si un ecran a ete ouvert.
function UI.ImportCatalogueString(str)
    local payload, err = HR.Catalog.Decode(str)
    if not payload then
        UI.ShowImportReport("This catalogue could not be read.", { err })
        return false
    end
    local rep, err2 = HR.Catalog.Analyse(payload)
    if not rep then
        UI.ShowImportReport("This catalogue was refused.", { err2 or "Unknown error." })
        return false
    end
    -- Vraiment vide = rien a ecrire ET rien a retirer. Un pack sans entree qui SUPPRIME des
    -- plans deja recus n'est pas vide : c'est une retractation, et elle doit passer (§10.6).
    if rep.total == 0 and (rep.removals or 0) == 0 and #rep.rejected == 0 then
        UI.ShowImportReport("This catalogue is empty.",
            { "It declares no variant this client can read." })
        return false
    end
    UI.ShowCatalogImport(rep)
    return true
end
