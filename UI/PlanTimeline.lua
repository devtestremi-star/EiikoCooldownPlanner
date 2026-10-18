-- HealPlanner - UI/PlanTimeline.lua
-- NOUVELLE interface de planification (Phase 3) : une frise chronologique STATIQUE
-- de 0 a 300 s. Chaque capacite planifiable du boss est placee sur l'axe au temps
-- exact de son apparition ; au-dessus de chacune, un bouton "+" (UI Kit) ouvre le
-- selecteur de defensif. Tout est visible d'un coup (aucun scroll).
-- (L'ancienne liste verticale est archivee : Archive/ConfigFrame_pre_timeline.lua.)
local addonName, HR = ...

HR.UI = HR.UI or {}
local UI = HR.UI

local FIGHT      = 300          -- duree de la frise (s)
local LINE_Y     = 210          -- distance (px) du haut du cadre a l'axe (bas = place pour
                                -- empiler les defensifs choisis AU-DESSUS de la capacite)
local ICON       = 28           -- taille de l'icone d'une capacite (et des defensifs)
local PAD_L      = 24           -- marge gauche de l'axe
local PAD_R      = 24           -- marge droite de l'axe
local PLUS_SIZE  = 24           -- taille du bouton "+"
local DEF_GAP    = 4            -- ecart vertical entre defensifs empiles
local MARKER_MIN_GAP = ICON + 8 -- ecart horizontal MINIMUM entre 2 marqueurs (anti-overlap)
local OFF_SHIFT  = 8            -- decalage visuel FIXE (px) gauche/droite selon le signe de
                                -- l'offset (indication de sens, NON proportionnel a la valeur)

local PhaseLengthSource, RenderPhaseHandles   -- phases a longueur variable (cf. plus bas)

-- Picker custom des CD (remplace le menu WoW natif). Look de l'addon.
local WHITE8X8       = "Interface\\Buttons\\WHITE8x8"
local CDP_W          = 340      -- largeur (assez large pour ne jamais chevaucher temps + Force)
local CDP_MAXH       = 440
local CDP_HEADER_H   = 24
local CDP_ROW_H      = 28
local CDP_ICON       = 22
local CDP_SECTION    = { [1] = "Healer CDs", [2] = "Group Externals", [3] = "Personals", [4] = "Custom spells" }

local function fmtTime(t)
    return string.format("%d:%02d", math.floor(t / 60), t % 60)
end

-- Nom d'un defensif (raid ou perso), pour en extraire les 3 premieres lettres.
local function DefName(def)
    local d = HR.defensives[def] or (HR.personalDefensives and HR.personalDefensives[def])
    return (d and d.name) or tostring(def)
end

-- Bordure 1px (4 cotes) BLANCHE autour d'une frame.
local function WhiteBorder(frame, th)
    th = th or 1
    frame._eb = frame._eb or {}
    for _, k in ipairs({ "top", "bottom", "left", "right" }) do
        frame._eb[k] = frame._eb[k] or frame:CreateTexture(nil, "OVERLAY")
        frame._eb[k]:SetColorTexture(1, 1, 1, 1)
    end
    local e = frame._eb
    e.top:ClearAllPoints();    e.top:SetPoint("TOPLEFT");    e.top:SetPoint("TOPRIGHT");    e.top:SetHeight(th)
    e.bottom:ClearAllPoints(); e.bottom:SetPoint("BOTTOMLEFT"); e.bottom:SetPoint("BOTTOMRIGHT"); e.bottom:SetHeight(th)
    e.left:ClearAllPoints();   e.left:SetPoint("TOPLEFT");   e.left:SetPoint("BOTTOMLEFT");  e.left:SetWidth(th)
    e.right:ClearAllPoints();  e.right:SetPoint("TOPRIGHT"); e.right:SetPoint("BOTTOMRIGHT"); e.right:SetWidth(th)
end

-- Petit bouton +/- au look du selecteur d'externals (HealerSpecs.SmallButton) : fond
-- sombre + glyphe + surbrillance, + bordure BLANCHE. Reutilise pour les boutons d'offset.
local function SmallButton(parent, glyph)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(14, 14)
    b.bg = b:CreateTexture(nil, "BACKGROUND"); b.bg:SetAllPoints(); b.bg:SetColorTexture(0.2, 0.2, 0.2, 0.9)
    b.txt = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); b.txt:SetPoint("CENTER"); b.txt:SetText(glyph)
    b:SetHighlightTexture(WHITE8X8, "ADD")
    local hl = b:GetHighlightTexture(); if hl then hl:SetVertexColor(1, 1, 1, 0.18) end
    WhiteBorder(b)
    return b
end

