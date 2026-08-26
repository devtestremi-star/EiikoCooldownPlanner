-- HealPlanner - UI/HealerSpecs.lua
-- Section "Composition" (bandeau au-dessus de la timeline) :
--   MAIN FRAME : titre "Summary" + recap READ-ONLY de la variante active (icone de spe
--     + externals), et a DROITE (toujours colle) le SELECTEUR DE VARIANTE custom +
--     New / Duplicate / Delete. Hauteurs uniformes (= taille des icones du recap).
--   MODALES : New (selection progressive), Duplicate (nom), Delete (StaticPopup de
--     confirmation). Toutes en FULLSCREEN_DIALOG (sinon elles passent derriere la fenetre).
local addonName, HR = ...

HR.UI = HR.UI or {}
local UI = HR.UI

UI.SPECS_H = 84                  -- 2 lignes cote variantes (boutons + select) + padding
local SPEC_ICON = 32
local SPEC_GAP  = 8
local EXT_BTN   = 15
local EXT_GAP   = 12
local CTRL_H    = SPEC_ICON      -- hauteur du selecteur et des boutons = taille des icones
local PADX      = 10             -- padding interne du container Summary/Variantes
local PADY      = 7
local SUMMARY_ICONS = 8          -- le container Summary doit pouvoir afficher 8 icones
local SUMMARY_W = PADX * 2 + SUMMARY_ICONS * SPEC_ICON + (SUMMARY_ICONS - 1) * SPEC_GAP

local WHITE8X8       = "Interface\\Buttons\\WHITE8x8"
local TOOLTIP_BORDER = "Interface\\Tooltips\\UI-Tooltip-Border"

local POPUP_W    = 300
local POPUP_MAXH = 380
local HEADER_H   = 26
local FILTER_H   = 50            -- bandeau fixe (2 cases : spe courante + plans synces) au-dessus du scroll
local ICON_RECAP  = 30            -- taille des icones dans les lignes du popup selecteur
local VARROW_H    = 60            -- ligne de variante sur 2 niveaux : nom + rangee d'icones
local SECTION_GAP = 8

-- Confirmation de suppression d'une variante (StaticPopup => toujours au-dessus).
StaticPopupDialogs["ECP_DELETE_VARIANT"] = {
    text = "Delete variant \"%s\"?",
    button1 = YES, button2 = NO,
    OnAccept = function(self, data)
        local id = data or (self and self.data)
        if id and HR.V2_DeleteVariant(id) then
            UI.RefreshRows()
            if UI.varPopup and UI.varPopup:IsShown() then UI.RenderVariantPopup() end   -- maj liste, popup reste ouvert
        end
    end,
    -- Reaffiche le catcher du selecteur (neutralise pendant la confirmation) s'il est encore
    -- ouvert -> le clic-en-dehors refonctionne apres le dialog (Yes comme No).
    OnHide = function()
        if UI.varPopup and UI.varPopup:IsShown() and UI.varPopup.catcher then
            UI.varPopup.catcher:Show()
        end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, showAlert = true, preferredIndex = 3,
}

-- Confirmation de remise a ZERO de la planification du BOSS AFFICHE (variante VISIBLE).
-- data = { variant, encounterID } capture au clic. Vide juste ce boss (autres boss intacts).
StaticPopupDialogs["ECP_RESET_BOSS_PLAN"] = {
    text = "Reset the plan for \"%s\"?\n\nAll cooldowns placed on this boss will be removed.\nThis action is irreversible.",
    button1 = YES, button2 = NO,
    OnAccept = function(self, data)
        data = data or (self and self.data)
        if data and HR.ClearVariantBossPlan(data.variant, data.encounterID) then
            UI.RefreshRows()
            HR:Print("Boss plan reset.")
        end
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, showAlert = true, preferredIndex = 3,
}

