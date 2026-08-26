-- HealPlanner - UI/ProgressBars.lua
-- Representation ALTERNATIVE de la timeline du combat : des PROGRESS BARS (a cote de / au lieu de
-- la timeline d'icones defilantes). INDEPENDANTE de la TimelineBox (chacune son Enable ; on peut
-- afficher les DEUX). Toggles separes sous l'onglet "Bars and Timeline" (colonne "Bars" : Enable
-- bars / Grow / look-ahead / fond).
--
-- ⚠ CONSOMMATEUR EXTERNE de la timeline : ce module NE collecte PAS les sorts du boss lui-meme.
-- Il interroge le PRODUCTEUR partage `HR.Runtime.TimelineBossEvents(now, window)` (defini dans
-- UI/TimelineBox.lua), exactement comme la TimelineBox. Source de verite unique -> les deux
-- representations restent synchrones.
--
-- Modele :
--   * UI.progressBox = la barre INITIALE (= barre de reference). Sa POSITION est fixe (cle
--     "progress") et sa TAILLE = la taille d'UNE barre (progressBarWidth/Height). Les barres
--     suivantes s'empilent au-dessus ou en dessous (option progressGrow) SANS bouger l'initiale.
--   * Outils MODE TEST uniquement : une poignee de deplacement + une poignee de RESIZE (coin
--     bas-droit) qui regle la taille de reference (drag = move, drag du coin = resize).
local addonName, HR = ...

HR.UI = HR.UI or {}
local UI = HR.UI
HR.Runtime = HR.Runtime or {}

local function Opt()
    if not HR.db then return {} end
    HR.db.options = HR.db.options or {}
    return HR.db.options
end

local PB_GAP     = 2      -- ecart vertical entre deux barres
local PB_MINW, PB_MINH = 90, 12     -- bornes du resize
local PB_MAXW, PB_MAXH = 600, 60
local PB_REBUILD = 0.05   -- cadence de rendu (20 fps : assez fluide pour des barres)
local PB_TEX     = "Interface\\TargetingFrame\\UI-StatusBar"

