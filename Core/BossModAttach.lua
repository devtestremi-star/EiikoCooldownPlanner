-- EiikoCooldownPlanner - BossModAttach.lua
-- ACCROCHE les defensifs planifies aux barres des AUTRES bossmods : chaque barre de capacite
-- de boss recoit, collee a sa droite, les icones des CD prevus par le plan pour CETTE
-- occurrence. Option UNIQUE : HR.db.options.attachDefsToBossMods.
--
-- DEUX sources, decorees INDEPENDAMMENT (un joueur qui fait tourner les deux bossmods voit
-- ses icones sur les deux jeux de barres) :
--   A. BigWigs / LittleWigs -> message `BigWigs_BarCreated`, teardown `LibCandyBar_Stop`
--   B. DBM                  -> callback `DBM_TimerBegin` + `DBT:GetBar(id)`,
--                              teardown `bar:SetCallback` (aucun evenement de fin naturelle)
--
-- EXCLUSIF avec hideOtherBossMods (cf. Core/ForeignBars.lua) : masquer les barres et les
-- decorer n'a aucun sens ensemble. L'exclusivite est resolue A LA LECTURE (Enabled() de
-- ForeignBars teste notre option), JAMAIS par reecriture de la DB du joueur.
--
-- INTERDIT ici, comme dans ForeignBars : ecrire dans la SavedVariable d'un autre addon
-- (BigWigs3DB, DBM_AllSavedOptions...), patcher leur code, ou appeler BigWigs:NewPlugin
-- (BigWigs_Core est LoadOnDemand et notre DB atterrirait chez lui). Tout est runtime-only.
--
-- LE POINT DUR : relier une barre a une occurrence du plan. Voir ResolveBar().
local addonName, HR = ...

HR.BossModAttach = HR.BossModAttach or {}
local BMA = HR.BossModAttach

-- Table cible de BigWigsLoader.RegisterMessage (le loader refuse BigWigsLoader lui-meme),
-- et de LibCandyBar.RegisterCallback.
local bwProxy = {}

-- RENDU : strictement calque sur les Progress bars ECP (UI/ProgressBars.lua:107-127,
-- fonction StyleBar) pour que les icones soient indiscernables d'une barre a l'autre.
-- Textures brutes (pas de Frame), taille = hauteur de la barre SANS PLAFOND, gap 2, crop
-- 0.08-0.92, desaturation quand le defensif est passe, alpha 1 (mien) / 0.85 (autre).
-- Volontairement ABSENTS, comme sur les Progress bars : bandeau, texte d'offset, glow, tooltip.
local ICON_GAP   = 2       -- ecart entre icones ET ecart barre -> 1re icone (cf. StyleBar)
local FALLBACK_H = 22      -- hauteur si la barre ne la donne pas (= defaut progressBarHeight)
local RETRY      = 0.25    -- periode de re-resolution tant que la barre n'est pas liee
local RECONCILE  = 1.5     -- tolerance (s) pour reconcilier avec une occurrence deja liee
local STORE_KEY  = "eiiko:defs"

local function Enabled()
    -- GATE DE ZONE (imposee, pas une option) : hors d'un donjon de HR.content, l'addon est
    -- DORMANT. `Live()` ci-dessous le couvrait deja par EFFET DE BORD (pas d'etat runtime hors
    -- donjon) ; la garde explicite rend l'intention lisible et symetrique de ForeignBars.
    -- FAIL-CLOSED : cf. Core/ForeignBars.lua (ce fichier est charge AVANT UI/RuntimeBox.lua).
    if not (HR.RuntimeAllowed and HR.RuntimeAllowed()) then return false end
    local o = HR.db and HR.db.options
    return (o and o.attachDefsToBossMods == true) or false
end

-- Etat runtime exploitable : en combat LIVE, sur un boss modelise (passthrough = boss non
-- decrit -> aucun plan a afficher).
local function Live()
    local s = HR.Runtime and HR.Runtime.state
    if not s or s.mode ~= "live" or s.passthrough then return nil end
    if not s.boss or not s.planned then return nil end
    return s
