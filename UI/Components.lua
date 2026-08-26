-- HealPlanner - UI/Components.lua
-- Bibliotheque de composants UI reutilisables (le "design system" de l'addon).
--
-- Convention (façon "component" React, mais en retained-mode) :
--   * une FACTORY  C.XxxButton(parent, opts)  construit le sous-arbre UNE fois
--     (= mount / constructor) et retourne une FRAME native augmentee d'un mixin ;
--   * `opts` = les "props" initiales (table, tous champs optionnels) ;
--   * des SETTERS (:SetText, :SetSelected, :SetOnClick...) = la mise a jour
--     (= render : on MUTE les widgets existants, on ne recree jamais).
-- L'instance EST une frame -> SetPoint / Show / Hide / parentage marchent direct.
local addonName, HR = ...

HR.UI = HR.UI or {}
local UI = HR.UI
UI.Components = UI.Components or {}
local C = UI.Components

-- Couleurs du design system : tirees du Color Manager (Core/Colors.lua) si present,
-- repli sur les litteraux historiques sinon (robustesse a l'ordre de chargement).
-- On garde l'alpha historique (le manager n'expose que la teinte de base).
local function rgba(name, a, fallback)
    if HR.Colors then
        local r, g, b = HR.Colors.Unpack(name)
        return { r, g, b, a }
    end
    return fallback
end
local DARK_GRAY  = rgba("gray15", 0.95, { 0.15, 0.15, 0.15, 0.95 })
local DARKER     = rgba("gray10", 0.90, { 0.10, 0.10, 0.10, 0.90 })
local BLACK      = rgba("black",  1,    { 0, 0, 0, 1 })
local LIGHT_GRAY = rgba("gray75", 1,    { 0.75, 0.75, 0.75, 1 })

-- Resout une "prop couleur" en table {r,g,b,a} : accepte une table directe, un NOM
-- de couleur du manager (string), ou nil -> defaut fourni.
local function resolveColor(v, default)
    if type(v) == "string" then
        return HR.Colors and HR.Colors.Get(v) or default
    elseif type(v) == "table" then
        return v
    end
    return default
end

local TOOLTIP_BORDER = "Interface\\Tooltips\\UI-Tooltip-Border"
local WHITE8X8       = "Interface\\Buttons\\WHITE8x8"

-- Petit utilitaire : applique un script OnClick qui appelle self._onClick(self, mouseButton).
local function WireOnClick(b)
    b:RegisterForClicks("LeftButtonUp")
    b:SetScript("OnClick", function(self, mouseButton)
        if self._onClick then self._onClick(self, mouseButton) end
    end)
end

--------------------------------------------------------------------------------
-- 0. ImageText — primitif d'AFFICHAGE : image + texte OVERLAY sur un bandeau optionnel.
--    AUCUNE interaction (pas de bouton) : pour du clic, nester/composer dans un Button
--    (c'est ce que fait C.ImageButton, via le meme builder de regions ci-dessous).
--    opts = { image, text, size | width/height, crop=<bool def true>,
--             textSize=<n>, textColor=<{r,g,b,a}|nom|nil def blanc>, shadow=<bool def true>,
--             banner=<bool>, bannerColor=<{r,g,b,a}|nom|nil def noir 0.8>, bannerHeight=<n> }
--    banner est cree si `banner` OU `bannerColor` est fourni (sinon aucun -> .banner nil).
--    Methodes : SetImage, SetText, SetTextColor, SetBannerColor.
--------------------------------------------------------------------------------

-- Construit les regions "image + bandeau optionnel + texte overlay" DIRECTEMENT sur `f`
-- (Frame ou Button). Partage par C.ImageText et C.ImageButton -> une seule source, et
-- pas de frame enfant (sinon le contenu passerait AU-DESSUS du HIGHLIGHT du bouton).
--   f.image  = Texture ARTWORK (remplit f, rognee par defaut)
--   f.banner = Texture ARTWORK sublevel 1 (bandeau bas)  [seulement si demande]
--   f.label  = FontString OVERLAY (bas centre, ombre)
local function buildImageText(f, opts)
    f.image = f:CreateTexture(nil, "ARTWORK")
    f.image:SetAllPoints()
    if opts.crop ~= false then
        f.image:SetTexCoord(0.08, 0.92, 0.08, 0.92)   -- rogne la bordure des icones
    end

    local wantBanner = opts.banner or (opts.bannerColor ~= nil)
    if wantBanner then
        local bc = resolveColor(opts.bannerColor, { 0, 0, 0, 0.8 })
        f.banner = f:CreateTexture(nil, "ARTWORK", nil, 1)   -- au-dessus de l'image, sous le texte
        f.banner:SetColorTexture(bc[1], bc[2], bc[3], bc[4] or 1)
        f.banner:SetPoint("BOTTOMLEFT", 0, 0)
        f.banner:SetPoint("BOTTOMRIGHT", 0, 0)
        f.banner:SetHeight(opts.bannerHeight or ((opts.textSize or 11) + 3))
    end

    f.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.label:SetPoint("BOTTOM", 0, wantBanner and 1 or 2)   -- centre dans le bandeau si present
    local tc = resolveColor(opts.textColor, { 1, 1, 1, 1 })
    f.label:SetTextColor(tc[1], tc[2], tc[3], tc[4] or 1)
    if opts.shadow ~= false then
        f.label:SetShadowColor(0, 0, 0, 1)
        f.label:SetShadowOffset(1, -1)
    end
    if opts.textSize then
        local fpath, _, flags = f.label:GetFont()
        f.label:SetFont(fpath, opts.textSize, flags)
    end
end

local ImageTextMixin = {}
function ImageTextMixin:SetImage(tex) self.image:SetTexture(tex) end
function ImageTextMixin:SetText(t)    self.label:SetText(t or "") end
function ImageTextMixin:SetTextColor(r, g, b, a) self.label:SetTextColor(r, g, b, a or 1) end
function ImageTextMixin:SetBannerColor(r, g, b, a)
    if self.banner then self.banner:SetColorTexture(r, g, b, a or 1) end
end

function C.ImageText(parent, opts)
    opts = opts or {}
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(opts.width or opts.size or 36, opts.height or opts.size or 36)
    buildImageText(f, opts)
    Mixin(f, ImageTextMixin)
    if opts.image then f:SetImage(opts.image) end
    if opts.text  then f:SetText(opts.text) end
    return f
end

--------------------------------------------------------------------------------
-- 1. ImageButton — image de fond + texte en OVERLAY (par-dessus l'image).
--    opts = { image=<texture>, text=<string>, size=<n> | width/height,
--             crop=<bool, def true>, onClick=<fn>,
--             textSize=<n>,            -- taille de police du label (def = GameFontNormal)
--             textBanner=<bool>,       -- bandeau noir en bas (lisibilite du texte)
--             bannerHeight=<n> }       -- hauteur du bandeau (def = textSize+3)
--    Les 3 derniers sont OPT-IN (nil par defaut => comportement inchange ailleurs).
--------------------------------------------------------------------------------

local ImageButtonMixin = {}

function ImageButtonMixin:SetImage(tex)
    self.image:SetTexture(tex)
end

function ImageButtonMixin:SetText(t)
    self.label:SetText(t or "")
end

-- Etat selectionne : liseré doré + image pleine ; sinon image desaturee/attenuee
-- (comme les anciens onglets de navigation). Non appele = etat neutre plein.
function ImageButtonMixin:SetSelected(on)
    self._selected = on and true or false
    self.selBorder:SetShown(self._selected)
    self.image:SetDesaturated(not self._selected)
    self.image:SetAlpha(self._selected and 1 or 0.55)
end

function ImageButtonMixin:IsSelected()
    return self._selected
end

function ImageButtonMixin:SetOnClick(fn)
    self._onClick = fn
end

function C.ImageButton(parent, opts)
    opts = opts or {}
    local b = CreateFrame("Button", nil, parent)
    local w = opts.width  or opts.size or 36
    local h = opts.height or opts.size or 36
    b:SetSize(w, h)

    -- Liseré de selection (couleur + epaisseur via le theme : IMAGE_BUTTON_BORDER_*),
    -- derriere l'image, cache par defaut.
    local ibTh = (HR.Theme and HR.Theme.Value("IMAGE_BUTTON_BORDER_THICKNESS", 2)) or 2
    b.selBorder = b:CreateTexture(nil, "BACKGROUND")
    b.selBorder:SetPoint("TOPLEFT", -ibTh, ibTh)
    b.selBorder:SetPoint("BOTTOMRIGHT", ibTh, -ibTh)
    if HR.Theme then b.selBorder:SetColorTexture(HR.Theme.Unpack("IMAGE_BUTTON_BORDER_COLOR"))
    else b.selBorder:SetColorTexture(0.62, 0.44, 0.92, 1) end   -- repli violet (plus de gold)
    b.selBorder:Hide()

    -- Contenu (image + bandeau optionnel + label) = MEMES regions que C.ImageText, posees
    -- directement sur le bouton via le builder partage (pas de frame enfant -> le HIGHLIGHT
    -- du bouton reste au-dessus). textBanner = opt-in (bandeau noir 0.8 par defaut).
    buildImageText(b, {
        crop = opts.crop, textSize = opts.textSize,
        banner = opts.textBanner, bannerHeight = opts.bannerHeight,
    })
    b.textBanner = b.banner        -- compat : consommateurs togglent it.btn.textBanner:SetShown(...)

    -- Surbrillance au survol.
    b:SetHighlightTexture(WHITE8X8, "ADD")
    local hl = b:GetHighlightTexture()
    if hl then hl:SetVertexColor(1, 1, 1, 0.12) end

    Mixin(b, ImageButtonMixin)
    if opts.image then b:SetImage(opts.image) end
    if opts.text  then b:SetText(opts.text)  end
    b._onClick = opts.onClick
    WireOnClick(b)
    return b
end

--------------------------------------------------------------------------------
-- 2. TextButton — texte centre, fond gris fonce, bordure noire.
--    Etat selectionne => bordure jaune (liseré).
--    DEUX variantes via opts.square :
--      * defaut (square=false) : bordure arrondie (UI-Tooltip-Border), compacte.
--      * square=true           : coins DROITS (bordure pleine 1px dessinee a la
--                                main) + plus d'espace (padding/hauteur).
--    opts = { text=, width=, height=, autoWidth=<bool>, minWidth=, padX=, padY=,
--             square=<bool>, borderColor=, selectedColor=, hoverColor=, thickness=,
--             onClick=, selected= }
--    hoverColor = couleur de bordure au survol (defaut = token BUTTON_BORDER_HOVER_COLOR ;
--      ignore quand selectionne). nil => pas d'effet de survol sur la bordure.
--    padX/padY = air mini texte<->bord (horizontal/vertical). Ils agissent TOUJOURS
--      comme PLANCHER : ne retrecissent jamais une width/height explicite, garantissent
--      juste l'espace mini autour du texte. autoWidth => largeur pilotee par le texte
--      (= texte + 2*padX), bornee a `minWidth` (defaut 90/70 ; passer 0 = padX seul maitre).
--------------------------------------------------------------------------------

-- Cree une bordure pleine a coins droits (4 textures ancrees aux bords du frame ;
-- elles se redimensionnent toutes seules via l'ancrage a deux points). Renvoie la
-- table { top, bottom, left, right } pour la recoloration.
local function AddSquareBorder(f, th, color)
    th = th or 1
    color = color or BLACK
    local cr, cg, cb, ca = color[1], color[2], color[3], color[4] or 1
    local function edge()
        local t = f:CreateTexture(nil, "BORDER")
        t:SetColorTexture(cr, cg, cb, ca)
        return t
    end
    local top, bottom, left, right = edge(), edge(), edge(), edge()
    top:SetPoint("TOPLEFT");     top:SetPoint("TOPRIGHT");     top:SetHeight(th)
    bottom:SetPoint("BOTTOMLEFT"); bottom:SetPoint("BOTTOMRIGHT"); bottom:SetHeight(th)
    left:SetPoint("TOPLEFT");    left:SetPoint("BOTTOMLEFT");   left:SetWidth(th)
    right:SetPoint("TOPRIGHT");  right:SetPoint("BOTTOMRIGHT"); right:SetWidth(th)
    return { top = top, bottom = bottom, left = left, right = right }
end

local TextButtonMixin = {}

function TextButtonMixin:SetText(t)
    self.label:SetText(t or "")
    self:Relayout()
    if self._struck then self:SetStruck(true) end   -- recalcule la largeur du trait
end

-- (Re)calcule la taille selon le texte + padding. padX/padY = air mini autour du texte ;
-- width/height (reqW/reqH) servent de PLANCHER (le padding ne retrecit jamais une taille
-- explicite, il ne fait que la pousser si le texte + pad la depasse). autoWidth => la
-- largeur suit le texte (plancher = _minWidth).
function TextButtonMixin:Relayout()
    local tw = self.label:GetStringWidth()
    local th = self.label:GetStringHeight()
    local w
    if self._autoWidth then
        w = math.max(self._minWidth, tw + self._padX * 2)
    else
        w = math.max(self._reqW or self._defW, tw + self._padX * 2)
    end
    local h = math.max(self._reqH or self._defH, th + self._padY * 2)
    self:SetSize(w, h)
end

-- Change le padding a chaud (table {x=,y=} ou deux nombres) puis relayout.
function TextButtonMixin:SetPadding(x, y)
    if type(x) == "table" then x, y = x.x, x.y end
    if x then self._padX = x end
    if y then self._padY = y end
    self:Relayout()
end

-- Barre (strikethrough) le texte : trait fin centre, large comme la chaine. Pas de
-- support natif -> on superpose une texture (recalculee a chaque SetText si actif).
function TextButtonMixin:SetStruck(on)
    self._struck = on and true or false
    if self._struck and not self.strike then
        self.strike = self:CreateTexture(nil, "OVERLAY", nil, 1)
        self.strike:SetColorTexture(0.9, 0.9, 0.9, 0.9)
        self.strike:SetHeight(1)
    end
    if not self.strike then return end
    if self._struck then
        self.strike:ClearAllPoints()
        self.strike:SetPoint("CENTER", self.label, "CENTER", 0, 0)
        self.strike:SetWidth(math.max(1, self.label:GetStringWidth()))
        self.strike:Show()
    else
        self.strike:Hide()
    end
end

-- Recolore la bordure quelle que soit la variante (arrondie ou pleine).
function TextButtonMixin:SetBorderColor(r, g, b, a)
    if self._border then
        for _, t in pairs(self._border) do t:SetColorTexture(r, g, b, a or 1) end
    else
        self:SetBackdropBorderColor(r, g, b, a or 1)
    end
end

-- Etat visuel : le SURVOL change la BORDURE (violet) ; la SELECTION change le FOND
-- (violet clair, token dedie) + assombrit le texte pour rester lisible. Les deux sont
-- independants (un bouton selectionne ET survole montre les deux).
function TextButtonMixin:_ApplyBorderState()
    -- Bordure : violet au survol, sinon couleur de repos (la selection n'y touche pas).
    if self._hovering and self._hoverColor then
        self:SetBorderColor(unpack(self._hoverColor))
    else
        self:SetBorderColor(unpack(self._borderColor or BLACK))
    end
    -- Fond + texte : selon l'etat selectionne.
    if self._selected then
        self:SetBackdropColor(unpack(self._selFill or self._fillColor or DARK_GRAY))
        self.label:SetTextColor(1, 1, 1)
    else
        self:SetBackdropColor(unpack(self._fillColor or DARK_GRAY))
        local g = self._hovering and 0.95 or 0.8
        self.label:SetTextColor(g, g, g)
    end
end

function TextButtonMixin:SetSelected(on)
    self._selected = on and true or false
    self:_ApplyBorderState()
end

function TextButtonMixin:IsSelected()
    return self._selected
end

-- Change l'epaisseur de bordure (px pleins pour "square" ; edgeSize de la texture pour
-- l'arrondi). Pour l'arrondi, edgeSize est fige au SetBackdrop -> on le refait.
function TextButtonMixin:SetBorderThickness(th)
    self._thickness = th
    if self._border then
        self._border.top:SetHeight(th);  self._border.bottom:SetHeight(th)
        self._border.left:SetWidth(th);  self._border.right:SetWidth(th)
    else
        self:SetBackdrop({
            bgFile   = WHITE8X8,
            edgeFile = TOOLTIP_BORDER,
            edgeSize = th,
            insets   = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        self:SetBackdropColor(unpack(DARK_GRAY))
    end
end

-- Re-applique les valeurs THEME du chrome (bordure : couleur/epaisseur/selection),
-- en respectant les overrides explicites du call-site (opts.*). Appelee au changement
-- de theme. Repose ensuite la couleur courante selon l'etat selectionne.
function TextButtonMixin:ApplyTheme()
    if not HR.Theme then return end
    if not self._ovBorder then self._borderColor = HR.Theme.Color(self._borderTok) end
    if not self._ovSel    then self._selFill     = HR.Theme.Color(self._selTok) end
    if not self._ovHover  then self._hoverColor  = HR.Theme.Color(self._hoverTok) end
    if not self._ovThick  then
        self:SetBorderThickness(HR.Theme.Value(self._thickTok, self._square and 1 or 12))
    end
    self:_ApplyBorderState()
end

function TextButtonMixin:SetOnClick(fn)
    self._onClick = fn
end

-- Registre (cles faibles) des boutons a re-skinner au changement de theme + hook unique.
local themedButtons = setmetatable({}, { __mode = "k" })
local themeHooked = false
local function RegisterThemed(b)
    themedButtons[b] = true
    if themeHooked or not HR.Theme then return end
    themeHooked = true
    HR.Theme.OnChange(function()
        for btn in pairs(themedButtons) do btn:ApplyTheme() end
    end)
end

function C.TextButton(parent, opts)
    opts = opts or {}
    local square = opts.square and true or false
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b._padX = opts.padX or (square and 18 or 12)        -- marge horizontale texte<->bord
    b._padY = opts.padY or 0                            -- marge verticale (0 = pas de plancher impose)
    b._reqW = opts.width                                -- largeur demandee (plancher), nil sinon
    b._reqH = opts.height                               -- hauteur demandee (plancher), nil sinon
    b._minWidth = opts.minWidth or (square and 90 or 70) -- plancher de largeur en mode autoWidth (0 = padX seul maitre)
    b._defW = square and 120 or 90                      -- largeur par defaut (largeur fixe sans width)
    b._defH = square and 30 or 24                       -- hauteur par defaut
    b._autoWidth = opts.autoWidth and not opts.width
    b:SetSize(b._reqW or b._defW, b._reqH or b._defH)   -- taille initiale ; Relayout affine au SetText

    -- Bordure : les DEFAUTS viennent du THEME actif (tokens BUTTON_BORDER_*), via la
    -- variante. Les props opts.* gardent la PRIORITE (override -> figees, le theme ne
    -- les ecrasera pas au swap). La "taille" arrondie est mappee sur edgeSize.
    b._square   = square
    b._borderTok = square and "BUTTON_BORDER_SQUARED_COLOR"     or "BUTTON_BORDER_ROUND_COLOR"
    b._thickTok  = square and "BUTTON_BORDER_SQUARED_THICKNESS" or "BUTTON_BORDER_ROUND_THICKNESS"
    b._selTok    = "BUTTON_SELECTED_COLOR"     -- FOND de l'etat selectionne (violet clair)
    b._hoverTok  = "BUTTON_BORDER_HOVER_COLOR"
    b._ovBorder  = opts.borderColor   and resolveColor(opts.borderColor)   or nil
    b._ovSel     = opts.selectedColor and resolveColor(opts.selectedColor) or nil
    b._ovHover   = opts.hoverColor    and resolveColor(opts.hoverColor)    or nil
    b._ovThick   = opts.thickness

    b._fillColor   = DARK_GRAY                                                  -- fond repos/survol
    b._borderColor = b._ovBorder or (HR.Theme and HR.Theme.Color(b._borderTok)) or BLACK
    b._selFill     = b._ovSel    or (HR.Theme and HR.Theme.Color(b._selTok))    or DARK_GRAY
    b._hoverColor  = b._ovHover  or (HR.Theme and HR.Theme.Color(b._hoverTok))  or nil
    local th       = b._ovThick  or (HR.Theme and HR.Theme.Value(b._thickTok, square and 1 or 12))
                                  or (square and 1 or 12)
    b._thickness = th

    if square then
        -- Coins droits : fond seul (pas d'edge arrondi) + bordure pleine dessinee.
        b:SetBackdrop({ bgFile = WHITE8X8 })
        b:SetBackdropColor(unpack(DARK_GRAY))
        b._border = AddSquareBorder(b, th, b._borderColor)
    else
        -- Bordure arrondie native (UI-Tooltip-Border) ; edgeSize = "epaisseur".
        b:SetBackdrop({
            bgFile   = WHITE8X8,
            edgeFile = TOOLTIP_BORDER,
            edgeSize = th,
            insets   = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        b:SetBackdropColor(unpack(DARK_GRAY))
    end

    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    b.label:SetPoint("CENTER")

    -- Surbrillance au survol (legere).
    b:SetHighlightTexture(WHITE8X8, "ADD")
    local hl = b:GetHighlightTexture()
    if hl then
        hl:SetVertexColor(1, 1, 1, 0.08)
        local inset = square and 1 or 3
        hl:SetPoint("TOPLEFT", inset, -inset)
        hl:SetPoint("BOTTOMRIGHT", -inset, inset)
    end

    Mixin(b, TextButtonMixin)
    b._onClick = opts.onClick
    WireOnClick(b)
    -- Effet de survol sur la BORDURE (en plus du highlight de fond). Ignore quand
    -- selectionne (le liseré de selection prime). HookScript = ne clobber aucun
    -- OnEnter/OnLeave eventuel du call-site.
    b:HookScript("OnEnter", function(self) self._hovering = true;  self:_ApplyBorderState() end)
    b:HookScript("OnLeave", function(self) self._hovering = false; self:_ApplyBorderState() end)
    b:SetText(opts.text or "")
    b:SetSelected(opts.selected)        -- pose la bordure (couleur selon le theme)
    RegisterThemed(b)                   -- suit les changements de theme (re-skin live)
    return b
end

--------------------------------------------------------------------------------
-- 3. PlusButton — "+" centre, fond fonce, bordure gris clair POINTILLEE (dashed).
--    La bordure dashed n'existe pas en natif : on la dessine en posant des petits
--    segments de texture le long du perimetre (re-layoutes au redimensionnement).
--    opts = { text=<def "+">, size= | width/height, onClick=,
--             dash=, gap=, thickness=, color={r,g,b,a} }
--------------------------------------------------------------------------------

-- (Re)pose les segments de la bordure pointillee selon la taille courante.
local function LayoutDashes(f)
    local cfg  = f._dashCfg
    local pool = f._dashes
    local w, h = f:GetSize()
    if not cfg or w <= 0 or h <= 0 then return end

    local n = 0
    local function seg(x, y, sw, sh)
        n = n + 1
        local t = pool[n]
        if not t then t = f:CreateTexture(nil, "OVERLAY"); pool[n] = t end
        t:SetColorTexture(cfg.color[1], cfg.color[2], cfg.color[3], cfg.color[4] or 1)
        t:ClearAllPoints()
        t:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", x, y)
        t:SetSize(sw, sh)
        t:Show()
    end

    local step = cfg.dash + cfg.gap
    local th = cfg.thickness
    -- Bords horizontaux (haut + bas).
    local x = 0
    while x < w do
        local len = math.min(cfg.dash, w - x)
        seg(x, h - th, len, th)     -- haut
        seg(x, 0, len, th)          -- bas
        x = x + step
    end
    -- Bords verticaux (gauche + droite).
    local y = 0
    while y < h do
        local len = math.min(cfg.dash, h - y)
        seg(0, y, th, len)          -- gauche
        seg(w - th, y, th, len)     -- droite
        y = y + step
    end
    -- Cache les segments en trop (pool reutilise apres un retrecissement).
    for i = n + 1, #pool do pool[i]:Hide() end
end

local PlusButtonMixin = {}

function PlusButtonMixin:SetText(t)
    self.label:SetText(t or "+")
end

function PlusButtonMixin:SetOnClick(fn)
    self._onClick = fn
end

function C.PlusButton(parent, opts)
    opts = opts or {}
    local b = CreateFrame("Button", nil, parent)
    local sz = opts.size or 32
    b:SetSize(opts.width or sz, opts.height or sz)

    -- Fond fonce.
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(unpack(DARKER))

    -- "+" centre.
    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    b.label:SetPoint("CENTER")
    b.label:SetTextColor(1, 1, 1)
    b.label:SetText(opts.text or "+")

    -- Surbrillance au survol.
    b:SetHighlightTexture(WHITE8X8, "ADD")
    local hl = b:GetHighlightTexture()
    if hl then hl:SetVertexColor(1, 1, 1, 0.10) end

    -- Bordure pointillee.
    b._dashes = {}
    b._dashCfg = {
        color     = opts.color or LIGHT_GRAY,
        dash      = opts.dash or 4,
        gap       = opts.gap or 3,
        thickness = opts.thickness or 1,
    }
    b:HookScript("OnSizeChanged", LayoutDashes)
    LayoutDashes(b)

    Mixin(b, PlusButtonMixin)
    b._onClick = opts.onClick
    WireOnClick(b)
    return b
end

--------------------------------------------------------------------------------
-- 4. Window — frame principale custom (tranche avec l'UI Blizzard) :
--    fond GRID, bordures NOIRES, bandeau de titre AGRANDI.
--    opts = { title=, width=, height=, titleHeight=, borderSize=, borderColor=,
--             grid=<bool, def true>, gridSize=, gridColor={r,g,b,a},
--             bg={r,g,b,a}, headerBg={r,g,b,a}, onClose= }
--    bg / borderColor / borderSize : defauts tires du theme (MODAL_BACKGROUND_COLOR /
--      MODAL_BORDER_COLOR / MODAL_BORDER_THICKNESS) ; opts.* priment et figent la valeur.
--    L'instance expose `.content` (frame interne sous le bandeau) ou les
--    consommateurs ancrent leur contenu, et `:SetTitle(text)`.
--------------------------------------------------------------------------------

-- (Re)dessine la grille de fond selon la taille courante (pool de lignes fines).
local function LayoutGrid(f)
    local cfg  = f._gridCfg
    local pool = f._gridLines
    local w, h = f:GetSize()
    if not cfg or w <= 0 or h <= 0 then return end

    local n = 0
    local function line(x, y, sw, sh)
        n = n + 1
        local t = pool[n]
        if not t then t = f:CreateTexture(nil, "BACKGROUND", nil, 1); pool[n] = t end
        t:SetColorTexture(cfg.color[1], cfg.color[2], cfg.color[3], cfg.color[4] or 0.06)
        t:ClearAllPoints()
        t:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", x, y)
        t:SetSize(sw, sh)
        t:Show()
    end

    local g, th = cfg.size, cfg.thickness
    local x = g
    while x < w do line(x, 0, th, h); x = x + g end     -- lignes verticales
    local y = g
    while y < h do line(0, y, w, th); y = y + g end     -- lignes horizontales
    for i = n + 1, #pool do pool[i]:Hide() end
end

local WindowMixin = {}

function WindowMixin:SetTitle(text)
    self.title:SetText(text or "")
end

-- Re-applique le fond + la couleur de bordure du theme (sauf overrides opts). L'EPAISSEUR
-- n'est pas re-jouee a chaud (elle conditionne l'inset du header/contenu, fige a la
-- construction) -> un changement de MODAL_BORDER_THICKNESS prend effet au prochain open/reload.
function WindowMixin:ApplyTheme()
    if not HR.Theme then return end
    if not self._ovBg and self.bg then
        self._bgColor = HR.Theme.Color("MODAL_BACKGROUND_COLOR")
        self.bg:SetColorTexture(unpack(self._bgColor))
    end
    if not self._ovBorder and self._border then
        self._borderColor = HR.Theme.Color("MODAL_BORDER_COLOR")
        for _, t in pairs(self._border) do t:SetColorTexture(unpack(self._borderColor)) end
    end
end

-- Registre (cles faibles) des fenetres a re-skinner au changement de theme + hook unique.
local themedWindows = setmetatable({}, { __mode = "k" })
local windowThemeHooked = false
local function RegisterThemedWindow(f)
    themedWindows[f] = true
    if windowThemeHooked or not HR.Theme then return end
    windowThemeHooked = true
    HR.Theme.OnChange(function()
        for win in pairs(themedWindows) do win:ApplyTheme() end
    end)
end

-- Registre (cles faibles) des fenetres/modales de l'addon a RESCALER ensemble (option
-- "Scale", onglet General). N'inclut PAS les elements runtime (timeline/upcoming/comm/
-- announce), qui ont chacun leur propre echelle. C.Window s'y enregistre auto ; les modales
-- en CreateFrame brut (VariantBar/ShareFrame) appellent HR.RegisterScaledFrame elles-memes.
HR._scaledFrames = HR._scaledFrames or setmetatable({}, { __mode = "k" })
local function CurrentUIScale()
    return (HR.db and HR.db.options and HR.db.options.uiScale) or 1
end
function HR.RegisterScaledFrame(f)
    if not f then return end
    HR._scaledFrames[f] = true
    f:SetScale(CurrentUIScale())     -- applique l'echelle courante des la creation
end
function HR.ApplyUIScale()
    local s = CurrentUIScale()
    for f in pairs(HR._scaledFrames) do if f.SetScale then f:SetScale(s) end end
end

function C.Window(parent, opts)
    opts = opts or {}
    -- Defauts fond/bordure tires du THEME (tokens MODAL_*) ; opts.* gardent la priorite.
    local th  = opts.borderSize or (HR.Theme and HR.Theme.Value("MODAL_BORDER_THICKNESS", 2)) or 2
    local thh = opts.titleHeight or 46            -- bandeau de titre AGRANDI

    local f = CreateFrame("Frame", opts.name, parent or UIParent)
    f:SetSize(opts.width or 880, opts.height or 584)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)

    -- Fond de base (sombre), sous la grille. Couleur = opts.bg (override) sinon token thème.
    f._ovBg = opts.bg
    f._bgColor = opts.bg or (HR.Theme and HR.Theme.Color("MODAL_BACKGROUND_COLOR")) or { 0.06, 0.06, 0.07, 0.96 }
    f.bg = f:CreateTexture(nil, "BACKGROUND", nil, 0)
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(unpack(f._bgColor))

    -- Grille (lignes fines, re-layoutees au redimensionnement).
    if opts.grid ~= false then
        f._gridLines = {}
        f._gridCfg = {
            color     = opts.gridColor or { 1, 1, 1, 0.05 },
            size      = opts.gridSize or 32,
            thickness = 1,
        }
        f:HookScript("OnSizeChanged", LayoutGrid)
        LayoutGrid(f)
    end

    -- Fond personnalise (texture maison), PAR-DESSUS la grille. Si le fichier est absent
    -- la texture est transparente => la grille / le fond sombre restent visibles (zero
    -- casse). Formats : BLP ou TGA non compresse (24/32 bits), dimensions puissance de 2.
    if opts.bgTexture then
        f.bgTex = f:CreateTexture(nil, "BACKGROUND", nil, 2)
        f.bgTex:SetAllPoints()
        f.bgTex:SetTexture(opts.bgTexture)
    end

    -- Bordure pleine (reutilise le helper du TextButton square). Couleur = opts.borderColor
    -- (override) sinon token thème MODAL_BORDER_COLOR (noir par defaut).
    f._ovBorder = opts.borderColor and resolveColor(opts.borderColor) or nil
    f._borderColor = f._ovBorder or (HR.Theme and HR.Theme.Color("MODAL_BORDER_COLOR")) or { 0, 0, 0, 1 }
    f._border = AddSquareBorder(f, th, f._borderColor)

    -- Bandeau de titre (insere DANS la bordure pour ne pas la masquer).
    f.header = f:CreateTexture(nil, "ARTWORK", nil, 0)
    f.header:SetPoint("TOPLEFT", th, -th)
    f.header:SetPoint("TOPRIGHT", -th, -th)
    f.header:SetHeight(thh)
    f.header:SetColorTexture(unpack(opts.headerBg or (HR.Theme and HR.Theme.Color("ZONE_BACKGROUND")) or { 0, 0, 0, 0.55 }))

    -- Liseré bas du bandeau (separe le header du contenu).
    f.headerLine = f:CreateTexture(nil, "ARTWORK", nil, 1)
    f.headerLine:SetPoint("TOPLEFT", f.header, "BOTTOMLEFT", 0, 0)
    f.headerLine:SetPoint("TOPRIGHT", f.header, "BOTTOMRIGHT", 0, 0)
    f.headerLine:SetHeight(1)
    f.headerLine:SetColorTexture(0, 0, 0, 1)

    -- Titre (gros), centre dans le bandeau, en blanc.
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    f.title:SetPoint("CENTER", f.header, "CENTER", 0, 0)
    f.title:SetTextColor(1, 1, 1)
    f.title:SetText(opts.title or "")

    -- Bouton de fermeture custom ("×") dans le bandeau, en haut a droite.
    f.close = CreateFrame("Button", nil, f)
    f.close:SetSize(thh - 12, thh - 12)
    f.close:SetPoint("RIGHT", f.header, "RIGHT", -8, 0)
    f.close.x = f.close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.close.x:SetPoint("CENTER")
    f.close.x:SetText("\195\151")        -- "×"
    f.close.x:SetTextColor(0.8, 0.8, 0.8)
    f.close:SetScript("OnEnter", function(self) self.x:SetTextColor(1, 0.3, 0.3) end)
    f.close:SetScript("OnLeave", function(self) self.x:SetTextColor(0.8, 0.8, 0.8) end)
    f.close:SetScript("OnClick", function()
        if opts.onClose then opts.onClose(f) else f:Hide() end
    end)

    -- Zone de contenu : sous le bandeau, dans la bordure. Les consommateurs y
    -- ancrent leurs widgets (au lieu de la frame directement).
    f.content = CreateFrame("Frame", nil, f)
    f.content:SetPoint("TOPLEFT", th, -(th + thh + 1))
    f.content:SetPoint("BOTTOMRIGHT", -th, th)

    -- Deplacable par le bandeau de titre.
    f:SetMovable(true)
    f:EnableMouse(true)
    f.header.region = f
    local dragger = CreateFrame("Frame", nil, f)
    dragger:SetPoint("TOPLEFT", f.header)
    dragger:SetPoint("BOTTOMRIGHT", f.header)
    dragger:EnableMouse(true)
    dragger:RegisterForDrag("LeftButton")
    dragger:SetScript("OnDragStart", function() f:StartMoving() end)
    dragger:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        if opts.onMoved then opts.onMoved(f) end
    end)

    Mixin(f, WindowMixin)
    RegisterThemedWindow(f)             -- fond + bordure suivent les changements de theme
    HR.RegisterScaledFrame(f)          -- suit l'option "Scale" (fenetre principale + modales)
    return f
end

--------------------------------------------------------------------------------
-- 5. Container — cadre REUTILISABLE : fond + bordure pleine 4 cotes + padding.
--    opts = { name=, padX=, padY=, thickness=, bg={r,g,b,a}, borderColor=,
--             content=<bool, def true> }
--    Defauts fond/bordure/epaisseur tires du THEME (tokens CONTAINER_*) ; opts.* priment.
--    L'instance EST une frame (SetPoint/SetSize pour la dimensionner). Si content!=false,
--    expose `.content` = zone interne insettee de (thickness + padX/padY) ou ancrer son
--    contenu. Methodes : :GetPad() -> padX,padY  /  :SetPadding(x,y).
--------------------------------------------------------------------------------

local ContainerMixin = {}

function ContainerMixin:GetPad() return self._padX, self._padY end

function ContainerMixin:_InsetContent()
    if not self.content then return end
    local i = self._thickness
    self.content:ClearAllPoints()
    self.content:SetPoint("TOPLEFT", i + self._padX, -(i + self._padY))
    self.content:SetPoint("BOTTOMRIGHT", -(i + self._padX), i + self._padY)
end

function ContainerMixin:SetPadding(x, y)
    if type(x) == "table" then x, y = x.x, x.y end
    if x then self._padX = x end
    if y then self._padY = y end
    self:_InsetContent()
end

function C.Container(parent, opts)
    opts = opts or {}
    local f = CreateFrame("Frame", opts.name, parent)
    f._padX = opts.padX or 10
    f._padY = opts.padY or 7
    f._thickness = opts.thickness or (HR.Theme and HR.Theme.Value("CONTAINER_BORDER_THICKNESS", 1)) or 1

    -- Fond.
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(unpack(opts.bg or (HR.Theme and HR.Theme.Color("CONTAINER_BACKGROUND_COLOR")) or { 0.08, 0.08, 0.09, 0.98 }))

    -- Bordure pleine 4 cotes (couleur unie, pas de liseré de texture).
    local bc = (opts.borderColor and resolveColor(opts.borderColor))
            or (HR.Theme and HR.Theme.Color("CONTAINER_BORDER_COLOR")) or { 0.4, 0.4, 0.4, 1 }
    local th = f._thickness
    local function edge()
        local t = f:CreateTexture(nil, "BORDER"); t:SetColorTexture(unpack(bc)); return t
    end
    local et, eb, el, er = edge(), edge(), edge(), edge()
    et:SetPoint("TOPLEFT");    et:SetPoint("TOPRIGHT");    et:SetHeight(th)
    eb:SetPoint("BOTTOMLEFT"); eb:SetPoint("BOTTOMRIGHT"); eb:SetHeight(th)
    el:SetPoint("TOPLEFT");    el:SetPoint("BOTTOMLEFT");  el:SetWidth(th)
    er:SetPoint("TOPRIGHT");   er:SetPoint("BOTTOMRIGHT"); er:SetWidth(th)
    f._edges = { top = et, bottom = eb, left = el, right = er }

    -- Zone de contenu insettee (bordure + padding) pour les consommateurs qui veulent
    -- y ancrer directement leurs widgets.
    if opts.content ~= false then
        f.content = CreateFrame("Frame", nil, f)
    end
    Mixin(f, ContainerMixin)
    f:_InsetContent()
    return f
end

--------------------------------------------------------------------------------
-- 6. ScrollPopup — popup flottant REUTILISABLE (selecteurs custom : select de
--    variante, picker de CD...). Fond + bordure (memes tokens que les boutons
--    arrondis), zone scrollable, et un "catcher" plein ecran qui ferme au clic
--    en dehors. Le consommateur positionne le popup (SetPoint) + peut changer sa
--    largeur (:SetWidth) avant :Open().
--    opts = { name=, width= }
--    Expose : .content (ou poser/ancrer les lignes), .scroll, .catcher.
--    Methodes : :Open() (montre catcher + popup), :Close() (cache tout).
--------------------------------------------------------------------------------

local ScrollPopupMixin = {}

function ScrollPopupMixin:Open()
    self.catcher:Show()
    self:Show()
    self:Raise()
end

function ScrollPopupMixin:Close()
    self:Hide()                 -- OnHide masque le catcher
end

function C.ScrollPopup(opts)
    opts = opts or {}
    local W = opts.width or 300

    -- Catcher plein ecran (sous le popup) : clic en dehors => fermeture.
    local catcher = CreateFrame("Frame", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("FULLSCREEN")
    catcher:EnableMouse(true)
    catcher:Hide()

    local f = CreateFrame("Frame", opts.name, UIParent, "BackdropTemplate")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetWidth(W)
    f:SetBackdrop({
        bgFile   = WHITE8X8,
        edgeFile = TOOLTIP_BORDER,
        edgeSize = (HR.Theme and HR.Theme.Value("BUTTON_BORDER_ROUND_THICKNESS", 12)) or 12,
        insets   = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(unpack((HR.Theme and HR.Theme.Color("CONTAINER_BACKGROUND_COLOR")) or { 0.08, 0.08, 0.09, 0.98 }))
    if HR.Theme then f:SetBackdropBorderColor(HR.Theme.Unpack("POPUP_BORDER_COLOR"))
    else f:SetBackdropBorderColor(0, 0, 0, 1) end
    f:Hide()

    f.catcher = catcher
    catcher:SetScript("OnMouseDown", function() f:Hide() end)
    f:SetScript("OnHide", function() catcher:Hide() end)

    local sf = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 6, -6)
    sf:SetPoint("BOTTOMRIGHT", -26, 6)
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(W - 34, 1)
    sf:SetScrollChild(content)
    f.scroll = sf
    f.content = content

    Mixin(f, ScrollPopupMixin)
    return f
end

--------------------------------------------------------------------------------
-- 6b. InfoBox — cadre EXPLICATIF reutilisable d'une section (bordure VIOLETTE, fond GRIS,
--     texte BLANC ; couleurs THEMEES via les tokens INFOBOX_*). Le texte wrap dans le cadre.
--     C.InfoBox(parent, { text=<string>, height=<px, def 40>, padding=<px, def 10> })
--       -> frame ; frame:SetText(str) met a jour le texte. Le CALLER ancre le cadre (TOPLEFT +
--          TOPRIGHT, ou une largeur) ; la hauteur = opts.height (fixe, ajustable au texte reel).
--------------------------------------------------------------------------------
function C.InfoBox(parent, opts)
    opts = opts or {}
    local pad = opts.padding or 10
    local th  = (HR.Theme and HR.Theme.Value("INFOBOX_BORDER_THICKNESS", 1)) or 1
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    f:SetBackdrop({ bgFile = WHITE8X8, edgeFile = TOOLTIP_BORDER, edgeSize = 12,
                    insets = { left = th, right = th, top = th, bottom = th } })
    if HR.Theme then
        f:SetBackdropColor(HR.Theme.Unpack("INFOBOX_BACKGROUND_COLOR"))
        f:SetBackdropBorderColor(HR.Theme.Unpack("INFOBOX_BORDER_COLOR"))
    else
        f:SetBackdropColor(0, 0, 0, 0.7); f:SetBackdropBorderColor(0.42, 0.28, 0.66, 1)
    end
    -- Texte ancre en HAUT-GAUCHE seulement (PAS BOTTOMRIGHT) : sa largeur est fixee par
    -- Relayout(w) -> le wrap + GetStringHeight sont fiables, et la HAUTEUR du cadre suit le texte.
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.text:SetPoint("TOPLEFT", pad, -pad)
    f.text:SetJustifyH("LEFT"); f.text:SetJustifyV("TOP"); f.text:SetWordWrap(true)
    if HR.Theme then f.text:SetTextColor(HR.Theme.Unpack("INFOBOX_TEXT_COLOR")) else f.text:SetTextColor(1, 1, 1) end
    f._pad  = pad
    f._minH = opts.minHeight or (pad * 2 + 4)
    f:SetHeight(f._minH)
    -- Recale la HAUTEUR sur le texte a partir de la LARGEUR du cadre `w` (le texte prend
    -- w - 2*pad). `FontString:SetWidth` rend `GetStringHeight` fiable immediatement (pas de defer).
    function f:Relayout(w)
        w = w or self:GetWidth()
        if not w or w < 40 then return end
        self.text:SetWidth(w - self._pad * 2)
        self:SetHeight(math.max((self.text:GetStringHeight() or 0) + self._pad * 2, self._minH))
    end
    function f:SetText(str) self.text:SetText(str or ""); self:Relayout() end
    f:SetText(opts.text or "")
    return f
end

--------------------------------------------------------------------------------
-- 7. TextTip — tooltip TEXTE custom REUTILISABLE (titre + corps wrap), au look de
--    l'addon (fond sombre + bordure thémée). Sert a EXPLIQUER l'UI un peu partout.
--    Singleton partage. Se dimensionne a son contenu, ancrage intelligent (gauche/droite).
--    * C.ShowTextTip(owner, title, body, opts) / C.HideTextTip()
--    * C.AttachHelpTip(frame, title, body, opts) : pose le hover (EnableMouse + HookScript).
--      title/body = STRING ou FONCTION(self) (contenu dynamique ; title -> nil = pas de tip).
--    opts = { width=<px, def 280>, titleColor={r,g,b} }.
--------------------------------------------------------------------------------

local textTip
local TEXTTIP_W, TEXTTIP_PAD = 280, 12

local function buildTextTip()
    if textTip then return textTip end
    local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    f:SetFrameStrata("TOOLTIP")
    f:SetBackdrop({ bgFile = WHITE8X8, edgeFile = TOOLTIP_BORDER, edgeSize = 12,
                    insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    f:SetBackdropColor(0.06, 0.06, 0.07, 0.98)
    if HR.Theme then f:SetBackdropBorderColor(HR.Theme.Unpack("POPUP_BORDER_COLOR"))
    else f:SetBackdropBorderColor(0.42, 0.28, 0.66, 1) end
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", TEXTTIP_PAD, -TEXTTIP_PAD); f.title:SetJustifyH("LEFT")
    f.body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.body:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -6); f.body:SetJustifyH("LEFT")
    f.body:SetTextColor(0.85, 0.85, 0.85)
    f:Hide()
    textTip = f
    return f
end

function C.ShowTextTip(owner, title, body, opts)
    opts = opts or {}
    local f = buildTextTip()
    local w = opts.width or TEXTTIP_W
    f.title:SetWidth(w); f.body:SetWidth(w)
    local tc = opts.titleColor or { 1, 1, 1 }
    f.title:SetText(title or ""); f.title:SetTextColor(tc[1], tc[2], tc[3])
    f.body:SetText(body or "")
    local bh = (body and body ~= "") and (f.body:GetStringHeight() + 6) or 0
    f:SetSize(w + TEXTTIP_PAD * 2, TEXTTIP_PAD + f.title:GetStringHeight() + bh + TEXTTIP_PAD)
    f:ClearAllPoints()
    local cx = owner.GetCenter and select(1, owner:GetCenter())
    if cx and cx > UIParent:GetWidth() / 2 then
        f:SetPoint("TOPRIGHT", owner, "TOPLEFT", -8, 0)     -- owner a droite -> tip a gauche
    else
        f:SetPoint("TOPLEFT", owner, "TOPRIGHT", 8, 0)      -- owner a gauche -> tip a droite
    end
    f:Show()
end

function C.HideTextTip()
    if textTip then textTip:Hide() end
end

function C.AttachHelpTip(frame, title, body, opts)
    frame:EnableMouse(true)
    frame:HookScript("OnEnter", function(self)
        local t = title
        if type(t) == "function" then t = t(self) end
        if not t then return end                       -- nil title => pas de tip
        local b = body
        if type(b) == "function" then b = b(self) end
        C.ShowTextTip(self, t, b, opts)
    end)
    frame:HookScript("OnLeave", function() C.HideTextTip() end)
end

--------------------------------------------------------------------------------
-- 8. Chip — PASTILLE d'information compacte (texte court sur fond sombre, coins ARRONDIS).
--    Sert a lister des petites entites cote a cote (ex. les porteurs de cle d'un donjon
--    sur la homepage). AUCUNE interaction : pour du clic, nester dans un Button.
--    opts = { text, padX=<def 12>, padY=<def 6>, minHeight=<def 0>, minWidth=<def 16>,
--             maxWidth=<n|nil>, textSize=<n>, bg=<{r,g,b,a}|nom|nil def noir 0.55>,
--             borderColor=<idem ; DEFAUT = la couleur de fond, donc AUCUN contour visible>,
--             edgeSize=<def 8> }
--    TAILLE AUTO dans les DEUX sens : texte + 2*padX / + 2*padY (recalculee a chaque
--    SetText) -> le consommateur lit :GetWidth()/:GetHeight() APRES SetText pour composer
--    sa mise en page (flow, wrap...). L'arrondi reprend la bordure des boutons "ronds"
--    (UI-Tooltip-Border), avec un edgeSize reduit adapte a la petite taille.
--    Methodes : SetText, SetMaxWidth, SetChipColor, SetBorderColor.
--------------------------------------------------------------------------------

local ChipMixin = {}

-- Largeur = texte + padX des DEUX cotes, bornee par _maxW si le call-site en impose une (le
-- texte est alors TRONQUE par le FontString au lieu de deborder). Hauteur = texte + padY des
-- deux cotes (plancher _minH) -> padding sur les 4 cotes.
function ChipMixin:Relayout()
    local w = math.max(self._minW, (self.label:GetStringWidth() or 0) + self._padX * 2)
    if self._maxW and w > self._maxW then
        w = self._maxW
        self.label:SetWidth(math.max(1, w - self._padX * 2))
    else
        self.label:SetWidth(0)          -- 0 = largeur libre (auto)
    end
    local h = math.max(self._minH, (self.label:GetStringHeight() or 0) + self._padY * 2)
    self:SetSize(w, h)
end

-- Plafond de largeur (nil = aucun). Utile quand la place disponible est connue du parent.
function ChipMixin:SetMaxWidth(w)
    self._maxW = w
    self:Relayout()
end

function ChipMixin:SetText(t)
    self.label:SetText(t or "")
    self:Relayout()
end

function ChipMixin:SetChipColor(r, g, b, a)
    self:SetBackdropColor(r, g, b, a or 1)
end

function ChipMixin:SetBorderColor(r, g, b, a)
    self:SetBackdropBorderColor(r, g, b, a or 1)
end

function C.Chip(parent, opts)
    opts = opts or {}
    -- Coins ARRONDIS : meme bordure de texture que la variante ronde de C.TextButton, avec un
    -- edgeSize plus petit (une chip fait ~20 px de haut ; 12 mangerait toute la pastille).
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    f._padX = opts.padX or 12
    f._padY = opts.padY or 6
    f._minW = opts.minWidth or 16
    f._minH = opts.minHeight or 0

    local es = opts.edgeSize or 8
    f:SetBackdrop({
        bgFile   = WHITE8X8,
        edgeFile = TOOLTIP_BORDER,
        edgeSize = es,
        insets   = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    local bg = resolveColor(opts.bg, { 0, 0, 0, 0.55 })
    f:SetBackdropColor(unpack(bg))
    -- L'ARRONDI vient de la texture de bordure ; un liseré CONTRASTE dessus rend le resultat
    -- sale a cette taille. Par defaut on teinte donc la bordure comme le FOND : la silhouette
    -- reste arrondie, aucun contour n'apparait. Passer borderColor pour en remettre un.
    f:SetBackdropBorderColor(unpack(resolveColor(opts.borderColor, bg)))

    f.label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.label:SetPoint("CENTER")
    f.label:SetWordWrap(false)          -- une chip tient sur UNE ligne (sinon elle deborde)
    if opts.textSize then
        local fpath, _, flags = f.label:GetFont()
        f.label:SetFont(fpath, opts.textSize, flags)
    end

    Mixin(f, ChipMixin)
    f._maxW = opts.maxWidth
    f:SetText(opts.text)
    return f
end

--------------------------------------------------------------------------------
-- Demo : fenetre montrant les 3 boutons (verification visuelle in-game).
--   Appel : /ecp uidemo   (ou re-appel pour fermer)
--------------------------------------------------------------------------------

function C.ShowDemo()
    if C.demo then
        C.demo:SetShown(not C.demo:IsShown())
        return
    end

    local f = CreateFrame("Frame", "ECPComponentsDemo", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(360, 260)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    tinsert(UISpecialFrames, "ECPComponentsDemo")
    if f.TitleText then f.TitleText:SetText("Components demo") end

    local function caption(text, x, y)
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", x, y)
        fs:SetText(text)
        return fs
    end

    -- 1. ImageButton (image + texte overlay).
    caption("1. ImageButton", 20, -36)
    local img = C.ImageButton(f, {
        image = "Interface\\Icons\\spell_holy_renew",
        text  = "5",
        size  = 44,
        onClick = function() HR:Print("ImageButton clicked") end,
    })
    img:SetPoint("TOPLEFT", 20, -54)

    -- 2a. TextButton arrondi (selectionnable, bordure jaune si actif).
    caption("2a. TextButton (rounded)", 130, -36)
    local txt = C.TextButton(f, {
        text = "Variant A",
        width = 110,
        onClick = function(self) self:SetSelected(not self:IsSelected()) end,
    })
    txt:SetPoint("TOPLEFT", 130, -54)
    txt:SetSelected(true)

    -- 2b. TextButton "square" (coins droits, plus d'espace).
    caption("2b. TextButton (square)", 130, -96)
    local txt2 = C.TextButton(f, {
        text = "Variant B",
        square = true,
        onClick = function(self) self:SetSelected(not self:IsSelected()) end,
    })
    txt2:SetPoint("TOPLEFT", 130, -114)

    -- 3. PlusButton (bordure pointillee).
    caption("3. PlusButton", 20, -120)
    local plus = C.PlusButton(f, {
        size = 40,
        onClick = function() HR:Print("PlusButton clicked") end,
    })
    plus:SetPoint("TOPLEFT", 20, -138)

    C.demo = f
end

-- Demo de la frame principale custom (grid + bordure noire + gros titre).
--   Appel : /ecp uidemo win
function C.ShowWindowDemo()
    if C.winDemo then
        C.winDemo:SetShown(not C.winDemo:IsShown())
        return
    end
    local w = C.Window(UIParent, {
        name   = "ECPWindowDemo",
        title  = "EiikoCooldownPlanner",
        width  = 1144,    -- 880 +30%
        height = 759,     -- 584 +30%
    })
    tinsert(UISpecialFrames, "ECPWindowDemo")

    -- Un peu de contenu d'exemple dans la zone `.content`.
    local hint = w.content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    hint:SetPoint("TOPLEFT", 16, -16)
    hint:SetText("Zone de contenu (window.content) - le plan / les onglets viendront ici.")

    local b = C.TextButton(w.content, { text = "Sample", square = true })
    b:SetPoint("TOPLEFT", 16, -48)

    C.winDemo = w
end
