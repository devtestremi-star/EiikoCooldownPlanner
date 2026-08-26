-- HealPlanner - Core/Glow.lua
-- Surbrillance "proc" NATIVE : reproduit le glow des sorts proc du jeu en animant
-- l'atlas flipbook natif (UI-HUD-ActionBar-Proc-Loop-Flipbook) via une AnimationGroup
-- FlipBook. Aucune lib, aucune fonction taintee (on N'appelle PAS
-- ActionButton_ShowOverlayGlow). Interface conservee : HR.SetupGlow / HR.ApplyGlow.
local addonName, HR = ...

local LOOP_ATLAS = "UI-HUD-ActionBar-Proc-Loop-Flipbook"
-- Grille du flipbook natif (lignes x colonnes = nb d'images). A ajuster si l'anim
-- parait decoupee en jeu (valeurs natives connues : 6 x 5 = 30 images).
local FB_ROWS, FB_COLS, FB_FRAMES = 6, 5, 30
local FB_DURATION = 1.0
-- L'overlay deborde de l'icone (le glow encadre l'icone, comme sur les boutons natifs).
local OVERSIZE = 0.40

-- Fallback (texture proc classique) si l'atlas flipbook est indisponible : simple
-- pulsation de la texture IconAlert.
local ALERT_TEX = "Interface\\SpellActivationOverlay\\IconAlert"

local function BuildFlipbook(g)
    g.glowTex = g:CreateTexture(nil, "OVERLAY")
    g.glowTex:SetAllPoints()
    local ok = g.glowTex:SetAtlas(LOOP_ATLAS, false)
    if ok == false then return false end   -- atlas absent -> fallback

    g.ag = g:CreateAnimationGroup()
    g.ag:SetLooping("REPEAT")
    local flip = g.ag:CreateAnimation("FlipBook")
    flip:SetChildKey("glowTex")            -- cible g.glowTex
    flip:SetDuration(FB_DURATION)
    flip:SetFlipBookRows(FB_ROWS)
    flip:SetFlipBookColumns(FB_COLS)
    flip:SetFlipBookFrames(FB_FRAMES)
    flip:SetFlipBookFrameWidth(0)          -- 0 => derive de la taille / grille
    flip:SetFlipBookFrameHeight(0)
    return true
end

local function BuildFallback(g)
    g.glowTex = g:CreateTexture(nil, "OVERLAY")
    g.glowTex:SetAllPoints()
    g.glowTex:SetTexture(ALERT_TEX)
    g.glowTex:SetBlendMode("ADD")
    g.ag = g:CreateAnimationGroup()
    g.ag:SetLooping("REPEAT")
    local a1 = g.ag:CreateAnimation("Alpha")
    a1:SetFromAlpha(0.35); a1:SetToAlpha(1); a1:SetDuration(0.5); a1:SetOrder(1)
    local a2 = g.ag:CreateAnimation("Alpha")
    a2:SetFromAlpha(1); a2:SetToAlpha(0.35); a2:SetDuration(0.5); a2:SetOrder(2)
end

-- Prepare un cadre pour recevoir le glow proc (idempotent).
function HR.SetupGlow(f)
    if f.procGlow then return end
    local g = CreateFrame("Frame", nil, f)
    local ox = (f:GetWidth() or 0) * OVERSIZE / 2
    local oy = (f:GetHeight() or 0) * OVERSIZE / 2
    g:SetPoint("TOPLEFT", f, "TOPLEFT", -ox, oy)
    g:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", ox, -oy)
    g:SetFrameLevel((f:GetFrameLevel() or 0) + 8)
    g:Hide()

    if not BuildFlipbook(g) then BuildFallback(g) end
    f.procGlow = g
end

-- Active (on=true) ou retire le glow proc sur un cadre.
function HR.ApplyGlow(f, on)
    if not f.procGlow then HR.SetupGlow(f) end
    local g = f.procGlow
    if not g then return end
    if on then
        g:Show()
        if g.ag and not g.ag:IsPlaying() then g.ag:Play() end
    else
        if g.ag then g.ag:Stop() end
        g:Hide()
    end
end

--------------------------------------------------------------------------------
-- Glow CONFIGURABLE (timeline / upcoming) : type au choix via LibCustomGlow
-- (pixel/autocast/button) + le proc NATIF ci-dessus. UI non-securisee => pas de taint.
--------------------------------------------------------------------------------

local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)
local GKEY = "ECP_glow"

-- Lance le glow decrit par `g` sur `f`. g = { type, color={r,g,b,a}, pixel={lines,
-- frequency, length(0=auto), thickness, xOff, yOff, border} }. Coupe tout glow precedent.
function HR.StartGlow(f, g)
    if not f then return end
    g = g or {}
    local t = g.type or "proc"
    if f._ecpGlow == t then return end   -- deja actif avec ce type -> ne pas relancer (anti-flicker
                                         -- en rendu live ; pour forcer un refresh : StopGlow d'abord)
    HR.StopGlow(f)
    local c = g.color or { 1, 1, 1, 1 }
    local p = g.pixel or {}
    if t == "pixel" and LCG then
        LCG.PixelGlow_Start(f, c, p.lines or 8, p.frequency or 0.2,
            (p.length and p.length > 0) and p.length or nil,
            p.thickness or 2, p.xOff or 0, p.yOff or 0, p.border and true or false, GKEY)
    elseif t == "autocast" and LCG then
        LCG.AutoCastGlow_Start(f, c, p.lines or 4, p.frequency or 0.2, 1, p.xOff or 0, p.yOff or 0, GKEY)
    elseif t == "button" and LCG then
        LCG.ButtonGlow_Start(f, c, 0.125)
    else                                 -- "proc" : flipbook natif (sans lib)
        HR.ApplyGlow(f, true)
    end
    f._ecpGlow = t
end

-- Coupe tout glow (quel que soit le type) sur `f`.
function HR.StopGlow(f)
    if not f then return end
    if LCG then
        LCG.PixelGlow_Stop(f, GKEY)
        LCG.AutoCastGlow_Stop(f, GKEY)
        LCG.ButtonGlow_Stop(f)
    end
    HR.ApplyGlow(f, false)
    f._ecpGlow = nil
end

--------------------------------------------------------------------------------
-- Settings de COMPOSITION partages (timeline / upcoming). Memes cles, deux sous-tables
-- INDEPENDANTES dans HR.db.options. DEFAULTS = source de verite (les "tokens" partages
-- par l'UI d'options, l'apercu, et le runtime).
--------------------------------------------------------------------------------

HR.CompDefaults = {
    bgColor          = { 0, 0, 0, 0.75 },                        -- noir, opacite 75%
    -- Bordure par defaut = #7600FF (violet). Partagee timeline/upcoming/comm.
    borderColor      = { 0x76 / 255, 0x00 / 255, 0xFF / 255, 1 },
    borderThickness  = 1,
    scale            = 1.0,
    textColor        = { 1, 1, 1, 1 },                           -- timeline (texte de decompte)
    textSize         = 14,                                       -- timeline (texte de decompte)
    bossTextColor    = { 1, 1, 1, 1 },                           -- upcoming : nom du sort de boss
    bossTextSize     = 12,                                       -- upcoming : nom du sort de boss
}

-- Glow GLOBAL : un seul reglage partage par TOUS les glows de l'addon (timeline, upcoming...).
-- Stocke dans HR.db.options.glow (pas par module).
HR.GlowDefaults = {
    glowType  = "proc",                                          -- pixel|autocast|button|proc
    glowColor = { 0.95, 0.95, 0.32, 1 },
    glowPixel = { lines = 8, frequency = 0.2, length = 0, thickness = 2, xOff = 0, yOff = 0, border = false },
}
function HR.GlowOpt()
    HR.db.options = HR.db.options or {}
    HR.db.options.glow = HR.db.options.glow or {}
    return HR.db.options.glow
end
function HR.GlowGet(key)
    local v = HR.GlowOpt()[key]
    if v ~= nil then return v end
    return HR.GlowDefaults[key]
end

-- Sous-table de settings d'un module ("timeline"|"upcoming") (creee a la demande).
function HR.CompOpt(moduleKey)
    HR.db.options = HR.db.options or {}
    HR.db.options[moduleKey] = HR.db.options[moduleKey] or {}
    return HR.db.options[moduleKey]
end

-- Valeur d'un setting (override module sinon defaut). Les tables (couleurs/pixel) renvoyees
-- en defaut sont a considerer LECTURE SEULE (l'UI ecrit une NOUVELLE table dans CompOpt).
function HR.CompGet(moduleKey, key)
    local v = HR.CompOpt(moduleKey)[key]
    if v ~= nil then return v end
    return HR.CompDefaults[key]
end

-- Table de glow prete pour HR.StartGlow, depuis les settings GLOBAUX de glow.
function HR.CompGlow()
    return { type = HR.GlowGet("glowType"),
             color = HR.GlowGet("glowColor"),
             pixel = HR.GlowGet("glowPixel") }
end
