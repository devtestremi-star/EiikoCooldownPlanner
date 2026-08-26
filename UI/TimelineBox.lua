-- HealPlanner - UI/TimelineBox.lua
-- Mode d'affichage ALTERNATIF a l'Upcoming bar : une reproduction de la timeline
-- native de Blizzard. Les capacites poussees par le serveur (events
-- ENCOUNTER_TIMELINE_EVENT_ADDED) apparaissent en haut et DEFILENT vers le bas au
-- fil du temps ; arrivees en bas (instant du cast), elles disparaissent.
--   * AUCUN filtrage : on affiche TOUT ce que le serveur pousse (mode brut,
--     icone/nom = Secret Values affichees mais jamais lues).
--   * En plus des sorts du boss, on POUSSE dans la meme timeline les CD defensifs
--     PLANIFIES (depuis nos donnees), positionnes a leur instant prevu.
-- Active uniquement quand l'option `timelineMode` est on. Fenetre deplacable a part
-- (cle de position "timeline"). N'altere PAS l'Upcoming bar / Communication bar.
local addonName, HR = ...

HR.UI = HR.UI or {}
local UI = HR.UI

HR.Runtime = HR.Runtime or {}

local ET = C_EncounterTimeline

local REBUILD   = 0.05  -- frequence de RECONSTRUCTION de la liste (collecte/tri/glow)
                        -- + re-calage du scroll. Le MOUVEMENT entre deux Rebuild est
                        -- porte par l'animation GPU du strip (fluide), cf. BuildTimeline.
