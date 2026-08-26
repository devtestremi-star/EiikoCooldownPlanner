-- EiikoCooldownPlanner - UI/ImportText.lua
-- Ecrans d'import des plans au format texte `ecp;2` (outil web). Cf. PLAN_FORMAT.md.
--
-- Deux chemins, selon le `kind` du document :
--   CAS 1 (kind=boss)    : ECRASE le plan d'un seul boss dans la variante AFFICHEE.
--                          Aucun nom demande. Bloque si le plan n'est pas jouable
--                          tel quel dans cette variante.
--   CAS 2 (kind=variant) : cree une NOUVELLE variante ; le nom est saisi par le
--                          joueur, tout le reste est dicte par l'import.
--
-- Regle commune : on BLOQUE au moindre ecart, avec un rapport detaille. Rien n'est
-- ecrit tant que tout ne passe pas. Un plan a moitie importe est pire qu'un import
-- rate : le joueur ne s'en apercoit qu'en combat.
local addonName, HR = ...

HR.UI = HR.UI or {}
local UI = HR.UI

--------------------------------------------------------------------------------
-- Modale de RAPPORT (erreurs bloquantes)
--------------------------------------------------------------------------------

local function BuildReportModal()
    local C = UI.Components
    local m = C.Window(UIParent, {
        name = "ECPImportReportModal", title = "Import failed", width = 620, height = 420,
    })
    m:SetFrameStrata("FULLSCREEN_DIALOG"); m:SetToplevel(true)
    tinsert(UISpecialFrames, "ECPImportReportModal")

    local c = m.content

    m.headline = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    m.headline:SetPoint("TOPLEFT", 16, -14)
    m.headline:SetPoint("RIGHT", c, "RIGHT", -16, 0)
    m.headline:SetJustifyH("LEFT"); m.headline:SetWordWrap(true)

    local scroll = CreateFrame("ScrollFrame", nil, c, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -46)
    scroll:SetPoint("BOTTOMRIGHT", -32, 50)
    scroll.bg = scroll:CreateTexture(nil, "BACKGROUND")
    scroll.bg:SetAllPoints(); scroll.bg:SetColorTexture(0, 0, 0, 0.5)

    -- EditBox multiligne en LECTURE (selectionnable/copiable, non editable de fait :
    -- toute frappe restaure le texte). Meme motif que la modale d'export.
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true); edit:SetFontObject(ChatFontNormal)
    edit:SetAutoFocus(false); edit:SetTextInsets(6, 6, 6, 6)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus(); m:Hide() end)
    edit:SetScript("OnTextChanged", function(self, user)
        if user then self:SetText(m.reportText or "") end
    end)
    scroll:SetScrollChild(edit)
    m.scroll, m.edit = scroll, edit

    local close = C.TextButton(c, { text = "Close", width = 120, onClick = function() m:Hide() end })
    close:SetPoint("BOTTOMRIGHT", -16, 14)

    m:Hide()
    UI.importReportModal = m
end