-- Recap d'une variante en ICONES (markup), version rescaled du recap du main frame.
local function VariantRecapMarkup(v, size)
    size = size or 16
    local parts = {}
    if v.healer then
        -- ...OrNone : une variante SANS heal montre l'icone "No healer" plutot que rien
        -- (sinon son recap commencerait direct aux externals, sans dire de quoi il s'agit).
        local prof = HR.GetHealProfileOrNone(v.healer)
        if prof then parts[#parts + 1] = HR.HealProfileIconMarkup(prof, size) end
    end
    -- CD du heal selon ses talents (icones).
    for _, cd in ipairs(HR.GetVariantHealerCDs(v)) do
        local icon = HR.GetDefensiveIcon(cd.key)
        parts[#parts + 1] = string.format("|T%s:%d:%d:0:0:64:64:5:59:5:59|t", tostring(icon), size, size)
    end
    for _, e in ipairs(HR.GetExternals()) do
        local n = HR.VariantExternalCount(v.externals, v.talentSpells, e.key)   -- + trinket du heal
        if n > 0 then
            local icon = HR.GetDefensiveIcon(e.key)
            local m = string.format("|T%s:%d:%d:0:0:64:64:5:59:5:59|t", tostring(icon), size, size)
            for _ = 1, n do parts[#parts + 1] = m end   -- 1 icone PAR exemplaire (pas de chiffre)
        end
    end
    return table.concat(parts, " ")
end

-- "Classe - Spe" (ex. "Monk - Mistweaver").
local function SpecLabel(prof)
    local className = HR.ClassName(prof.class)
    local specName = prof.spec
    if (not specName) and prof.specID and GetSpecializationInfoByID then
        local _, n = GetSpecializationInfoByID(prof.specID); specName = n
    end
    return className .. (specName and (" - " .. specName) or "")
end

--------------------------------------------------------------------------------
-- Selecteur de variante CUSTOM (popup maison)
--------------------------------------------------------------------------------

local function BuildVariantPopup()
    if UI.varPopup then return end
    -- Composant partage (fond + bordure + scroll + catcher), cf. C.ScrollPopup.
    local f = UI.Components.ScrollPopup({ name = "ECPVariantPopup", width = POPUP_W })
    f.content.headers = {}; f.content.rows = {}

    -- Bandeau FIXE (ne defile pas) : case "Show current class only" ancree au cadre
    -- externe, le scroll est repousse de FILTER_H pour lui laisser la place.
    local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    cb:SetSize(22, 22)
    cb:SetPoint("TOPLEFT", 6, -4)
    cb.label = cb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cb.label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    cb.label:SetText("Show current spec only")
    cb:SetScript("OnClick", function(self)
        HR.db.options.variantSpecOnly = self:GetChecked() and true or false
        UI.RenderVariantPopup()          -- re-render la liste, le popup reste ouvert
    end)
    f.classFilter = cb

    -- Case "Show sync plans" : les plans POUSSES par un tiers n'apparaissent pas dans la
    -- liste normale (ils ne sont pas l'oeuvre du joueur). Cochee, elle n'affiche QU'EUX et
    -- court-circuite "Show current spec only" -- un plan recu d'un autre heal n'a aucune
    -- raison d'etre masque par le filtre de spe.
    local sb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    sb:SetSize(22, 22)
    sb:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 0, -2)
    sb.label = sb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sb.label:SetPoint("LEFT", sb, "RIGHT", 2, 0)
    sb.label:SetText("Show sync plans")
    sb:SetScript("OnClick", function(self)
        HR.db.options.showSyncedPlans = self:GetChecked() and true or false
        UI.RenderVariantPopup()          -- re-render la liste, le popup reste ouvert
    end)
    f.syncFilter = sb

    f.scroll:SetPoint("TOPLEFT", 6, -(6 + FILTER_H))

    UI.varPopup = f
    UI.varPopupCatcher = f.catcher       -- compat (ToggleVariantPopup l'utilise)
end

local function AcquireHeader(content, i)
    local h = content.headers[i]
    if not h then
        h = CreateFrame("Frame", nil, content)
        h:SetHeight(HEADER_H)
        h.text = h:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        h.text:SetPoint("BOTTOMLEFT", 4, 4)
        h.line = h:CreateTexture(nil, "ARTWORK")
        h.line:SetPoint("BOTTOMLEFT", 2, 0); h.line:SetPoint("BOTTOMRIGHT", -2, 0); h.line:SetHeight(1)
        content.headers[i] = h
    end
    h:Show()
    return h
end

local function AcquireVarRow(content, i)
    local r = content.rows[i]
    if not r then
        r = CreateFrame("Button", nil, content)
        r:SetHeight(VARROW_H)
        r.sel = r:CreateTexture(nil, "BACKGROUND"); r.sel:SetAllPoints(); r.sel:SetColorTexture(1, 1, 1, 0.18); r.sel:Hide()
        r:SetHighlightTexture(WHITE8X8, "ADD")
        local hl = r:GetHighlightTexture(); if hl then hl:SetVertexColor(1, 1, 1, 0.08) end
        -- Ligne 1 : nom de la variante.
        r.name = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        r.name:SetPoint("TOPLEFT", 10, -5); r.name:SetPoint("RIGHT", -26, 0)
        r.name:SetJustifyH("LEFT"); r.name:SetWordWrap(false)
        r.name:SetTextColor(HR.Theme.Unpack("BASE_TEXT_COLOR"))   -- nom de variante en BASE (le GameFontNormal est dore par defaut)
        -- Ligne 2 : rangee d'icones (pool, remplie par UI.LayoutVariantIcons).
        r.iconPool = {}
        -- Croix de suppression (en haut a droite ; cachee pour les Base templates).
        r.del = CreateFrame("Button", nil, r)
        r.del:SetSize(20, 20)
        r.del:SetPoint("TOPRIGHT", -2, -4)
        r.del.x = r.del:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        r.del.x:SetPoint("CENTER"); r.del.x:SetText("\195\151"); r.del.x:SetTextColor(0.7, 0.7, 0.7)
        r.del:SetScript("OnEnter", function(s) s.x:SetTextColor(1, 0.3, 0.3) end)
        r.del:SetScript("OnLeave", function(s) s.x:SetTextColor(0.7, 0.7, 0.7) end)
        content.rows[i] = r
    end
    r:Show()
    return r
end

-- Rend UN groupe (header + rangees) du selecteur. `st` porte l'etat de mise en page mutable
-- (y courant + compteurs de pools). Extrait pour etre rejoue a l'identique sur le groupe
-- "No healer", qui vit HORS de HR.HEAL_PROFILES.
local function RenderVariantGroup(content, W, prof, grp, activeId, st)
    table.sort(grp, function(a, b)
        local ab, bb = a.base and 0 or 1, b.base and 0 or 1
        if ab ~= bb then return ab < bb end
        return (a.name or "") < (b.name or "")
    end)
    st.hi = st.hi + 1
    local h = AcquireHeader(content, st.hi)
    h:ClearAllPoints(); h:SetPoint("TOPLEFT", 0, -st.y); h:SetWidth(W)
    -- prof.class est nil pour le pseudo-profil "No healer" -> gris neutre (pas de couleur
    -- de classe), et libelle explicite (SpecLabel suppose une vraie classe).
    local c = (prof.class and RAID_CLASS_COLORS[prof.class]) or { r = 0.7, g = 0.7, b = 0.7 }
    h.text:SetText(prof.class and SpecLabel(prof) or prof.name)
    h.text:SetTextColor(c.r, c.g, c.b)
    h.line:SetColorTexture(c.r, c.g, c.b, 0.55)
    st.y = st.y + HEADER_H
    for _, v in ipairs(grp) do
        st.ri = st.ri + 1
        local r = AcquireVarRow(content, st.ri)
        r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, -st.y); r:SetWidth(W)
        -- Prefixe "DEFAULT" (rouge) devant le nom si c'est la variante auto-chargee de sa spe.
        local nm = HR.IsDefaultVariant(v.id) and (HR.Theme.Hex("ERROR_COLOR") .. "DEFAULT|r " .. v.name) or v.name
        -- Prefixe "SYNC" (vert) pour un plan POUSSE par un tiers : ce n'est pas l'oeuvre du
        -- joueur, et son contenu sera ecrase a la prochaine poussee de son auteur.
        if v.synced then nm = HR.COLORS.GREEN .. "SYNC|r " .. nm end
        r.name:SetText(nm)
        UI.LayoutVariantIcons(r, r.iconPool, 10, -24, v, ICON_RECAP, 6)   -- ligne 2
        r.sel:SetShown(activeId == v.id)
        r:SetScript("OnClick", function()
            HR.SelectVariant(v.id); UI.CloseVariantPopup(); UI.RefreshRows()
        end)
        if v.base then
            r.del:Hide()
        else
            r.del:Show()
            r.del:SetScript("OnClick", function()
                -- On NE ferme PAS le selecteur. Le catcher (FULLSCREEN) fermerait le popup
                -- au moindre clic -> on le NEUTRALISE le temps de la confirmation (reaffiche
                -- a la fermeture du dialog, cf. OnHide de ECP_DELETE_VARIANT). On remonte
                -- aussi le dialog au-dessus du popup pour qu'il soit visible/cliquable.
                if UI.varPopup and UI.varPopup.catcher then UI.varPopup.catcher:Hide() end
                local dlg = StaticPopup_Show("ECP_DELETE_VARIANT", v.name, nil, v.id)
                if dlg then dlg:SetFrameStrata("FULLSCREEN_DIALOG"); dlg:Raise() end
            end)
        end
        st.y = st.y + VARROW_H
    end
    st.y = st.y + SECTION_GAP
end

function UI.RenderVariantPopup()
    BuildVariantPopup()
    local content = UI.varPopup.content
    for _, h in ipairs(content.headers) do h:Hide() end
    for _, r in ipairs(content.rows) do r:Hide() end

    -- Filtre "Show current spec only" : reflette l'option sur la case + calcule la clef
    -- de profil de heal du joueur (spe active ; pretre => PRIEST_HOLY/PRIEST_DISC).
    -- ⚠️ INOPERANT pour un non-healer : sa clef ("WARRIOR"...) ne matche aucun profil, le
    -- popup se viderait ENTIEREMENT. On grise la case et on ignore l'option pour lui (sans
    -- jamais ECRIRE dans HR.db.options : elle reste valable pour ses persos heal).
    local isHealer = HR.IsHealerPlayer()
    local syncOnly = HR.db.options.showSyncedPlans and true or false
    if UI.varPopup.syncFilter then
        UI.varPopup.syncFilter:SetChecked(syncOnly)
    end
    if UI.varPopup.classFilter then
        UI.varPopup.classFilter:SetChecked(HR.db.options.variantSpecOnly and true or false)
        -- Grisee quand le filtre de sync prend la main (elle est alors sans effet), comme
        -- pour un non-healer. On n'ECRIT jamais dans l'option : elle reste vraie ailleurs.
        UI.varPopup.classFilter:SetEnabled(isHealer and not syncOnly)
        local g = (isHealer and not syncOnly) and 1 or 0.5
        UI.varPopup.classFilter.label:SetTextColor(g, g, g)
    end
    local specOnly = (not syncOnly) and HR.db.options.variantSpecOnly and isHealer
    local myKey = HR.MyHealKey()

    -- Les plans RECUS d'un tiers (`v.synced`) et les plans du joueur ne cohabitent jamais
    -- dans la liste : la case bascule de l'un a l'autre.
    local list = {}
    for _, v in ipairs(HR.V2_GetVariants()) do
        if (v.synced and true or false) == syncOnly then list[#list + 1] = v end
    end
    local active = HR.GetActiveVariant()
    local activeId = active and active.id
    local byHealer = {}
    for _, v in ipairs(list) do
        local k = v.healer or HR.NO_HEALER      -- healer absent (donnee heritee) => groupe "No healer"
        byHealer[k] = byHealer[k] or {}
        table.insert(byHealer[k], v)
    end

    local W = UI.varPopup:GetWidth() - 34    -- largeur calee sur celle du select (cf. ToggleVariantPopup)
    content:SetWidth(W)
    local st = { y = 4, hi = 0, ri = 0 }
    for _, prof in ipairs(HR.HEAL_PROFILES) do
        local grp = byHealer[prof.key]
        if grp and ((not specOnly) or (prof.key == myKey)) then
            RenderVariantGroup(content, W, prof, grp, activeId, st)
        end
    end
    -- Groupe "No healer" (variantes de DPS/TANK) : rendu APRES les vrais profils, et TOUJOURS
    -- affiche (il n'appartient a aucune spe -> "Show current spec only" ne le masque pas).
    -- ⚠️ Sans cette passe, ces variantes seraient des FANTOMES : jouables mais absentes du
    -- selecteur, donc ni re-selectionnables ni supprimables (le bouton `del` vit ici).
    local noHeal = byHealer[HR.NO_HEALER]
    if noHeal then
        RenderVariantGroup(content, W, HR.NO_HEAL_PROFILE, noHeal, activeId, st)
    end
    content:SetHeight(math.max(st.y, 1))
    UI.varPopup:SetHeight(math.min(st.y + 12 + FILTER_H, POPUP_MAXH))
end

function UI.ToggleVariantPopup()
    BuildVariantPopup()
    if UI.varPopup:IsShown() then UI.CloseVariantPopup(); return end
    local trig = UI.specsPanel and UI.specsPanel.varTrigger
    if not trig then return end
    UI.varPopup:SetWidth(trig:GetWidth())       -- popup cale sur la largeur du select
    UI.RenderVariantPopup()                     -- (apres SetWidth : le contenu utilise GetWidth)
    UI.varPopup:ClearAllPoints()
    UI.varPopup:SetPoint("TOPLEFT", trig, "BOTTOMLEFT", 0, -2)
    UI.varPopupCatcher:Show()
    UI.varPopup:Show()
end

function UI.CloseVariantPopup()
    if UI.varPopup then UI.varPopup:Close() end   -- cache popup + catcher (cf. C.ScrollPopup)
end

--------------------------------------------------------------------------------
-- Briques reutilisables (selecteurs de spe heal et d'externals)
--------------------------------------------------------------------------------

local function SmallButton(parent, glyph)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(EXT_BTN, EXT_BTN)
    b.bg = b:CreateTexture(nil, "BACKGROUND"); b.bg:SetAllPoints(); b.bg:SetColorTexture(0.2, 0.2, 0.2, 0.9)
    b.txt = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); b.txt:SetPoint("CENTER"); b.txt:SetText(glyph)
    b:SetHighlightTexture(WHITE8X8, "ADD")
    local hl = b:GetHighlightTexture(); if hl then hl:SetVertexColor(1, 1, 1, 0.18) end
    return b
end

-- Cooldown formate "m:ss" (ou "Ns" sous la minute).
local function fmtCD(cd)
    if cd >= 60 then return string.format("%d:%02d", math.floor(cd / 60), cd % 60) end
    return cd .. "s"
end

local function CreateExtItem(parent)
    local it = CreateFrame("Frame", nil, parent)
    it:SetSize(SPEC_ICON + 2 + EXT_BTN, SPEC_ICON)

    -- Icone = ImageButton (avec bandeau noir + texte pour afficher la DUREE des variantes).
    it.btn = UI.Components.ImageButton(it, { size = SPEC_ICON, textSize = 10, textBanner = true })
    it.btn:SetPoint("LEFT")
    it.btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        if it._specName then                                   -- icone de spe heal (summary)
            GameTooltip:SetText(it._specName)
        elseif it._key then
            local d = HR.defensives[it._key]
            if d and d.itemId then GameTooltip:SetItemByID(d.itemId)          -- trinket (Vessel)
            else
                local sid = HR.GetDefensiveSpellID(it._key)
                if type(sid) == "number" then GameTooltip:SetSpellByID(sid) else GameTooltip:SetText(it._name or "") end
            end
        else
            return
        end
        GameTooltip:Show()
    end)
    it.btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    it.qty = it.btn:CreateFontString(nil, "OVERLAY")
    it.qty:SetFont(STANDARD_TEXT_FONT, 14, "OUTLINE")
    it.qty:SetPoint("TOPRIGHT", it.btn, "TOPRIGHT", -1, -1); it.qty:SetTextColor(1, 1, 1)  -- en haut (le bandeau duree est en bas)

    it.plus  = SmallButton(it, "+"); it.plus:SetPoint("TOPLEFT", it.btn, "TOPRIGHT", 2, 0)
    it.minus = SmallButton(it, "-"); it.minus:SetPoint("BOTTOMLEFT", it.btn, "BOTTOMRIGHT", 2, 0)
    return it
end

-- Declarations anticipees : LayoutVariantIcons (juste en dessous) les utilise, mais elles
-- vivent plus bas avec le reste de la mecanique summary/overflow (memes fonctions partagees).
local VariantSummaryIcons, AcquireMoreBtn

-- Icone de recap (popup selecteur de variante) : ImageButton (taille `size`) + bandeau de
-- duree. Mouse DESACTIVEE => les clics passent a la ligne (selection de variante). Pas de
-- tooltip (le popup est transitoire ; on veut surtout VOIR icones + CD).
local function CreateRecapIcon(parent, size)
    local it = CreateFrame("Frame", nil, parent)
    it:SetSize(size, size)
    it.btn = UI.Components.ImageButton(it, { size = size, textSize = 10, textBanner = true })
    it.btn:SetAllPoints()
    it.btn:EnableMouse(false)
    return it
end

-- Layout du recap d'une variante en ICONES dans `parent` a partir de (x0,y0) :
--   spec heal | CD du heal (bandeau = CD de la variante : Chi-Ji 1:00 vs 2:00...) |
--   externals repetes par compte (bandeau de duree pour les variantes AMZ/Darkness).
-- Pool reutilisable. Renvoie le x final.
function UI.LayoutVariantIcons(parent, pool, x0, y0, v, size, gap)
    size = size or ICON_RECAP; gap = gap or 6
    -- MEME mecanique que le summary : descripteurs partages + overflow (SUMMARY_ICONS-1 + "+X").
    local items = VariantSummaryIcons(v)
    local total, shownN, overflow = #items, #items, 0
    if total > SUMMARY_ICONS then
        shownN = SUMMARY_ICONS - 1
        overflow = total - shownN
    end
    local x = x0
    for i = 1, shownN do
        local item = items[i]
        local it = pool[i]
        if not it then it = CreateRecapIcon(parent, size); pool[i] = it end
        it:SetSize(size, size); it.btn:SetSize(size, size)
        if item.spec then
            HR.ApplyHealProfileIcon(it.btn.image, item.spec); it.btn.image:SetDesaturated(false)
            it.btn:SetText(""); if it.btn.textBanner then it.btn.textBanner:SetShown(false) end
        else
            it.btn:SetImage(HR.GetDefensiveIcon(item.key)); it.btn.image:SetDesaturated(false)
            it.btn:SetText(item.banner and fmtCD(item.cd) or "")
            if it.btn.textBanner then it.btn.textBanner:SetShown(item.banner and true or false) end
        end
        it:ClearAllPoints(); it:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y0); it:Show()
        x = x + size + gap
    end
    for j = shownN + 1, #pool do pool[j]:Hide() end

    if overflow > 0 then
        local hidden = {}
        for i = shownN + 1, total do hidden[#hidden + 1] = items[i] end
        local b = AcquireMoreBtn(parent, size)
        b:SetSize(size, size); b.txt:SetText("+" .. overflow); b._hidden = hidden
        b:ClearAllPoints(); b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y0); b:Show()
        x = x + size + gap
    elseif parent._moreBtn then
        parent._moreBtn:Hide()
    end
    return x
end

-- Descripteurs ORDONNES des icones du summary d'une variante : spec heal, puis CD du heal
-- (selon talents), puis externals (repetes par compte). { spec=prof } | { key, name, cd, banner }.
-- (assigne l'upvalue anticipe -> utilisable par LayoutVariantIcons defini plus haut)
function VariantSummaryIcons(v)
    local items = {}
    if v.healer then
        -- ...OrNone : cf. VariantRecapMarkup -- une variante sans heal affiche "No healer".
        local prof = HR.GetHealProfileOrNone(v.healer)
        if prof then items[#items + 1] = { spec = prof, name = prof.name } end
    end
    for _, cd in ipairs(HR.GetVariantHealerCDs(v)) do
        items[#items + 1] = { key = cd.key, name = cd.name, cd = cd.cooldown, banner = true }
    end
    for _, e in ipairs(HR.GetExternals()) do
        local n = HR.VariantExternalCount(v.externals, v.talentSpells, e.key)
        local d = HR.defensives[e.key]
        local hasDur = (d and d.spellID) and true or false
        for _ = 1, n do
            items[#items + 1] = { key = e.key, name = e.name, cd = d.cooldown, banner = hasDur }
        end
    end
    return items
end


-- Tooltip CUSTOM du bouton overflow : grille d'ICONES (image + bandeau duree) des sorts
-- non affiches, dimensionnee selon son contenu.
local OVTIP_PAD, OVTIP_COLS = 8, 8
local function BuildOverflowTip()
    if UI.ovTip then return UI.ovTip end
    local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    f:SetFrameStrata("TOOLTIP")
    f:SetBackdrop({ bgFile = WHITE8X8, edgeFile = TOOLTIP_BORDER, edgeSize = 12,
                    insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    f:SetBackdropColor(0.06, 0.06, 0.07, 0.98)
    f:SetBackdropBorderColor(HR.Theme.Unpack("POPUP_BORDER_COLOR"))
    f.icons = {}
    f:Hide()
    UI.ovTip = f
    return f
end

local function ShowOverflowTip(anchor, items)
    if not items or #items == 0 then return end
    local f = BuildOverflowTip()
    local n = #items
    local cols = math.min(n, OVTIP_COLS)
    local rows = math.ceil(n / OVTIP_COLS)
    for i, item in ipairs(items) do
        local it = f.icons[i]
        if not it then it = CreateRecapIcon(f, SPEC_ICON); f.icons[i] = it end
        it:SetSize(SPEC_ICON, SPEC_ICON); it.btn:SetSize(SPEC_ICON, SPEC_ICON)
        if item.spec then
            HR.ApplyHealProfileIcon(it.btn.image, item.spec); it.btn.image:SetDesaturated(false)
            it.btn:SetText(""); if it.btn.textBanner then it.btn.textBanner:SetShown(false) end
        else
            it.btn:SetImage(HR.GetDefensiveIcon(item.key)); it.btn.image:SetDesaturated(false)
            it.btn:SetText(item.banner and fmtCD(item.cd) or "")
            if it.btn.textBanner then it.btn.textBanner:SetShown(item.banner and true or false) end
        end
        local col, row = (i - 1) % OVTIP_COLS, math.floor((i - 1) / OVTIP_COLS)
        it:ClearAllPoints()
        it:SetPoint("TOPLEFT", f, "TOPLEFT", OVTIP_PAD + col * (SPEC_ICON + SPEC_GAP),
                                            -OVTIP_PAD - row * (SPEC_ICON + SPEC_GAP))
        it:Show()
    end
    for j = n + 1, #f.icons do f.icons[j]:Hide() end
    f:SetSize(OVTIP_PAD * 2 + cols * SPEC_ICON + (cols - 1) * SPEC_GAP,
              OVTIP_PAD * 2 + rows * SPEC_ICON + (rows - 1) * SPEC_GAP)
    f:ClearAllPoints(); f:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 4)
    f:Show()
end

local function HideOverflowTip()
    if UI.ovTip then UI.ovTip:Hide() end
end

-- Bouton overflow "+X" reutilisable (un par `parent`, memorise dans parent._moreBtn) : meme
-- tooltip custom que le summary. SetPropagateMouseClicks => le clic selectionne quand meme la
-- ligne du popup (la souris reste active pour le hover du tooltip). Assigne l'upvalue anticipe.
function AcquireMoreBtn(parent, size)
    local b = parent._moreBtn
    if not b then
        b = CreateFrame("Frame", nil, parent)
        b.bg = b:CreateTexture(nil, "BACKGROUND"); b.bg:SetAllPoints(); b.bg:SetColorTexture(0.15, 0.15, 0.15, 0.95)
        b.txt = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); b.txt:SetPoint("CENTER"); b.txt:SetTextColor(1, 1, 1)
        b:EnableMouse(true)
        if b.SetPropagateMouseClicks then b:SetPropagateMouseClicks(true) end
        b:SetScript("OnEnter", function(self) ShowOverflowTip(self, self._hidden) end)
        b:SetScript("OnLeave", function() HideOverflowTip() end)
        parent._moreBtn = b
    end
    return b
end

-- Rangee de choix du profil : les 7 profils de heal, PUIS une icone "No healer" (variante de
-- DPS/TANK : un plan d'externals sans soigneur designe). Ce dernier choix vaut HR.NO_HEALER,
-- une clef bien reelle -> la variante reste editable, listable et partageable (a l'inverse
-- d'un healer nil, qui la rendrait inaccessible).
local function RenderHealerRow(parent, pool, x0, y0, getSel, onSel)
    local x = x0
    local profiles = {}
    for i, prof in ipairs(HR.HEAL_PROFILES) do profiles[i] = prof end
    profiles[#profiles + 1] = HR.NO_HEAL_PROFILE
    for i, prof in ipairs(profiles) do
        local b = pool[i]
        if not b then
            b = UI.Components.ImageButton(parent, { size = SPEC_ICON })
            b:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText(self._specName or ""); GameTooltip:Show()
            end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
            pool[i] = b
        end
        b._specName = prof.name
        HR.ApplyHealProfileIcon(b.image, prof)
        b:SetOnClick(function() onSel(prof.key) end)
        b:SetSelected(getSel() == prof.key)
        b:ClearAllPoints(); b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y0); b:Show()
        x = x + SPEC_ICON + SPEC_GAP
    end
    for j = #profiles + 1, #pool do pool[j]:Hide() end
    return x
end

-- Configure un item-icone d'external (image + bandeau duree). `it` = CreateExtItem.
local function setupExtIcon(it, e, desat)
    it._key = e.key; it._name = e.name
    it.btn:SetImage(HR.GetDefensiveIcon(e.key))
    it.btn.image:SetDesaturated(desat)
    -- Duree (bandeau noir) seulement pour les sorts a VARIANTES (cle synthetique avec
    -- champ spellID : AMZ, Darkness...). Sorts simples => pas de bandeau.
    local d = HR.defensives[e.key]
    local hasDur = (d and d.spellID) and true or false
    it.btn:SetText(hasDur and fmtCD(d.cooldown) or "")
    if it.btn.textBanner then it.btn.textBanner:SetShown(hasDur) end
end

local function RenderExternalsRow(parent, pool, x0, y0, ext, onChange, readOnly, talentSpells)
    local x, shown = x0, 0
    for _, e in ipairs(HR.GetExternals()) do
        if readOnly then
            -- Summary : 1 icone PAR exemplaire (un sort/item 2x = 2 icones), AUCUN chiffre.
            -- Compte = compo externals + trinket du heal (cf. HR.VariantExternalCount).
            local n = HR.VariantExternalCount(ext, talentSpells, e.key)
            for _ = 1, n do
                shown = shown + 1
                local it = pool[shown]
                if not it then it = CreateExtItem(parent); pool[shown] = it end
                setupExtIcon(it, e, false)
                it.qty:Hide(); it.plus:Hide(); it.minus:Hide()
                it:ClearAllPoints(); it:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y0); it:Show()
                x = x + SPEC_ICON + SPEC_GAP
            end
        else
            -- Modale editable : 1 icone + compteur + boutons +/- (le trinket du heal n'est
            -- PAS replie ici, il a son propre toggle dans la rangee talents).
            local n = ext[e.key] or 0
            shown = shown + 1
            local it = pool[shown]
            if not it then it = CreateExtItem(parent); pool[shown] = it end
            setupExtIcon(it, e, n == 0)
            if n > 0 then it.qty:SetText(n); it.qty:Show() else it.qty:Hide() end
            it.plus:Show(); it.minus:Show()
            it.plus:SetScript("OnClick", function() ext[e.key] = (ext[e.key] or 0) + 1; if onChange then onChange() end end)
            it.minus:SetScript("OnClick", function() ext[e.key] = math.max(0, (ext[e.key] or 0) - 1); if onChange then onChange() end end)
            it:ClearAllPoints(); it:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y0); it:Show()
            x = x + SPEC_ICON + 2 + EXT_BTN + EXT_GAP
        end
    end
    for j = shown + 1, #pool do pool[j]:Hide() end
    return x
end

-- Item d'une VARIANTE de sort talente : ImageButton (icone) + duree en TEXTE OVERLAY
-- (bandeau noir) pour distinguer les durees d'un meme sort.
local function CreateTalentItem(parent)
    local it = CreateFrame("Frame", nil, parent)
    it:SetSize(SPEC_ICON, SPEC_ICON)
    it.btn = UI.Components.ImageButton(it, { size = SPEC_ICON, textSize = 10, textBanner = true })
    it.btn:SetPoint("TOPLEFT")
    it.btn:SetScript("OnEnter", function(self)
        local d = it._key and HR.defensives[it._key]
        if not d then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        if d.itemId then GameTooltip:SetItemByID(d.itemId) else GameTooltip:SetSpellByID(it._sid) end
        GameTooltip:AddLine(d.name .. "  " .. fmtCD(d.cooldown), 1, 1, 1, true)
        GameTooltip:Show()
    end)
    it.btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return it
end

-- `spells` = HR.GetHealerTalentSpells(profil) ; `choices` = { [spellID] = cle_variante|nil }.
-- Chaque VARIANTE = une icone (cote a cote) ; comportement SWITCH : clic = selectionne (et
-- desactive l'autre variante du meme sort) ; re-clic sur la selectionnee = desactive.
local TALENT_GROUP_GAP = 14   -- ecart entre deux sorts (groupes de variantes)
local function RenderTalentRow(parent, pool, x0, y0, spells, choices, onChange)
    local x, idx = x0, 0
    for si, sp in ipairs(spells) do
        if si > 1 then x = x + TALENT_GROUP_GAP end
        local cur = choices[sp.spellID]
        for _, key in ipairs(sp.variants) do
            idx = idx + 1
            local it = pool[idx]
            if not it then it = CreateTalentItem(parent); pool[idx] = it end
            local d = HR.defensives[key]
            it._sid, it._key = sp.spellID, key
            it.btn:SetImage(HR.GetDefensiveIcon(key))   -- gere itemId (trinket) + spellID
            it.btn:SetText(d and fmtCD(d.cooldown) or "?")   -- duree en overlay (bandeau noir)
            it.btn:SetSelected(cur == key)
            it.btn:SetOnClick(function()
                if choices[sp.spellID] == key then
                    choices[sp.spellID] = nil                                   -- re-clic = desactive
                else
                    choices[sp.spellID] = key                                   -- switch vers cette variante
                    -- choiceNode : sorts mutuellement exclusifs -> desactive les autres du meme node.
                    if sp.choiceNode then
                        for _, other in ipairs(spells) do
                            if other.spellID ~= sp.spellID and other.choiceNode == sp.choiceNode then
                                choices[other.spellID] = nil
                            end
                        end
                    end
                end
                if onChange then onChange() end
            end)
            it:ClearAllPoints(); it:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y0); it:Show()
            x = x + SPEC_ICON + SPEC_GAP
        end
    end
    for j = idx + 1, #pool do pool[j]:Hide() end
    return x
end

-- Rangee de TEMPLATES selectionnables (boutons texte, single-select). Affichee quand la
-- case "Copy from a template" est cochee. `emptyFS` montre si aucun template ne matche.
local function RenderTemplateRow(parent, pool, x0, y0, templates, selectedId, onPick, emptyFS)
    if #templates == 0 then
        for _, b in ipairs(pool) do b:Hide() end
        if emptyFS then emptyFS:ClearAllPoints(); emptyFS:SetPoint("TOPLEFT", parent, "TOPLEFT", x0, y0 - 4); emptyFS:Show() end
        return
    end
    if emptyFS then emptyFS:Hide() end
    local x = x0
    for i, t in ipairs(templates) do
        local b = pool[i]
        if not b then b = UI.Components.TextButton(parent, { autoWidth = true, minWidth = 0, padX = 12, padY = 6 }); pool[i] = b end
        b:SetText(t.name or ("Template " .. tostring(t.id)))
        b:SetSelected(selectedId == t.id)
        b:SetOnClick(function() onPick(t.id) end)
        b:ClearAllPoints(); b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y0); b:Show()
        x = x + b:GetWidth() + 6
    end
    for j = #templates + 1, #pool do pool[j]:Hide() end
end

--------------------------------------------------------------------------------
-- Bandeau du main frame (READ-ONLY) + controles de variante (colles a droite)
--------------------------------------------------------------------------------

-- Une variante peut etre promue en template SI elle est healer-seul (aucun external
-- declare > 0) ET qu'elle n'est pas deja un template (isTemplate / Base template).
local function CanSetTemplate(v)
    if not v or v.isTemplate or v.base then return false end
    for _, n in pairs(v.externals or {}) do
        if (n or 0) > 0 then return false end
    end
    return true
end

function UI.BuildHealerSpecs(parent)
    if UI.specsPanel then return UI.specsPanel end
    local p = CreateFrame("Frame", nil, parent)
    p:SetHeight(UI.SPECS_H)

    -- DEUX conteneurs distincts (composant reutilisable C.Container : fond + bordure +
    -- padding parametrables, defauts thémés). content=false : on ancre le contenu sur `p`
    -- et on dimensionne chaque boite pour epouser SON contenu (cf. fonctions de rendu).
    -- Crees AVANT le contenu => dessines derriere.
    p.summaryBox = UI.Components.Container(p, { padX = PADX, padY = PADY, content = false, thickness = 2 })
    p.variantBox = UI.Components.Container(p, { padX = PADX, padY = PADY, content = false })
    p.summaryBox:SetFrameLevel(p:GetFrameLevel())   -- sous les frames de contenu (icone/boutons)
    p.variantBox:SetFrameLevel(p:GetFrameLevel())

    -- Boite "variante ACTIVE" : (0) sous-titre, (1) nom de la variante ACTIVE (jouee en
    -- combat), (2) bouton "Show this variant on screen" (selectionne l'active a l'ecran).
    -- Tooltip explicatif + bordure ROUGE quand la variante VISIBLE (selectionnee) != ACTIVE.
    p.boxSubtitle = p.summaryBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    p.boxSubtitle:SetPoint("TOPLEFT", PADX, -6); p.boxSubtitle:SetPoint("RIGHT", p.summaryBox, "RIGHT", -PADX, 0)
    p.boxSubtitle:SetJustifyH("LEFT"); p.boxSubtitle:SetTextColor(HR.Theme.Unpack("BASE_TEXT_COLOR"))
    p.boxSubtitle:SetText("Your currently active variant for this dungeon")

    -- Titre = "<nom du boss>  -  <nom de la variante active>".
    p.boxTitle = p.summaryBox:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    p.boxTitle:SetPoint("TOPLEFT", PADX, -24); p.boxTitle:SetPoint("RIGHT", p.summaryBox, "RIGHT", -PADX, 0)
    p.boxTitle:SetJustifyH("LEFT"); p.boxTitle:SetWordWrap(false); p.boxTitle:SetTextColor(1, 1, 1)

    p.boxShow = UI.Components.TextButton(p.summaryBox, { text = "Show this variant on screen", autoWidth = true,
        minWidth = 0, padX = 10, padY = 4, onClick = function()
            local active = HR.GetV2Used()
            if active then HR.SelectVariant(active.id); UI.RefreshRows() end
        end })

    -- Tooltip d'aide CUSTOM (composant reutilisable) : explique active vs visible, SEULEMENT
    -- quand differentes (title renvoie nil sinon => pas de tooltip).
    UI.Components.AttachHelpTip(p.summaryBox,
        function(self) return self._dirty and "Active vs visible variant" or nil end,
        "The active variant is the variant that is gonna play during a boss fight. "
        .. "The currently visible variant is not the one that will be used during combat. "
        .. "If you wish to active the currently visible variant during combat, click the \"use\" button.",
        { titleColor = HR.Theme.Color("ERROR_COLOR") })

    p.healerIcon = UI.Components.ImageButton(p, { size = SPEC_ICON })
    p.healerIcon:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM"); GameTooltip:SetText(self._specName or ""); GameTooltip:Show()
    end)
    p.healerIcon:SetScript("OnLeave", function() GameTooltip:Hide() end)
    p.healerIcon:Hide()

    p.exts = {}; p.healerCDs = {}; p.summaryIcons = {}

    -- Bouton d'OVERFLOW du summary ("+X") : montre le nombre d'icones non affichees, et
    -- liste les sorts manquants au survol (tooltip).
    p.summaryMore = CreateFrame("Frame", nil, p)
    p.summaryMore:SetSize(SPEC_ICON, SPEC_ICON)
    p.summaryMore.bg = p.summaryMore:CreateTexture(nil, "BACKGROUND")
    p.summaryMore.bg:SetAllPoints(); p.summaryMore.bg:SetColorTexture(0.15, 0.15, 0.15, 0.95)
    p.summaryMore.txt = p.summaryMore:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.summaryMore.txt:SetPoint("CENTER"); p.summaryMore.txt:SetTextColor(1, 1, 1)
    p.summaryMore:EnableMouse(true)
    p.summaryMore:SetScript("OnEnter", function(self) ShowOverflowTip(self, self._hidden) end)
    p.summaryMore:SetScript("OnLeave", function() HideOverflowTip() end)
    p.summaryMore:Hide()
    p.empty = p.summaryBox:CreateFontString(nil, "OVERLAY", "GameFontDisable"); p.empty:SetText("No variant yet - click New"); p.empty:Hide()

    p.varTrigger = CreateFrame("Button", nil, p, "BackdropTemplate")
    p.varTrigger:SetSize(210, CTRL_H)
    -- Bordure alignee sur les boutons arrondis (tokens BUTTON_BORDER_ROUND_*).
    p.varTrigger:SetBackdrop({ bgFile = WHITE8X8, edgeFile = TOOLTIP_BORDER,
                               edgeSize = HR.Theme.Value("BUTTON_BORDER_ROUND_THICKNESS", 12),
                               insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    p.varTrigger:SetBackdropColor(0.15, 0.15, 0.15, 0.95)
    p.varTrigger:SetBackdropBorderColor(HR.Theme.Unpack("POPUP_BORDER_COLOR"))
    p.varTrigger.label = p.varTrigger:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    p.varTrigger.label:SetPoint("LEFT", 8, 0); p.varTrigger.label:SetPoint("RIGHT", -18, 0)
    p.varTrigger.label:SetJustifyH("LEFT"); p.varTrigger.label:SetTextColor(1, 1, 1)
    p.varTrigger.arrow = p.varTrigger:CreateTexture(nil, "OVERLAY")
    p.varTrigger.arrow:SetSize(12, 12); p.varTrigger.arrow:SetPoint("RIGHT", -5, 0)
    p.varTrigger.arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
    p.varTrigger:SetHighlightTexture(WHITE8X8, "ADD")
    local thl = p.varTrigger:GetHighlightTexture()
    if thl then thl:SetVertexColor(1, 1, 1, 0.08); thl:SetPoint("TOPLEFT", 3, -3); thl:SetPoint("BOTTOMRIGHT", -3, 3) end
    p.varTrigger:SetScript("OnClick", function() UI.ToggleVariantPopup() end)
    p.varTrigger:Hide()

    p.varNew = UI.Components.TextButton(p, { text = "New", autoWidth = true, minWidth = 0, padX = 15, padY = 9, onClick = function() UI.OpenNewVariantModal() end })
    p.varNew:Hide()
    p.varDup = UI.Components.TextButton(p, { text = "Duplicate", autoWidth = true, minWidth = 0, padX = 15, padY = 9, onClick = function() UI.OpenDuplicateModal() end })
    p.varDup:Hide()
    p.varEdit = UI.Components.TextButton(p, { text = "Edit", autoWidth = true, minWidth = 0, padX = 15, padY = 9, onClick = function()
        local cur = HR.GetActiveVariant()
        if not cur then HR:Print("No variant to edit."); return end
        UI.OpenEditVariantModal(cur)
    end })
    p.varEdit:Hide()

    -- Use : definit la variante SELECTIONNEE comme ACTIVE (jouee en combat, ★).
    p.varUse = UI.Components.TextButton(p, { text = "Use", autoWidth = true, minWidth = 0, padX = 15, padY = 9, onClick = function()
        local cur = HR.GetActiveVariant()
        if cur then
            HR.SetV2Used(cur.id)
            UI.RefreshRows()
            HR:Print(("Variant \"%s\" set as active in combat."):format(cur.name))
        end
    end })
    p.varUse:Hide()

    -- Default : marque la variante VISIBLE comme defaut auto-charge a l'entree du donjon
    -- (pour MA spe active). Toggle : re-cliquer retire le defaut. Une seule par (donjon, spe).
    p.varDefault = UI.Components.TextButton(p, { text = "Default", autoWidth = true, minWidth = 0, padX = 15, padY = 9, onClick = function()
        local cur = HR.GetActiveVariant()
        if not cur then return end
        local dID = UI.activeDungeonID
        if HR.IsDefaultVariant(cur.id, dID) then
            HR.ClearDefaultVariant(cur.id, dID)          -- retrait TOUJOURS permis (meme spe differente)
            HR:Print(("Variant \"%s\" is no longer the auto-load default."):format(cur.name))
        elseif HR.SetDefaultVariant(cur.id, dID) then
            HR:Print(("Variant \"%s\" will auto-load when you enter this dungeon on this spec."):format(cur.name))
        else
            -- Seul echec restant depuis que le defaut est cle sur la specID du JOUEUR :
            -- specialisation indeterminee (GetSpecialization nil, ex. perso bas niveau).
            HR:Print("Could not set the default: your current specialization is unknown.")
        end
        UI.RefreshRows()
    end })
    UI.Components.AttachHelpTip(p.varDefault, "Default variant", function()
        local cur = HR.GetActiveVariant()
        -- Le defaut est cle sur la spe ACTIVE DU JOUEUR (pas sur le profil heal de la
        -- variante) -> n'importe quelle variante peut l'etre, y compris un plan importe
        -- d'un autre heal ou une variante "No healer".
        local body = "Auto-load this variant when you enter this dungeon on your current spec. "
            .. "Only one default per dungeon and spec; setting a new one replaces the previous."
        if cur and not (HR.CanSetDefault(cur) or HR.IsDefaultVariant(cur.id, UI.activeDungeonID)) then
            body = body .. "\n|cffff6060Unavailable:|r your current specialization is unknown."
        end
        return body
    end)
    p.varDefault:Hide()

    -- Set template : marque la variante VISIBLE comme template reutilisable. Actif
    -- UNIQUEMENT si la variante est healer-seul (aucun external) ET pas deja un template.
    p.varSetTemplate = UI.Components.TextButton(p, { text = "Set template", autoWidth = true, minWidth = 0, padX = 15, padY = 9, onClick = function()
        local cur = HR.GetActiveVariant()
        if cur and CanSetTemplate(cur) then
            cur.isTemplate = true
            UI.RefreshRows()
            HR:Print(("Variant \"%s\" saved as a reusable template."):format(cur.name))
        end
    end })
    UI.Components.AttachHelpTip(p.varSetTemplate, "Set template", function()
        local cur = HR.GetActiveVariant()
        local body = "Flag this healer-only variant as a reusable template, so it can be picked when creating future variants for this healer + talents."
        if not (cur and CanSetTemplate(cur)) then
            if cur and cur.isTemplate then
                body = body .. "\n|cffff6060Unavailable:|r this variant is already a template."
            else
                body = body .. "\n|cffff6060Unavailable:|r a template must be healer-only (remove all externals)."
            end
        end
        return body
    end)
    p.varSetTemplate:Hide()

    -- Sync : pousse la variante active sur le canal de synchro (ECPSync). Chez les
    -- destinataires elle est importee et posee ACTIVE sans aucun clic. Le bouton ne fait
    -- qu'EMETTRE l'evenement ; tout le reste vit dans Core/Sync/ (cf. HR.EmitEvent).
    p.varSync = UI.Components.TextButton(p, { text = "Sync", autoWidth = true, minWidth = 0, padX = 15, padY = 9, onClick = function()
        HR.EmitEvent(HR.EV.PLAN_SHARED, { dID = UI.activeDungeonID, variant = HR.GetActiveVariant() })
    end })
    UI.Components.AttachHelpTip(p.varSync, "Sync", function()
        local body = "Push this plan to your party. Members running the addon get it imported and set "
            .. "as their active plan right away, with no click and no duplicate: pushing again "
            .. "updates the very same plan on their side."
        local cur = HR.GetActiveVariant()
        if cur and cur.synced then
            body = body .. "\n|cffff6060Unavailable:|r this plan was received from "
                .. ((cur.syncFrom and cur.syncFrom.name) or "another player")
                .. ". Duplicate it to make it yours."
        end
        return body
    end)
    p.varSync:Hide()

    -- Export / Import : modales a chaine (sous le container des variantes, completement a droite).
    p.varExport = UI.Components.TextButton(p, { text = "Export", autoWidth = true, minWidth = 0, padX = 15, padY = 9, onClick = function() UI.OpenExportModal() end })
    p.varExport:Hide()
    p.varImport = UI.Components.TextButton(p, { text = "Import", autoWidth = true, minWidth = 0, padX = 15, padY = 9, onClick = function() UI.OpenImportModal() end })
    p.varImport:Hide()

    -- Reset : remet a ZERO la planification du BOSS AFFICHE pour la variante VISIBLE (confirmation
    -- obligatoire). Les autres boss de la variante restent intacts.
    p.varReset = UI.Components.TextButton(p, { text = "Reset", autoWidth = true, minWidth = 0, padX = 15, padY = 9, onClick = function()
        local cur = HR.GetActiveVariant()
        if not cur then return end
        local dungeon = HR.content[UI.selDungeon]
        local boss = dungeon and dungeon.bosses[UI.selBoss]
        if not boss then return end
        StaticPopup_Show("ECP_RESET_BOSS_PLAN", boss.name, nil, { variant = cur, encounterID = boss.id })
    end })
    p.varReset:Hide()

    UI.specsPanel = p
    return p
end

-- Controles de variante (colles a droite) sur DEUX lignes :
--   ligne 1 = tous les boutons (New | Duplicate | Delete | Use | Share)
--   ligne 2 = le selecteur, aligne a droite sous les boutons.
local function RenderVariantControls(p, v)
    -- Ligne 1 : boutons, chaines depuis la droite (Set template le plus a droite).
    p.varSetTemplate:ClearAllPoints(); p.varSetTemplate:SetPoint("TOPRIGHT", p, "TOPRIGHT", -PADX, -PADY)
    p.varDefault:ClearAllPoints(); p.varDefault:SetPoint("RIGHT", p.varSetTemplate, "LEFT", -6, 0)
    p.varUse:ClearAllPoints();    p.varUse:SetPoint("RIGHT", p.varDefault, "LEFT", -6, 0)
    p.varEdit:ClearAllPoints();   p.varEdit:SetPoint("RIGHT", p.varUse, "LEFT", -6, 0)
    p.varDup:ClearAllPoints();    p.varDup:SetPoint("RIGHT", p.varEdit, "LEFT", -6, 0)
    p.varNew:ClearAllPoints();    p.varNew:SetPoint("RIGHT", p.varDup, "LEFT", -6, 0)

    -- Ligne 2 : selecteur PLEINE LARGEUR (de New a gauche jusqu'au bouton de droite).
    p.varTrigger:ClearAllPoints()
    p.varTrigger:SetPoint("TOPLEFT", p.varNew, "BOTTOMLEFT", 0, -6)
    p.varTrigger:SetPoint("TOPRIGHT", p.varSetTemplate, "BOTTOMRIGHT", 0, -6)
    -- Prefixe "DEFAULT" (rouge) devant le nom quand la variante affichee est le defaut de sa spe.
    local trigName = v and ((HR.IsDefaultVariant(v.id, UI.activeDungeonID) and (HR.Theme.Hex("ERROR_COLOR") .. "DEFAULT|r ") or "") .. v.name) or nil
    p.varTrigger.label:SetText(v and (VariantRecapMarkup(v, 24) .. "  " .. trigName) or "-")

    -- Conteneur Variantes : pleine hauteur, colle a droite, bord gauche = avant le bouton
    -- le plus a gauche (New, la ligne de boutons etant plus large que le selecteur) + padding.
    p.variantBox:ClearAllPoints()
    p.variantBox:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, 0)
    p.variantBox:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", 0, 0)
    p.variantBox:SetPoint("LEFT", p.varNew, "LEFT", -PADX, 0)
    p.variantBox:Show()

    -- SOUS le container, completement a droite : Import + Export + Sync (sortis de la rangee de boutons).
    p.varSync:ClearAllPoints();   p.varSync:SetPoint("TOPRIGHT", p, "BOTTOMRIGHT", -PADX, -4)
    p.varExport:ClearAllPoints(); p.varExport:SetPoint("RIGHT", p.varSync, "LEFT", -6, 0)
    p.varImport:ClearAllPoints(); p.varImport:SetPoint("RIGHT", p.varExport, "LEFT", -6, 0)
    p.varReset:ClearAllPoints();  p.varReset:SetPoint("RIGHT", p.varImport, "LEFT", -6, 0)

    -- Sync : seulement SON PROPRE plan. Un plan recu d'un tiers n'est pas re-poussable
    -- (il appartient a son auteur) -- le joueur doit le dupliquer pour se l'approprier.
    local canSync = (v and not v.synced) and true or false
    p.varSync:SetEnabled(canSync); p.varSync:SetAlpha(canSync and 1 or 0.4)

    -- Set template : actif seulement pour une variante healer-seul pas encore template.
    local canTpl = CanSetTemplate(v)
    p.varSetTemplate:SetEnabled(canTpl); p.varSetTemplate:SetAlpha(canTpl and 1 or 0.4)

    -- Default : surligne quand la variante VISIBLE est le defaut auto-charge de sa spe.
    -- Actif seulement si la variante est de MA spe (set) OU deja le defaut (retrait permis).
    local isDef  = v and HR.IsDefaultVariant(v.id, UI.activeDungeonID) or false
    local defEn  = isDef or (v and HR.CanSetDefault(v)) or false
    p.varDefault:SetSelected(isDef)
    p.varDefault:SetEnabled(defEn); p.varDefault:SetAlpha(defEn and 1 or 0.4)

    p.varTrigger:Show(); p.varNew:Show(); p.varDup:Show(); p.varEdit:Show()
    p.varUse:Show(); p.varDefault:Show(); p.varSetTemplate:Show(); p.varSync:Show(); p.varExport:Show(); p.varImport:Show(); p.varReset:Show()
    p.varNew:SetSelected(false)   -- au repos hors etat vide (voir RenderEmptyVariantControls)
end

-- Etat SANS variante (nouveau joueur / donjon vierge depuis le retrait des Base templates) :
-- on invite a en creer une. Seuls New + Import restent visibles ; tout ce qui suppose une
-- variante active est masque.
local function RenderEmptyVariantControls(p)
    p.varTrigger:Hide(); p.varDup:Hide(); p.varEdit:Hide(); p.varUse:Hide()
    p.varDefault:Hide(); p.varSetTemplate:Hide(); p.varSync:Hide(); p.varExport:Hide(); p.varReset:Hide()
    p.variantBox:Hide()

    p.varNew:ClearAllPoints();    p.varNew:SetPoint("TOPRIGHT", p, "TOPRIGHT", -PADX, -PADY); p.varNew:Show()
    p.varNew:SetSelected(true)    -- mis en avant (fond selectionne) : c'est l'action a faire
    p.varImport:ClearAllPoints(); p.varImport:SetPoint("RIGHT", p.varNew, "LEFT", -6, 0);      p.varImport:Show()

    p.empty:ClearAllPoints()
    p.empty:SetPoint("TOPLEFT", PADX, -52)
    p.empty:Show()
end

function UI.RenderHealerSpecs()
    local p = UI.BuildHealerSpecs(UI.body)
    p:Show()
    p.healerIcon:Hide()
    if p.boxIcons then for _, it in ipairs(p.boxIcons) do it:Hide() end end   -- ancien rendu icones
    local box = p.summaryBox
    local visible = HR.GetActiveVariant()        -- variante VISIBLE (selectionnee, a l'ecran)
    local active  = HR.GetV2Used()               -- variante ACTIVE (jouee en combat)
    if box._moreBtn then box._moreBtn:Hide() end
    p.empty:Hide()

    -- LIGNE 0 (sous-titre) + LIGNE 1 (titre = "nom du boss - nom de la variante ACTIVE").
    local dungeon = HR.content[UI.selDungeon or 1]
    local boss = dungeon and dungeon.bosses[UI.selBoss or 1]
    local bossName = (boss and boss.name) or ""
    local varName = (active and active.name) or "-"
    p.boxSubtitle:Show()
    -- Boss en EMPHASIZE (violet), nom de variante en BASE (blanc).
    p.boxTitle:SetText(HR.Theme.Hex("EMPHASIZE_TEXT_COLOR") .. bossName .. "|r  |cffaaaaaa-|r  "
        .. HR.Theme.Hex("BASE_TEXT_COLOR") .. varName .. "|r"); p.boxTitle:Show()

    local dirty = (visible and active and visible.id ~= active.id) and true or false
    box._dirty = dirty

    -- LIGNE 2 : "Show this variant on screen" -> selectionne l'active. Desactive si on
    -- regarde DEJA l'active (visible == active).
    p.boxShow:ClearAllPoints(); p.boxShow:SetPoint("BOTTOMLEFT", box, "BOTTOMLEFT", PADX, PADY)
    p.boxShow:Show()
    p.boxShow:SetEnabled(dirty); p.boxShow:SetAlpha(dirty and 1 or 0.4)

    -- Bordure de la boite entiere : ROUGE si visible != active, sinon couleur thémée.
    local r, g, b, a = HR.Theme.Unpack("CONTAINER_BORDER_COLOR")
    for _, e in pairs(box._edges) do
        if dirty then e:SetColorTexture(HR.Theme.Unpack("ERROR_COLOR")) else e:SetColorTexture(r, g, b, a or 1) end
    end

    -- Boite : largeur FIXE, pleine hauteur, collee a gauche.
    box:ClearAllPoints()
    box:SetPoint("TOPLEFT", p, "TOPLEFT", 0, 0)
    box:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 0, 0)
    box:SetWidth(SUMMARY_W)
    box:Show()

    if visible then
        RenderVariantControls(p, visible)
    else
        RenderEmptyVariantControls(p)
    end
end

--------------------------------------------------------------------------------
-- Modale "New variant" (selection progressive)
--------------------------------------------------------------------------------

-- Active/desactive une case SANS la masquer (regle UI : une option indisponible reste
-- visible -> grisee + remise a sa valeur par defaut ; pas d'apparition/disparition).
local function SetCheckEnabled(chk, enabled)
    chk:SetEnabled(enabled)
    if not enabled then chk:SetChecked(false) end          -- defaut = decoche
    local g = enabled and 1 or 0.4
    chk.text:SetTextColor(g, g, g)
end

-- Tooltip custom (titre + corps DYNAMIQUE) sur un widget. getLines() -> title, body
-- (le body peut expliquer pourquoi l'option est indisponible).
local function BuildNewVariantModal()
    local m = UI.Components.Window(UIParent, {
        name = "ECPNewVariantModal", title = "New variant", width = 560, height = 500,
        bgTexture = (HR.Assets.registry["bg-variant"]) and HR.Asset("bg-variant") or nil,
    })
    m:SetFrameStrata("FULLSCREEN_DIALOG"); m:SetToplevel(true)
    tinsert(UISpecialFrames, "ECPNewVariantModal")
    local c = m.content

    -- Fond d'ecran (bg-2) en mode "cover" : la texture (creee par Window en m.bgTex) est
    -- CARREE et la fenetre rectangulaire => on conserve le ratio et on rogne l'excedent
    -- via SetTexCoord (aucune distorsion). Recalcule au redimensionnement.
    if m.bgTex then
        local function LayoutModalBg()
            local w, h = m:GetWidth(), m:GetHeight()
            if not w or not h or w <= 0 or h <= 0 then return end
            local af = w / h              -- ratio fenetre (texture supposee carree 1:1)
            if af >= 1 then
                local dv = 1 / af         -- fenetre large => on rogne haut/bas
                m.bgTex:SetTexCoord(0, 1, (1 - dv) / 2, (1 + dv) / 2)
            else
                local du = af             -- fenetre haute => on rogne gauche/droite
                m.bgTex:SetTexCoord((1 - du) / 2, (1 + du) / 2, 0, 1)
            end
        end
        m:HookScript("OnSizeChanged", LayoutModalBg)
        LayoutModalBg()
        -- Voile sombre PAR-DESSUS l'image (BACKGROUND sublevel 3 > bgTex 2) mais SOUS le
        -- contenu (frames enfants) pour garder la lisibilite du formulaire.
        m.bgDim = m:CreateTexture(nil, "BACKGROUND", nil, 3)
        m.bgDim:SetAllPoints()
        m.bgDim:SetColorTexture(0, 0, 0, 0.7)
    end

    m.draftExternals = {}; m.healer = nil; m.healerRows = {}; m.extPool = {}
    m.talentSpells = {}; m.talentPool = {}
    m.templatePool = {}; m.copyTemplateId = nil

    local hl = c:CreateFontString(nil, "OVERLAY", "GameFontNormal"); hl:SetPoint("TOPLEFT", 16, -12); hl:SetText("Select your healer spec:"); hl:SetTextColor(1, 1, 1)

    -- Sorts du healer dependant d'un talent (variantes de CD) : choix de la variante.
    -- (Le scan/discovery se fait via "Scan my group".)
    local tl = c:CreateFontString(nil, "OVERLAY", "GameFontNormal"); tl:SetPoint("TOPLEFT", 16, -74); tl:SetText("Select healer's talents"); tl:SetTextColor(1, 1, 1)

    local el = c:CreateFontString(nil, "OVERLAY", "GameFontNormal"); el:SetPoint("TOPLEFT", 16, -148); el:SetText("Select available group externals:"); el:SetTextColor(1, 1, 1)

    local nl = c:CreateFontString(nil, "OVERLAY", "GameFontNormal"); nl:SetPoint("TOPLEFT", 16, -220); nl:SetText("Name for this variant"); nl:SetTextColor(1, 1, 1)
    local edit = CreateFrame("EditBox", nil, c, "InputBoxTemplate")
    edit:SetSize(280, 24); edit:SetPoint("TOPLEFT", nl, "BOTTOMLEFT", 4, -6); edit:SetAutoFocus(false)  -- champ SOUS le titre
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEnterPressed", function() UI.SubmitNewVariant() end)
    m.edit = edit

    -- "Copy from a template" : coche => debloque la liste des templates (meme healer +
    -- memes talents) ; cliquer un template copie son plan dans la nouvelle variante.
    local chk = CreateFrame("CheckButton", nil, c, "UICheckButtonTemplate"); chk:SetPoint("TOPLEFT", 14, -278)
    chk.text = chk:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); chk.text:SetPoint("LEFT", chk, "RIGHT", 2, 0)
    chk.text:SetText("Copy from a template"); chk.text:SetTextColor(1, 1, 1)
    chk:SetScript("OnClick", function() UI.RenderNewVariantModal() end)
    m.importChk = chk

    -- Libelle "aucun template" (affiche sous la case quand cochee sans match).
    m.templateEmpty = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    m.templateEmpty:SetText("No matching template (same healer + talents)"); m.templateEmpty:Hide()

    -- "Set as template" : visible UNIQUEMENT quand la compo est healer-seul (aucun external).
    -- Marque la variante creee comme template reutilisable.
    local tchk = CreateFrame("CheckButton", nil, c, "UICheckButtonTemplate"); tchk:SetPoint("TOPLEFT", 14, -334)
    tchk.text = tchk:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); tchk.text:SetPoint("LEFT", tchk, "RIGHT", 2, 0)
    tchk.text:SetText("Set as template (healer only)"); tchk.text:SetTextColor(1, 1, 1)
    m.templateChk = tchk

    UI.Components.AttachHelpTip(chk, "Copy from a template", function()
        local body = "Copy the plan from one of the selected healer's variants that match the current talent selection."
        if not chk:IsEnabled() then
            body = body .. "\n|cffff6060Unavailable:|r no template matches this healer + talents yet."
        end
        return body
    end)
    UI.Components.AttachHelpTip(tchk, "Set as template", function()
        local body = "Save this healer-only variant as a reusable template for future variants."
        if not tchk:IsEnabled() then
            body = body .. "\n|cffff6060Unavailable:|r remove all externals (a template is healer-only)."
        end
        return body
    end)

    local create = UI.Components.TextButton(c, { text = "Create", width = 110, onClick = function() UI.SubmitNewVariant() end })
    create:SetPoint("BOTTOMRIGHT", -16, 16)
    m.createBtn = create
    local cancel = UI.Components.TextButton(c, { text = "Cancel", width = 110, onClick = function() m:Hide() end })
    cancel:SetPoint("RIGHT", create, "LEFT", -8, 0)

    -- Scan du groupe : selectionne le HEALER + pre-remplit les externals (classes/roles,
    -- + tentative de variante de CD par talent pour le joueur local). En bas a gauche.
    local scan
    scan = UI.Components.TextButton(c, { text = "Scan my group", width = 130, onClick = function()
        if m._scanning then return end                                  -- garde anti double-clic
        local function setScanning(on)
            m._scanning = on
            scan:SetText(on and "Scanning..." or "Scan my group")
            scan:SetEnabled(not on)
        end
        setScanning(true)

        -- 1) Synchrone : healer + comptes externals immediats (joueur local fiable).
        local h = HR.ScanGroupHealer(); if h and not m.editId then m.healer = h end   -- heal verrouille en edition
        local res = HR.ScanGroupExternals()
        wipe(m.draftExternals)
        for k, n in pairs(res) do if n > 0 then m.draftExternals[k] = n end end
        UI.RenderNewVariantModal()

        -- 2) Async serialise : talents du heal (inspect heal), PUIS trinkets du groupe
        --    (inspect des membres non-heal) -> on affine les comptes au retour.
        UI.DiscoverTalentSpells(function()
            HR.ScanGroupTrinkets(function(counts)
                for k, n in pairs(counts) do
                    m.draftExternals[k] = (n > 0) and n or nil          -- compte autoritaire (inspect)
                end
                UI.RenderNewVariantModal()
                setScanning(false)
                HR:Print("Scan du groupe termine.")
            end)
        end)
    end })
    scan:SetPoint("BOTTOMLEFT", 16, 16)
    m.scanBtn = scan

    m:Hide()
    UI.newVarModal = m
end

function UI.RenderNewVariantModal()
    local m = UI.newVarModal
    local c = m.content
    RenderHealerRow(c, m.healerRows, 16, -32,
        function() return m.healer end,
        function(k)
            if m.editId then return end                                    -- heal VERROUILLE en edition
            if k ~= m.healer then m.healer = k; wipe(m.talentSpells) end   -- spe change -> reset talents
            UI.RenderNewVariantModal()
        end)
    -- Sorts talentes du healer (vide si aucun healer choisi, ou si "No healer" : pas de
    -- soigneur => aucun talent a decliner, HR.GetHealerTalentSpells renvoie deja {}).
    local spells = (m.healer and m.healer ~= HR.NO_HEALER and HR.GetHealerTalentSpells(m.healer)) or {}
    RenderTalentRow(c, m.talentPool, 16, -94, spells, m.talentSpells,
        function() UI.RenderNewVariantModal() end)
    RenderExternalsRow(c, m.extPool, 16, -168, m.draftExternals,
        function() UI.RenderNewVariantModal() end, false)

    -- En EDITION : on edite la compo (externals + talents), pas le plan -> pas de template/import.
    if m.editId then
        m.importChk:Hide(); m.templateChk:Hide(); m.templateEmpty:Hide()
        for _, b in ipairs(m.templatePool) do b:Hide() end
        return
    end
    m.importChk:Show(); m.templateChk:Show()

    -- "Copy from a template" : la case reste TOUJOURS visible ; elle est juste GRISEE (+
    -- reset) tant qu'aucun template ne matche le healer + talents courants.
    local templates = (m.healer and HR.GetMatchingTemplates(m.healer, m.talentSpells)) or {}
    SetCheckEnabled(m.importChk, #templates > 0)
    if not m.importChk:IsEnabled() then m.copyTemplateId = nil end

    local copying = m.importChk:GetChecked() and true or false
    if copying then
        -- si le template selectionne n'est plus dans la liste, on le deselectionne.
        if m.copyTemplateId then
            local ok = false
            for _, t in ipairs(templates) do if t.id == m.copyTemplateId then ok = true; break end end
            if not ok then m.copyTemplateId = nil end
        end
        RenderTemplateRow(c, m.templatePool, 16, -304, templates, m.copyTemplateId,
            function(id) m.copyTemplateId = (m.copyTemplateId == id) and nil or id; UI.RenderNewVariantModal() end,
            m.templateEmpty)
    else
        for _, b in ipairs(m.templatePool) do b:Hide() end
        m.templateEmpty:Hide()
    end

    -- "Set as template" : reste visible ; grisee (+ reset) tant que la compo n'est pas
    -- healer-seul (aucun external > 0).
    local hasExt = false
    for _, n in pairs(m.draftExternals) do if (n or 0) > 0 then hasExt = true; break end end
    SetCheckEnabled(m.templateChk, not hasExt)
end

-- Bouton "Discover" : scanne le healer du groupe (local ou allie via inspect) et applique
-- la variante de talent qui matche pour chaque sort talente du healer choisi.
function UI.DiscoverTalentSpells(onDone)
    onDone = onDone or function() end
    local m = UI.newVarModal
    if not m or not m.healer then HR:Print("Pick a healer spec first (or 'No healer')."); return onDone() end
    -- "No healer" : aucun soigneur designe -> rien a scanner (le scan lit les talents d'un heal).
    if m.healer == HR.NO_HEALER then HR:Print("Discover: no healer spec selected."); return onDone() end
    HR:Print("Discover: lecture des talents du healer du groupe...")
    HR.ScanHealerTalents(function(tset, err, hname, unit)
        if err or not tset then HR:Print("Discover: " .. (err or "echec.")); return onDone() end
        local spells = HR.GetHealerTalentSpells(m.healer)
        wipe(m.talentSpells)
        for _, sp in ipairs(spells) do
            if sp.trinket then
                -- Trinket : scan d'ITEM (equipe), pas de talent. Le `unit` vient du scan.
                if HR.HasTrinket(sp.itemId, unit) then m.talentSpells[sp.spellID] = sp.variants[1] end
            else
                local match = HR.MatchTalentVariant(sp.variants, tset)
                if match then m.talentSpells[sp.spellID] = match end
            end
        end
        HR:Print(("Discover: talents de %s appliques."):format(hname or "?"))
        UI.RenderNewVariantModal()
        onDone()
    end)
end

function UI.OpenNewVariantModal()
    if not UI.newVarModal then BuildNewVariantModal() end
    local m = UI.newVarModal
    m.editId = nil
    m.healer = nil; wipe(m.draftExternals); wipe(m.talentSpells); m.copyTemplateId = nil
    m.edit:SetText(""); m.importChk:SetChecked(false); m.templateChk:SetChecked(false)
    m._scanning = false                                              -- reset du loader Scan
    if m.scanBtn then m.scanBtn:SetText("Scan my group"); m.scanBtn:SetEnabled(true) end
    if m.SetTitle then m:SetTitle("New variant") end
    if m.createBtn then m.createBtn:SetText("Create") end
    UI.RenderNewVariantModal()
    m:Show(); m:Raise(); m.edit:SetFocus()
end

-- Edite une variante existante : reutilise la modale de creation avec le MEME preset (healer
-- VERROUILLE, externals + talents pre-remplis). A la validation, UI.SubmitNewVariant bascule en
-- UPDATE (purge des defensifs orphelins). Cf. HR.V2_UpdateVariant.
function UI.OpenEditVariantModal(v)
    if not v then return end
    if not UI.newVarModal then BuildNewVariantModal() end
    local m = UI.newVarModal
    m.editId = v.id
    m.healer = v.healer
    wipe(m.draftExternals); for k, n in pairs(v.externals or {}) do m.draftExternals[k] = n end
    wipe(m.talentSpells);   for k, val in pairs(v.talentSpells or {}) do m.talentSpells[k] = val end
    m.copyTemplateId = nil
    m.edit:SetText(v.name or "")
    m.importChk:SetChecked(false); m.templateChk:SetChecked(false)
    m._scanning = false
    if m.scanBtn then m.scanBtn:SetText("Scan my group"); m.scanBtn:SetEnabled(true) end
    if m.SetTitle then m:SetTitle("Edit variant") end
    if m.createBtn then m.createBtn:SetText("Save") end
    UI.RenderNewVariantModal()
    m:Show(); m:Raise(); m.edit:SetFocus()
end

function UI.SubmitNewVariant()
    local m = UI.newVarModal; if not m then return end
    -- Choix EXPLICITE exige (evite une creation par inadvertance) : "No healer" EST un choix
    -- valide (m.healer == HR.NO_HEALER), seul l'absence de selection est refusee.
    if not m.healer then HR:Print("Pick a healer spec first (or 'No healer')."); return end
    local name = strtrim(m.edit:GetText() or "")
    if name == "" then HR:Print("Give the variant a name."); return end

    -- Mode EDITION : met a jour la variante existante (externals + talents + nom) puis purge les
    -- defensifs devenus orphelins. Le HEAL reste verrouille. Pas de template/import ici.
    if m.editId then
        local _, removed = HR.V2_UpdateVariant(m.editId, name, m.draftExternals, m.talentSpells)
        m:Hide()
        UI.RefreshRows()
        if removed and removed > 0 then
            HR:Print(("Variant updated (%d placed cooldown%s removed)."):format(removed, removed > 1 and "s" or ""))
        end
        return
    end

    -- isTemplate uniquement si healer-seul (la case n'est visible que dans ce cas).
    local hasExt = false
    for _, n in pairs(m.draftExternals) do if (n or 0) > 0 then hasExt = true; break end end
    local opts = {
        isTemplate     = (not hasExt) and m.templateChk:GetChecked() and true or nil,
        copyTemplateId = m.importChk:GetChecked() and m.copyTemplateId or nil,
    }
    HR.V2_CreateVariant(name, m.healer, m.draftExternals, m.talentSpells, opts)
    m:Hide()
    UI.RefreshRows()
end

--------------------------------------------------------------------------------
-- Modale "Duplicate" (nom seulement)
--------------------------------------------------------------------------------

local function BuildDuplicateModal()
    local m = UI.Components.Window(UIParent, {
        name = "ECPDuplicateModal", title = "Duplicate variant", width = 380, height = 160,
        bgTexture = (HR.Assets.registry["bg-variant"]) and HR.Asset("bg-variant") or nil,
    })
    m:SetFrameStrata("FULLSCREEN_DIALOG"); m:SetToplevel(true)
    tinsert(UISpecialFrames, "ECPDuplicateModal")
    local c = m.content

    -- Fond d'ecran (bg-2) en mode "cover" + voile sombre (meme rendu que la modale New variant).
    if m.bgTex then
        local function LayoutModalBg()
            local w, h = m:GetWidth(), m:GetHeight()
            if not w or not h or w <= 0 or h <= 0 then return end
            local af = w / h              -- ratio fenetre (texture supposee carree 1:1)
            if af >= 1 then
                local dv = 1 / af         -- fenetre large => on rogne haut/bas
                m.bgTex:SetTexCoord(0, 1, (1 - dv) / 2, (1 + dv) / 2)
            else
                local du = af             -- fenetre haute => on rogne gauche/droite
                m.bgTex:SetTexCoord((1 - du) / 2, (1 + du) / 2, 0, 1)
            end
        end
        m:HookScript("OnSizeChanged", LayoutModalBg)
        LayoutModalBg()
        m.bgDim = m:CreateTexture(nil, "BACKGROUND", nil, 3)   -- voile lisibilite (au-dessus de bgTex)
        m.bgDim:SetAllPoints()
        m.bgDim:SetColorTexture(0, 0, 0, 0.7)
    end

    local nl = c:CreateFontString(nil, "OVERLAY", "GameFontNormal"); nl:SetPoint("TOPLEFT", 16, -16); nl:SetText("Name:"); nl:SetTextColor(HR.Theme.Unpack("BASE_TEXT_COLOR"))
    local edit = CreateFrame("EditBox", nil, c, "InputBoxTemplate")
    edit:SetSize(250, 24); edit:SetPoint("LEFT", nl, "RIGHT", 10, 0); edit:SetAutoFocus(false)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEnterPressed", function() UI.SubmitDuplicate() end)
    m.edit = edit
    local ok = UI.Components.TextButton(c, { text = "Duplicate", width = 110, onClick = function() UI.SubmitDuplicate() end })
    ok:SetPoint("BOTTOMRIGHT", -16, 14)
    local cancel = UI.Components.TextButton(c, { text = "Cancel", width = 110, onClick = function() m:Hide() end })
    cancel:SetPoint("RIGHT", ok, "LEFT", -8, 0)
    m:Hide()
    UI.dupModal = m
end

function UI.OpenDuplicateModal()
    local cur = HR.GetActiveVariant()
    if not cur then HR:Print("No variant to duplicate."); return end
    if not UI.dupModal then BuildDuplicateModal() end
    local m = UI.dupModal
    m.edit:SetText((cur.name or "") .. " copy")
    m:Show(); m:Raise(); m.edit:SetFocus(); m.edit:HighlightText()
end

function UI.SubmitDuplicate()
    local m = UI.dupModal; if not m then return end
    local name = strtrim(m.edit:GetText() or "")
    if name == "" then HR:Print("Give the variant a name."); return end
    HR.V2_DuplicateVariant(name)
    m:Hide()
    UI.RefreshRows()
end

--------------------------------------------------------------------------------
-- Modale "Export" (chaine copiable) -- contenu a venir (vide pour l'instant)
--------------------------------------------------------------------------------

local function BuildExportModal()
    local m = UI.Components.Window(UIParent, {
        name = "ECPExportModal", title = "Export variant", width = 560, height = 420,
        bgTexture = (HR.Assets.registry["bg-variant"]) and HR.Asset("bg-variant") or nil,
    })
    m:SetFrameStrata("FULLSCREEN_DIALOG"); m:SetToplevel(true)
    tinsert(UISpecialFrames, "ECPExportModal")

    -- Fond d'ecran (bg-2) en mode "cover" + voile sombre (meme rendu que New variant / Duplicate).
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
    local lbl = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("TOPLEFT", 16, -14); lbl:SetText("Press Ctrl+C to copy (the window closes automatically):"); lbl:SetTextColor(1, 1, 1)

    -- Zone scrollable + EditBox multiligne (la chaine base64 peut etre longue).
    local scroll = CreateFrame("ScrollFrame", nil, c, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -36)
    scroll:SetPoint("BOTTOMRIGHT", -32, 50)
    scroll.bg = scroll:CreateTexture(nil, "BACKGROUND"); scroll.bg:SetAllPoints(); scroll.bg:SetColorTexture(0, 0, 0, 0.5)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true); edit:SetFontObject(ChatFontNormal)
    edit:SetAutoFocus(true)                 -- saisit le focus des l'affichage (pas de souci de timing)
    edit:SetWidth(496); edit:SetTextInsets(4, 4, 4, 4)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus(); m:Hide() end)
    -- Selectionne TOUT a chaque prise de focus (auto ou clic) -> Ctrl+C copie tout.
    edit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    -- Read-only : toute saisie utilisateur restaure la chaine (l'export ne peut pas etre altere).
    edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput then self:SetText(m.exportStr or "") end
    end)
    -- "AUTOCOPY" facon SimulationCraft : WoW n'a pas d'API clipboard, mais on DETECTE le
    -- Ctrl+C (ou Ctrl+X) -> l'OS copie la selection, et on ferme la fenetre juste apres.
    local ctrlDown = false
    edit:SetScript("OnKeyDown", function(_, key)
        if key == "LCTRL" or key == "RCTRL" or key == "LMETA" or key == "RMETA" then ctrlDown = true end
    end)
    edit:SetScript("OnKeyUp", function(_, key)
        if key == "LCTRL" or key == "RCTRL" or key == "LMETA" or key == "RMETA" then
            C_Timer.After(0.2, function() ctrlDown = false end)   -- petite grace (Ctrl relache avant C)
        end
        if ctrlDown and (key == "C" or key == "X") then
            C_Timer.After(0.1, function() m:Hide() end)           -- ferme APRES la copie OS
        end
    end)
    scroll:SetScrollChild(edit)
    m.scroll, m.edit = scroll, edit

    -- Re-selectionne + focus (declenche OnEditFocusGained -> HighlightText). Largeur calee sur
    -- le scroll. SetFocus immediat + repli a la frame suivante (robuste a l'ouverture).
    function m.SelectAll()
        edit:SetWidth(scroll:GetWidth() or 496)
        edit:SetFocus()
        C_Timer.After(0, function() if m:IsShown() then edit:SetFocus() end end)
    end

    -- Bouton de fermeture manuelle (la copie auto-ferme deja via Ctrl+C).
    local ok = UI.Components.TextButton(c, { text = "Close", width = 120, onClick = function() m:Hide() end })
    ok:SetPoint("BOTTOMRIGHT", -16, 14)

    m:Hide()
    UI.exportModal = m
end

function UI.OpenExportModal()
    local cur = HR.GetActiveVariant()
    if not cur then HR:Print("No variant to export."); return end
    if not UI.exportModal then BuildExportModal() end
    local m = UI.exportModal
    local dID = UI.activeDungeonID
    if not dID then local d = HR.content and HR.content[UI.selDungeon]; dID = d and d.id end
    local str = (HR.Share and HR.Share.EncodeVariant) and HR.Share.EncodeVariant(dID, cur) or nil
    m.exportStr = str or ""
    m.edit:SetText(str or "<export failed: encoding unavailable or no dungeon>")
    m:Show(); m:Raise()
    m.SelectAll()                                      -- focus + selection -> Ctrl+C immediat
    if not str then HR:Print("Export failed (encoding unavailable or no dungeon selected).") end
end

--------------------------------------------------------------------------------
-- Import : decode une chaine collee -> cree la variante -> l'affiche comme variante EN
-- COURS D'EDITION (lastSeen), PAS comme variante runtime (used/★). Va sur le donjon de la
-- variante au besoin. Renvoie true si l'import a reussi.
--------------------------------------------------------------------------------

function UI.ImportVariantString(str)
    str = str and strtrim(str) or ""
    -- Format texte externe (`ecp;2`, nu ou en enveloppe `ecp64:`) => chemin dedie, qui
    -- gere les DEUX cas (boss unique / donjon complet) et ses propres ecrans.
    -- Aiguillage non ambigu : l'alphabet Base64 du format natif ne contient pas de ';'.
    if HR.ShareText and HR.ShareText.Looks(str) then
        return UI.ImportTextPlan(str)
    end
    if not (HR.Share and HR.Share.DecodeVariant) then
        HR:Print("Import unavailable (encoding library missing)."); return false
    end
    local payload = HR.Share.DecodeVariant(str)
    if not payload then HR:Print("Import failed: invalid or corrupted string."); return false end
    local v, dID = HR.Share.ImportPayload(payload, nil)
    if not v then HR:Print("Import failed: invalid plan."); return false end
    -- Aller sur le donjon de la variante (si different) puis la SELECTIONNER comme EDITEE.
    local idx
    for i, d in ipairs(HR.content) do if d.id == dID then idx = i; break end end
    if idx and UI.selDungeon ~= idx and UI.SelectDungeon then UI.SelectDungeon(idx) end
    HR.SelectVariant(v.id, dID)                        -- lastSeen = variante visible/editee
    UI.RefreshRows()
    HR:Print(("Variant \"%s\" imported."):format(v.name))
    return true
end

-- Modale "Import" (champ texte editable + bouton Import). Reprend la structure de l'export.
local function BuildImportModal()
    local m = UI.Components.Window(UIParent, {
        name = "ECPImportModal", title = "Import variant", width = 560, height = 420,
        bgTexture = (HR.Assets.registry["bg-variant"]) and HR.Asset("bg-variant") or nil,
    })
    m:SetFrameStrata("FULLSCREEN_DIALOG"); m:SetToplevel(true)
    tinsert(UISpecialFrames, "ECPImportModal")

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
    local lbl = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("TOPLEFT", 16, -14); lbl:SetText("Paste a variant string below, then click Import:"); lbl:SetTextColor(1, 1, 1)

    -- Zone scrollable + EditBox multiligne EDITABLE (le joueur y colle la chaine).
    local scroll = CreateFrame("ScrollFrame", nil, c, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -36)
    scroll:SetPoint("BOTTOMRIGHT", -32, 50)
    scroll.bg = scroll:CreateTexture(nil, "BACKGROUND"); scroll.bg:SetAllPoints(); scroll.bg:SetColorTexture(0, 0, 0, 0.5)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true); edit:SetFontObject(ChatFontNormal)
    edit:SetAutoFocus(false)
    edit:SetWidth(496); edit:SetTextInsets(4, 4, 4, 4)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus(); m:Hide() end)
    scroll:SetScrollChild(edit)
    m.scroll, m.edit = scroll, edit

    local function DoImport()
        if UI.ImportVariantString(edit:GetText()) then m:Hide() end
    end

    -- Import : valide la chaine. Cancel : ferme sans rien faire.
    local imp = UI.Components.TextButton(c, { text = "Import", width = 120, onClick = DoImport })
    imp:SetPoint("BOTTOMRIGHT", -16, 14)
    local cancel = UI.Components.TextButton(c, { text = "Cancel", width = 120, onClick = function() m:Hide() end })
    cancel:SetPoint("RIGHT", imp, "LEFT", -8, 0)

    m:Hide()
    UI.importModal = m
end

function UI.OpenImportModal()
    if not UI.importModal then BuildImportModal() end
    local m = UI.importModal
    m.edit:SetText("")
    m:Show(); m:Raise()
    m.edit:SetWidth(m.scroll:GetWidth() or 496)   -- largeur connue une fois la fenetre posee
    m.edit:SetFocus()
end