local TL_ICON   = 26    -- taille d'une icone de la timeline
local TL_GAP    = 2     -- ecart entre une icone et la ligne centrale (icones rapprochees)
local TL_W      = TL_ICON * 2 + TL_GAP * 2 + 2  -- 2 colonnes de part et d'autre de la ligne
local TL_H      = 360   -- hauteur de la fenetre (zone de defilement)
local TL_TOPPAD = 14    -- marge haute (entree dans la fenetre)
local TL_BOTPAD = 18    -- marge basse (ligne du "maintenant")
local CENTER_X  = TL_W / 2  -- x de la ligne verticale centrale (boss a gauche / defs a droite)
local STACK_OFF = 0.70      -- decalage vertical des defensifs empiles (% de l'icone)
local THRESHOLD = 5         -- seuil (s) : on declenche un hook quand une icone passe dessous

-- Acces aux options (defauts garantis via DB_DEFAULTS).
local function Opt()
    if not HR.db then return {} end
    HR.db.options = HR.db.options or {}
    return HR.db.options
end

--------------------------------------------------------------------------------
-- Flux des sorts du boss : capacites brutes poussees par le serveur (non filtrees)
-- Table module-locale, alimentee par nos propres handlers d'event (multi-handlers ;
-- independante de la logique de matching de l'Upcoming bar dans RuntimeBox.lua).
--------------------------------------------------------------------------------

local rawEvents = {}    -- [eventID] = { eventID, icon, name, endTime }

local function WipeRaw()
    for k in pairs(rawEvents) do rawEvents[k] = nil end
end

--------------------------------------------------------------------------------
-- Rendu : pool d'icones positionnees par temps restant (0 = bas / window = haut)
--------------------------------------------------------------------------------

-- Reutilise un widget LIBRE (non associe a une icone affichee), sinon en cree un.
-- (Pool par cle, pas par index : une icone garde son widget tant qu'elle est a l'ecran.)
-- `box` = instance cible (timeline reelle OU apercu des settings : multi-instances).
local function AcquireFree(box)
    for _, w in ipairs(box.items) do
        if w._free then w._free = false; return w end
    end
    -- Parente au STRIP (conteneur scrolle par animation), pas a la box.
    local w = CreateFrame("Frame", nil, box.strip)
    w:SetSize(TL_ICON, TL_ICON)
    w:EnableMouse(true)
    w.tex = w:CreateTexture(nil, "ARTWORK")
    w.tex:SetAllPoints()
    w.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    -- Compte a rebours AU CENTRE de l'icone (police/couleur reglees a chaud).
    w.label = w:CreateFontString(nil, "OVERLAY")
    w.label:SetPoint("CENTER", w, "CENTER", 0, 0)
    w.label:SetFont(STANDARD_TEXT_FONT, 14, "OUTLINE")
    -- Nom du sort, a GAUCHE de l'icone (sorts du boss uniquement).
    w.name = w:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    w.name:SetPoint("RIGHT", w, "LEFT", -4, 0)
    w.name:SetJustifyH("RIGHT")
    w.name:SetWordWrap(false)
    HR.SetupGlow(w)
    w:SetScript("OnEnter", function(self)
        if not self._name then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self._name)
        GameTooltip:Show()
    end)
    w:SetScript("OnLeave", function() GameTooltip:Hide() end)
    w._free = false
    box.items[#box.items + 1] = w
    return w
end

-- Applique police (taille) + couleur au compte a rebours. SetFont n'est appele que
-- si la taille change (sur certains clients SetFont reinitialise la couleur du
-- FontString -> on ne le rappelle pas inutilement), SetTextColor toujours.
local function StyleLabel(label, size, col)
    if label._size ~= size then
        label:SetFont(STANDARD_TEXT_FONT, size, "OUTLINE")
        label._size = size
    end
    label:SetTextColor(col[1] or 1, col[2] or 1, col[3] or 1)
end

-- N'appelle ApplyGlow que si l'etat change (evite de relancer l'anim 10x/s).
local function SetGlow(w, on)
    if w._glowOn ~= on then
        if on then HR.StartGlow(w, HR.CompGlow()) else HR.StopGlow(w) end
        w._glowOn = on
    end
end

-- Place une icone a sa position ECRAN voulue, calculee depuis son temps restant :
-- bas (rem 0) -> haut (rem = window). `_extra` = empilement vertical des defs. Appelee
-- chaque frame par Reposition (SetPoint direct, plus d'animation -> rendu == logique).
local function PositionWidget(box, w, window, usableH)
    if not box then return end
    local rem = (w._endTime or 0) - GetTime()
    local screenOff = TL_BOTPAD + (rem / window) * usableH + (w._extra or 0)
    w:ClearAllPoints()
    w:SetPoint(w._anchor or "RIGHT", box.strip, "BOTTOMLEFT", w._ax or 0, screenOff)
end

--------------------------------------------------------------------------------
-- PRODUCTEUR partage de la "timeline du combat" (sorts de BOSS a venir). Source de
-- verite UNIQUE, interrogeable par n'importe quel consommateur (TimelineBox = colonne
-- gauche, et tout consommateur EXTERNE : ex. les progress bars). On ne duplique plus la
-- collecte. Renvoie une liste TRIEE par temps restant, chaque entree :
--   { key (cle stable), rem (s avant le cast), name, icon, spellID, [defs] }
-- Sources selon l'etat : test -> occurrences theoriques (s.timeline) ; passthrough (boss
-- non modelise) -> events serveur bruts (rawEvents ; name/icon = Secret Values affichables
-- mais jamais lues/comparees) ; modelise -> sorts reconnus (s.recognized) + defensifs lies
-- (s.liveDefs, groupes par eventID).
-- `opts` (consommateur barres) :
--   * withDefs : attache `defs` = { {token, icon, mine, eff (absolu), rem}, ... } a chaque entree
--                (defensifs PLANIFIES pour ce sort, pour decorer la barre ; ne cree PAS d'entree).
-- ⚠ Tri par `rem` UNIQUEMENT (number) : aucune comparaison sur name/icon (peuvent etre secrets).
-- Une entree est affichee UNIQUEMENT tant que le sort est dans la timeline backend et pas encore
-- lance (rem dans [0, window]). Des qu'il en sort (cast passe / event retire), la barre disparait
-- (plus de "survie pendant l'execution du CD" -> plus de barre fantome).
function HR.Runtime.TimelineBossEvents(now, window, opts)
    local s = HR.Runtime.state
    local out = {}
    if not s then return out end
    opts   = opts or {}
    now    = now or GetTime()
    window = window or (Opt().timelineWindow or 30)

    -- Decide l'inclusion d'une entree + l'ajoute. `defs` peut etre nil.
    local function consider(key, rem, name, icon, spellID, defs)
        if (rem >= 0) and (rem <= window) then
            -- Couleur de barre choisie par le joueur pour ce sort (bossSpells du profil actif).
            -- nil => le consommateur (ProgressBars) applique HR.DEFAULT_BAR_COLOR.
            local barColor
            if spellID and HR.GetBossSpellOverride then
                local rec = HR.GetBossSpellOverride(s.encounterID, spellID, false)
                barColor = rec and rec.barColor or nil
            end
            out[#out + 1] = { key = key, rem = rem, name = name, icon = icon,
                spellID = spellID, defs = defs, barColor = barColor }
        end
    end

    if s.mode == "test" then
        local elapsed = now - (s.pullTime or now)
        for _, occ in ipairs(s.timeline or {}) do
            local defs
            if opts.withDefs then
                defs = {}
                local base = (s.pullTime or now) + HR.OccDefTime(occ)   -- meme base que HR.Schedule
                for _, e in ipairs(occ.defs or {}) do
                    local token = HR.EntryToken(e)
                    local eff   = base + (HR.EntryOffset(e) or 0) / 1000
                    defs[#defs + 1] = { token = token, icon = HR.GetDirectiveIcon(token),
                        mine = HR.Schedule.IsMine(token), eff = eff, rem = eff - now }
                end
            end
            consider("B" .. tostring(occ.key), occ.time - elapsed, occ.name,
                HR.GetSpellIcon(occ.spellID), occ.spellID, defs)
        end
    elseif s.passthrough then
        for id, ev in pairs(rawEvents) do
            consider("B" .. tostring(id), ev.endTime - now, ev.name, ev.icon, nil, nil)
        end
    else
        -- Modelise : UNIQUEMENT les events reconnus (dans la timeline backend). Les defensifs
        -- planifies (s.liveDefs, groupes par eventID) servent juste a decorer la barre (icones a
        -- droite) ; ils NE creent PLUS de slot : quand l'event boss est retire de s.recognized,
        -- sa barre disparait (plus de fantome "survivant" au cast).
        local byEv
        if opts.withDefs then
            byEv = {}
            for _, ld in ipairs(s.liveDefs or {}) do
                if ld.eventID ~= nil then
                    local g = byEv[ld.eventID]; if not g then g = {}; byEv[ld.eventID] = g end
                    local eff = ld.defTime + (ld.offset or 0) / 1000
                    g[#g + 1] = { token = ld.defID, icon = HR.GetDirectiveIcon(ld.defID),
                        mine = ld.mine, eff = eff, rem = eff - now }
                end
            end
        end
        for id, r in pairs(s.recognized or {}) do
            consider("B" .. tostring(id), r.endTime - now, r.name,
                HR.GetSpellIcon(r.spellID), r.spellID, byEv and byEv[id] or nil)
        end
    end
    table.sort(out, function(a, b) return a.rem < b.rem end)
    -- DEVLOG (change-triggered) : quelle BRANCHE (test/passthrough/modele) et quelles cles sont
    -- vivantes. Revele une entree fantome persistante (ex. "ADDS") ou deux sources melees.
    if opts.withDefs and HR.DevLogEnabled and HR.DevLogEnabled() then
        local branch = (s.mode == "test" and "test") or (s.passthrough and "passthrough") or "modeled"
        local parts = {}
        for _, o in ipairs(out) do parts[#parts + 1] = HR.DevSafe(o.key) end
        table.sort(parts)
        local sig = branch .. "|" .. table.concat(parts, ",")
        if sig ~= HR.Runtime._pbProdSig then
            HR.Runtime._pbProdSig = sig
            HR.DevLog("producer", "branch=%s n=%d keys=[%s]", branch, #out, table.concat(parts, ","))
        end
    end
    return out
end

-- RECONSTRUCTION (throttlee) : collecte/tri/glow/texture. La POSITION n'est PAS posee
-- ici : c'est `Reposition` (chaque frame) qui place chaque icone par SetPoint direct,
-- en fonction de son `rem` courant (plus d'animation Translation -> plus de desync de
-- rendu possible, et GetBottom == position reelle). Chaque icone garde le MEME widget
-- d'un Rebuild a l'autre (map box.active par cle). On memorise sur le widget de quoi le
-- (re)placer chaque frame : `_anchor`, `_ax`, `_extra` (empilement des defs).
local function Rebuild(box)
    if not box then return end
    if box._dragging then return end    -- drag en cours : pas de relayout (les icones suivent la boite)
    local s = HR.Runtime.state
    -- TIMELINE TOUJOURS VIVANTE : la logique (matching -> defensifs lies -> hook de seuil)
    -- tourne des qu'il y a un encounter, MEME si la Timeline est masquee (alpha 0). Seule
    -- la VISIBILITE depend de `timelineMode` (HR.Runtime.UpdateVisibility) ; l'Upcoming box
    -- consomme les hooks emis ici. -> condition d'activite = simplement un state present.
    local active = (s ~= nil)
    if not active then
        for _, w in ipairs(box.items) do w:Hide(); w._free = true; SetGlow(w, false) end
        wipe(box.active)
        return
    end

    local o       = Opt()
    -- Masquee (timelineMode off) : icones click-through (sinon elles captureraient le survol
    -- et afficheraient des tooltips invisibles a alpha 0).
    local tlVisible = (o.timelineMode == true)
    local window  = o.timelineWindow or 30
    local nowT    = GetTime()
    local txtSize = HR.CompGet("timeline", "textSize")
    local txtCol  = HR.CompGet("timeline", "textColor")
    local base    = box.strip:GetFrameLevel()

    -- 1) Items desires dans la fenetre [0, window] -> desired[key] = descripteur.
    --    `extra` = empilement vertical des defs (porte sur le widget pour Reposition).
    local desired = {}
    local function place(key, rem, extra, descr)
        descr.endTime = nowT + rem
        descr.extra   = extra or 0
        desired[key]  = descr
    end

    -- Sorts du boss (colonne GAUCHE) : consommes depuis le PRODUCTEUR partage
    -- (HR.Runtime.TimelineBossEvents) -> source de verite unique, partagee avec les autres
    -- consommateurs (ex. progress bars). La TimelineBox n'habille que la presentation.
    for _, ev in ipairs(HR.Runtime.TimelineBossEvents(nowT, window)) do
        place(ev.key, ev.rem, 0, {
            icon = ev.icon, name = ev.name,
            anchor = "RIGHT", ax = CENTER_X - TL_GAP, level = base + 1,
            showLabel = true, isBoss = true, glow = false })
    end

    -- Defensifs (colonne DROITE) : lus dans le moteur de planning (HR.Schedule), positionnes
    -- par leur baseTime -> la timeline IGNORE l'offset (les defensifs d'un meme sort restent
    -- GROUPES au temps du sort ; l'offset n'agit que sur l'Upcoming/Announcement/son). TEST et
    -- LIVE unifies (le moteur lit s.timeline / s.liveDefs). Groupes par instant (mine en 1er).
    local defItems = {}
    local function pushDef(key, rem, icon, name, mine, defID, bossName)
        defItems[#defItems + 1] = { key = key, rem = rem, icon = icon, name = name,
            mine = mine, defID = defID, bossName = bossName, ord = #defItems + 1 }
    end
    for _, e in ipairs(HR.Schedule.Active(nowT)) do
        local rem = e.baseTime - nowT          -- baseTime = temps du defensif SANS offset
        if rem >= 0 and rem <= window then
            local d = HR.defensives[HR.DefKeyOf(e.token)]
            pushDef("D" .. tostring(e.occKey) .. "|" .. tostring(e.token), rem,
                HR.GetDirectiveIcon(e.token),                      -- SMALL_DEF => icone du perso "main"
                (d and d.name) or tostring(e.token),
                e.mine, e.token, e.bossName)
        end
    end
    local groups = {}
    for _, it in ipairs(defItems) do
        local k = string.format("%.3f", it.rem)
        local g = groups[k]; if not g then g = {}; groups[k] = g end
        g[#g + 1] = it
    end
    for _, g in pairs(groups) do
        table.sort(g, function(a, b)
            if (a.mine == true) ~= (b.mine == true) then return a.mine == true end
            return a.ord < b.ord
        end)
        for idx, it in ipairs(g) do
            local first = (idx == 1)
            place(it.key, it.rem, (idx - 1) * (TL_ICON * STACK_OFF), {
                icon = it.icon, name = it.name, defID = it.defID, bossName = it.bossName,
                anchor = "LEFT", ax = CENTER_X + TL_GAP, level = base + 2 + (#g - idx),
                showLabel = first, isBoss = false, glow = (first and it.mine == true) })
        end
    end

    -- 2) Retrait des icones actives devenues non desirees (libere le widget).
    for key, w in pairs(box.active) do
        if not desired[key] then
            w:Hide(); w._free = true; SetGlow(w, false); box.active[key] = nil
        end
    end

    -- 3) Placement / mise a jour. On memorise sur le widget de quoi le placer chaque
    --    frame (_anchor/_ax/_extra) ; la POSITION effective est posee par Reposition.
    for key, d in pairs(desired) do
        local w = box.active[key]
        local isNew = (w == nil)
        -- _fired5 = edge du seuil 5s ; remis a false UNIQUEMENT quand le widget recoit
        -- une NOUVELLE icone (sinon l'etat persiste tant que l'icone est a l'ecran).
        if isNew then w = AcquireFree(box); box.active[key] = w; w._fired5 = false end
        w.tex:SetTexture(d.icon or 134400)
        w._name, w._endTime, w._showLabel = d.name, d.endTime, d.showLabel
        w._isBoss, w._glow = d.isBoss, d.glow      -- contexte pour le hook de seuil
        w._defID, w._bossName = d.defID, d.bossName -- (defensif) pour l'Upcoming box / hook
        w._anchor, w._ax, w._extra = d.anchor, d.ax, d.extra   -- pour le placement par frame
        w:EnableMouse(tlVisible)                    -- click-through quand la Timeline est masquee
        w:SetFrameLevel(d.level)
        if d.showLabel then StyleLabel(w.label, txtSize, txtCol); w.label:Show()
        else w.label:Hide() end
        -- Nom a GAUCHE de l'icone, UNIQUEMENT pour les sorts de boss (sauf si "Hide boss spell
        -- name"). Les defensifs n'affichent JAMAIS leur nom dans la timeline (icone seule ; survol).
        if d.isBoss and not o.timelineHideBossName then
            w.name:ClearAllPoints()
            w.name:SetPoint("RIGHT", w, "LEFT", -4, 0)
            w.name:SetJustifyH("RIGHT")
            w.name:SetText(d.name)
            w.name:Show()
        else
            w.name:Hide()
        end
        SetGlow(w, d.glow)
        w:Show()
        -- Position : posee par Reposition, appele juste apres Rebuild dans le meme OnUpdate
        -- (avant le rendu) -> pas de flash pour une icone nouvelle/recyclee.
    end
end

--------------------------------------------------------------------------------
-- Bus de hooks de timeline : plusieurs ACTIONS (glow renforce, son, alerte, /yell,
-- flash...) peuvent s'abonner et recevoir les evenements de la timeline. Les actions
-- concretes seront branchees plus tard ; ici on pose juste le bus + le dispatch.
--   evt = { type, threshold, name, isBoss, mine, endTime, widget }
--     type = "threshold" : une icone vient de passer SOUS le seuil (THRESHOLD s).
--   ⚠ pour un sort de BOSS, `name` peut etre une Secret Value (affichable mais pas
--     comparable / non utilisable comme cle) ; `isBoss`/`mine` sont surs.
--------------------------------------------------------------------------------

HR.Runtime.timelineHooks = HR.Runtime.timelineHooks or {}

-- Enregistre une action `fn(evt)`. Renvoie fn (pratique pour la desinscription).
function HR.Runtime.RegisterTimelineHook(fn)
    if type(fn) == "function" then
        HR.Runtime.timelineHooks[#HR.Runtime.timelineHooks + 1] = fn
    end
    return fn
end

-- Diffuse un evenement a tous les hooks. Chacun sous pcall : un hook fautif n'impacte
-- ni les autres ni le rendu.
function HR.Runtime.FireTimelineEvent(evt)
    local hooks = HR.Runtime.timelineHooks
    for i = 1, #hooks do
        local ok, err = pcall(hooks[i], evt)
        if not ok and HR.debug then HR:Debug("[tl hook] " .. tostring(err)) end
    end
end

-- Hook par defaut : simple trace de debug (preuve que le bus tourne ; a remplacer par
-- les vraies actions plus tard).
HR.Runtime.RegisterTimelineHook(function(evt)
    if HR.debug and evt.type == "threshold" then
        HR:Debug(("[tl] <%ds : %s (%s)"):format(evt.threshold, tostring(evt.name),
            evt.isBoss and "boss" or "def"))
    end
end)

-- Par frame : POSITIONNE chaque icone (SetPoint direct depuis son rem courant), rafraichit
-- le chiffre du timer, masque les icones passees sous la ligne "maintenant", et detecte le
-- franchissement du seuil (edge -> hook une seule fois par icone). Plus d'animation : la
-- position ecran est recalculee ici a chaque frame (fluide, sub-pixel, jamais desynchronisee).
local function Reposition(box)
    if not box or not box.active then return end
    if box._dragging then return end    -- drag : les icones suivent rigidement la fenetre
    local o       = Opt()
    local now     = GetTime()
    local window  = o.timelineWindow or 30
    local usableH = box:GetHeight() - TL_TOPPAD - TL_BOTPAD
    -- Seuil de tir des edges de BOSS (debug). Les edges de DEFENSIFS (son/TTS/upcoming) ne
    -- viennent plus d'ici : le moteur HR.Schedule les tire (au temps EFFECTIF, offset compris).
    local threshold = o.upcomingThreshold or THRESHOLD
    if o.announceDisabled ~= true then
        threshold = math.max(threshold, o.announceThreshold or 0)
    end
    for _, w in pairs(box.active) do
        local rem = w._endTime - now
        if rem < 0 then
            if w:IsShown() then w:Hide() end
        else
            PositionWidget(box, w, window, usableH)   -- position ecran = f(rem) chaque frame
            -- Franchissement du seuil : rem deja calcule chaque frame -> simple edge.
            -- On diffuse un evenement sur le bus de hooks (actions branchees plus tard).
            if w._isBoss and rem <= threshold and not w._fired5 then
                w._fired5 = true
                HR.Runtime.FireTimelineEvent({
                    type = "threshold", threshold = threshold,
                    name = w._name, isBoss = true, mine = w._glow,
                    bossName = w._bossName, endTime = w._endTime, widget = w,
                })
            end
            if w._showLabel then w.label:SetText(tostring(math.ceil(rem))) end
            if not w:IsShown() then w:Show() end
        end
    end
end

local function OnUpdate(self, dt)
    self._acc = (self._acc or 0) + dt
    if self._acc >= REBUILD then
        self._acc = 0
        Rebuild(self)
    end
    Reposition(self)        -- a chaque frame : mouvement fluide
end

--------------------------------------------------------------------------------
-- Options : application a chaud (scale, couleur de fond)
--------------------------------------------------------------------------------

-- Applique la composition a la timeline.
local function ApplyTLBox(box)
    if not box then return end
    HR.SetFrameScaleInPlace(box, HR.CompGet("timeline", "scale") or 1.0)   -- rescale SANS deplacer
    HR.SaveFramePos("timeline", box)                                       -- persiste la pos
    local bg = HR.CompGet("timeline", "bgColor")
    if box.bg then box.bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4] or 1) end
    local bc = HR.CompGet("timeline", "borderColor")
    local bt = HR.CompGet("timeline", "borderThickness") or 0
    if box.edges then
        local e = box.edges
        e.top:ClearAllPoints();    e.top:SetPoint("TOPLEFT");    e.top:SetPoint("TOPRIGHT");    e.top:SetHeight(bt)
        e.bottom:ClearAllPoints(); e.bottom:SetPoint("BOTTOMLEFT"); e.bottom:SetPoint("BOTTOMRIGHT"); e.bottom:SetHeight(bt)
        e.left:ClearAllPoints();   e.left:SetPoint("TOPLEFT");   e.left:SetPoint("BOTTOMLEFT");  e.left:SetWidth(bt)
        e.right:ClearAllPoints();  e.right:SetPoint("TOPRIGHT"); e.right:SetPoint("BOTTOMRIGHT"); e.right:SetWidth(bt)
        for _, t in pairs(e) do t:SetColorTexture(bc[1], bc[2], bc[3], bc[4] or 1); t:SetShown(bt > 0) end
    end
    local ts, tc = HR.CompGet("timeline", "textSize"), HR.CompGet("timeline", "textColor")
    for _, w in ipairs(box.items) do
        if w.label then StyleLabel(w.label, ts, tc) end                  -- countdown : taille/couleur des settings
    end
    -- "Hide boss spell name" : applique tout de suite aux icones de boss affichees.
    local hideName = Opt().timelineHideBossName
    for _, w in pairs(box.active or {}) do
        if w.name then w.name:SetShown(w._isBoss and not hideName) end
    end
end

function HR.Runtime.ApplyTimelineOptions()
    ApplyTLBox(UI.timelineBox)
end

-- Refresh MANUEL : libere toutes les icones -> le prochain rendu re-pose tout proprement.
-- (Le bouton au-dessus de la timeline appelle ceci.) Avec le placement par frame ce n'est
-- plus necessaire pour corriger un bug, mais le bouton sert aussi de poignee de deplacement.
function HR.Runtime.RefreshTimeline()
    local box = UI.timelineBox
    if not box then return end
    for _, w in ipairs(box.items) do w:Hide(); w._free = true; SetGlow(w, false) end
    wipe(box.active)
end

--------------------------------------------------------------------------------
-- Construction de la fenetre
--------------------------------------------------------------------------------


local function BuildTimeline()
    -- Fond TRANSPARENT (pas de backdrop) : seules la ligne centrale et les icones sont visibles.
    local f = CreateFrame("Frame", "HealPlannerTimelineBox", UIParent)
    f:SetSize(TL_W, TL_H)
    f:SetPoint("LEFT", UIParent, "LEFT", 40, 0)
    f:SetFrameStrata("BACKGROUND")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(false)        -- click-through (plus de poignee de deplacement)
    -- Fond + bordure (4 cotes), colores/dimensionnes par ApplyTimelineOptions (composition).
    f.bg = f:CreateTexture(nil, "BACKGROUND"); f.bg:SetAllPoints()
    f.edges = {}
    for _, k in ipairs({ "top", "bottom", "left", "right" }) do f.edges[k] = f:CreateTexture(nil, "ARTWORK") end

    -- Bouton de REFRESH (au-dessus de la timeline) + poignee de deplacement (la timeline est
    -- click-through) : clic = refresh, glisser = deplacer.
    f.refreshBtn = CreateFrame("Button", nil, f)
    f.refreshBtn:SetSize(54, 16)
    f.refreshBtn:SetPoint("BOTTOM", f, "TOP", 0, 1)
    f.refreshBtn:SetFrameStrata("MEDIUM")
    f.refreshBtn.bg = f.refreshBtn:CreateTexture(nil, "BACKGROUND"); f.refreshBtn.bg:SetAllPoints(); f.refreshBtn.bg:SetColorTexture(0.15, 0.15, 0.15, 0.9)
    f.refreshBtn.t = f.refreshBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); f.refreshBtn.t:SetPoint("CENTER"); f.refreshBtn.t:SetText("refresh")
    f.refreshBtn:SetScript("OnClick", function() if HR.Runtime.RefreshTimeline then HR.Runtime.RefreshTimeline() end end)
    f.refreshBtn:RegisterForDrag("LeftButton")
    f.refreshBtn:SetScript("OnDragStart", function()
        if not HR.Runtime.AnchorsVisible() then return end                 -- drag en mode ancres seulement
        f:StartMoving(); f._dragging = true   -- _dragging : les icones suivent la fenetre
    end)
    f.refreshBtn:SetScript("OnDragStop", function()
        f:StopMovingOrSizing(); f._dragging = false
        HR.SaveFramePosTopLeft("timeline", f)   -- ancre TOPLEFT harmonisee (rescale in place)
    end)
    f.refreshBtn:SetScript("OnEnter", function(self)
        self.bg:SetColorTexture(0.28, 0.28, 0.3, 0.95)         -- survol : leger eclaircissement
        GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText("Refresh timeline"); GameTooltip:AddLine("Drag to move", 0.8, 0.8, 0.8); GameTooltip:Show()
    end)
    f.refreshBtn:SetScript("OnLeave", function(self)
        self.bg:SetColorTexture(0.15, 0.15, 0.15, 0.9)
        GameTooltip:Hide()
    end)
    f.refreshBtn:Hide()   -- montre par UpdateVisibility quand la timeline est affichee

    -- Ligne VERTICALE centrale : separe sorts du boss (gauche) / defensifs (droite).
    f.centerLine = f:CreateTexture(nil, "ARTWORK")
    f.centerLine:SetColorTexture(0.85, 0.85, 0.85, 0.55)
    f.centerLine:SetWidth(1)
    f.centerLine:SetPoint("TOP", f, "TOPLEFT", CENTER_X, -6)
    f.centerLine:SetPoint("BOTTOM", f, "BOTTOMLEFT", CENTER_X, TL_BOTPAD)

    -- STRIP : conteneur fixe des icones (positionnees par SetPoint chaque frame, cf. Reposition).
    f.strip = CreateFrame("Frame", nil, f)
    f.strip:SetSize(TL_W, TL_H)
    f.strip:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)

    f.items = {}        -- pool de widgets (reutilises via _free)
    f.active = {}       -- icones affichees : cle stable -> widget
    f:SetScript("OnUpdate", OnUpdate)
    UI.timelineBox = f
    -- Echelle AVANT restore = MEME source que ApplyTLBox (composition) : sinon SetFrameScaleInPlace
    -- y recalerait l'offset (legacy/composition) a chaque init -> derive cumulative au reload.
    f:SetScale(HR.CompGet("timeline", "scale") or 1.0)
    HR.RestoreFramePos("timeline", f)
    HR.Runtime.ApplyTimelineOptions()
    f:Show()
end

-- Construit la fenetre Timeline HORS COMBAT (appelee depuis HR.Runtime.PreBuild).
function HR.Runtime.PreBuildTimeline()
    if not UI.timelineBox then BuildTimeline() end
end

--------------------------------------------------------------------------------
-- Evenements : flux brut des capacites serveur (collecte permanente, non filtree)
--------------------------------------------------------------------------------

HR:RegisterEvent("ENCOUNTER_START", function() WipeRaw() end)
HR:RegisterEvent("ENCOUNTER_END", function() WipeRaw() end)

HR:RegisterEvent("ENCOUNTER_TIMELINE_EVENT_ADDED", function(_, eventInfo)
    local s = HR.Runtime.state
    if not s or s.mode ~= "live" then return end
    if type(eventInfo) ~= "table" or eventInfo.id == nil then return end
    local rem = tonumber(eventInfo.duration) or 0
    if ET and ET.GetEventTimeRemaining then
        local ok, r = pcall(ET.GetEventTimeRemaining, eventInfo.id)
        if ok and type(r) == "number" then rem = r end
    end
    rawEvents[eventInfo.id] = {
        eventID = eventInfo.id,
        icon    = eventInfo.iconFileID,     -- Secret Value possible : affichee, jamais lue
        name    = eventInfo.spellName,      -- idem
        endTime = GetTime() + rem,
    }
end)

HR:RegisterEvent("ENCOUNTER_TIMELINE_EVENT_REMOVED", function(_, eventID)
    rawEvents[eventID] = nil
end)
