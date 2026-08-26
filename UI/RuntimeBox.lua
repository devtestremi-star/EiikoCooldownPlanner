-- HealPlanner - UI/RuntimeBox.lua
-- Affichage en combat, en DEUX fenetres deplacables independamment :
--   * "Upcoming bar" (UI.runtimeBox) : ligne du nom de variante (haut) ; en dessous
--     une COLONNE entete (icone / nom plus petit / timer) avec a sa DROITE les
--     defensifs planifies ; en dessous le bandeau des CD perso previsionnels.
--   * "Communication bar" (UI.commBar) : la rangee de boutons-macros securises (/p).
--     Detachee pour etre placee separement ; layout horizontal ou vertical (option).
-- Positions et options persistees (HR.db.ui / HR.db.options).
--
-- Deux modes : LIVE (timeline serveur) / TEST (timeline theorique). cf. ancienne doc.
local addonName, HR = ...

HR.UI = HR.UI or {}
local UI = HR.UI

HR.Runtime = HR.Runtime or {}

local ET = C_EncounterTimeline

local THROTTLE  = 0.1
local LINGER    = 2
local ATK_ICON  = 36    -- icone de la capacite a venir (haut de la colonne)
local DEF_ICON  = 36    -- icone d'un defensif planifie
local DEF_GAP   = 4
local WARN_WINDOW = 5   -- (Upcoming bar) on n'affiche un hit que dans ses N dernieres s
local BOX_W       = 280  -- largeur de l'Upcoming bar
local VAR_H       = 18   -- ligne du nom de variante (haut)
local TOP_H       = 92   -- hauteur de la zone du haut (variante + ligne icones + timer)
local COMM_BTN    = 24   -- taille d'un bouton-macro
local COMM_GAP    = 6
local COMM_PAD    = 3    -- marge entre la bordure de la barre et les boutons

-- Acces aux options (valeurs par defaut garanties via DB_DEFAULTS).
local function Opt()
    if not HR.db then return {} end
    HR.db.options = HR.db.options or {}
    return HR.db.options
end

--------------------------------------------------------------------------------
-- Upcoming bar : entete + defensifs planifies + bandeau de rappel
--------------------------------------------------------------------------------