-- Tailles de reference (= taille d'UNE barre, reglee au resize).
local function BarW()  return tonumber(Opt().progressBarWidth)  or 220 end
local function BarH()  return tonumber(Opt().progressBarHeight) or 22 end
local function GrowUp() return Opt().progressGrow == "up" end

--------------------------------------------------------------------------------
-- Widget "barre" : fond + StatusBar + icone (carree) + nom + compte a rebours.
--------------------------------------------------------------------------------

local function MakeBar(parent)
    local b = CreateFrame("Frame", nil, parent)
    b:EnableMouse(false)   -- affichage seul (pas de capture de clic)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(0, 0, 0, 0.6)
    b.bar = CreateFrame("StatusBar", nil, b)
    b.bar:SetPoint("TOPLEFT", 0, 0)
    b.bar:SetPoint("BOTTOMRIGHT", 0, 0)
    b.bar:SetStatusBarTexture(PB_TEX)
    b.bar:SetMinMaxValues(0, 1)
    b.bar:SetStatusBarColor(0.20, 0.50, 0.90, 0.85)
    -- Couche OVERLAY (parentee au StatusBar) -> AU-DESSUS du remplissage : icone boss, nom,
    -- decompte, et icones des defensifs planifies (bout droit de la barre).
    b.icon = b.bar:CreateTexture(nil, "OVERLAY")
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.icon:SetPoint("LEFT", b.bar, "LEFT", 0, 0)
    b.name = b.bar:CreateFontString(nil, "OVERLAY")
    b.name:SetPoint("LEFT", b.icon, "RIGHT", 4, 0)
    b.name:SetJustifyH("LEFT")
    b.name:SetWordWrap(false)
    b.time = b.bar:CreateFontString(nil, "OVERLAY")
    b.defIcons = {}   -- pool d'icones de defensifs (collees a droite)
    return b
end

-- Applique un item (ou vide) a une barre. `h` = hauteur de la barre (icones carrees = h) ;
-- `txtSize` = taille de police (option, plus d'auto). La barre garde sa taille EXACTE : les
-- icones de defensifs sont posees A DROITE, EN DEHORS de la barre (overflow assume si nombreuses).
-- `item` peut etre nil (barre vide = repere de placement). name/icon possiblement Secret :
-- on les passe a SetText/SetTexture (affichage) sans jamais les lire/comparer.
-- Remplissage : se VIDE a l'approche du cast (plein = loin, 0 = cast). La barre disparait au
-- cast (le producteur ne la renvoie plus des que rem < 0) -> plus de barre figee a 0.
local function StyleBar(b, item, window, h, txtSize, bgC, txtC)
    if not b then return end
    b.name:SetFont(STANDARD_TEXT_FONT, txtSize, "OUTLINE")
    b.time:SetFont(STANDARD_TEXT_FONT, txtSize, "OUTLINE")
    b.name:SetTextColor(txtC[1] or 1, txtC[2] or 1, txtC[3] or 1)
    b.time:SetTextColor(txtC[1] or 1, txtC[2] or 1, txtC[3] or 1)
    b.bg:SetColorTexture(bgC[1] or 0, bgC[2] or 0, bgC[3] or 0, bgC[4] or 1)
    b.icon:SetSize(h, h)

    if not item then
        b.bar:SetValue(0)
        b.icon:Hide(); b.name:SetText(""); b.time:SetText("")
        for _, di in ipairs(b.defIcons) do di:Hide() end
        return
    end
    b.icon:Show(); b.icon:SetTexture(item.icon or 134400)
    b.name:SetText(item.name or "")
    -- Couleur de remplissage de la barre : override joueur par sort (bossSpells.barColor du
    -- profil actif) sinon defaut. Resolue cote producteur (HR.Runtime.TimelineBossEvents).
    local barC = item.barColor or HR.DEFAULT_BAR_COLOR or { 0.20, 0.50, 0.90, 0.85 }
    b.bar:SetStatusBarColor(barC[1], barC[2], barC[3], barC[4] or 1)

    -- Decompte colle au bord DROIT, A L'INTERIEUR de la barre. Vide une fois le sort cast.
    b.time:ClearAllPoints()
    b.time:SetPoint("RIGHT", b.bar, "RIGHT", -3, 0)
    b.time:SetText((item.rem and item.rem > 0) and tostring(math.ceil(item.rem)) or "")
    -- Nom borne a droite par le decompte (pas de chevauchement).
    b.name:SetPoint("RIGHT", b.time, "LEFT", -4, 0)

    -- Icones des defensifs PLANIFIES : EN DEHORS de la barre, a sa droite (j=1 = collee a la
    -- barre, puis vers la droite). La barre conserve sa taille exacte ; overflow assume.
    local defs = item.defs or {}
    local diH  = h
    local gap  = 2
    for j = 1, #defs do
        local di = b.defIcons[j]
        if not di then
            di = b.bar:CreateTexture(nil, "OVERLAY")
            di:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            b.defIcons[j] = di
        end
        di:SetSize(diH, diH)
        di:ClearAllPoints()
        di:SetPoint("LEFT", b.bar, "RIGHT", gap + (j - 1) * (diH + gap), 0)
        di:SetTexture(defs[j].icon or 134400)
        di:SetDesaturated((defs[j].rem and defs[j].rem < 0) or false)   -- defensif deja passe = grise
        di:SetAlpha(defs[j].mine and 1 or 0.85)
        di:Show()
    end
    for j = #defs + 1, #b.defIcons do b.defIcons[j]:Hide() end

    local frac = (window > 0) and (item.rem / window) or 0
    if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
    b.bar:SetValue(frac)
end

--------------------------------------------------------------------------------
-- Rendu : la barre INITIALE (refBar) suit la boite (SetAllPoints -> resize live) ; les
-- barres SUIVANTES s'empilent dans le sens `progressGrow` a partir de la boite.
--------------------------------------------------------------------------------

local function Render(f)
    if not f or f._sizing then return end   -- pas de relayout pendant un resize en cours
    local window = Opt().progressWindow or 30
    local now    = GetTime()
    -- CONSOMMATION du producteur partage (pas de collecte locale). withDefs = on recupere les
    -- defensifs planifies par sort (icones a droite de la barre). La barre suit la timeline
    -- backend : elle disparait des que le sort en sort (cast passe / event retire) -> pas de ghost.
    local list   = HR.Runtime.TimelineBossEvents
        and HR.Runtime.TimelineBossEvents(now, window, { withDefs = true }) or {}
    local barH   = BarH()
    local up     = GrowUp()
    local bgC    = HR.CompGet("progress", "bgColor")
    local txtC   = HR.CompGet("progress", "textColor")
    local txtSz  = tonumber(Opt().progressTextSize) or 12

    -- DEVLOG : vide ~1x/s la liste des barres AFFICHEES (ce que le producteur renvoie a la barre).
    -- Revele les entrees fantomes (ex. "ADDS" bloquee) + si le `rem` d'une barre ne descend pas.
    if HR.DevLogEnabled() and #list > 0 then
        f._devAcc = (f._devAcc or 0) + PB_REBUILD
        if f._devAcc >= 1.0 then
            f._devAcc = 0
            HR.DevLogList("bars", ("Render win=%d up=%s"):format(window, tostring(up)), list, function(it, k)
                return string.format("%s key=%s name='%s' rem=%.2f defs=%d",
                    (k == 1) and "REF " or "extra", HR.DevSafe(it.key), HR.DevSafe(it.name),
                    it.rem or -99, it.defs and #it.defs or 0)
            end)
        end
    end

    -- Barre initiale (= boite) : item le plus imminent, ou vide (repere de placement).
    StyleBar(f.refBar, list[1], window, f:GetHeight(), txtSz, bgC, txtC)

    -- Barres suivantes (item 2..N) : empilees dans le sens choisi, taille de reference.
    local need = math.max(#list - 1, 0)
    for j = 1, need do
        local b = f.extra[j]
        if not b then b = MakeBar(f); f.extra[j] = b end
        b:SetSize(BarW(), barH)
        b:ClearAllPoints()
        local off = j * (barH + PB_GAP)
        if up then
            b:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, off)    -- au-dessus de l'initiale
        else
            b:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -off)         -- en dessous de l'initiale
        end
        StyleBar(b, list[j + 1], window, barH, txtSz, bgC, txtC)
        b:Show()
    end
    for j = need + 1, #f.extra do f.extra[j]:Hide() end
end

local function OnUpdate(self, dt)
    self._acc = (self._acc or 0) + dt
    if self._acc < PB_REBUILD then return end
    self._acc = 0
    Render(self)
end

--------------------------------------------------------------------------------
-- Options : taille de reference + echelle (composition "progress", scale partage).
--------------------------------------------------------------------------------

function HR.Runtime.ApplyProgressOptions()
    local f = UI.progressBox
    if not f then return end
    HR.SetFrameScaleInPlace(f, HR.CompGet("progress", "scale") or 1.0)   -- rescale SANS deplacer
    f:SetSize(BarW(), BarH())                                            -- taille de reference (TOPLEFT fixe)
    HR.SaveFramePos("progress", f)                                       -- GetPoint (TOPLEFT normalise au drag/resize)
    Render(f)
end

--------------------------------------------------------------------------------
-- Outils MODE TEST : deplacement + resize (regle la taille d'UNE barre).
--------------------------------------------------------------------------------

local function AddTools(f)
    -- Poignee de DEPLACEMENT (au-dessus de la barre initiale, comme la TimelineBox).
    local h = CreateFrame("Button", nil, f)
    h:SetSize(54, 14)
    h:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 0, 1)   -- poignee ancree COMPLETEMENT a gauche
    h:SetFrameStrata("MEDIUM")
    h:RegisterForDrag("LeftButton")
    h.bg = h:CreateTexture(nil, "BACKGROUND"); h.bg:SetAllPoints(); h.bg:SetColorTexture(0.15, 0.15, 0.15, 0.9)
    h.t = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); h.t:SetPoint("CENTER"); h.t:SetText("move")
    h:SetScript("OnDragStart", function()
        f:StartMoving()
    end)
    h:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        HR.SaveFramePosTopLeft("progress", f)   -- ancre TOPLEFT normalisee (resize coherent)
    end)
    h:SetScript("OnEnter", function(self)
        self.bg:SetColorTexture(0.28, 0.28, 0.3, 0.95)
        GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText("Drag to move"); GameTooltip:Show()
    end)
    h:SetScript("OnLeave", function(self) self.bg:SetColorTexture(0.15, 0.15, 0.15, 0.9); GameTooltip:Hide() end)
    h:Hide()
    f.moveHandle = h

    -- Poignee de RESIZE (coin bas-droit) : regle la taille de reference d'UNE barre.
    local g = CreateFrame("Button", nil, f)
    g:SetSize(16, 16)
    g:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    g:SetFrameStrata("MEDIUM")
    g:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    g:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    g:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    g:SetScript("OnMouseDown", function()
        f._sizing = true
        f:StartSizing("BOTTOMRIGHT")
    end)
    g:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing(); f._sizing = false
        Opt().progressBarWidth  = math.floor((f:GetWidth()  or BarW()) + 0.5)
        Opt().progressBarHeight = math.floor((f:GetHeight() or BarH()) + 0.5)
        HR.SaveFramePosTopLeft("progress", f)   -- TOPLEFT fixe -> le coin haut-gauche ne bouge pas
        HR.Runtime.ApplyProgressOptions()
    end)
    g:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText("Drag to resize one bar"); GameTooltip:Show()
    end)
    g:SetScript("OnLeave", function() GameTooltip:Hide() end)
    g:Hide()
    f.resizeGrip = g