-- headline : une phrase de contexte. errors : liste de chaines.
function UI.ShowImportReport(headline, errors)
    if not UI.importReportModal then BuildReportModal() end
    local m = UI.importReportModal
    local lines = {}
    for i, e in ipairs(errors or {}) do lines[#lines + 1] = ("%d.  %s"):format(i, e) end
    m.reportText = table.concat(lines, "\n\n")
    m.headline:SetText(headline or "")
    m.headline:SetTextColor(1, 0.82, 0)
    m:Show(); m:Raise()
    m.edit:SetWidth(m.scroll:GetWidth() or 560)
    m.edit:SetText(m.reportText)
    m.edit:SetCursorPosition(0)
end

--------------------------------------------------------------------------------
-- Modale de CONFIRMATION (les deux cas : ecrasement de boss / nom de variante)
--------------------------------------------------------------------------------

local function BuildConfirmModal()
    local C = UI.Components
    local m = C.Window(UIParent, {
        name = "ECPImportConfirmModal", title = "Import plan", width = 560, height = 340,
    })
    m:SetFrameStrata("FULLSCREEN_DIALOG"); m:SetToplevel(true)
    tinsert(UISpecialFrames, "ECPImportConfirmModal")

    local c = m.content

    m.summary = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    m.summary:SetPoint("TOPLEFT", 16, -14)
    m.summary:SetPoint("RIGHT", c, "RIGHT", -16, 0)
    m.summary:SetJustifyH("LEFT"); m.summary:SetWordWrap(true)
    m.summary:SetSpacing(3)

    -- Bandeau d'avertissement (CAS 1 : l'ecrasement est destructif).
    -- Largeur EXPLICITE (et pas via une ancre RIGHT) : InfoBox:Relayout() lit GetWidth()
    -- au moment du SetText et abandonne si le rect n'est pas encore resolu -> le cadre
    -- resterait a sa hauteur minimale, texte tronque.
    m.warn = C.InfoBox(c, {})
    m.warn:SetWidth(508)
    m.warn:SetPoint("TOPLEFT", m.summary, "BOTTOMLEFT", 0, -12)

    -- Champ de nom (CAS 2 uniquement). Repositionne explicitement par chaque ecran :
    -- pas de chainage d'ancres sur `warn`, dont la hauteur varie et qui peut etre masque.
    m.nameLbl = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    m.nameLbl:SetText("Variant name:")

    local eb = CreateFrame("EditBox", nil, c, "InputBoxTemplate")
    eb:SetSize(360, 24); eb:SetAutoFocus(false)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEnterPressed", function() if m.Accept then m.Accept() end end)
    eb:SetScript("OnTextChanged", function() if m.Sync then m.Sync() end end)
    m.nameBox = eb

    m.ok = C.TextButton(c, { text = "Import", width = 150, onClick = function()
        if m.Accept then m.Accept() end
    end })
    m.ok:SetPoint("BOTTOMRIGHT", -16, 14)

    local cancel = C.TextButton(c, { text = "Cancel", width = 110,
                                     onClick = function() m:Hide() end })
    cancel:SetPoint("RIGHT", m.ok, "LEFT", -8, 0)

    m:Hide()
    UI.importConfirmModal = m
end

local function ConfirmModal()
    if not UI.importConfirmModal then BuildConfirmModal() end
    return UI.importConfirmModal
end

--------------------------------------------------------------------------------
-- CAS 1 : ecrasement d'un boss
--------------------------------------------------------------------------------

local function OpenBossConfirm(resolved, parsed, variant)
    local ST = HR.ShareText
    local m  = ConfirmModal()
    local n  = ST.CountAssignments(resolved.assignments, parsed.encID)

    m.summary:SetText(("Dungeon:  |cffffd100%s|r\nBoss:  |cffffd100%s|r\n" ..
                       "Target variant:  |cffffd100%s|r\nIncoming assignments:  |cffffd100%d|r")
        :format(resolved.dungeon.name or "?", resolved.boss.name or "?",
                variant.name or "?", n))

    m.warn:Show()
    m.warn:SetText("This boss's current plan will be REPLACED. Other bosses are untouched.\n" ..
                   "Manual entries that the format cannot carry (Defensive, Empty the bag, " ..
                   "Ramp, trinkets) will be lost on this boss.")
    m.nameLbl:Hide(); m.nameBox:Hide()
    m.ok:SetText("Overwrite")
    m.ok:Enable(); m.ok:SetAlpha(1)
    m.Sync = nil

    m.Accept = function()
        ST.ApplyBoss(resolved, variant, parsed.encID)
        m:Hide()
        if UI.ShowDungeonVariant then UI.ShowDungeonVariant(resolved.dID, variant) end
        if UI.RefreshRows then UI.RefreshRows() end
        HR:Print(("Boss \"%s\" plan replaced (%d assignments) in variant \"%s\".")
            :format(resolved.boss.name or "?", n, variant.name or "?"))
    end

    m:Show(); m:Raise()
end

--------------------------------------------------------------------------------
-- CAS 2 : variante integrale
--------------------------------------------------------------------------------