-- Instance CIBLE du rendu courant : fixee par OnUpdate a `self` (multi-instances : Upcoming
-- bar REELLE + duplicata d'apercu dans les settings). Les helpers de rendu lisent `activeBox`
-- (repli sur UI.runtimeBox hors passe de rendu, ex. appels externes a UpdateWaiting).
local activeBox

-- Icone d'un defensif planifie (tooltip au survol). Position posee par LayoutDefIcons.
local function AcquireDefIcon(i)
    local box = activeBox or UI.runtimeBox
    local b = box.defIcons[i]
    if not b then
        b = CreateFrame("Frame", nil, box.defBox)   -- enfant du container 1 (CD prochain sort)
        b:SetSize(DEF_ICON, DEF_ICON)
        b:EnableMouse(true)
        b.tex = b:CreateTexture(nil, "ARTWORK")
        b.tex:SetAllPoints()
        b.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        -- Compte a rebours PAR icone (sous l'icone) : avec les offsets, les defensifs d'un
        -- meme sort divergent dans le temps -> chacun son timer (cf. moteur HR.Schedule).
        b.timer = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.timer:SetPoint("TOP", b, "BOTTOM", 0, -1)
        HR.SetupGlow(b)
        b:SetScript("OnEnter", function(self)
            if not self.defName then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.defName)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        box.defIcons[i] = b
    end
    return b
end

-- Appel generique SMALL_DEF -> defensif perso PRINCIPAL du joueur (flag `main`, filtre spe ;
-- repli sur le 1er). nil sinon -> icone/nom de l'appel.
local function ResolvePersonalCall(defID)
    if defID ~= "SMALL_DEF" then return nil end
    return HR.GetMainPersonalDefensive()
end

-- Place les icones des defensifs planifies a DROITE de la colonne entete (grille).
local function LayoutDefIcons(defs)
    local box = activeBox or UI.runtimeBox
    for _, b in ipairs(box.defIcons) do b:Hide() end
    -- Plan de defensifs = info HEAL : masque (barre comprise) pour les non-heal.
    if box.isHealer == false then box.noDef:Hide(); box.vbar:Hide(); return end
    box.vbar:Show()
    defs = defs or {}
    if #defs == 0 then
        box.noDef:ClearAllPoints()
        box.noDef:SetPoint("LEFT", box.vbar, "RIGHT", 8, 0)
        box.noDef:Show()
        return
    end
    box.noDef:Hide()
    local _, playerClass = UnitClass("player")
    -- Sur la MEME ligne que l'attaque, a droite de la barre verticale.
    for i, def in ipairs(defs) do
        local b = AcquireDefIcon(i)
        local d = HR.defensives[def]
        local pers = ResolvePersonalCall(def)
        b.tex:SetTexture(HR.GetDefensiveIcon(pers and pers.spellID or def))
        b.defName = (pers and pers.name) or (d and d.name) or nil
        if pers ~= nil or (d ~= nil and d.class == playerClass) then HR.StartGlow(b, HR.CompGlow()) else HR.StopGlow(b) end
        b:ClearAllPoints()
        b:SetPoint("LEFT", box.vbar, "RIGHT", 8 + (i - 1) * (DEF_ICON + DEF_GAP), 0)
        b:Show()
    end
end

-- Masque les widgets de l'ancien layout (entete d'icone, barre verticale, variante,
-- bandeau de rappel). Le nouveau layout = nom du sort + separateur + colonne de defs.
local function HideLegacyWidgets(box)
    if box.variantLabel then box.variantLabel:Hide() end
    if box.icon then box.icon:Hide() end
    if box.vbar then box.vbar:Hide() end
    if box.noDef then box.noDef:Hide() end
    if box.remindLines then for _, b in ipairs(box.remindLines) do b:Hide() end end
end

local function UpdateWaiting()
    local box = activeBox or UI.runtimeBox
    if not box then return end
    HideLegacyWidgets(box)
    if box.sep then box.sep:Hide() end
    for _, t in ipairs(box.defIcons) do t:Hide() end
    for _, t in ipairs(box.persoIcons or {}) do t:Hide() end   -- container 2
    if box.persoLblP then box.persoLblP:Hide() end
    if box.persoLblE then box.persoLblE:Hide() end
    box.name:Hide()
    box.name:SetText("")
    box.timer:SetText("")
    -- Rien a afficher : box minimale (juste le fond, deplacable par la poignee).
    box:SetWidth(70)
    box:SetHeight(18)
end

--------------------------------------------------------------------------------
-- Container 2 : CD du JOUEUR COURANT dans le plan complet du boss (deux categories,
-- ordre d'apparition). "personal" = appels generiques (SMALL_DEF/BIG_DEF/EMPTY_BAG,
-- resolus vers le sort perso du joueur) ; "external" = CD de raid (external=true)
-- jouables par la classe/spe du joueur (AMZ, Rally, Zephyr...). VUE D'ENSEMBLE statique.
--------------------------------------------------------------------------------

local PERSO_ICON     = 20
local PERSO_GAP      = 2    -- ecart entre icones (rangee ou colonne)
local PERSO_BANNER_H = 9    -- hauteur du bandeau noir (timer DANS l'icone, lisibilite)

local function FmtClock(t)
    t = math.max(0, math.floor(t or 0))
    return string.format("%d:%02d", math.floor(t / 60), t % 60)
end

-- Scanne le plan complet du boss courant et renvoie UNE liste FUSIONNEE (personals +
-- externals) ordonnee par temps d'apparition. Chaque entree = { defID, time, name, icon, kind }.
-- Vue d'ensemble des CD du JOUEUR (container 2). LES TEMPS VIENNENT DU MOTEUR
-- (HR.Schedule.PlanAll) -> identiques a "what's next" pour un meme defensif (source unique,
-- aucun recalcul ici). On se contente de CLASSER (external / appel perso) et de filtrer
-- (jouable par le joueur). `time` = relatif au pull (ce qu'attend LayoutPersoRow).
local function PlayerPlanCDs(s)
    local pull = s.pullTime or 0
    local cds = {}
    for _, e in ipairs(HR.Schedule.PlanAll()) do
        local defID = e.token
        local d = HR.defensives[HR.DefKeyOf(defID)]
        local time = e.eff - pull                         -- temps moteur (offset compris), relatif au pull
        if d and d.external and HR.TokenIsMine(defID) then   -- rôle+@heal-conscient (copie heal vs dps)
            cds[#cds + 1] = { defID = defID, time = time, name = d.name,
                              icon = HR.GetDefensiveIcon(defID), kind = "external" }
        elseif Opt().upcomingHeals and d and d.role == "HEALER" and not d.external and HR.TokenIsMine(defID) then
            -- CD de HEAL du joueur (option "Show heal cooldowns"). d.role == "HEALER" => TokenIsMine
            -- (PlayerCanUseDefensive) n'est vrai que pour un HEAL de cette classe/spe : healer-only.
            cds[#cds + 1] = { defID = defID, time = time, name = d.name,
                              icon = HR.GetDefensiveIcon(defID), kind = "heal" }
        elseif d and not d.class and not d.external and HR.TokenIsMine(defID) then
            -- appel generique (SMALL_DEF/EMPTY_BAG) = CD perso. SMALL_DEF -> icone du perso "main"
            -- (HR.GetDirectiveIcon) ; EMPTY_BAG garde son icone. TokenIsMine exclut SMALL_DEF pour
            -- un TANK (pas de directive de CD perso au tank).
            cds[#cds + 1] = { defID = defID, time = time, name = d.name,
                              icon = HR.GetDirectiveIcon(defID), kind = "personal" }
        end
    end
    table.sort(cds, function(a, b) return a.time < b.time end)
    return cds
end

-- Icone d'un CD du container 2 (tooltip nom + temps d'apparition). Timer DANS l'icone sur
-- bandeau noir : composant d'affichage UI.Components.ImageText (setup partage avec les
-- variantes AMZ 3/4 min de la modale). tex/timer = alias vers image/label (LayoutPersoRow
-- fait b.tex:SetTexture / b.timer:SetText+SetTextColor).
local function AcquirePersoIcon(i)
    local box = activeBox or UI.runtimeBox
    local b = box.persoIcons[i]
    if not b then
        b = UI.Components.ImageText(box.persoBox, {
            size = PERSO_ICON, textSize = 7,
            banner = true, bannerColor = { 0, 0, 0, 0.8 }, bannerHeight = PERSO_BANNER_H,
        })
        b:EnableMouse(true)          -- affichage pur, mais souris activee pour le tooltip
        b.tex   = b.image            -- alias compat (SetTexture cote LayoutPersoRow)
        b.timer = b.label            -- alias compat (SetText / SetTextColor par tick)
        b:SetScript("OnEnter", function(self)
            if not self.tip then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.tip)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        box.persoIcons[i] = b
    end
    return b
end

-- Pose la liste FUSIONNEE (perso + external) en RANGEE (horizontal) OU en COLONNE
-- (vertical, option `upcomingVertical`). `elapsed` = temps ecoule depuis le pull (pour le
-- compte a rebours). Chaque entree = 1 icone (timer DANS l'icone, sur bandeau noir).
-- Renvoie (largeur contenu, hauteur contenu) dans les deux cas.
local function LayoutPersoRow(list, elapsed)
    local box = activeBox or UI.runtimeBox
    for _, b in ipairs(box.persoIcons) do b:Hide() end
    if box.persoLblP then box.persoLblP:Hide() end   -- libelles de categorie supprimes (bloc unique)
    if box.persoLblE then box.persoLblE:Hide() end
    if #list == 0 then return 0, 0 end
    local vertical = (Opt().upcomingVertical == true)
    local pos, n = 0, 0
    for _, e in ipairs(list) do
        -- CD PASSE (rem <= 0) => RETIRE : il disparait de Personal Timeline (plus de grise persistant).
        -- CEIL comme "what's next" / LayoutDefRow (coherence d'affichage a la seconde).
        local rem = (e.time or 0) - (elapsed or 0)
        if rem > 0 then
            n = n + 1
            local b = AcquirePersoIcon(n)
            b.tex:SetTexture(e.icon)
            b.tip = e.name and (e.name .. "   " .. FmtClock(e.time)) or nil
            b.timer:SetText(FmtClock(math.ceil(rem)))
            if rem <= 5 then b.timer:SetTextColor(1, 0.2, 0.2)
            else b.timer:SetTextColor(1, 1, 1) end
            b:ClearAllPoints()
            if vertical then
                b:SetPoint("TOP", box.persoBox, "TOP", 0, -pos)      -- COLONNE : icones centrees, empilees vers le bas
            else
                b:SetPoint("TOPLEFT", box.persoBox, "TOPLEFT", pos, 0)   -- RANGEE : icones de gauche a droite
            end
            pos = pos + PERSO_ICON + PERSO_GAP
            b:Show()
        end
    end
    if n == 0 then return 0, 0 end
    if vertical then
        return PERSO_ICON, pos - PERSO_GAP          -- largeur = 1 icone, hauteur = pile
    else
        return pos - PERSO_GAP, PERSO_ICON          -- largeur = rangee, hauteur = 1 icone
    end
end

-- "Personal Timeline" (anciennement "My Timeline" / container 2) : SEUL contenu de la boite. Le container
-- 1 "what's next" a ete SUPPRIME (visuel + logique). Affiche la liste fusionnee des CD du JOUEUR
-- (persos + externals), triee par ordre d'apparition, avec un decompte par icone. Hauteur = 1
-- slot FIXE -> la boite ne se redimensionne pas verticalement en combat.
local UP_PAD = 6   -- marge interieure de la boite

local function RenderUpcoming()
    local box = activeBox or UI.runtimeBox
    HideLegacyWidgets(box)
    if box.sep then box.sep:Hide() end
    if box.timer then box.timer:Hide() end
    if box.name then box.name:Hide() end
    if box.defBox then box.defBox:Hide() end
    for _, b in ipairs(box.defIcons) do b:Hide() end

    local s     = HR.Runtime.state
    local pc    = box.persoBox
    local colW  = 0                                       -- largeur de la colonne (contenu)
    local contentH = 0                                    -- hauteur empilee (contenu)
    local atWill = false
    if s then
        -- Recalcule a chaque rendu (PAS de cache) : en live, les temps des defensifs deja
        -- matches viennent de s.liveDefs et evoluent.
        local elapsed = GetTime() - (s.pullTime or GetTime())
        local list = PlayerPlanCDs(s)
        if s.mode == "test" then
            -- TEST uniquement : 4 sorts max (fenetre glissante des prochains A VENIR ; les
            -- passes sont exclus -> ils disparaissent, comme le fait aussi LayoutPersoRow).
            local up = {}
            for _, e in ipairs(list) do
                if (e.time - elapsed) > 0 then up[#up + 1] = e end
                if #up >= 4 then break end
            end
            list = up
        end
        colW, contentH = LayoutPersoRow(list, elapsed)   -- (largeur, hauteur) du contenu (rangee ou colonne)
        -- Plus AUCUN CD du joueur A VENIR (jamais planifie OU le dernier est passe) -> "at will".
        if contentH == 0 then atWill = true end
    else
        for _, b in ipairs(box.persoIcons) do b:Hide() end
    end
    pc:ClearAllPoints()
    pc:SetPoint("TOPLEFT", box, "TOPLEFT", UP_PAD, -UP_PAD)
    pc:SetSize(math.max(colW, 1), math.max(contentH, 1))
    if atWill and not HR.Runtime.AnchorsVisible() then
        -- Rien de planifie pour le joueur => on MASQUE l'element (alpha 0). Exception : en mode
        -- ancres (placement/test) on le laisse visible pour pouvoir le positionner. UpdateVisibility
        -- restaure l'alpha a 1 des qu'un CD reapparait (il tourne avant RenderUpcoming au tick).
        box:SetAlpha(0)
    end
    if colW > 0 and contentH > 0 then
        box:SetWidth(UP_PAD + colW + UP_PAD)        -- taille AJUSTEE au contenu (pas de marge parasite)
        box:SetHeight(UP_PAD + contentH + UP_PAD)
    else
        box:SetWidth(70); box:SetHeight(18)         -- vide : taille minimale pour la poignee (mode ancres)
    end
end

-- Le moteur headless HR.Schedule est la source unique : chaque defensif planifie VIVANT porte
-- son baseTime + offset (test depuis s.timeline, live depuis s.liveDefs). Consomme par "Personal Timeline"
-- (via HR.Schedule.PlanAll) et l'Announcement (ci-dessous). Temps EFFECTIF = baseTime + offset/1000.
local function effTime(e) return e.baseTime + (e.offset or 0) / 1000 end

--------------------------------------------------------------------------------
-- Announcement : message centre a l'ecran (alternative a l'Upcoming bar). MEME source
-- (le moteur HR.Schedule), mais TOUJOURS filtree "mien" (un sort qui ME concerne) + son
-- PROPRE seuil. Les deux peuvent etre actifs en meme temps.
--------------------------------------------------------------------------------
local AN_PAD  = 8
local AN_GAP  = 4     -- espace entre icones accumulees
local AN_MIN_W = 300  -- largeur MINIMALE de la boite d'annonce (fixe -> ancrage stable, icones centrees)

local function AnIconSize() return Opt().announceIconSize or 32 end

-- Defensifs sous le seuil, chacun = une ENTREE distincte (accumulation, pas de regroupement).
-- Par defaut : uniquement les MIENS. Option "Show all spells" (announceShowAll) : TOUS les sorts
-- du plan (CD de heal, externals type AMZ/Zephyr, appels perso). Dedup par occKey|token ; tri par rem.
local function MineAnnounceEntries(now)
    local thr = Opt().announceThreshold or 5
    local showAll = (Opt().announceShowAll == true)
    local out, seen = {}, {}
    for _, e in ipairs(HR.Schedule.Active(now)) do
        if showAll or e.mine then
            local rem = effTime(e) - now
            local key = tostring(e.occKey) .. "|" .. tostring(e.token)
            if rem <= thr and not seen[key] then
                seen[key] = true
                out[#out + 1] = { token = e.token, rem = rem, mine = e.mine }
            end
        end
    end
    -- Tri DECROISSANT par rem : le layout va de gauche->droite, donc le plus PROCHE (plus petit
    -- rem, atteint 0 en premier) se retrouve le plus a DROITE.
    table.sort(out, function(a, b) return a.rem > b.rem end)
    return out
end

-- Icone (pool) = FRAME (texture + timer overlay centre + support glow), agglomeree a gauche.
local function AcquireAnnounceIcon(i)
    local box = UI.announceBox
    box.icons = box.icons or {}
    local f = box.icons[i]
    if not f then
        f = CreateFrame("Frame", nil, box)
        f.tex = f:CreateTexture(nil, "ARTWORK")
        f.tex:SetAllPoints()
        f.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        f.timer = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        f.timer:SetPoint("CENTER")
        box.icons[i] = f
    end
    return f
end

local function HideAnnounceIcons(box)
    for _, f in ipairs(box.icons or {}) do HR.StopGlow(f); f:Hide() end
end

local function RenderAnnounceIdle(box)
    HideAnnounceIcons(box)
    -- Meme taille FIXE qu'en contenu -> aucun saut de la boite (donc de l'ancre) entre repos/annonce.
    box:SetSize(AN_MIN_W, AnIconSize() + AN_PAD)
end

-- Rendu : une icone par entree (timer overlay au centre). La boite a une LARGEUR FIXE (>= 300,
-- plus large que necessaire) -> elle NE SE REDIMENSIONNE PAS quand le nb d'icones change, donc
-- l'ancre/la poignee ne bougent plus. Les icones sont CENTREES dans la boite (posees depuis le
-- milieu). SMALL_DEF => icone generique unique.
local function RenderAnnounce(box, entries)
    local sz    = AnIconSize()
    local tc    = HR.CompGet("announce", "textColor")
    local glow  = (Opt().announceGlowMine == true)
    -- Pass 1 : taille de chaque icone (miens = pleine, autres = 65%) + largeur totale du contenu.
    local iszs, tw = {}, 0
    for i, e in ipairs(entries) do
        local isz = e.mine and sz or math.floor(sz * 0.65 + 0.5)
        iszs[i] = isz
        tw = tw + isz + (i > 1 and AN_GAP or 0)
    end
    -- Largeur FIXE : max(contenu, 300) -> stable pour le cas courant (contenu < 300). Contenu centre.
    local boxW = math.max(tw + 2 * AN_PAD, AN_MIN_W)
    box:SetSize(boxW, sz + AN_PAD)
    local x = (boxW - tw) / 2                        -- bord gauche de la rangee CENTREE
    for i, e in ipairs(entries) do
        local isz   = iszs[i]
        local fsize = math.max(8, math.floor(isz * 0.42 + 0.5))   -- police du timer = ratio de la taille
        local f = AcquireAnnounceIcon(i)
        f:SetSize(isz, isz)
        f:ClearAllPoints(); f:SetPoint("LEFT", box, "LEFT", x, 0)
        f.tex:SetTexture(HR.GetDirectiveIcon(e.token) or 134400)   -- SMALL_DEF -> icone du perso "main"
        f.timer:SetFont(STANDARD_TEXT_FONT, fsize, "OUTLINE")
        f.timer:SetTextColor(tc[1] or 1, tc[2] or 1, tc[3] or 1, tc[4] or 1)
        f.timer:SetText(("%ds"):format(math.max(0, math.ceil(e.rem))))
        if glow and e.mine then HR.StartGlow(f, HR.CompGlow()) else HR.StopGlow(f) end   -- glow SEULEMENT les miens
        f:Show()
        x = x + isz + AN_GAP
    end
    for i = #entries + 1, #(box.icons or {}) do   -- masque le reste du pool
        HR.StopGlow(box.icons[i]); box.icons[i]:Hide()
    end
end

-- Met a jour le message : une icone par defensif MIEN sous le seuil (accumulation).
local function UpdateAnnouncement(now)
    local box = UI.announceBox
    if not box then return end
    if Opt().announceDisabled == true then RenderAnnounceIdle(box); return end
    local entries = MineAnnounceEntries(now)
    if #entries == 0 then RenderAnnounceIdle(box); return end
    -- DEVLOG (change-triggered) : logge la liste de tokens annonces quand elle change.
    if HR.DevLogEnabled() then
        local parts = {}
        for _, e in ipairs(entries) do parts[#parts + 1] = tostring(e.token) end
        local sig = table.concat(parts, ",")
        if sig ~= box._devSig then
            box._devSig = sig
            HR.DevLog("announce", "tokens=[%s] n=%d", sig, #entries)
        end
    end
    RenderAnnounce(box, entries)
end

local function OnUpdate(self, dt)
    self._acc = (self._acc or 0) + dt
    if self._acc < THROTTLE then return end
    self._acc = 0

    activeBox = self                -- cible du rendu de cette passe (reelle OU apercu)
    HR.Runtime.UpdateVisibility()   -- auto-correction de la visibilite a chaque tick
    if not HR.RuntimeAllowed() then activeBox = nil; return end   -- GATE ZONE : rien a rendre

    -- Announcement : pilote par la box REELLE uniquement (pas les apercus), independant de
    -- l'etat (vide si rien). Lit la meme source (le moteur HR.Schedule) que l'Upcoming bar.
    if self == UI.runtimeBox then UpdateAnnouncement(GetTime()) end

    local s = HR.Runtime.state
    if not s then UpdateWaiting(); activeBox = nil; return end

    local now = GetTime()
    -- Moteurs headless, une fois par tick depuis la box REELLE uniquement :
    --   * HR.Schedule.Tick : edges partages (debug / consommateurs de l'event bus).
    --   * HR.Alerts.Tick   : systeme d'alerte SONORE autonome (son propre seuil).
    if self == UI.runtimeBox then
        HR.Schedule.Tick(now)
        if HR.Alerts and HR.Alerts.Tick then HR.Alerts.Tick(now) end
    end
    -- Test : arret quand toutes les occurrences sont passees (pilote par la box REELLE
    -- uniquement, pas l'apercu, pour ne pas couper le test pendant l'edition des settings).
    if self == UI.runtimeBox and s.mode == "test" then
        local last = s.timeline and s.timeline[#s.timeline]
        if last and (now - s.pullTime) > last.time + LINGER then activeBox = nil; HR.Runtime.Stop(); return end
    end

    -- "Personal Timeline" : liste des CD du joueur, rendue TOUJOURS tant qu'un encounter/test tourne
    -- (hauteur stable). Plus de "what's next" / seuil.
    RenderUpcoming()
    activeBox = nil
end

--------------------------------------------------------------------------------
-- Options : application a chaud (scale, couleur de fond, layout des macros)
--------------------------------------------------------------------------------

-- Applique la composition "upcoming" a la barre.
local function ApplyUpBox(box)
    if not box then return end
    local scale = HR.CompGet("upcoming", "scale") or 1.0
    HR.SetFrameScaleInPlace(box, scale)                                -- rescale SANS deplacer
    HR.SaveFramePos("runtime", box)   -- GetPoint (sur a l'init) ; ancre normalisee TOPLEFT au drag
    -- La poignee garde une taille a l'ecran CONSTANTE (contre-scale du scale de la boite).
    if box.handle then box.handle:SetScale(1 / scale) end
    -- Fond (composition "upcoming").
    local bg = HR.CompGet("upcoming", "bgColor")
    box:SetBackdropColor(bg[1] or 0, bg[2] or 0, bg[3] or 0, bg[4] or 0.85)
    -- Bordure : 4 cotes dessines a la main (le BackdropTemplate n'a pas d'edgeFile).
    local bc = HR.CompGet("upcoming", "borderColor")
    local bt = HR.CompGet("upcoming", "borderThickness") or 1
    local e = box.edges
    if e then
        e.top:ClearAllPoints();    e.top:SetPoint("TOPLEFT");    e.top:SetPoint("TOPRIGHT");    e.top:SetHeight(bt)
        e.bottom:ClearAllPoints(); e.bottom:SetPoint("BOTTOMLEFT"); e.bottom:SetPoint("BOTTOMRIGHT"); e.bottom:SetHeight(bt)
        e.left:ClearAllPoints();   e.left:SetPoint("TOPLEFT");   e.left:SetPoint("BOTTOMLEFT");  e.left:SetWidth(bt)
        e.right:ClearAllPoints();  e.right:SetPoint("TOPRIGHT"); e.right:SetPoint("BOTTOMRIGHT"); e.right:SetWidth(bt)
        for _, t in pairs(e) do t:SetColorTexture(bc[1], bc[2], bc[3], bc[4] or 1); t:SetShown((bt or 0) > 0) end
    end
end

-- Upcoming bar : pas d'enfant securise -> scale/couleur libres a tout moment.
function HR.Runtime.ApplyUpcomingOptions()
    ApplyUpBox(UI.runtimeBox)
end

-- Announcement : taille d'icone / couleur du timer / glow sont appliques au RENDU (par tick,
-- RenderAnnounce). Ici on se contente de rafraichir la visibilite (poignee = AnchorsVisible).
function HR.Runtime.ApplyAnnounceOptions()
    HR.Runtime.UpdateVisibility()
end

-- Communication bar : contient des boutons securises -> scale uniquement HORS COMBAT.
-- Fond + bordure = composition "comm" (partagee avec timeline/upcoming), non protegee.
function HR.Runtime.ApplyCommOptions()
    local c = UI.commBar
    if not c then return end
    local bg = HR.CompGet("comm", "bgColor")
    c:SetBackdropColor(bg[1] or 0, bg[2] or 0, bg[3] or 0, bg[4] or 1)     -- couleur : libre
    if c.edges then                                                        -- bordure (4 cotes)
        local bc = HR.CompGet("comm", "borderColor")
        local bt = HR.CompGet("comm", "borderThickness") or 0
        local e = c.edges
        e.top:ClearAllPoints();    e.top:SetPoint("TOPLEFT");    e.top:SetPoint("TOPRIGHT");    e.top:SetHeight(bt)
        e.bottom:ClearAllPoints(); e.bottom:SetPoint("BOTTOMLEFT"); e.bottom:SetPoint("BOTTOMRIGHT"); e.bottom:SetHeight(bt)
        e.left:ClearAllPoints();   e.left:SetPoint("TOPLEFT");   e.left:SetPoint("BOTTOMLEFT");  e.left:SetWidth(bt)
        e.right:ClearAllPoints();  e.right:SetPoint("TOPRIGHT"); e.right:SetPoint("BOTTOMRIGHT"); e.right:SetWidth(bt)
        for _, t in pairs(e) do t:SetColorTexture(bc[1], bc[2], bc[3], bc[4] or 1); t:SetShown(bt > 0) end
    end
    if InCombatLockdown() then return end                                  -- scale/layout : hors combat
    -- PAS de conversion d'ancre ici : a l'init le rect n'est pas a jour (et la taille pas encore
    -- relayout) -> SaveFramePosTopLeft calculerait un offset faux = SAUT au relog. La position
    -- restauree (TOPLEFT, ou ancienne "TOP"/"CENTER") est stable : SetFrameScaleInPlace garde le
    -- point d'ancrage fixe quel qu'il soit. La normalisation vers TOPLEFT se fait au drag-stop /
    -- reset (rect a jour), donc toute position re-placee est deja TOPLEFT.
    HR.SetFrameScaleInPlace(c, HR.CompGet("comm", "scale") or 1.0)         -- rescale SANS deplacer
    HR.SaveFramePos("comm", c)            -- GetPoint-based (stable) ; PAS GetRight/GetTop (rect non a jour)
    HR.Runtime.RefreshCallButtons()       -- relayout (horizontal/vertical) + taille
end

-- Mode "arrangement" : les ANCRES (poignees de deplacement) sont montrees et les fenetres HUD
-- forcees visibles pour les placer. Actif UNIQUEMENT en mode TEST (plus d'option "Show anchors").
function HR.Runtime.AnchorsVisible()
    local s = HR.Runtime.state
    return (s and s.mode == "test") and true or false
end

-- Les 4 boites HUD NON securisees. En mode dormant on les `Hide()` et pas seulement SetAlpha(0) :
-- une frame a alpha 0 RECOIT TOUJOURS LES CLICS (rectangle invisible qui bloque l'UI de WoW), et
-- l'alpha du parent n'eteint pas le mouse des enfants (les icones de defensif ont leur propre
-- EnableMouse(true), cf. AcquireDefIcon). `Hide` regle les deux d'un coup, enfants compris.
-- Sans danger ici : AUCUNE de ces 4 ne contient d'enfant securise -- tous les
-- SecureActionButtonTemplate sont enfants de UI.commBar (cf. BuildCommBar).
-- Pas de table intermediaire : UpdateVisibility tourne a CHAQUE tick d'OnUpdate (zero garbage),
-- et un `ipairs` sur une table a trous s'arreterait au premier nil (une boite non construite
-- masquerait les suivantes).
local function SetPlainBoxesShown(shown)
    local a, b, c, d = UI.runtimeBox, UI.timelineBox, UI.progressBox, UI.announceBox
    if a then a:SetShown(shown) end
    if b then b:SetShown(shown) end
    if c then c:SetShown(shown) end
    if d then d:SetShown(shown) end
end

-- Comm bar : elle, contient les boutons securises -> `Hide` ET `EnableMouse` y sont PROTEGES en
-- combat. On neutralise donc la souris HORS COMBAT seulement ; en combat on se contente de
-- l'alpha et PLAYER_REGEN_ENABLED (RefreshCalls) rattrape des la sortie de combat.
-- Le cache `commMouseOn` evite de re-appeler EnableMouse a chaque tick d'OnUpdate ; laisser le
-- cache PERIME quand on est en combat est voulu : le prochain appel hors combat appliquera.
local commMouseOn = true
local function SetCommMouse(on)
    local c = UI.commBar
    if not c or commMouseOn == on then return end
    if InCombatLockdown() then return end
    c:EnableMouse(on)
    for _, sb in ipairs(c.callBtns or {}) do sb:EnableMouse(on) end
    commMouseOn = on
end

-- Visibilite via OPACITE (SetAlpha non protege -> OK meme en combat avec les boutons securises).
-- IMPOSE (hardcode, PAS une option) : HORS COMBAT, aucun element runtime ne s'affiche, SAUF en
-- mode test (qui force tout visible pour placer les ancres). En combat -> selon l'Enable de
-- chaque composant (My Tasks / Timeline / Progress / Announcement / Communication bar).
function HR.Runtime.UpdateVisibility()
    -- GATE DE ZONE (imposee, pas une option) : hors d'un donjon de HR.content, l'addon est
    -- DORMANT -- aucun composant rendu et aucun clic capte. Le mode TEST bypasse. Le raid n'est
    -- plus un cas special : une instance de raid ne matche simplement aucun donjon.
    if not HR.RuntimeAllowed() then
        SetPlainBoxesShown(false)   -- masque + click-through, poignees et enfants inclus
        if UI.commBar then
            UI.commBar:SetAlpha(0)
            if UI.commBar.handle then UI.commBar.handle:SetShown(false) end
        end
        SetCommMouse(false)
        return
    end
    -- Sortie de dormance : re-montrer les boites AVANT que la logique par composant ne pose leur
    -- alpha, et rendre la souris a la comm bar (sinon drag et /yell restent morts).
    SetPlainBoxesShown(true)
    SetCommMouse(true)
    local combat   = InCombatLockdown()
    local anchors  = HR.Runtime.AnchorsVisible()          -- = mode test uniquement
    local state    = (HR.Runtime.state ~= nil)            -- encounter LIVE ou test en cours
    -- IMPOSE (hardcode, PAS une option) : HORS COMBAT, aucun element runtime ne s'affiche, SAUF le
    -- mode test. HUD (My Tasks / Timeline / Progress / Announcement) = pendant un encounter/test.
    -- Comm bar = tout combat (les appels servent meme hors boss) OU encounter/test.
    local visible     = (state or anchors)
    local commVisible = (combat or state or anchors)
    local upc      = (Opt().upcomingEnabled ~= false)   -- Upcoming bar activee (defaut on)
    local tl       = (Opt().timelineMode == true)        -- Timeline d'icones activee (defaut off)
    -- Barres et timeline d'icones : deux representations INDEPENDANTES (chacune son Enable). On
    -- peut afficher les DEUX en meme temps ; plus d'exclusivite.
    local bars     = (Opt().timelineProgressBars == true)
    -- Communication bar : feature SOIGNEUR ; option "Enable for non-healer role" pour l'afficher
    -- quand meme en role non-soin. "Disable Communication Bar" (commDisabled) la masque totalement.
    local canShowComm = (Opt().commDisabled ~= true)
        and ((HR.GetPlayerRole() == "HEALER") or (Opt().commNonHealer == true))
    if UI.commBar then
        local commShown = (canShowComm and commVisible) and true or false
        UI.commBar:SetAlpha(commShown and 1 or 0)
        if UI.commBar.handle then UI.commBar.handle:SetShown(anchors and commShown) end
    end
    if UI.runtimeBox  then
        local upShown = (visible and upc) and true or false
        UI.runtimeBox:SetAlpha(upShown and 1 or 0)
        if UI.runtimeBox.handle then UI.runtimeBox.handle:SetShown(anchors and upShown) end
    end
    if UI.timelineBox then
        -- Timeline d'ICONES : affichee des que la timeline est activee (independante des barres).
        local tlShown = (visible and tl) and true or false
        UI.timelineBox:SetAlpha(tlShown and 1 or 0)
        -- refreshBtn = refresh (toujours quand la timeline est affichee) ET poignee de drag
        -- (le drag lui-meme est garde par AnchorsVisible cote OnDragStart).
        if UI.timelineBox.refreshBtn then
            UI.timelineBox.refreshBtn:SetShown(tlShown)
            UI.timelineBox.refreshBtn:EnableMouse(tlShown)
        end
    end
    -- Progress bars : representation ALTERNATIVE (mutuellement exclusive avec la timeline
    -- d'icones). Les outils move/resize ne s'affichent qu'en mode ancres (placement/calibrage).
    if UI.progressBox then
        local pbShown = (visible and bars) and true or false
        UI.progressBox:SetAlpha(pbShown and 1 or 0)
        local toolsOn = pbShown and anchors
        if UI.progressBox.moveHandle then
            UI.progressBox.moveHandle:SetShown(toolsOn); UI.progressBox.moveHandle:EnableMouse(toolsOn)
        end
        if UI.progressBox.resizeGrip then
            UI.progressBox.resizeGrip:SetShown(toolsOn); UI.progressBox.resizeGrip:EnableMouse(toolsOn)
        end
    end
    -- Announcement : alternative a l'Upcoming bar, memes regles de visibilite + son toggle.
    if UI.announceBox then
        local anShown = (visible and (Opt().announceDisabled ~= true)) and true or false
        UI.announceBox:SetAlpha(anShown and 1 or 0)
        if UI.announceBox.handle then
            UI.announceBox.handle:SetShown((anchors and anShown) and true or false)
        end
    end
end

-- Persiste la position d'une frame selon le mode d'ancrage voulu. `mode` :
--   true / "TOPRIGHT" -> coin haut-droit (boite runtime, collee au coin ecran)
--   "TOPLEFT"         -> coin haut-gauche (comm bar : origine du contenu, scale a gauche)
--   sinon             -> SaveFramePos (GetPoint tel quel)
-- A n'appeler QUE quand la frame est affichee + posee (GetLeft/GetTop a jour) : les variantes
-- TopLeft/TopRight lisent le rect. cf. bug du saut au relog (conversion sur un rect perime).
local function SavePosForMode(key, frame, mode)
    -- Ancre HARMONISEE : au DRAG / RESET (rect a jour) les fenetres HUD se sauvent en TOPLEFT ->
    -- SetFrameScaleInPlace garde le coin haut-gauche fixe = rescale in place coherent. (Le SCALE,
    -- lui, sauve via GetPoint : cf. bug rect-non-a-jour a l'init.)
    -- EXCEPTION `mode == "TOP"` : banniere CENTREE (Announcement) -> ancre HAUT-CENTRE (reste
    -- centree horizontalement quand la largeur du contenu change).
    if mode == "TOP" then HR.SaveFramePosTop(key, frame)
    else HR.SaveFramePosTopLeft(key, frame) end
end

-- Recentre toutes les fenetres deplacables au centre de l'ecran et persiste la position.
-- La Communication bar contient des boutons securises -> deplacable HORS COMBAT seulement.
function HR.Runtime.ResetPositions()
    local function center(frame, key, mode)
        if not frame then return end
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        SavePosForMode(key, frame, mode)
    end
    center(UI.runtimeBox,  "runtime",  true)
    center(UI.timelineBox, "timeline", false)
    center(UI.progressBox, "progress", "TOPLEFT")   -- barres : ancre TOPLEFT (resize coherent)
    if InCombatLockdown() then
        HR:Print("Communication bar position will reset out of combat.")
    else
        center(UI.commBar, "comm", "TOPLEFT")   -- ancrage TOPLEFT normalise (stable au rescale)
    end
end

--------------------------------------------------------------------------------
-- Construction des fenetres
--------------------------------------------------------------------------------

-- Fond seul, SANS bordure (look epure). Le deplacement passe par une petite poignee.
local BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    tile = true, tileSize = 16,
}

-- Ajoute une poignee de deplacement (bouton sombre au-dessus, centre) a une fenetre.
-- Meme look que la poignee/bouton de la Timeline (rectangle sombre + label, eclairci au
-- survol). `key` = cle de sauvegarde de position ; `guardCombat` = drag interdit en combat.
-- `anchorMode` : IGNORE (ancre HARMONISEE en TOPLEFT au drag-stop via SavePosForMode ; la
-- normalisation se fait ICI, rect a jour, et plus a l'init : cf. bug de saut au relog/scaling).
local function AddDragHandle(frame, key, guardCombat, anchorMode)
    local h = CreateFrame("Frame", nil, frame)
    h:SetSize(45, 13)   -- +25% par rapport a 36x10
    h:SetPoint("BOTTOM", frame, "TOP", 0, 1)   -- POSEE AU-DESSUS de la boite (pas de chevauchement)
    h:EnableMouse(true)
    h:RegisterForDrag("LeftButton")
    h.tex = h:CreateTexture(nil, "BACKGROUND")
    h.tex:SetAllPoints()
    h.tex:SetColorTexture(0.15, 0.15, 0.15, 0.9)
    h.label = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h.label:SetPoint("CENTER")
    local fontFile, _, fontFlags = h.label:GetFont()
    h.label:SetFont(fontFile, 10, fontFlags)   -- +25% (tient dans 13px)
    h.label:SetText("move")
    h:SetScript("OnEnter", function(self)
        self.tex:SetColorTexture(0.28, 0.28, 0.3, 0.95)
        GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText("Drag to move"); GameTooltip:Show()
    end)
    h:SetScript("OnLeave", function(self)
        self.tex:SetColorTexture(0.15, 0.15, 0.15, 0.9)
        GameTooltip:Hide()
    end)
    h:SetScript("OnDragStart", function()
        if guardCombat and InCombatLockdown() then return end   -- comm bar : boutons securises (pas de drag en combat)
        frame:StartMoving()
    end)
    h:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        SavePosForMode(key, frame, anchorMode)
    end)
    frame.handle = h
    return h
end

local function BuildBox()
    local f = CreateFrame("Frame", "HealPlannerRuntimeBox", UIParent, "BackdropTemplate")
    f:SetSize(BOX_W, TOP_H + 8)
    f:SetClampedToScreen(true)
    f:EnableMouse(false)
    f:SetBackdrop(BACKDROP)
    f:SetBackdropColor(0, 0, 0, 0.85)
    -- Bordure 4 cotes (le BackdropTemplate n'a pas d'edgeFile) -> coloree/dimensionnee
    -- par ApplyUpcomingOptions (composition "upcoming", comme la Timeline).
    f.edges = {}
    for _, k in ipairs({ "top", "bottom", "left", "right" }) do f.edges[k] = f:CreateTexture(nil, "BORDER") end
    do
        f:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -20, -220)
        -- Strata BACKGROUND : la fenetre reste TOUJOURS sous l'UI native de Blizzard
        -- (panneaux Personnage/Sorts en MEDIUM, menu ESC en DIALOG) -> n'obscurcit
        -- jamais un menu ouvert et ne gene pas la navigation.
        f:SetFrameStrata("BACKGROUND")
        f:SetMovable(true)
        AddDragHandle(f, "runtime", false, true)   -- poignee libre ; ancrage haut-droit (coin ecran)
    end

    -- Deux containers TRANSPARENTS (aucun backdrop) empiles verticalement, poses par
    -- RenderUpcoming :
    --   * defBox   : CD du prochain sort (nom + rangee de defensifs + countdown).
    --   * persoBox : liste fusionnee des CD du joueur (perso + external, un seul bloc).
    f.defBox     = CreateFrame("Frame", nil, f)
    f.persoBox   = CreateFrame("Frame", nil, f)
    f.persoIcons = {}

    -- Ligne du haut : nom de la variante jouee.
    f.variantLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.variantLabel:SetPoint("TOPLEFT", 12, -8)
    f.variantLabel:SetPoint("RIGHT", f, "RIGHT", -10, 0)
    f.variantLabel:SetJustifyH("LEFT")
    f.variantLabel:SetWordWrap(false)
    f.variantLabel:SetTextColor(HR.Theme.Unpack("BASE_TEXT_COLOR"))

    -- Ligne d'icones (memes tailles) : attaque | barre verticale | defensifs planifies.
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(ATK_ICON, ATK_ICON)
    f.icon:SetPoint("TOPLEFT", 12, -(8 + VAR_H))
    f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    f.vbar = f:CreateTexture(nil, "ARTWORK")
    f.vbar:SetColorTexture(0.6, 0.6, 0.6, 0.8)
    f.vbar:SetSize(2, ATK_ICON)
    f.vbar:SetPoint("LEFT", f.icon, "RIGHT", 6, 0)

    -- Timer + nom du prochain sort : enfants du container 1 (poses par RenderUpcoming).
    f.timer = f.defBox:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.timer:SetPoint("TOPLEFT", f.icon, "BOTTOMLEFT", 0, -6)

    f.name = f.defBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.name:SetPoint("LEFT", f.timer, "RIGHT", 8, 0)
    f.name:SetJustifyH("LEFT")
    f.name:SetWordWrap(false)

    f.noDef = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.noDef:SetText("No defensive planned")
    f.noDef:Hide()

    f.defIcons = {}
    f.remindLines = {}

    f.sep = f:CreateTexture(nil, "ARTWORK")
    f.sep:SetColorTexture(0.4, 0.4, 0.4, 0.5)
    f.sep:SetHeight(1)
    f.sep:Hide()

    f:SetScript("OnUpdate", OnUpdate)
    UI.runtimeBox = f
    -- Echelle AVANT restore = MEME source que ApplyUpBox (composition) : sinon SetFrameScaleInPlace
    -- y recalerait l'offset (legacy/composition) a chaque init -> derive cumulative au reload.
    f:SetScale(HR.CompGet("upcoming", "scale") or 1.0)
    HR.RestoreFramePos("runtime", f)
    HR.Runtime.ApplyUpcomingOptions()
    activeBox = f; UpdateWaiting(); activeBox = nil   -- etat "en attente"
    f:Show()
    return f
end

-- Communication bar : la rangee de boutons-macros securises (detachee, deplacable).
local function BuildCommBar()
    local c = CreateFrame("Frame", "HealPlannerCommBar", UIParent, "BackdropTemplate")
    c:SetSize(120, COMM_BTN + COMM_PAD * 2)
    -- Ancrage TOPLEFT (= origine du contenu : les boutons partent du coin haut-gauche) -> le
    -- rescale/resize ne deplace plus la barre (cf. saut au scaling avec l'ancien TOPRIGHT).
    c:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 900, -150)
    c:SetFrameStrata("LOW")
    c:SetClampedToScreen(true)
    c:SetMovable(true)
    c:EnableMouse(true)
    c:RegisterForDrag("LeftButton")
    -- Boutons securises -> drag HORS COMBAT seulement (deplacer le parent les bougerait).
    c:SetScript("OnDragStart", function(self)
        if InCombatLockdown() or not HR.Runtime.AnchorsVisible() then return end   -- deplacable en mode ancres seulement
        self:StartMoving()
    end)
    c:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- StartMoving re-ancre la frame au point standard le plus proche (souvent "TOP" pres du
        -- centre). On NORMALISE en TOPLEFT ici (rect a jour) pour que la sauvegarde reste
        -- coherente avec l'ancrage par defaut -> plus de saut au relog.
        HR.SaveFramePosTopLeft("comm", self)
    end)
    c:SetBackdrop(BACKDROP)
    c:SetBackdropColor(0, 0, 0, 0.6)
    -- Bordure : 4 textures (colorees/dimensionnees par ApplyCommOptions, composition "comm").
    c.edges = {}
    for _, k in ipairs({ "top", "bottom", "left", "right" }) do c.edges[k] = c:CreateTexture(nil, "ARTWORK") end
    AddDragHandle(c, "comm", true, "TOPLEFT")   -- poignee (drag hors combat) ; ancrage TOPLEFT normalise

    c.callBtns = {}
    for i, m in ipairs(HR.externalMacros or {}) do
        local sb = CreateFrame("Button", "HealPlannerCall" .. i, c, "SecureActionButtonTemplate")
        sb:SetSize(COMM_BTN, COMM_BTN)
        sb:RegisterForClicks("AnyUp", "AnyDown")
        sb:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        sb.tex = sb:CreateTexture(nil, "ARTWORK")
        sb.tex:SetAllPoints()
        sb.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local d = m.key and HR.ResolveDefEntry(m.key)
        sb.tex:SetTexture(m.icon or (m.key and HR.GetDefensiveIcon(m.key)) or 134400)
        sb._label = (d and d.name) or m.label or m.name
        sb._macro = m.name
        sb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Call: " .. (self._label or ""))
            GameTooltip:AddLine("Click -> /p (macro " .. self._macro .. ")", 0.7, 0.7, 0.7)
            if self._enabled == false then
                GameTooltip:AddLine("Unavailable: nobody in the group can provide it", 1, 0.3, 0.3)
            end
            GameTooltip:Show()
        end)
        sb:SetScript("OnLeave", function() GameTooltip:Hide() end)
        sb:SetScript("PreClick", function(self, button)
            if not HR.debug then return end
            HR:Debug(("[call] clic %s btn=%s type=%s macro=%s combat=%s")
                :format(self:GetName() or "?", tostring(button),
                    tostring(self:GetAttribute("type")), tostring(self:GetAttribute("macro")),
                    tostring(InCombatLockdown())))
        end)
        if not InCombatLockdown() then sb:SetAttribute("type", "macro") end
        c.callBtns[i] = sb
    end

    UI.commBar = c
    c:SetScale(HR.CompGet("comm", "scale") or 1.0)   -- echelle AVANT restore (offset sauve a cette echelle)
    HR.RestoreFramePos("comm", c)
    HR.Runtime.ApplyCommOptions()       -- couleur + scale + layout depuis les options
    c:Show()
end

-- Nombre de COLONNES de la Communication bar (remplace l'ancien commLayout). Les boutons sont
-- ranges en grille de N colonnes : 1 colonne = ancien "vertical" ; 9 colonnes = ancien
-- "horizontal" (au plus 9 boutons -> une seule rangee). Migration douce : si `commColumns` est
-- absent, on l'INFERE une fois depuis l'ancien `commLayout` (lu, jamais reecrit) et on n'ecrit
-- qu'une NOUVELLE cle. cf. ApplyDefaults ne seed PAS commColumns (sinon il ecraserait l'infer).
function HR.Runtime.CommColumns()
    local o = Opt()
    if o.commColumns == nil then
        o.commColumns = (o.commLayout == "vertical") and 1 or 9
    end
    local n = math.floor(tonumber(o.commColumns) or 9)
    return (n < 1) and 1 or n
end

-- (Re)applique role/compo/layout des boutons d'appel. HORS COMBAT uniquement.
--   ROLE : Communication bar = feature SOIGNEUR ; option "Enable for non-healer role"
--          (commNonHealer) pour l'afficher quand meme en role non-soin.
--   COMPO : un CD dont la classe est absente du groupe est grise + neutralise.
--   LAYOUT : grille de N colonnes (option Columns) ; la commBar se redimensionne.
function HR.Runtime.RefreshCallButtons()
    local c = UI.commBar
    if not c or not c.callBtns then return end
    if InCombatLockdown() then return end
    if HR.RebuildGroup then HR.RebuildGroup() end   -- snapshot du VRAI groupe a jour (independant de la variante)
    if HR.RefreshMacroPings then HR.RefreshMacroPings() end   -- re-cible le /ping des macros sur la compo courante (hors combat)
    local isHealer = (HR.GetPlayerRole() == "HEALER")
    local canShow  = isHealer or (Opt().commNonHealer == true)   -- gate role (option non-soigneur)
    if UI.runtimeBox then UI.runtimeBox.isHealer = isHealer end   -- lu par LayoutDefIcons (plan = info heal)
    local reverse   = (Opt().commReverse == true)
    local availOnly = (Opt().commAvailOnly == true)   -- "Show only available spells"

    -- 1) Etat (visibilite / dispo / macro) + collecte des boutons visibles.
    local vis = {}
    for i, sb in ipairs(c.callBtns) do
        local m = HR.externalMacros[i]
        local d = m.key and HR.ResolveDefEntry(m.key)
        -- Dispo = ce que le VRAI groupe peut fournir (classe, + role pour le spec-gate).
        local enabled = (not d) or HR.GroupHasExternal(d)
        -- Soigneur (ou option non-soigneur) ; si "available only", on masque les indispos.
        local show = canShow and (not availOnly or enabled)
        sb:SetShown(show)

        local idx = GetMacroIndexByName(m.name)
        sb:SetAttribute("macro", (enabled and idx and idx > 0) and idx or nil)
        sb.tex:SetDesaturated(not enabled)
        sb:SetAlpha(enabled and 1 or 0.4)
        sb._enabled = enabled

        if show then vis[#vis + 1] = sb end
    end

    -- 2) Ordre (eventuellement inverse) puis empilage en GRILLE de `cols` colonnes
    -- (remplissage par rangees, gauche->droite puis haut->bas).
    if reverse then
        for i = 1, math.floor(#vis / 2) do
            vis[i], vis[#vis - i + 1] = vis[#vis - i + 1], vis[i]
        end
    end
    local cols = HR.Runtime.CommColumns()
    local step = COMM_BTN + COMM_GAP
    for idx, sb in ipairs(vis) do
        local col = (idx - 1) % cols            -- colonne (0-based)
        local row = math.floor((idx - 1) / cols) -- rangee  (0-based)
        sb:ClearAllPoints()
        sb:SetPoint("TOPLEFT", COMM_PAD + col * step, -(COMM_PAD + row * step))
    end

    local n        = math.max(#vis, 1)
    local usedCols = math.max(math.min(cols, n), 1)   -- colonnes reellement remplies
    local rows     = math.ceil(n / cols)
    local pad2     = COMM_PAD * 2
    c:SetSize(usedCols * COMM_BTN + (usedCols - 1) * COMM_GAP + pad2,
              rows     * COMM_BTN + (rows     - 1) * COMM_GAP + pad2)
end

-- Announcement : banniere centrale (icone + texte), deplacable. Pas d'OnUpdate propre :
-- pilotee par l'OnUpdate de la box REELLE (UpdateAnnouncement). Pas d'enfant securise.
local function BuildAnnounce()
    local f = CreateFrame("Frame", "HealPlannerAnnounce", UIParent)
    f:SetSize(120, 30)
    f:SetPoint("TOP", UIParent, "TOP", 0, -180)   -- banniere : ancre HAUT-CENTRE (reste centree)
    f:SetFrameStrata("BACKGROUND")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(false)
    AddDragHandle(f, "announce", false, "TOP")     -- ancre HAUT-CENTRE au drag (banniere centree)
    f.icons = {}   -- pool d'icones-frames (texture + timer overlay), une par defensif annonce
    UI.announceBox = f
    -- MIGRATION : une position d'announce sauvegardee AVANT l'ancre HAUT-CENTRE (point non "TOP",
    -- ex. ancien TOPLEFT/CENTER) restaurerait la banniere ANCREE A GAUCHE -> elle grandit vers la
    -- droite et se decale a chaque changement de contenu. On la PURGE -> retour a l'ancre haut-centre
    -- par defaut (le joueur peut re-deplacer). C'est une position d'affichage (pas un plan).
    if HR.db and HR.db.ui and HR.db.ui.announce and HR.db.ui.announce.point ~= "TOP" then
        HR.db.ui.announce = nil
    end
    HR.RestoreFramePos("announce", f)
    HR.Runtime.ApplyAnnounceOptions()
    RenderAnnounceIdle(f)
    f:Show()
end

-- Construit les fenetres HORS COMBAT (init). Les boutons securises ne recoivent
-- leurs attributs qu'a ce moment.
function HR.Runtime.PreBuild()
    if InCombatLockdown() then return end
    if not UI.runtimeBox then BuildBox() end
    if not UI.commBar then BuildCommBar() end
    if not UI.announceBox then BuildAnnounce() end
    if HR.Runtime.PreBuildTimeline then HR.Runtime.PreBuildTimeline() end
    if HR.Runtime.PreBuildProgress then HR.Runtime.PreBuildProgress() end
    if HR.UpdateZoneGate then HR.UpdateZoneGate() end   -- gate de zone a jour des l'init (/reload en donjon)
    -- L'Upcoming bar et l'Announcement INTERROGENT le moteur (HR.Schedule) chaque tick : plus
    -- d'abonnement au hook de seuil de la Timeline. Le son/TTS, lui, reste sur le bus (edge tire
    -- par HR.Schedule.Tick). cf. Core/Schedule.lua.
    HR.Runtime.UpdateVisibility()
end

-- S'assure que les fenetres existent puis applique la visibilite (opacite).
local function ShowBox()
    if not UI.runtimeBox or not UI.commBar then
        if InCombatLockdown() then return end
        HR.Runtime.PreBuild()
    end
    if UI.runtimeBox then UI.runtimeBox._acc = 0 end
    HR.Runtime.UpdateVisibility()
end

--------------------------------------------------------------------------------
-- Controleur
--------------------------------------------------------------------------------

-- Sorts qui DEMARRENT au pull (ex. Ick & Krick) : Blizzard n'envoie PAS d'event
-- ENCOUNTER_TIMELINE pour eux -> ils n'apparaitraient nulle part. REGLE : toute
-- occurrence theorique a moins de SYNTH_PULL_WINDOW s du pull est POUSSEE telle quelle
-- dans le backend (recognized + active + liveDefs), comme si on avait recu un event
-- Blizzard. Mirroir EXACT du handler ADDED, mais l'occurrence est connue (pas de matching
-- par duree). Lecture seule cote DB (on lit les assignments, on n'ecrit rien).
local SYNTH_PULL_WINDOW = 2
local function PushSyntheticPullEvents(s)
    if not s or s.passthrough then return end
    s.seen = s.seen or {}; s.recognized = s.recognized or {}
    s.active = s.active or {}; s.liveDefs = s.liveDefs or {}
    local _, pClass = UnitClass("player")
    for _, occ in ipairs(s.planned or {}) do
        local eventID = "SYNTH:" .. tostring(occ.key)
        if (occ.time or 0) < SYNTH_PULL_WINDOW and not s.seen[eventID] then
            s.seen[eventID] = true
            local endTime = (s.pullTime or GetTime()) + (occ.time or 0)   -- cast-start absolu theorique
            s.recognized[eventID] = {
                eventID = eventID, spellID = occ.spellID, name = occ.name,
                enabled = true, endTime = endTime, synthetic = true,
            }
            local defs = HR.GetAssignments(s.variant, s.encounterID, occ.key)
            s.active[eventID] = {
                eventID = eventID, occ = occ, defs = defs, endTime = endTime, synthetic = true,
            }
            local base = HR.OccDefTime(occ, endTime)
            for i, e in ipairs(defs) do
                local token  = HR.EntryToken(e)
                local offset = HR.EntryOffset(e)
                local d = HR.defensives[HR.DefKeyOf(token)]
                s.liveDefs[#s.liveDefs + 1] = {
                    key = "L" .. tostring(eventID) .. "|" .. i,
                    defID = token, defTime = base,
                    offset = offset, occKey = occ.key,
                    mine = HR.TokenIsMine(token),
                    eventID = eventID, bossName = occ.name,
                }
            end
            if HR.debug then
                HR:Debug(("[rt] synth pull %s @%.1fs defs=%d"):format(tostring(occ.name), occ.time or 0, #defs))
            end
        end
    end
end

-- DEBUG (/ecp devlog) : vide une timeline d'occurrences + l'identite du boss. `raw` = avant
-- FilterTimeline (occurrences desactivees comprises), `used` = apres (ce qui pilote le runtime).
-- name/spellID possiblement Secret (live) -> HR.DevSafe (jamais lu/compare).
local function DevDumpTimeline(tag, boss, raw, used)
    if not HR.DevLogEnabled() then return end
    HR.DevLog("start", "%s boss=%s id=%s rep=%s raw=%d used=%d", tag,
        HR.DevSafe(boss and boss.name), HR.DevSafe(boss and boss.id),
        (boss and boss.phases) and "phases" or "abilities",
        raw and #raw or -1, used and #used or -1)
    if boss and boss.durationGroups then
        for dur, ids in pairs(boss.durationGroups) do
            HR.DevLog("start", "  durationGroup[%s] = %s", tostring(dur), table.concat(ids, ","))
        end
    end
    local function line(o)
        return string.format("key=%s sid=%s t=%.2f aoe=%s inTL=%s name='%s' ovr='%s' custom='%s'",
            HR.DevSafe(o.key), HR.DevSafe(o.spellID), o.time or -1,
            tostring(o.aoe), tostring(o.allowInTimeline),
            HR.DevSafe(o.name), HR.DevSafe(o.overridenName), HR.DevSafe(o.customName))
    end
    HR.DevLogList("start", tag .. " USED", used or {}, line)
    -- Occurrences RETIREES par FilterTimeline (dans raw, absentes de used) -> revele un doublon
    -- ou une entree "morte" (ex. shortname legacy) qui polluerait les barres/timeline.
    if raw and used then
        local usedKeys = {}
        for _, o in ipairs(used) do usedKeys[o.key] = true end
        local removed = {}
        for _, o in ipairs(raw) do if not usedKeys[o.key] then removed[#removed + 1] = o end end
        if #removed > 0 then HR.DevLogList("start", tag .. " FILTERED-OUT", removed, line) end
    end
end

function HR.Runtime.StartLive(encounterID)
    -- GATE ZONE (imposee) : jamais de timeline backend hors d'un donjon connu. On rafraichit la
    -- gate ICI MEME : ENCOUNTER_START est rare, et ca supprime tout risque de flag perime.
    if not HR.UpdateZoneGate() then return false end
    local boss, dungeon = HR.GetBossByEncounterID(encounterID)
    if not boss then return false end
    boss = HR.ResolveBossTimeline(boss)   -- timeline de la variante active (no-op si aucune)
    local passthrough = not HR.BossEnabled(boss)
    -- Variante ACTIVE (V2, PAR DONJON) du donjon du combat ; repli sur l'ancien systeme.
    local variant = (dungeon and HR.GetV2Used(dungeon.id))
        or (dungeon and HR.GetUsedVariant(dungeon.id))
        or (dungeon and HR.GetVariants(dungeon.id)[1])
    local rawOccs = passthrough and {} or HR.GenerateOccurrences(boss, HR.FIGHT_LENGTH)
    local planned = passthrough and {} or HR.FilterTimeline(rawOccs)
    DevDumpTimeline("StartLive", boss, rawOccs, planned)
    HR.Runtime.state = {
        mode        = "live",
        boss        = boss,
        encounterID = encounterID,
        variant     = variant,
        passthrough = passthrough,
        -- Timeline = occurrences ACTIVES seulement (sorts desactives filtres).
        planned     = planned,
        pullTime    = GetTime(),
        active      = {},
        durCounters = {},   -- compteur d'occurrences PAR duree (matching, reset au pull)
        currentPhase = 1,   -- phase runtime detectee (avance via boss.phaseTransitions ; reset au pull)
        recognized  = {},   -- [eventID] = { spellID, name, enabled, ... } pour la Timeline
        seen        = {},   -- [eventID] = true : evite de recompter/redoubler un re-ADD
        liveDefs    = {},   -- defensifs SPAWNES au match d'un event boss (timing live + marqueur)
    }
    PushSyntheticPullEvents(HR.Runtime.state)   -- sorts au pull sans event Blizzard (ex. Ick & Krick)
    ShowBox()
    return true
end

function HR.Runtime.StartTest(encounterID, variant)
    local boss = HR.GetBossByEncounterID(encounterID)
    if not boss then return false end
    boss = HR.ResolveBossTimeline(boss)   -- timeline de la variante active (no-op si aucune)
    local raw = HR.GenerateOccurrences(boss, HR.FIGHT_LENGTH)
    local timeline = HR.FilterTimeline(raw)
    if #timeline == 0 then return false end
    for _, o in ipairs(timeline) do
        o.defs = HR.GetAssignments(variant, boss.id, o.key)
    end
    DevDumpTimeline("StartTest", boss, raw, timeline)
    HR.Runtime.state = {
        mode = "test", boss = boss, variant = variant,
        pullTime = GetTime(), timeline = timeline, index = 1,
    }
    ShowBox()
    return true
end

-- Mode test DEDIE (bouton "Start test") : boss invente + variante de test (AMZ + small
-- def sur la capacite 1). Threshold upcoming force a 10s (warnOverride). Respecte les
-- toggles Timeline/Upcoming (via ShowBox -> UpdateVisibility).
function HR.Runtime.StartTestMode()
    -- Regenere a CHAQUE start : le CD de heal injecte depend de la classe/spe courante
    -- (la spe peut ne pas etre connue a l'init).
    if HR.BuildTestVariant then HR.BuildTestVariant() end
    local boss, variant = HR.testBoss, HR.testVariant
    if not boss or not variant then return false end
    local raw = HR.GenerateOccurrences(boss, HR.FIGHT_LENGTH)
    local timeline = HR.FilterTimeline(raw)
    if #timeline == 0 then return false end
    for _, o in ipairs(timeline) do
        o.defs = HR.GetAssignments(variant, boss.id, o.key)
    end
    DevDumpTimeline("StartTestMode", boss, raw, timeline)
    HR.Runtime.state = {
        mode = "test", boss = boss, variant = variant,
        pullTime = GetTime(), timeline = timeline, index = 1,
        warnOverride = 10,   -- (test) fenetre upcoming forcee a 10s
    }
    ShowBox()
    return true
end

function HR.Runtime.Stop()
    HR.Runtime.state = nil               -- le moteur (HR.Schedule) lit l'etat : plus rien a vider
    if UI.runtimeBox then UpdateWaiting() end
    HR.Runtime.UpdateVisibility()       -- re-masque hors combat si l'option est on
end

-- (Plus AUCUN apercu de module dans les Settings : le joueur regarde directement son UI en jeu.
-- Les reglages de composition s'appliquent en direct sur les vrais modules via ApplyXxxOptions.)

--------------------------------------------------------------------------------
-- Evenements
--------------------------------------------------------------------------------

HR:RegisterEvent("ENCOUNTER_START", function(_, encounterID)
    HR.Runtime.StartLive(encounterID)
end)

HR:RegisterEvent("ENCOUNTER_END", function()
    HR.Runtime.Stop()
end)

-- GATE DE ZONE (imposee, pas une option) : LISTE BLANCHE des donjons de HR.content, matches par
-- `zoneID` (= instanceID de GetInstanceInfo). Hors de ces donjons -> addon DORMANT. Raid, BG,
-- arene, delve, scenario et monde ouvert sont exclus SANS avoir a les enumerer, et c'est
-- raid-safe PAR CONSTRUCTION (HR.content ne contient que des donjons, aucun instanceID de raid
-- ne peut y matcher). Un zoneID faux echoue du BON cote : feature inactive, jamais active a tort.
-- Gate StartLive (pas de timeline backend) ET UpdateVisibility/OnUpdate (rien rendu, rien cliquable).
function HR.UpdateZoneGate()
    HR.inKnownDungeon = (HR.GetCurrentDungeonIndex ~= nil and HR.GetCurrentDungeonIndex() ~= nil)
    return HR.inKnownDungeon
end

-- Le mode TEST bypasse la restriction de zone : on doit pouvoir tester n'importe ou (ville,
-- monde ouvert...). Seul le chemin LIVE est gate par la zone.
function HR.RuntimeAllowed()
    local s = HR.Runtime.state
    if s and s.mode == "test" then return true end
    return HR.inKnownDungeon == true
end

local function RefreshCalls()
    HR.UpdateZoneGate()   -- rafraichit la gate de zone AVANT la visibilite
    if HR.Runtime.RefreshCallButtons then HR.Runtime.RefreshCallButtons() end
    if HR.Runtime.UpdateVisibility then HR.Runtime.UpdateVisibility() end
    -- Les 2 modules tiers relisent la gate dans leur Enabled(), mais ForeignBars porte un ETAT
    -- PERSISTANT (reparent de EncounterTimeline) : sans ce rappel, la timeline Blizzard
    -- resterait masquee apres la sortie du donjon.
    if HR.ForeignBars   and HR.ForeignBars.Apply   then HR.ForeignBars.Apply()   end
    if HR.BossModAttach and HR.BossModAttach.Apply then HR.BossModAttach.Apply() end
end
HR:RegisterEvent("PLAYER_ENTERING_WORLD", RefreshCalls)
HR:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", RefreshCalls)
HR:RegisterEvent("GROUP_ROSTER_UPDATE", RefreshCalls)
HR:RegisterEvent("PLAYER_ROLES_ASSIGNED", RefreshCalls)   -- role change (ex. heal->dps) -> re-gate les externals
HR:RegisterEvent("PLAYER_REGEN_ENABLED", RefreshCalls)   -- fin de combat -> peut re-masquer
HR:RegisterEvent("PLAYER_REGEN_DISABLED", function()      -- entree en combat -> affiche
    HR.UpdateZoneGate()   -- symetrique de PLAYER_REGEN_ENABLED : gate a jour AVANT la visibilite
    if HR.Runtime.UpdateVisibility then HR.Runtime.UpdateVisibility() end
end)

HR:RegisterEvent("ENCOUNTER_TIMELINE_EVENT_ADDED", function(_, eventInfo)
    local s = HR.Runtime.state
    if not s or s.mode ~= "live" then return end
    if type(eventInfo) ~= "table" or eventInfo.id == nil then return end

    -- Ignore les events EN PAUSE a l'ajout : transitoires (annules peu apres). Les traiter
    -- afficherait des doublons et fausserait le compteur de rotation. (cf. BigWigs)
    if ET and ET.GetEventState then
        local ok, st = pcall(ET.GetEventState, eventInfo.id)
        if ok and st == 1 then return end       -- 1 = Paused
    end

    local rem = tonumber(eventInfo.duration) or 0
    if ET and ET.GetEventTimeRemaining then
        local ok, r = pcall(ET.GetEventTimeRemaining, eventInfo.id)
        if ok and type(r) == "number" then rem = r end
    end
    local endTime = GetTime() + rem
    -- (id et duration sont LISIBLES meme en M+ ; spellName/icon secrets -> jamais logges bruts.)
    HR.DevLog("ADDED", "id=%s dur=%s rem=%.2f pass=%s", tostring(eventInfo.id),
        tostring(eventInfo.duration), rem, tostring(s.passthrough))

    if s.passthrough then
        s.active[eventInfo.id] = {
            eventID = eventInfo.id, raw = true,
            icon = eventInfo.iconFileID, name = eventInfo.spellName, endTime = endTime,
        }
        return
    end

    s.recognized  = s.recognized or {}
    s.durCounters = s.durCounters or {}
    s.seen        = s.seen or {}

    -- Anti-doublon / anti-desync : un id DEJA traite (re-ADDED apres pause/resume) ne doit
    -- PAS recompter la rotation ni creer une 2e entree -> on rafraichit juste l'echeance.
    if s.seen[eventInfo.id] then
        HR.DevLog("ADDED", "  id=%s RE-ADD (already seen) -> refresh endTime only", tostring(eventInfo.id))
        if s.recognized[eventInfo.id] then s.recognized[eventInfo.id].endTime = endTime end
        if s.active[eventInfo.id]     then s.active[eventInfo.id].endTime     = endTime end
        return
    end
    s.seen[eventInfo.id] = true

    -- (0) Transition de phase : si cette duree est un marqueur declare (boss.phaseTransitions), on
    -- avance la phase courante AVANT de matcher, pour que l'ouverture de la nouvelle phase resolve
    -- dans le bon scope. Sens unique (> currentPhase) : un marqueur re-fire ou une duree-marqueur
    -- qui recurre en milieu de phase est un no-op. (Place sous le dedup s.seen : pas de re-trigger.)
    local toPhase = HR.PhaseTransitionFor(s.boss, eventInfo.duration)
    if toPhase and toPhase > s.currentPhase then
        s.currentPhase = toPhase
        HR.DevLog("ADDED", "  phase -> %d", toPhase)
        if HR.debug then HR:Debug(("[rt] phase -> %d"):format(toPhase)) end
    end

    -- (1) Le sort entre dans la timeline. (2)+(3) Identification par DUREE (+ compteur de
    -- rotation si la duree ne suffit pas ; + scope de phase si tague). Aucun spellID secret lu.
    local recId, recName, planOk = HR.MatchByDuration(s.boss, eventInfo.duration, s.durCounters, s.currentPhase)
    HR.DevLog("ADDED", "  match dur=%s -> recId=%s recName=%s planOk=%s", tostring(eventInfo.duration),
        tostring(recId), HR.DevSafe(recName), tostring(planOk))

    -- (4) Toujours un doute (duree inconnue ou ambigue) : on n'affiche rien, on logge.
    if not recId then
        HR.DevLog("ADDED", "  UNRECOGNIZED (duree inconnue/ambigue) -> ignore")
        if HR.debug then
            HR:Debug(("[rt] sort non reconnu (duree %.2f)"):format(tonumber(eventInfo.duration) or -1))
        end
        return
    end

    -- (5) Sort trouve : autorise ? (Activer / DB, resolu sur l'id du PLAN s'il existe). Sinon ignore.
    local planId = HR.PlanIdFor(s.boss, recName)
    local sid    = planId or recId
    local ovr    = HR.GetBossSpellOverride(s.encounterID, sid, false)
    HR.DevLog("ADDED", "  planId=%s sid=%s enabled=%s", tostring(planId), tostring(sid),
        tostring(not (ovr and ovr.enabled == false)))
    if ovr and ovr.enabled == false then return end

    -- (6) Nom affiche : custom sinon nom de base. Memorise pour la TIMELINE.
    s.recognized[eventInfo.id] = {
        eventID = eventInfo.id, spellID = sid, name = (ovr and ovr.name) or recName,
        enabled = true, endTime = endTime,
    }

    -- Correspondance EVENTUELLE vers le plan (Upcoming bar + defensifs) : occurrence de CE
    -- sort la plus proche en temps. Pas de correspondance => pas d'entree Upcoming bar.
    -- planOk=false : sort display-only resolu par phase (ex. Gilded Destruction P1) qui partage son
    -- NOM avec une occurrence planifiee d'une autre phase => on affiche (deja fait ci-dessus) mais on
    -- NE relie PAS au plan, sinon le defensif de la P2 fuite en P1.
    if not planId or planOk == false then return end
    local fireRel = (GetTime() - s.pullTime) + rem
    local occ, bestDiff
    for _, o in ipairs(s.planned) do
        if o.spellID == planId then
            local d = math.abs(o.time - fireRel)
            if not bestDiff or d < bestDiff then occ, bestDiff = o, d end
        end
    end
    if not occ then
        HR.DevLog("ADDED", "  planId=%s : AUCUNE occurrence du plan matchee (fireRel=%.2f)", tostring(planId), fireRel)
        return
    end

    local defs = HR.GetAssignments(s.variant, s.encounterID, occ.key)
    HR.DevLog("ADDED", "  -> occ.key=%s name=%s occ.t=%.2f defs=%d (liveDefs repush)",
        HR.DevSafe(occ.key), HR.DevSafe(occ.name), occ.time or -1, #defs)
    if HR.debug then
        HR:Debug(("[rt] %s @%.0fs defs=%d"):format(tostring(occ.name), occ.time, #defs))
    end
    s.active[eventInfo.id] = {
        eventID = eventInfo.id, occ = occ, defs = defs, endTime = endTime,
    }

    -- ETAPE 1 : on SPAWNE les defensifs lies a CET event boss, avec leur temps ABSOLU
    -- (= marqueur applique sur l'instant live `endTime`). Ils vivent dans s.liveDefs et
    -- PERSISTENT independamment (un AFTER_CAST_END survit a la disparition de l'event boss).
    s.liveDefs = s.liveDefs or {}
    -- DEDUP PAR OCCURRENCE : une occurrence du plan = UN seul jeu de defensifs, peu importe
    -- combien d'events serveur y pointent. Le serveur re-diffuse la meme occurrence sous
    -- PLUSIEURS eventID (timeline re-broadcastee), et un RE-ADD apres REMOVED/STATE (s.seen
    -- efface) repasse ici -> sans dedup on empile le meme defensif N fois (bug "Revival x3"
    -- dans l'Upcoming bar / Announcement ; ex-"Darkness x7"). On purge donc TOUS les liveDefs
    -- de CETTE occurrence (occ.key) avant de reposer les siens. Couvre aussi synth-pull vs reel.
    for i = #s.liveDefs, 1, -1 do
        if s.liveDefs[i].occKey == occ.key then table.remove(s.liveDefs, i) end
    end
    local base = HR.OccDefTime(occ, endTime)
    local _, pClass = UnitClass("player")
    for i, e in ipairs(defs) do
        local token  = HR.EntryToken(e)
        local offset = HR.EntryOffset(e)
        local d = HR.defensives[HR.DefKeyOf(token)]
        -- defTime = temps de BASE (SANS offset) ; le moteur HR.Schedule ajoute l'offset pour
        -- le temps effectif (Upcoming/Announcement/son) et IGNORE l'offset pour la Timeline.
        s.liveDefs[#s.liveDefs + 1] = {
            key = "L" .. tostring(eventInfo.id) .. "|" .. i,
            defID = token, defTime = base,
            offset = offset, occKey = occ.key,
            mine = HR.TokenIsMine(token),
            eventID = eventInfo.id, bossName = occ.name,
        }
    end
end)

-- Un event retire/annule/termine doit disparaitre PARTOUT (sinon il persiste jusqu'a son
-- echeance -> "meme sort plusieurs fois qui defile"). On nettoie les 3 tables.
local function ForgetTimelineEvent(s, eventID)
    if not s then return end
    if s.active     then s.active[eventID]     = nil end
    if s.recognized then s.recognized[eventID] = nil end
    if s.seen       then s.seen[eventID]       = nil end
end

HR:RegisterEvent("ENCOUNTER_TIMELINE_EVENT_REMOVED", function(_, eventID)
    local s = HR.Runtime.state
    if s and s.mode == "live" then
        HR.DevLog("REMOVED", "id=%s -> forget (active/recognized/seen)", tostring(eventID))
        ForgetTimelineEvent(s, eventID)
    end
end)

HR:RegisterEvent("ENCOUNTER_TIMELINE_EVENT_STATE_CHANGED", function(_, eventID)
    local s = HR.Runtime.state
    if not s or s.mode ~= "live" or not (ET and ET.GetEventState) then return end
    local ok, st = pcall(ET.GetEventState, eventID)
    -- states : 1=Paused 2=Finished 3=Canceled. Le user signale des Canceled inattendus -> on
    -- logge SYSTEMATIQUEMENT l'etat (meme quand on n'agit pas) pour tracer d'ou ils viennent.
    HR.DevLog("STATE", "id=%s state=%s%s", tostring(eventID), tostring(ok and st or "?"),
        (ok and (st == 2 or st == 3)) and " -> forget" or "")
    if ok and (st == 2 or st == 3) then     -- 2 = Finished, 3 = Canceled
        ForgetTimelineEvent(s, eventID)
    end
end)