end

--------------------------------------------------------------------------------
-- Construction (HORS COMBAT, depuis HR.Runtime.PreBuild).
--------------------------------------------------------------------------------

local function BuildProgress()
    local f = CreateFrame("Frame", "HealPlannerProgressBars", UIParent)
    f:SetSize(BarW(), BarH())
    f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 40, -200)
    f:SetFrameStrata("BACKGROUND")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:SetResizable(true)
    if f.SetResizeBounds then f:SetResizeBounds(PB_MINW, PB_MINH, PB_MAXW, PB_MAXH) end
    f:EnableMouse(false)

    f.extra  = {}              -- pool des barres suivantes (item 2..N)
    f.refBar = MakeBar(f)      -- barre INITIALE : suit la boite (resize live)
    f.refBar:SetAllPoints(f)

    AddTools(f)

    f:SetScript("OnUpdate", OnUpdate)
    UI.progressBox = f
    -- Echelle AVANT restore (offset sauve a cette echelle), cf. meme logique que TimelineBox.
    f:SetScale(HR.CompGet("progress", "scale") or 1.0)
    HR.RestoreFramePos("progress", f)
    HR.Runtime.ApplyProgressOptions()
    f:SetAlpha(0)              -- masquee par defaut ; UpdateVisibility decide
    f:Show()
end

function HR.Runtime.PreBuildProgress()
    if not UI.progressBox then BuildProgress() end
end