end

--------------------------------------------------------------------------------
-- Resolution : barre BigWigs -> occurrence du plan
--------------------------------------------------------------------------------
-- Cascade a 3 niveaux, du plus sur au plus souple.
--
-- ATTENTION : ne PAS utiliser HR.MatchByDuration ici. Il est calibre sur les durees
-- d'annonce de C_EncounterTimeline (champ `durations` de Data/Content.lua) ; une barre
-- BigWigs classique tire sa duree du CODE DU MODULE BW (self:Bar(spellId, 25.6)), source
-- totalement differente. Les deux coincident parfois par hasard, jamais de facon fiable.

-- Niveau 1 : le plugin Timeline de BigWigs re-emet les events C_EncounterTimeline et pose
-- leur id sur la barre. C'est EXACTEMENT la cle de s.active -> lien direct, zero ambiguite.
local function ResolveByEventId(s, bar)
    if not bar.Get then return nil end
    local ok, eventId = pcall(bar.Get, bar, "bigwigs:eventId")
    if not ok or not eventId then return nil end
    local a = s.active[eventId]
    if a and a.occ then return a.occ, a.defs, "evt", eventId end
    return nil
end

-- Niveaux 2 et 3 : identifier le SORT.
--   2. key numerique > 0 = spellID (litteral du module BW, PAS une Secret Value : c'est
--      l'avantage decisif sur le chemin serveur).
--   3. repli par NOM via l'index planIdByName deja construit par le Matcher. Couvre le cas
--      frequent ou BW et ECP n'utilisent pas le meme spellID pour la meme capacite (cast id
--      vs damage id) : les deux affichent le meme nom.
local function ResolvePlanId(s, key, text)
    if type(key) == "number" and key > 0 then
        -- le spellID BW n'est retenu que s'il existe vraiment dans notre plan
        for _, o in ipairs(s.planned) do
            if o.spellID == key then return key, "id" end
        end
    end
    if type(text) == "string" and text ~= "" and HR.PlanIdFor then
        local id = HR.PlanIdFor(s.boss, text)
        if id then return id, "name" end
    end
    return nil
end

-- Quelle OCCURRENCE de ce sort ? `endAbs` = instant d'expiration de la barre (GetTime abs).
-- D'abord RECONCILIATION avec ce qui est deja lie cote ECP : si une entree de s.active
-- porte ce sort et expire au meme moment, on reutilise SON occurrence -> la barre BW et la
-- Personal Timeline designent la meme, jamais deux voisines.
-- Sinon, plus proche en temps dans s.planned (meme formule que le handler
-- ENCOUNTER_TIMELINE_EVENT_ADDED de UI/RuntimeBox.lua).
local function FindOcc(s, planId, endAbs)
    for evId, a in pairs(s.active) do
        if a.occ and a.occ.spellID == planId and a.endTime
           and math.abs(a.endTime - endAbs) < RECONCILE then
            return a.occ, a.defs, evId
        end
    end

    local fireRel = endAbs - s.pullTime
    local occ, bestDiff
    for _, o in ipairs(s.planned) do
        if o.spellID == planId then
            local d = math.abs(o.time - fireRel)
            if not bestDiff or d < bestDiff then occ, bestDiff = o, d end
        end
    end
    if not occ then return nil end
    return occ, HR.GetAssignments(s.variant, s.encounterID, occ.key)
end

-- Renvoie (occ, defs, mode, evId) ou nil. `endAbs` = GetTime() + temps restant de la barre.
-- `evId` (eventID serveur) n'est renseigne que si l'occurrence est deja liee cote ECP : il
-- permet de reprendre les temps DEJA CALCULES dans s.liveDefs (cf. BuildDisplayDefs).
local function ResolveBar(s, bar, key, text, endAbs)
    local occ, defs, mode, evId = ResolveByEventId(s, bar)
    if occ then return occ, defs, mode, evId end

    local planId
    planId, mode = ResolvePlanId(s, key, text)
    if not planId then return nil end

    occ, defs, evId = FindOcc(s, planId, endAbs)
    if not occ then return nil end
    return occ, defs, mode, evId