local function OpenVariantConfirm(resolved, parsed)
    local ST = HR.ShareText
    local m  = ConfirmModal()
    local n  = ST.CountAssignments(resolved.assignments)
    local nb = 0
    for _ in pairs(resolved.assignments) do nb = nb + 1 end

    local prof = HR.GetHealProfile(resolved.healerKey)
    m.summary:SetText(("Dungeon:  |cffffd100%s|r\nHealer:  |cffffd100%s|r (%s)\n" ..
                       "Bosses planned:  |cffffd100%d|r    Assignments:  |cffffd100%d|r")
        :format(resolved.dungeon.name or "?", (prof and prof.name) or resolved.healerKey,
                resolved.healerId or "?", nb, n))

    m.warn:Hide()
    m.nameLbl:Show(); m.nameBox:Show()
    m.nameLbl:ClearAllPoints()
    m.nameLbl:SetPoint("TOPLEFT", m.summary, "BOTTOMLEFT", 0, -22)
    m.nameBox:ClearAllPoints()
    m.nameBox:SetPoint("TOPLEFT", m.nameLbl, "BOTTOMLEFT", 6, -8)
    m.ok:SetText("Import")

    -- Le bouton desactive ne recoit pas OnClick (comportement natif des Button), mais
    -- C.TextButton n'a pas de skin "disabled" -> l'alpha rend l'etat visible.
    m.Sync = function()
        local empty = strtrim(m.nameBox:GetText() or "") == ""
        if empty then m.ok:Disable(); m.ok:SetAlpha(0.45)
        else          m.ok:Enable();  m.ok:SetAlpha(1) end
    end

    m.Accept = function()
        local name = strtrim(m.nameBox:GetText() or "")
        if name == "" then return end
        local v = ST.ApplyVariant(resolved, name)
        m:Hide()
        if not v then HR:Print("Import failed while creating the variant."); return end
        if UI.ShowDungeonVariant then UI.ShowDungeonVariant(resolved.dID, v) end
        if UI.RefreshRows then UI.RefreshRows() end
        HR:Print(("Variant \"%s\" imported (%d bosses, %d assignments)."):format(v.name, nb, n))
    end

    m:Show(); m:Raise()
    m.nameBox:SetText(parsed.title or "")
    m.nameBox:SetFocus(); m.nameBox:HighlightText()
    m.Sync()
end

--------------------------------------------------------------------------------
-- Point d'entree : aiguillage
--------------------------------------------------------------------------------

-- Traite une chaine `ecp;2` (nue ou en enveloppe `ecp64:`). Renvoie true si un ecran
-- a ete ouvert (succes du parsing), false si l'import est refuse d'emblee.
function UI.ImportTextPlan(str)
    local ST = HR.ShareText
    if not ST then HR:Print("Import unavailable (ShareText module missing)."); return false end

    local parsed, err = ST.Parse(str)
    if not parsed then
        UI.ShowImportReport("This plan could not be read.", { err })
        return false
    end

    -- On resout les occurrences avec la variante de timeline AFFICHEE par l'editeur,
    -- pas la variante jouee : sinon l'import ecraserait le plan que le joueur a sous
    -- les yeux pour en ecrire un prefixe d'une autre variante, donc invisible.
    local resolved, errors = ST.Resolve(parsed, { tlVariantFor = UI.GetViewedTlVariant })
    if not resolved then
        UI.ShowImportReport(
            "This plan does not match the addon's data. Nothing was imported.", errors)
        return false
    end

    if parsed.kind == "boss" then
        local variant = HR.GetActiveVariant(resolved.dID)
        local verrs = ST.ValidateAgainstVariant(resolved, variant)
        if #verrs > 0 then
            UI.ShowImportReport(
                ("This boss plan is not playable in variant \"%s\". Nothing was imported.")
                    :format(variant and variant.name or "?"), verrs)
            return false
        end
        OpenBossConfirm(resolved, parsed, variant)
    else
        OpenVariantConfirm(resolved, parsed)
    end
    return true
end
