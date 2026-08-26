-- HealPlanner - UI/WhatsNew.lua
-- Modale "What's new" affichee A L'INIT apres une mise a jour. Case "ne plus afficher jusqu'a
-- la prochaine MAJ" -> memorise la VERSION vue dans `HR.db.whatsNewVersion` (account-wide, racine
-- de HealPlannerDB, hors profil). Au changement de version (## Version du .toc -> HR.VERSION),
-- la comparaison ne matche plus -> la modale se re-affiche (reset implicite de la case).
--
-- ⚠ Le CONTENU est statique : editer `SECTIONS` ci-dessous a chaque version (+ bumper
-- ## Version dans le .toc pour re-declencher l'affichage).
local addonName, HR = ...
HR.UI = HR.UI or {}
local UI = HR.UI

-- Notes de version : une liste de SECTIONS statiques. Chaque section est rendue selon
-- la meme mise en page : TITRE (emphase) -> SEPARATEUR (emphase) -> TEXTE (wrap).
-- A EDITER a chaque version (+ bumper ## Version dans le .toc pour re-declencher).
local SECTIONS = {
    {
        title = "Patch 12.1 ready",
        text  = "New dungeon pool, bosses and timelines are in.",
    },
    {
        title = "Homepage & keystone queue",
        text  = "New homepage with your group keystones listed. Queue up for the selected keystone from there!",
    },
    {
        title = "Hide other bossmod bars",
        text  = "New options to hide other bossmod bars in mythic+. Only applies to dungeons.",
    },
    {
        title = "Attach to other bossmod bars",
        text  = "You can choose to use your favorite bossmod bars and still have planned CDs attached to them.",
    },
}

-- Couleur d'emphase (titre + separateur) : accent de l'addon (violet), repli littéral
-- hors Color Manager.
local ACCENT = { 0.62, 0.44, 0.92 }

-- Titre "ECP - What's new" : E/C/P aux MEMES couleurs de classe que le titre principal
-- (moine=E / druide=C / chaman=P), tirees de RAID_CLASS_COLORS (repli lettre brute).
local function classLetter(letter, classToken)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
    if c and c.colorStr then return "|c" .. c.colorStr .. letter .. "|r" end
    return letter
end
local function TitleStr()
    return classLetter("E", "MONK") .. classLetter("C", "DRUID") .. classLetter("P", "SHAMAN")
        .. " - What's new"
end

-- Couleur d'accent resolue (Color Manager si dispo, sinon littéral ACCENT).
local function accent()
    if HR.Colors and HR.Colors.Unpack then
        local r, g, b = HR.Colors.Unpack("accent")
        if r then return r, g, b end
    end
    return ACCENT[1], ACCENT[2], ACCENT[3]
end

-- Espacements verticaux de la mise en page d'une section (constants -> reutilises
-- pour empiler ET pour mesurer la hauteur totale).
local GAP_BEFORE_TITLE, TITLE_TO_SEP, SEP_H, SEP_TO_BODY = 14, 5, 2, 6

-- Rend une SECTION (titre emphase -> separateur emphase -> texte wrap), ancree sous
-- `anchor`. Renvoie le dernier widget (= point d'ancrage de la section suivante) et la
-- HAUTEUR verticale consommee (pour l'auto-dimensionnement de la modale).
local function RenderSection(content, anchor, sec)
    local ar, ag, ab = accent()

    -- 1. TITRE (emphase : gros + accent violet + ombre).
    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -GAP_BEFORE_TITLE)
    title:SetTextColor(ar, ag, ab)
    title:SetShadowColor(0, 0, 0, 1); title:SetShadowOffset(1, -1)
    title:SetText(sec.title)

    -- 2. SEPARATEUR (emphase : ligne 2px accent violet, largeur du contenu).
    local sep = content:CreateTexture(nil, "ARTWORK")
    sep:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -TITLE_TO_SEP)
    sep:SetPoint("RIGHT", content, "RIGHT", -20, 0)
    sep:SetHeight(SEP_H)
    sep:SetColorTexture(ar, ag, ab, 0.9)

    -- 3. TEXTE (wrap, ancre haut-gauche -> droite).
    local body = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    body:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 0, -SEP_TO_BODY)
    body:SetPoint("RIGHT", content, "RIGHT", -20, 0)
    body:SetJustifyH("LEFT"); body:SetJustifyV("TOP")
    body:SetSpacing(3)
    body:SetText(sec.text)

    local consumed = GAP_BEFORE_TITLE + (title:GetStringHeight() or 14)
                   + TITLE_TO_SEP + SEP_H + SEP_TO_BODY + (body:GetStringHeight() or 0)
    return body, consumed
end

local function Build()
    local C = HR.UI.Components
    local f = C.Window(UIParent, {
        name   = "ECPWhatsNew",
        width  = 520,
        height = 440,     -- provisoire : recalcule plus bas selon le nombre de sections
        title  = TitleStr(),
        -- Meme texture de fond que la modale "New variant".
        bgTexture = (HR.Assets and HR.Assets.registry["bg-variant"]) and HR.Asset("bg-variant") or nil,
    })
    f:Hide()
    tinsert(UISpecialFrames, "ECPWhatsNew")   -- ESC ferme la modale
    UI.whatsNew = f

    -- Surplomb = tout ce qui n'est PAS la zone de contenu (bandeau + bordures) ; constant,
    -- sert a re-deriver la hauteur de la fenetre a partir de la hauteur de contenu voulue.
    local overhead = f:GetHeight() - f.content:GetHeight()
    if overhead <= 0 or overhead > 120 then overhead = 51 end   -- repli (bandeau 46 + bordures)

    -- Layer noircissant DANS la modale : voile sombre par-dessus la texture de fond
    -- (bg-variant) pour faire ressortir le texte. Sur `f`, sous les widgets de `f.content`
    -- (frame enfant -> ses regions dessinent toujours au-dessus). Couvre la zone de contenu.
    f.dim = f:CreateTexture(nil, "ARTWORK")
    f.dim:SetPoint("TOPLEFT", f.content, "TOPLEFT", 0, 0)
    f.dim:SetPoint("BOTTOMRIGHT", f.content, "BOTTOMRIGHT", 0, 0)
    f.dim:SetColorTexture(0, 0, 0, 0.55)

    -- Petite ligne de version sous le bandeau.
    f.ver = f.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.ver:SetPoint("TOPLEFT", 20, -12)
    f.ver:SetText("v" .. tostring(HR.VERSION))

    -- Corps : une section par entree de SECTIONS (titre / separateur / texte), empilees.
    -- On cumule la hauteur consommee pour redimensionner la modale (auto-grow).
    local BOTTOM_PAD = 48                     -- place pour la case "ne plus afficher"
    local needed = 12 + (f.ver:GetStringHeight() or 10)
    local anchor = f.ver
    for _, sec in ipairs(SECTIONS) do
        local body, consumed = RenderSection(f.content, anchor, sec)
        anchor = body
        needed = needed + consumed
    end
    f:SetHeight(overhead + needed + BOTTOM_PAD)

    -- Case "ne plus afficher jusqu'a la prochaine MAJ" (bas-gauche).
    f.dontShow = CreateFrame("CheckButton", nil, f.content, "UICheckButtonTemplate")
    f.dontShow:SetSize(24, 24)
    f.dontShow:SetPoint("BOTTOMLEFT", 16, 14)
    local lbl = f.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("LEFT", f.dontShow, "RIGHT", 4, 0)
    lbl:SetText("Don't show again until the next update")
    f.dontShow:SetScript("OnClick", function(self)
        if not HR.db then return end
        -- Coche => version courante memorisee (ne reviendra qu'au prochain changement de version).
        HR.db.whatsNewVersion = self:GetChecked() and HR.VERSION or ""
    end)

    return f
end

-- Ouvre la modale (la construit si besoin) et synchronise texte + case. Appelable a la main.
function UI.ShowWhatsNew()
    if not (HR.UI.Components and HR.UI.Components.Window) then return end
    local f = UI.whatsNew or Build()
    f.ver:SetText("v" .. tostring(HR.VERSION))
    -- "Don't show again" COCHEE par defaut : on marque la version courante comme vue des l'ouverture
    -- => la modale n'apparait qu'UNE fois par version (plus a chaque reload). Decocher la case
    -- (OnClick remet whatsNewVersion = "") re-active l'affichage au prochain reload.
    if HR.db and HR.db.whatsNewVersion ~= HR.VERSION then HR.db.whatsNewVersion = HR.VERSION end
    f.dontShow:SetChecked(HR.db and HR.db.whatsNewVersion == HR.VERSION)
    f:Show()
end

-- Appele a l'init : affiche UNIQUEMENT si la version courante n'a pas ete "vue" (case cochee).
function UI.MaybeShowWhatsNew()
    if not HR.db then return end
    if HR.db.whatsNewVersion ~= HR.VERSION then
        UI.ShowWhatsNew()
    end
end