end

--------------------------------------------------------------------------------
-- Liste d'affichage : meme FORME que le producteur partage
--------------------------------------------------------------------------------
-- Les Progress bars consomment HR.Runtime.TimelineBossEvents(.., {withDefs=true})
-- (UI/TimelineBox.lua:140), qui produit { token, icon, mine, eff (absolu), rem }. Ce
-- producteur est indexe par EVENEMENT, pas par barre : on ne peut pas l'appeler ici. On
-- reproduit donc sa forme ET sa formule de `eff`, a l'identique, pour garantir la parite.
local function BuildDisplayDefs(s, occ, defs, evId, endAbs)
    local out = {}

    -- Cas courant : l'occurrence est deja liee -> s.liveDefs porte defTime/offset/mine DEJA
    -- calcules par RuntimeBox.lua:1335. Memes valeurs, meme origine que la Progress bar.
    if evId ~= nil then
        for _, ld in ipairs(s.liveDefs or {}) do
            if ld.eventID == evId then
                out[#out + 1] = {
                    icon = HR.GetDirectiveIcon(ld.defID),
                    mine = ld.mine,
                    eff  = ld.defTime + (ld.offset or 0) / 1000,   -- TimelineBox.lua:196
                }
            end
        end
        if #out > 0 then return out end
    end

    -- Repli : barre resolue par spellID/nom, aucun event serveur encore lie. On recalcule la
    -- base comme RuntimeBox (HR.OccDefTime applique le defMarker sur l'instant de cast reel).
    local base = HR.OccDefTime(occ, endAbs)
    for _, e in ipairs(defs or {}) do
        local token = HR.EntryToken(e)
        if token then
            out[#out + 1] = {
                icon = HR.GetDirectiveIcon(token),
                mine = HR.TokenIsMine(token),
                eff  = base + (HR.EntryOffset(e) or 0) / 1000,
            }
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- Pool de decorations
--------------------------------------------------------------------------------
-- Les barres LibCandyBar sont POOLEES et Stop() ne detache PAS les enfants : sans teardown
-- explicite, notre frame reapparait sur une barre recyclee sans rapport. Notre teardown :
-- ClearAllPoints + SetParent(UIParent) + Hide + retour au pool.

local pool = {}
local live = {}   -- [frame] = true : decorations actuellement attachees a une barre

-- TEXTURE brute, comme StyleBar (ProgressBars.lua:115) : pas de Frame, pas de glow, pas de
-- label. Le seul ecart est le parent (notre conteneur au lieu du StatusBar de la barre).
local function AcquireIcon(f, i)
    local ic = f.icons[i]
    if not ic then
        ic = f:CreateTexture(nil, "OVERLAY")
        ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        f.icons[i] = ic
    end
    return ic
end

-- IDEMPOTENT : une decoration DBM peut etre liberee deux fois (callback "Cancel" PUIS
-- ReleaseAll sur un kill/wipe). Sans ce garde-fou, la meme frame serait empilee deux fois
-- dans le pool et servirait deux barres a la fois.
local function ReleaseDeco(f)
    if not live[f] then return end
    for _, ic in ipairs(f.icons) do ic:Hide() end
    f:ClearAllPoints()
    f:SetParent(UIParent)
    f:Hide()
    f.bar, f.linked, f.endAbs, f.key, f.text = nil, nil, nil, nil, nil
    f.anchorTo, f.padX = nil, nil
    live[f] = nil
    pool[#pool + 1] = f
end

local function AcquireDeco()
    local f = table.remove(pool)
    if not f then
        f = CreateFrame("Frame", nil, UIParent)
        f.icons = {}
    end
    f.linked = false
    live[f] = true
    f:Show()
    return f
end

--------------------------------------------------------------------------------
-- Rendu
--------------------------------------------------------------------------------

-- Taille/position des icones. La hauteur est relue A CHAQUE FOIS sur la frame d'ancrage :
-- c'est ce qui fait suivre les redimensionnements silencieux, dans les DEUX bossmods --
-- emphasize BigWigs, et migration small -> huge de DBM (toute barre DBM y passe sous
-- ~9,9 s). Aucun des deux ne notifie les frames attachees.
local function LayoutIcons(f)
    local h
    if f.anchorTo then
        local ok, bh = pcall(f.anchorTo.GetHeight, f.anchorTo)
        if ok and bh and bh > 0 then h = bh end
    end
    h = h or f.barH or FALLBACK_H
    f.barH = h

    local n = 0
    for _, ic in ipairs(f.icons) do
        if ic:IsShown() then
            n = n + 1
            ic:SetSize(h, h)
            ic:ClearAllPoints()
            ic:SetPoint("LEFT", f, "LEFT", (n - 1) * (h + ICON_GAP), 0)
        end
    end
    if n > 0 then f:SetWidth(n * h + (n - 1) * ICON_GAP) end
    return n
end

-- Pose les icones. `list` = sortie de BuildDisplayDefs ({ icon, mine, eff }).
-- Calque de StyleBar (ProgressBars.lua:107-127) : taille = hauteur de la barre SANS plafond,
-- gap 2, desaturation si le defensif est passe, alpha 1 (mien) / 0.85 (autre).
local function RenderDefs(f, list)
    local n = #list
    for j = 1, n do
        local d  = list[j]
        local ic = AcquireIcon(f, j)
        ic:SetTexture(d.icon or 134400)
        ic:SetAlpha(d.mine and 1 or 0.85)
        ic.eff = d.eff
        ic:Show()
    end
    for j = n + 1, #f.icons do f.icons[j]:Hide() end
    if n == 0 then f:Hide() return false end
    LayoutIcons(f)
    f:Show()
    return true
end

-- Desaturation des defensifs deja passes (ProgressBars.lua:123) + suivi de la hauteur de la
-- barre. C'est tout ce qui evolue dans le temps ; rafraichi par le driver.
-- Renvoie true s'il reste au moins une icone a venir (donc du travail pour le driver).
local function RefreshDeco(f, now)
    local pending = false
    for _, ic in ipairs(f.icons) do
        if ic:IsShown() and ic.eff then
            local rem = ic.eff - now
            ic:SetDesaturated(rem < 0)
            if rem >= 0 then pending = true end
        end
    end
    -- La barre a-t-elle change de taille ? (emphasize BigWigs / small->huge DBM)
    if f.anchorTo then
        local ok, bh = pcall(f.anchorTo.GetHeight, f.anchorTo)
        if ok and bh and bh > 0 and math.abs(bh - (f.barH or 0)) > 0.5 then
            LayoutIcons(f)
        end
    end
    return pending
end

-- Ancrage sur les DEUX bords verticaux (pattern BarStyles.lua:131) : la hauteur suit la
-- barre toute seule. `anchorTo` = la frame dont on longe le bord DROIT (barre BigWigs, ou
-- StatusBar interne d'une barre DBM) ; `padX` = ecart horizontal (DBM peut avoir une icone
-- a droite de la barre, il faut la contourner).
local function AnchorDeco(f, anchorTo, padX)
    f.anchorTo = anchorTo
    f.padX     = padX or ICON_GAP
    f:ClearAllPoints()
    -- ICON_GAP en X = le `gap` de StyleBar : la 1re icone est a 2 px du bord droit de la barre.
    f:SetPoint("TOPLEFT", anchorTo, "TOPRIGHT", f.padX, 0)
    f:SetPoint("BOTTOMLEFT", anchorTo, "BOTTOMRIGHT", f.padX, 0)
    local ok, lvl = pcall(anchorTo.GetFrameLevel, anchorTo)
    if ok and lvl then f:SetFrameLevel(lvl + 5) end
    LayoutIcons(f)
end

-- Driver de re-resolution. Une frame decoration reste CACHEE tant qu'aucun defensif n'est
-- resolu, et OnUpdate NE SE DECLENCHE PAS sur une frame cachee -> on ne peut pas porter la
-- re-tentative sur la decoration elle-meme. Un seul driver toujours visible balaye donc les
-- decorations non liees, et s'arrete des qu'il n'y en a plus (zero cout au repos).
local driver = CreateFrame("Frame", nil, UIParent)
driver:Hide()

local TryLink   -- forward (le driver l'appelle, elle est definie juste apres)

local function PumpDriver()
    local acc = 0
    driver:SetScript("OnUpdate", function(self, dt)
        acc = acc + dt
        if acc < RETRY then return end
        acc = 0
        local now, pending = GetTime(), false
        for f in pairs(live) do
            if not f.linked then
                -- pas encore liee : on re-tente (BW demarre souvent sa barre avant l'event)
                if not (f.bar and TryLink(f)) then pending = true end
            elseif RefreshDeco(f, now) then
                -- liee, mais il reste des defensifs a venir -> desaturation a mettre a jour
                pending = true
            end
        end
        if not pending then
            self:SetScript("OnUpdate", nil)
            self:Hide()
        end
    end)
    driver:Show()
end

function TryLink(f)
    local s = Live()
    if not s then return false end
    local occ, defs, mode, evId = ResolveBar(s, f.bar, f.key, f.text, f.endAbs)
    if not occ then return false end
    f.linked = true
    local list = BuildDisplayDefs(s, occ, defs, evId, f.endAbs)
    HR:Debug("[bma] link", tostring(mode), tostring(occ.name), "defs=" .. tostring(#list))
    RenderDefs(f, list)
    RefreshDeco(f, GetTime())
    return true
end

--------------------------------------------------------------------------------
-- Handlers BigWigs
--------------------------------------------------------------------------------

-- Signature reelle : (event, plugin, bar, module, key, text, time, icon, isApprox)
-- ATTENTION : `bar` vient AVANT `module`, contrairement au message BigWigs_StartBar.
local function OnBigWigsBarCreated(_, _, bar, _, key, text, time)
    if not bar or not Enabled() then return end
    local s = Live()
    if not s then return end
    -- key negative = section Encounter Journal, key string = option nommee ("berserk",
    -- "stages"...) : aucun lien possible. Les barres du plugin Timeline ont key nil mais
    -- portent "bigwigs:eventId" -> on les laisse passer, le niveau 1 les traitera.
    if key ~= nil and (type(key) ~= "number" or key <= 0) then return end

    local f = AcquireDeco()
    f.bar    = bar
    f.key    = key
    f.text   = text
    f.endAbs = GetTime() + (tonumber(time) or 0)
    f:SetParent(bar)
    AnchorDeco(f, bar)             -- une barre BigWigs EST la frame a longer
    f:Hide()                       -- reste invisible tant qu'aucun defensif n'est resolu
    pcall(bar.Set, bar, STORE_KEY, f)

    TryLink(f)

    -- Driver lance dans TOUS les cas :
    --  - pas encore liee : BigWigs demarre souvent sa barre AVANT que l'event serveur
    --    n'existe (prediction du module), s.active peut etre vide ici -> on re-tente ;
    --  - deja liee : il faut desaturer les defensifs au fur et a mesure qu'ils passent.
    -- Il s'arrete tout seul des qu'il n'y a plus rien a faire. Aucun couplage avec le
    -- handler de RuntimeBox.
    PumpDriver()
end

-- L'emphasize redimensionne la barre et peut la reparenter -> on re-ancre.
local function OnBigWigsBarEmphasized(_, _, bar)
    if not bar or not bar.Get then return end
    local ok, f = pcall(bar.Get, bar, STORE_KEY)
    if not ok or not f then return end
    AnchorDeco(f, bar)   -- re-ancre + relayout (AnchorDeco relit la hauteur)
end

-- LibCandyBar_Stop est un callback GLOBAL de la lib : on recoit aussi les stops de barres
-- creees par d'autres addons -> on n'agit que si NOTRE cle est posee.
-- bar.data est mis a nil JUSTE APRES ce callback : tout le teardown doit se faire ICI.
local function OnCandyBarStop(_, bar)
    if not bar or not bar.Get then return end
    local ok, f = pcall(bar.Get, bar, STORE_KEY)
    if not ok or not f then return end
    pcall(bar.Set, bar, STORE_KEY, nil)
    ReleaseDeco(f)
end

--------------------------------------------------------------------------------
-- Handlers DBM
--------------------------------------------------------------------------------
-- DBM n'est PAS symetrique de BigWigs, trois pieges :
--
--  1. AUCUN evenement de fin naturelle. `DBM_TimerStop` ne part que sur un arret EXPLICITE,
--     jamais quand le timer arrive a zero, et `DBM_TimerEnd` n'existe pas. Le seul point de
--     passage commun a TOUTES les fins (expiration, stop, clic droit, wipe) est
--     `barPrototype:Cancel`, qui appelle `self:callback("Cancel")` -> on passe donc par
--     `bar:SetCallback`. C'est un SLOT UNIQUE : on CHAINE l'eventuel precedent, on ne l'ecrase
--     jamais (un autre addon pourrait s'en servir).
--  2. Les barres DBM sont POOLEES et recyclees SOUS UN AUTRE id, et DBM ne nettoie pas les
--     enfants ajoutes par des tiers -> sans release explicite, nos icones reapparaissent sur
--     un timer sans rapport. Meme piege que LibCandyBar, en plus silencieux.
--  3. Les enfants d'une barre se lisent par NOM GLOBAL (`_G[frame:GetName().."Bar"]`) : il
--     n'y a pas de `bar.frame.bar`. Et la TAILLE ne doit PAS etre lue sur `bar.frame` (elle
--     reste a 195x20 tant que l'option IconLocked est off) mais sur cette StatusBar interne.
--
-- A noter : le dispatch DBM passe par `securecall` -> nos erreurs sont AVALEES en silence.
-- Un bug ici ne leve pas d'erreur Lua, il se traduit par "rien ne s'affiche".

-- simpType des timers de CAPACITE, meme allowlist que Core/ForeignBars.lua : on ne decore
-- pas les timers utilitaires (pull, break, berserk, stage, respawn...).
local DBM_ABILITY_TYPES = { cd = true, cast = true, target = true }

-- Signature : (event, id, msg, timer, icon, simpType, spellId, colorId, modId, keep, fade,
--              spellName, guid, timerCount, isPriority, fullType, hasVariance,
--              variancePeakTimer, isEnabled)
local function OnDBMTimerBegin(_, id, _, timer, _, simpType, spellId, _, _, _, _, spellName,
                               _, _, _, _, _, _, isEnabled)
    if not id or not Enabled() then return end
    -- DBM_TimerBegin fire MEME quand la barre est desactivee cote joueur : sans ce test on
    -- decorerait une barre qui n'existe pas.
    if isEnabled == false then return end
    if not DBM_ABILITY_TYPES[simpType] then return end

    local s = Live()
    if not s then return end

    local DBT = _G.DBT
    if not DBT or not DBT.GetBar then return end
    local ok, bar = pcall(DBT.GetBar, DBT, id)
    if not ok or not bar or not bar.frame or not bar.SetCallback then return end

    -- StatusBar interne : c'est elle qui porte la vraie taille, et c'est son bord droit
    -- qu'on longe. Lecture par nom global (pas de champ .bar sur la frame).
    local okn, fname = pcall(bar.frame.GetName, bar.frame)
    if not okn or not fname then return end
    local statusBar = _G[fname .. "Bar"]
    if not statusBar then return end

    local f = AcquireDeco()
    f.bar    = bar              -- objet DBM (pas de :Get -> le niveau 1 de la cascade passe)
    f.key    = spellId          -- peut etre une string (waSpecialKey) -> repli par nom
    f.text   = spellName
    f.endAbs = GetTime() + (tonumber(timer) or 0)
    -- Parent = la FRAME de la barre (elle porte le SetScale : se parenter ailleurs ferait
    -- decrocher visuellement nos icones a chaque transition small <-> huge).
    f:SetParent(bar.frame)
    -- Si l'option IconRight de DBM est active, une icone occupe deja le bord droit : on la
    -- contourne (elle est carree, donc large comme la barre est haute).
    local padX = ICON_GAP
    if DBT.Options and DBT.Options.IconRight then
        local okh, bh = pcall(statusBar.GetHeight, statusBar)
        if okh and bh and bh > 0 then padX = bh + ICON_GAP end
    end
    AnchorDeco(f, statusBar, padX)
    f:Hide()

    -- Teardown : seul point de passage commun a toutes les fins. On CHAINE le precedent.
    local prev = bar.callback
    pcall(bar.SetCallback, bar, function(self, event, ...)
        if event == "Cancel" then ReleaseDeco(f) end
        if prev then prev(self, event, ...) end
    end)

    TryLink(f)
    PumpDriver()
end

local function InitDBM()
    local DBM = _G.DBM
    if not DBM or not DBM.RegisterCallback then return end
    pcall(DBM.RegisterCallback, DBM, "DBM_TimerBegin", OnDBMTimerBegin)
    -- Filet de securite : `Cancel` couvre normalement tout, mais un kill/wipe peut laisser
    -- des barres dans des etats limites. On purge, c'est idempotent.
    pcall(DBM.RegisterCallback, DBM, "DBM_Kill", function() pcall(BMA.ReleaseAll) end)
    pcall(DBM.RegisterCallback, DBM, "DBM_Wipe", function() pcall(BMA.ReleaseAll) end)
end

--------------------------------------------------------------------------------
-- Init / teardown
--------------------------------------------------------------------------------

local function InitBigWigs()
    local loader = _G.BigWigsLoader
    if not loader or not loader.RegisterMessage then return end
    -- ATTENTION : avec un POINT, pas ":" -- le loader leve une erreur explicite sinon.
    pcall(loader.RegisterMessage, bwProxy, "BigWigs_BarCreated", OnBigWigsBarCreated)
    pcall(loader.RegisterMessage, bwProxy, "BigWigs_BarEmphasized", OnBigWigsBarEmphasized)
end

local function InitCandyBar()
    if not _G.LibStub then return end
    local candy = LibStub("LibCandyBar-3.0", true)
    if not candy or not candy.RegisterCallback then return end
    pcall(candy.RegisterCallback, bwProxy, "LibCandyBar_Stop", OnCandyBarStop)
end

-- Purge toutes les decorations encore attachees (fin de combat, option decochee,
-- changement de profil). Les BARRES ne nous appartiennent pas : on ne les touche pas, on
-- retire seulement nos frames et la cle qu'on avait posee dessus.
function BMA.ReleaseAll()
    local n = {}
    for f in pairs(live) do n[#n + 1] = f end
    for _, f in ipairs(n) do
        local bar = f.bar
        if bar and bar.Set then pcall(bar.Set, bar, STORE_KEY, nil) end
        ReleaseDeco(f)
    end
end

-- Re-applicable : option changee, changement de profil.
function BMA.Apply()
    if not Enabled() then pcall(BMA.ReleaseAll) end
end

-- Une seule fois, a l'init (les handlers relisent l'option a chaque barre).
function BMA.Init()
    if BMA._inited then return end
    BMA._inited = true
    pcall(InitBigWigs)
    pcall(InitCandyBar)
    pcall(InitDBM)
end

-- Fin de combat : les barres restantes seront stoppees par BigWigs (-> LibCandyBar_Stop),
-- mais on nettoie le pool par securite.
HR:RegisterEvent("ENCOUNTER_END", function() pcall(BMA.ReleaseAll) end)