-- Bouton-image reutilisable d'un defensif assigne, empile dans un marqueur (mk.defs).
-- Meme taille que l'icone du boss ; label = 3 premieres lettres ; clic = menu (retrait).
local function AcquireDefBtn(mk, i)
    local b = mk.defs[i]
    if not b then
        b = UI.Components.ImageButton(mk, { size = ICON, textSize = 10, textBanner = true })
        -- Label d'OFFSET (decalage, ex. "+3" / "-2") : pose au RENDU au-dessus du bouton
        -- correspondant (+ a droite / - a gauche), pour rester LISIBLE (pas sur l'icone).
        b.offLbl = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        b.offLbl:SetTextColor(1, 0.82, 0)
        b.offLbl:Hide()
        -- Boutons - / + (meme look que le selecteur d'externals), alignes sur le BAS de
        -- l'icone, de part et d'autre (gauche = plus tot / droite = plus tard). MASQUES par
        -- defaut : ne s'affichent que sur l'icone SELECTIONNEE (clic gauche) -> visuel epure.
        b.nudgeL = SmallButton(b, "-"); b.nudgeL:SetPoint("BOTTOMRIGHT", b, "BOTTOMLEFT", -1, 0); b.nudgeL:Hide()
        b.nudgeR = SmallButton(b, "+"); b.nudgeR:SetPoint("BOTTOMLEFT", b, "BOTTOMRIGHT", 1, 0); b.nudgeR:Hide()
        -- Pas de 5 s, a l'exterieur des -/+ : [-5][-] icone [+][+5].
        b.nudgeL5 = SmallButton(b, "-5"); b.nudgeL5:SetWidth(20)
        b.nudgeL5:SetPoint("BOTTOMRIGHT", b.nudgeL, "BOTTOMLEFT", -1, 0); b.nudgeL5:Hide()
        b.nudgeR5 = SmallButton(b, "+5"); b.nudgeR5:SetWidth(20)
        b.nudgeR5:SetPoint("BOTTOMLEFT", b.nudgeR, "BOTTOMRIGHT", 1, 0); b.nudgeR5:Hide()
        -- Clic gauche = selection (affiche -/+) ; clic droit = menu (retrait).
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b:SetScript("OnEnter", function(self)
            if not self._def then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local d = HR.defensives[self._def]
            if d and d.itemId then
                GameTooltip:SetItemByID(d.itemId)
            else
                local sid = HR.GetDefensiveSpellID(self._def)
                if type(sid) == "number" then GameTooltip:SetSpellByID(sid)
                else GameTooltip:SetText(DefName(self._def)) end
            end
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        mk.defs[i] = b
    end
    return b
end

-- Marqueur reutilisable : icone (sur l'axe) + "+" au-dessus + temps en dessous.
local function CreateMarker(f)
    local mk = CreateFrame("Frame", nil, f)
    mk:SetSize(ICON, ICON)
    mk:EnableMouse(true)

    mk.icon = mk:CreateTexture(nil, "ARTWORK")
    mk.icon:SetAllPoints()
    mk.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    mk:SetScript("OnEnter", function(self)
        if not self.spellID then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetSpellByID(self.spellID)
        GameTooltip:Show()
    end)
    mk:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- "+" au-dessus de la capacite (le onClick est (re)defini a chaque rendu).
    mk.plus = UI.Components.PlusButton(mk, { size = PLUS_SIZE })
    mk.plus:SetPoint("BOTTOM", mk, "TOP", 0, 6)

    -- Temps de l'occurrence, sous l'icone.
    mk.time = mk:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mk.time:SetPoint("TOP", mk, "BOTTOM", 0, -3)

    mk.defs = {}        -- pool de boutons-image des defensifs empiles au-dessus du "+"

    return mk
end

--------------------------------------------------------------------------------
-- Phases a LONGUEUR VARIABLE (boss a `phaseSegments`) : une POIGNEE par frontiere de
-- phase, a faire glisser sur la frise. Allonger une phase prolonge son cycle ; les phases
-- suivantes se decalent. Le reglage est ecrit dans la variante au RELACHEMENT
-- (HR.V2_SetPhaseLength) ; pendant le drag, `UI.phaseDrag` surcharge la longueur pour un
-- rendu en direct. Clic droit = longueur par defaut. Les placements ne sont jamais touches.
--------------------------------------------------------------------------------

local HANDLE_TOP = 62           -- haut de la poignee (px depuis le haut du cadre ; axe a LINE_Y)

-- Source des longueurs pour le rendu : la variante, ou une copie surchargee par le drag.
PhaseLengthSource = function(boss, variant)
    local drag = UI.phaseDrag
    if not (drag and drag.encID == boss.id and boss.phaseSegments) then return variant end
    local own = variant and variant.phaseLengths and variant.phaseLengths[boss.id]
    local merged = {}
    for k, v in pairs(own or {}) do merged[k] = v end
    merged[drag.k] = drag.sec
    return { phaseLengths = { [boss.id] = merged } }
end

local function AcquirePhaseHandle(f, k)
    f.phaseHandles = f.phaseHandles or {}
    local h = f.phaseHandles[k]
    if h then return h end
    local ar, ag, ab = HR.Colors.Unpack("accent")

    h = {}
    -- Trait de demarcation gris (gris de l'addon), sous les marqueurs.
    h.line = f:CreateTexture(nil, "ARTWORK", nil, -1)
    h.line:SetColorTexture(HR.Colors.Unpack("bgDark"))
    h.line:SetWidth(4)

    -- Poignee : etiquette « move » au sommet de la ligne, fond gris de l'addon, bordure violette.
    local PAD_X, PAD_Y = 8, 4
    local g = CreateFrame("Button", nil, f)
    g:SetFrameLevel(f:GetFrameLevel() + 20)
    g.bg = g:CreateTexture(nil, "ARTWORK")
    g.bg:SetAllPoints()
    g.bg:SetColorTexture(HR.Colors.Unpack("bgDark"))
    WhiteBorder(g, 1)
    for _, t in pairs(g._eb) do t:SetColorTexture(ar, ag, ab, 1) end
    g.label = g:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    g.label:SetPoint("CENTER", 0, 0)
    g.label:SetFont(g.label:GetFont(), 11, "")
    g.label:SetText("move")
    g:SetSize(math.ceil(g.label:GetStringWidth()) + PAD_X * 2,
              math.ceil(g.label:GetStringHeight()) + PAD_Y * 2)
    -- Temps theorique de la frontiere, au-dessus de la poignee.
    g.time = g:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    g.time:SetPoint("BOTTOM", g, "TOP", 0, 2)
    h.grip = g

    g:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(("%s -> %s"):format(self._from or "?", self._to or "?"))
        if self._canEdit then
            GameTooltip:AddLine("Drag to set how long this phase lasts.", 1, 1, 1, true)
            GameTooltip:AddLine(("Right-click: default (%s)."):format(fmtTime(self._default or 0)), 0.7, 0.7, 0.7, true)
        else
            GameTooltip:AddLine(HR.EditBlockedText(self._why, self._var), 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    g:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Fin du drag : ecrit la longueur dans la variante (ou re-rend si rien n'a change).
    local function finishDrag(self)
        self:SetScript("OnUpdate", nil)
        local drag = UI.phaseDrag
        UI.phaseDrag = nil
        if drag and HR.V2_SetPhaseLength(drag.encID, drag.k, drag.sec) then
            UI.RefreshRows()
        elseif self._boss then
            UI.RenderPlanTimeline(self._boss)
        end
    end

    -- Drag : on suit le curseur (OnUpdate) tant que le bouton gauche est ENFONCE. Le
    -- relachement est detecte ici (IsMouseButtonDown) et pas seulement par OnMouseUp, qui ne
    -- part pas si le curseur a quitte la poignee.
    g:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" or not self._canEdit then return end
        UI.phaseDrag = { encID = self._boss.id, k = self._k, sec = self._len }
        self:SetScript("OnUpdate", function(btn)
            if not IsMouseButtonDown("LeftButton") then finishDrag(btn); return end
            local fr = btn:GetParent()
            local scale = fr:GetEffectiveScale()
            local cx = GetCursorPosition() / scale
            local axisW = fr:GetWidth() - PAD_L - PAD_R
            if axisW <= 0 then return end
            local t = (cx - fr:GetLeft() - PAD_L) / axisW * FIGHT
            local sec = math.floor(t - btn._start + 0.5)
            sec = math.max(HR.PHASE_MIN_LENGTH, math.min(FIGHT - btn._start, sec))
            if UI.phaseDrag and sec ~= UI.phaseDrag.sec then
                UI.phaseDrag.sec = sec
                UI.RenderPlanTimeline(btn._boss)
            end
        end)
    end)
    g:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then
            if self._canEdit and HR.V2_SetPhaseLength(self._boss.id, self._k, nil) then UI.RefreshRows() end
        elseif UI.phaseDrag then
            finishDrag(self)
        end
    end)

    f.phaseHandles[k] = h
    return h
end

RenderPhaseHandles = function(f, boss, lenSrc, canEdit, whyRO, curVar, xAt)
    for _, h in pairs(f.phaseHandles or {}) do h.line:Hide(); h.grip:Hide() end
    local segs = boss.phaseSegments
    if not segs or #segs < 2 then return end
    local start = 0
    for k = 1, #segs - 1 do
        local len = HR.GetPhaseLength(boss, lenSrc, k) or 0
        local t = start + len
        if t > FIGHT then break end
        if not segs[k].intermission then                -- intermission : longueur fixe, pas de poignee
            local h = AcquirePhaseHandle(f, k)
            local x = xAt(t)
            h.line:ClearAllPoints()
            h.line:SetPoint("TOP", f, "TOPLEFT", x, -HANDLE_TOP)
            h.line:SetPoint("BOTTOM", f, "BOTTOMLEFT", x, 4)
            h.line:Show()
            local g = h.grip
            g:ClearAllPoints()
            g:SetPoint("TOP", f, "TOPLEFT", x, -HANDLE_TOP)
            g._boss, g._k, g._start, g._len = boss, k, start, len
            g._from, g._to = segs[k].name, segs[k + 1].name
            g._default = segs[k].length
            g._canEdit, g._why, g._var = canEdit, whyRO, curVar
            g.time:SetText(fmtTime(t))
            g:SetAlpha(canEdit and 1 or 0.4)
            g:Show()
        end
        start = t
    end
end

-- Construit (une fois) le cadre de la frise, dans la zone du plan (sous la rangee
-- de boss). Parente a UI.body comme les autres panneaux.
local function BuildFrame()
    if UI.planTimeline then return UI.planTimeline end

    local f = CreateFrame("Frame", nil, UI.body)
    f:SetPoint("TOPLEFT", UI.specsPanel, "BOTTOMLEFT", 4, -44)   -- sous la compo + rangee Export/Import
    f:SetPoint("BOTTOMRIGHT", UI.body, "BOTTOMRIGHT", -16, 16)

    -- Axe horizontal (largeur via ancrage a deux points => suit la taille du cadre).
    f.axis = f:CreateTexture(nil, "ARTWORK")
    f.axis:SetColorTexture(0.6, 0.6, 0.6, 0.8)
    f.axis:SetHeight(2)
    f.axis:SetPoint("TOPLEFT", PAD_L, -LINE_Y)
    f.axis:SetPoint("TOPRIGHT", -PAD_R, -LINE_Y)

    f.ticks   = {}      -- graduations de minute (0..5)
    f.markers = {}      -- pool de marqueurs de capacites

    -- Bandeau LECTURE SEULE : une variante liee (recue par sync, ou promue depuis un
    -- catalogue) n'est pas editable. Le mutateur refuse deja (HR.CanEditVariant, garde
    -- pose dans Core/Plan2.lua) -- mais sans ce bandeau le joueur cliquerait dans le vide
    -- sans comprendre. On dit POURQUOI, et on donne la sortie.
    f.roBanner = CreateFrame("Frame", nil, f, "BackdropTemplate")
    f.roBanner:SetPoint("TOPLEFT", PAD_L, -2)
    f.roBanner:SetPoint("TOPRIGHT", -PAD_R, -2)
    f.roBanner:SetHeight(20)
    f.roBanner:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    -- INFORMATION, pas erreur : le rouge faisait lire « tu as fait une betise » alors
    -- qu'une variante de catalogue en lecture seule est un etat parfaitement normal.
    f.roBanner:SetBackdropColor(HR.Colors.Unpack("infoBg"))
    f.roBanner.text = f.roBanner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.roBanner.text:SetPoint("CENTER")
    f.roBanner:Hide()

    -- Bandeau BOSS DESACTIVE dans ce plan (v.bossOff) : le plan reste editable, mais rien ne
    -- sera annonce en combat. Meme style que le bandeau lecture seule, juste en dessous.
    f.offBanner = CreateFrame("Frame", nil, f, "BackdropTemplate")
    f.offBanner:SetHeight(20)
    f.offBanner:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
    f.offBanner:SetBackdropColor(HR.Colors.Unpack("infoBg"))
    f.offBanner.text = f.offBanner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.offBanner.text:SetPoint("CENTER")
    f.offBanner.text:SetText(HR.Colors.Hex("info")
        .. "Boss disabled in this plan: no calls in combat (\"Enable boss\" to turn them back on)." .. "|r")
    f.offBanner:Hide()

    -- Re-rendu si la taille change (1er layout = largeur 0 sinon).
    f:SetScript("OnSizeChanged", function(self)
        if self._boss then UI.RenderPlanTimeline(self._boss) end
    end)

    UI.planTimeline = f
    return f
end

-- Affiche la frise du boss : axe + graduations + une capacite par occurrence.
function UI.RenderPlanTimeline(boss)
    local f = BuildFrame()
    f._boss = boss
    f:Show()

    local width = f:GetWidth()
    if not width or width < 50 then width = 700 end        -- repli avant 1er layout
    local axisW = width - PAD_L - PAD_R
    local function xAt(t) return PAD_L + (t / FIGHT) * axisW end

    -- Graduations + libelles de minute (0:00 .. 5:00).
    for m = 0, 5 do
        local tk = f.ticks[m]
        if not tk then
            tk = {}
            tk.line = f:CreateTexture(nil, "ARTWORK")
            tk.line:SetColorTexture(0.6, 0.6, 0.6, 0.8)
            tk.line:SetSize(1, 8)
            tk.label = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            f.ticks[m] = tk
        end
        local x = xAt(m * 60)
        tk.line:ClearAllPoints()
        tk.line:SetPoint("CENTER", f, "TOPLEFT", x, -LINE_Y)
        tk.label:ClearAllPoints()
        tk.label:SetPoint("TOP", f, "TOPLEFT", x, -LINE_Y - 8)
        tk.label:SetText(fmtTime(m * 60))
    end

    -- Verrou d'edition : etat calcule UNE fois pour toute la frise. Les mutateurs refusent
    -- deja (Core/Plan2.lua) ; ici on ne fait que rendre le refus VISIBLE avant le clic.
    local curVar = HR.GetActiveVariant()
    local canEdit, whyRO = HR.CanEditVariant(curVar)
    if curVar and not canEdit then
        f.roBanner.text:SetText(HR.Colors.Hex("info") .. HR.EditBlockedText(whyRO, curVar) .. "|r")
        f.roBanner:Show()
    else
        f.roBanner:Hide()
    end
    if HR.IsBossOffInVariant(curVar, boss.id) then
        local top = f.roBanner:IsShown() and -24 or -2
        f.offBanner:ClearAllPoints()
        f.offBanner:SetPoint("TOPLEFT", PAD_L, top)
        f.offBanner:SetPoint("TOPRIGHT", -PAD_R, top)
        f.offBanner:Show()
    else
        f.offBanner:Hide()
    end

    -- Occurrences planifiables (variante de timeline visualisee = active par defaut).
    -- Phases a longueur variable : longueurs de la variante, sauf celle en cours de drag.
    local lenSrc = PhaseLengthSource(boss, curVar)
    local occ = HR.GenerateOccurrences(HR.WithPhaseLengths(
        HR.ResolveBossTimeline(boss, UI.GetViewedTlVariant(boss)), lenSrc), HR.FIGHT_LENGTH)

    for _, mk in ipairs(f.markers) do mk:Hide() end

    local prevX                 -- x du marqueur precedent (pour l'ecart minimum)
    for i, o in ipairs(occ) do
        local mk = f.markers[i]
        if not mk then mk = CreateMarker(f); f.markers[i] = mk end
        mk:Show()

        mk.spellID = o.spellID
        mk.icon:SetTexture(HR.GetSpellIcon(o.spellID))
        mk.time:SetText(fmtTime(o.time))

        -- Position X = temps exact, MAIS poussee si trop proche du marqueur precedent
        -- (la frise est une representation, pas une horloge : on evite le chevauchement).
        local x = xAt(o.time)
        if prevX and x < prevX + MARKER_MIN_GAP then x = prevX + MARKER_MIN_GAP end
        prevX = x

        mk:ClearAllPoints()
        mk:SetPoint("CENTER", f, "TOPLEFT", x, -LINE_Y)             -- icone centree sur l'axe

        -- 1 occurrence sur 2 : on INVERSE le sens de croissance. Le "+" et la liste de
        -- defensifs poussent vers le BAS (sinon vers le haut). Le temps va du cote oppose.
        local down = (i % 2 == 0)
        mk.plus:ClearAllPoints()
        mk.time:ClearAllPoints()
        if down then
            mk.plus:SetPoint("TOP", mk, "BOTTOM", 0, -6)
            mk.time:SetPoint("BOTTOM", mk, "TOP", 0, 3)
        else
            mk.plus:SetPoint("BOTTOM", mk, "TOP", 0, 6)
            mk.time:SetPoint("TOP", mk, "BOTTOM", 0, -3)
        end

        -- "+" : ouvre le selecteur de defensif (nouveau format) pour CETTE occurrence.
        -- En lecture seule on le GARDE, attenue et inerte, plutot que de le retirer : sa
        -- disparition faisait bouger toute la colonne (les defensifs s'empilent au-dessus de
        -- lui) et changeait la frise selon la variante regardee. Attenue, il tient sa place,
        -- montre que l'emplacement existe, et dit par son etat qu'il n'est pas pour ici.
        mk.plus:SetEnabled(canEdit)
        mk.plus:SetAlpha(canEdit and 1 or 0.3)
        mk.plus:SetOnClick(function(btn) UI.OpenPlanPicker(btn, boss.id, o) end)

        -- Defensifs choisis (tokens du nouveau format) : empiles AU-DESSUS du "+".
        for _, b in ipairs(mk.defs) do b:Hide() end
        local prev, prevShift = mk.plus, 0
        for di, e in ipairs(HR.NewPlan_Get(boss.id, o.key)) do
            local token  = HR.EntryToken(e)
            local off    = HR.EntryOffset(e)                 -- decalage (ms)
            local defKey = HR.DefKeyOf(token)
            local suffix = HR.TokenSuffix(token)             -- "#2" si instance multiple
            local b = AcquireDefBtn(mk, di)
            b._def   = defKey                                -- (tooltip)
            b._token = token
            b:SetImage(HR.GetDefensiveIcon(defKey))
            local dd = HR.defensives[defKey] or (HR.personalDefensives and HR.personalDefensives[defKey])
            local short = (dd and dd.short) or DefName(defKey):sub(1, 3)
            b:SetText(suffix and (short .. suffix) or short) -- shortname + #N si instance multiple
            -- OFFSET : label au-dessus du bouton correspondant (+ a droite / - a gauche).
            if off ~= 0 then
                -- Secondes entieres -> "+2" ; sinon une decimale ("+0.9", "-1.5") : les offsets
                -- venus du format web sont libres en ms, et "%+d" tronquait 900 ms en "+0"
                -- alors que l'icone (et le runtime) etaient bien decales.
                local secs = off / 1000
                b.offLbl:SetText((off % 1000 == 0) and ("%+d"):format(secs) or ("%+.1f"):format(secs))
                b.offLbl:ClearAllPoints()
                b.offLbl:SetPoint("BOTTOM", off > 0 and b.nudgeR or b.nudgeL, "TOP", 0, 1)
                b.offLbl:Show()
            else
                b.offLbl:Hide()
            end
            -- Boutons -/+ visibles UNIQUEMENT sur le defensif selectionne (clic gauche).
            local selKey   = o.key .. "|" .. token
            local selected = (UI.planSelDef == selKey)
            b.nudgeL:SetShown(selected and canEdit)
            b.nudgeR:SetShown(selected and canEdit)
            b.nudgeL:SetScript("OnClick", function() HR.NewPlan_NudgeOffset(boss.id, o.key, token, -1000); UI.RefreshRows() end)
            b.nudgeR:SetScript("OnClick", function() HR.NewPlan_NudgeOffset(boss.id, o.key, token,  1000); UI.RefreshRows() end)
            b.nudgeL5:SetShown(selected and canEdit)
            b.nudgeR5:SetShown(selected and canEdit)
            b.nudgeL5:SetScript("OnClick", function() HR.NewPlan_NudgeOffset(boss.id, o.key, token, -5000); UI.RefreshRows() end)
            b.nudgeR5:SetScript("OnClick", function() HR.NewPlan_NudgeOffset(boss.id, o.key, token,  5000); UI.RefreshRows() end)
            b:SetOnClick(function(btn, mouse)
                if mouse == "RightButton" then
                    UI.OpenPlanDefMenu(btn, boss.id, o, token)
                else
                    UI.planSelDef = selected and nil or selKey   -- bascule la selection
                    UI.RefreshRows()
                end
            end)
            -- Decalage visuel FIXE gauche/droite selon le signe (telescopage : on retranche le
            -- shift du precedent pour que chaque icone ait son propre decalage absolu, pas cumule).
            local shift = (off > 0 and OFF_SHIFT) or (off < 0 and -OFF_SHIFT) or 0
            b:ClearAllPoints()
            if down then b:SetPoint("TOP", prev, "BOTTOM", shift - prevShift, -DEF_GAP)
            else b:SetPoint("BOTTOM", prev, "TOP", shift - prevShift, DEF_GAP) end
            b:Show()
            prev, prevShift = b, shift
        end
    end

    RenderPhaseHandles(f, boss, lenSrc, canEdit, whyRO, curVar, xAt)
end

--------------------------------------------------------------------------------
-- Picker custom des CD (look addon) : 3 sections (Healer CDs / Group Externals /
-- Personals), temps restant (-Xs) en rouge + bouton Force pour les CD presque prets.
--------------------------------------------------------------------------------

local function BuildCDPicker()
    if UI.cdPicker then return end
    -- Composant partage (fond + bordure + scroll + catcher), cf. C.ScrollPopup.
    local f = UI.Components.ScrollPopup({ name = "ECPCDPicker", width = CDP_W })
    f.content.headers = {}; f.content.rows = {}
    UI.cdPicker = f
    UI.cdPickerCatcher = f.catcher       -- compat (OpenCDPicker l'utilise)
end

local function AcquireCDHeader(content, i)
    local h = content.headers[i]
    if not h then
        h = CreateFrame("Frame", nil, content); h:SetHeight(CDP_HEADER_H)
        -- Titre de categorie (ex. "Healer CDs") + separateur en EMPHASIZE (violet).
        h.text = h:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        h.text:SetPoint("BOTTOMLEFT", 4, 4); h.text:SetTextColor(HR.Theme.Unpack("EMPHASIZE_TEXT_COLOR"))
        h.line = h:CreateTexture(nil, "ARTWORK")
        h.line:SetPoint("BOTTOMLEFT", 2, 0); h.line:SetPoint("BOTTOMRIGHT", -2, 0); h.line:SetHeight(1)
        local lr, lg, lb = HR.Theme.Unpack("EMPHASIZE_TEXT_COLOR")
        h.line:SetColorTexture(lr, lg, lb, 0.4)
        content.headers[i] = h
    end
    h:Show()
    return h
end

local function AcquireCDRow(content, i)
    local r = content.rows[i]
    if not r then
        r = CreateFrame("Button", nil, content); r:SetHeight(CDP_ROW_H)
        r:SetHighlightTexture(WHITE8X8, "ADD")
        local hl = r:GetHighlightTexture(); if hl then hl:SetVertexColor(1, 1, 1, 0.08) end
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(CDP_ICON, CDP_ICON)
        r.icon:SetPoint("LEFT", 6, 0); r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        r.name = r:CreateFontString(nil, "OVERLAY", "GameFontNormal"); r.name:SetJustifyH("LEFT")
        r.time = r:CreateFontString(nil, "OVERLAY", "GameFontNormal"); r.time:SetJustifyH("RIGHT")
        r.force = CreateFrame("Button", nil, r); r.force:SetSize(48, 20); r.force:SetPoint("RIGHT", -6, 0)
        r.force.bg = r.force:CreateTexture(nil, "BACKGROUND"); r.force.bg:SetAllPoints(); r.force.bg:SetColorTexture(0.9, 0.5, 0.1, 0.85)
        r.force.t = r.force:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); r.force.t:SetPoint("CENTER"); r.force.t:SetText("Force"); r.force.t:SetTextColor(1, 1, 1)
        r.force:SetScript("OnEnter", function(s) s.bg:SetColorTexture(1, 0.6, 0.15, 1) end)
        r.force:SetScript("OnLeave", function(s) s.bg:SetColorTexture(0.9, 0.5, 0.1, 0.85) end)
        content.rows[i] = r
    end
    r:Show()
    return r
end

function UI.RenderCDPicker(encounterID, occ, uses)
    BuildCDPicker()
    local content = UI.cdPicker.content
    for _, h in ipairs(content.headers) do h:Hide() end
    for _, r in ipairs(content.rows) do r:Hide() end

    local W = CDP_W - 34
    content:SetWidth(W)
    local y, hi, ri, lastGroup = 4, 0, 0, nil
    for _, item in ipairs(HR.GetPlaceableDefs()) do
        if item.group ~= lastGroup then
            lastGroup = item.group
            hi = hi + 1
            local h = AcquireCDHeader(content, hi)
            h:ClearAllPoints(); h:SetPoint("TOPLEFT", 0, -y); h:SetWidth(W)
            h.text:SetText(CDP_SECTION[item.group] or "?")
            y = y + CDP_HEADER_H
        end
        ri = ri + 1
        local r = AcquireCDRow(content, ri)
        r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, -y); r:SetWidth(W)

        -- Plus de "Force" : on peut placer N'IMPORTE QUEL CD (on le decale ensuite via l'offset
        -- pour le rendre dispo). Le manque (-Xs) reste affiche comme indication.
        local _, shortfall = HR.NewPlan_TokenState(item.token, HR.OccDefTime(occ), uses)
        local ready = shortfall <= 0

        r.icon:SetTexture(HR.GetDefensiveIcon(item.defKey)); r.icon:SetDesaturated(not ready)
        r.name:SetText(item.label)
        local g = ready and 1 or 0.55; r.name:SetTextColor(g, g, g)

        -- A droite : le manque (-Xs, rouge) s'il y en a, puis la DUREE DU CD (gris) -- utile
        -- pour departager deux versions d'un meme sort (variantes de CD, sorts custom).
        -- Rien pour un appel sans CD (EMPTY_BAG, cd 0).
        local d = HR.defensives[item.defKey]
        local cdTxt = ""
        if d and (d.cooldown or 0) > 0 then
            cdTxt = "|cff999999" .. HR.FormatCooldown(d.cooldown)
                .. ((d.charges and d.charges > 1) and (" x" .. d.charges) or "") .. "|r"
        end
        local missTxt = ready and "" or string.format("|cffff3333(-%ds)|r", math.ceil(shortfall))
        r.time:SetText(missTxt .. ((missTxt ~= "" and cdTxt ~= "") and "  " or "") .. cdTxt)
        if r.force then r.force:Hide() end
        r.time:ClearAllPoints(); r.time:SetPoint("RIGHT", -8, 0)
        r.name:ClearAllPoints(); r.name:SetPoint("LEFT", r.icon, "RIGHT", 8, 0); r.name:SetPoint("RIGHT", r.time, "LEFT", -6, 0)

        r:SetScript("OnClick", function()
            HR.NewPlan_Add(encounterID, occ.key, item.token)
            UI.CloseCDPicker(); UI.RefreshRows()
        end)
        y = y + CDP_ROW_H
    end

    content:SetHeight(math.max(y, 1))
    UI.cdPicker:SetHeight(math.min(y + 12, CDP_MAXH))
end

function UI.OpenCDPicker(anchor, encounterID, occ, uses)
    BuildCDPicker()
    UI.RenderCDPicker(encounterID, occ, uses)
    UI.cdPicker:ClearAllPoints()
    UI.cdPicker:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", -4, -4)
    UI.cdPickerCatcher:Show()
    UI.cdPicker:Show()
end

function UI.CloseCDPicker()
    if UI.cdPicker then UI.cdPicker:Close() end   -- cache popup + catcher (cf. C.ScrollPopup)
end

-- Ouvre le picker custom pour cette occurrence (calcule la dispo par token).
function UI.OpenPlanPicker(anchor, encounterID, occ)
    local cur = HR.GetActiveVariant()
    if not cur then
        HR:Print("Create a variant first (New).")
        return
    end
    -- Ceinture ET bretelles : le "+" est deja masque sur une variante liee, mais ce point
    -- d'entree est public. Ouvrir un selecteur dont chaque clic serait refuse plus bas
    -- serait pire qu'un refus net.
    local canEdit, why = HR.CanEditVariant(cur)
    if not canEdit then
        HR:Print(HR.EditBlockedText(why, cur))
        return
    end
    local dungeon = HR.content[UI.selDungeon]
    local boss = dungeon and dungeon.bosses[UI.selBoss]
    local timeOf = {}
    if boss then
        for _, o in ipairs(HR.GenerateOccurrences(HR.WithPhaseLengths(
                HR.ResolveBossTimeline(boss, UI.GetViewedTlVariant(boss)), cur), HR.FIGHT_LENGTH)) do
            timeOf[o.key] = HR.OccDefTime(o)   -- temps d'usage du CD (defMarker inclus) ; offset ajoute dans NewPlan_Uses
        end
    end
    UI.OpenCDPicker(anchor, encounterID, occ, HR.NewPlan_Uses(encounterID, timeOf))
end

-- Menu d'un defensif deja place (clic sur son icone) : retrait.
function UI.OpenPlanDefMenu(anchor, encounterID, occ, token)
    local defKey = HR.DefKeyOf(token)
    local d = HR.defensives[defKey]
    MenuUtil.CreateContextMenu(anchor, function(owner, root)
        local icon = HR.GetDefensiveIcon(defKey)
        root:CreateTitle(string.format("|T%s:16:16:0:0:64:64:5:59:5:59|t %s",
            tostring(icon), (d and d.name or tostring(defKey)) .. (HR.TokenSuffix(token) or "")))
        -- Verrou d'edition : sur une variante liee, on n'offre pas « Remove » -- le
        -- mutateur refuserait de toute facon (Core/Plan2.lua) et le clic serait sans
        -- effet visible. On affiche la raison a la place, avec la sortie.
        local cur = HR.GetActiveVariant()
        local canEdit, why = HR.CanEditVariant(cur)
        if canEdit then
            root:CreateButton("Remove", function()
                HR.NewPlan_Remove(encounterID, occ.key, token)
                UI.RefreshRows()
            end)
            -- Remet le decalage a 0 (seulement s'il y en a un).
            if HR.NewPlan_GetOffset(encounterID, occ.key, token) ~= 0 then
                root:CreateButton("Reset offset", function()
                    HR.NewPlan_SetOffset(encounterID, occ.key, token, 0)
                    UI.RefreshRows()
                end)
            end
        else
            root:CreateTitle(HR.Colors.Hex("info") .. HR.EditBlockedText(why, cur) .. "|r")
        end
    end)
end
