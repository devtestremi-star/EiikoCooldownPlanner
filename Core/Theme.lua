-- HealPlanner - Core/Theme.lua
-- Couche THEME au-dessus du Color Manager (Core/Colors.lua). C'est l'INTERMEDIAIRE
-- semantique : l'UI ne lit pas une couleur brute (gold/black...) pour son "chrome",
-- elle lit un TOKEN (ex. BUTTON_BORDER_SQUARED_COLOR) dont la valeur depend du THEME
-- ACTIF. Pour repeindre toutes les bordures de bouton, on change le token (ou le theme)
-- une fois, au lieu de toucher chaque call-site.
--
--   Palette (Colors)  ->  Tokens (Theme, par theme)  ->  Consommateurs (UI)
--   "purpleLight"=...      BUTTON_SELECTED_COLOR = "purpleLight"
--
-- Deux types de tokens :
--   * COULEUR   : valeur = nom de couleur du palette (string, resolu via HR.Colors)
--                 OU table {r,g,b,a} directe.
--   * SCALAIRE  : valeur = nombre (ex. epaisseur de bordure en px / edgeSize arrondi).
local addonName, HR = ...

HR.Theme = HR.Theme or {}
local Theme = HR.Theme

-- Teintes supplementaires utiles aux themes (le palette reste l'inventaire de base ;
-- on ajoute ici ce dont les themes ont besoin). No-op si Colors pas encore charge.
if HR.Colors then
    HR.Colors.Register("green", { 0.25, 0.78, 0.35, 1 })
    HR.Colors.Register("blue",  { 0.25, 0.55, 0.95, 1 })
    HR.Colors.Register("darkPurple",   { 0.082, 0.024, 0.161, 1 }) -- #150629 (tres sombre, ~fond)
    HR.Colors.Register("purple",       { 0.42, 0.28, 0.66, 1 })    -- violet visible (bordure repos)
    HR.Colors.Register("purpleBright", { 0.62, 0.44, 0.92, 1 })    -- violet (bordure survol)
    HR.Colors.Register("purpleLight",  { 0.78, 0.62, 1.0, 1 })     -- violet PLUS CLAIR (fond selection)
    HR.Colors.Register("red",          { 0.95, 0.25, 0.25, 1 })    -- erreurs / etats invalides
end

-- Catalogue des themes : nom -> table { token = valeur }. Ajoute les tiens via
-- Theme.Register("monTheme", { ... }). Tout token absent retombe sur "default".
Theme.themes = {
    default = {
        BUTTON_BORDER_ROUND_COLOR            = "bgDark",      -- repos : se fond dans le bouton (pas de violet)
        BUTTON_BORDER_ROUND_THICKNESS        = 8,          -- edgeSize de la texture arrondie (reduit)
        BUTTON_BORDER_SQUARED_COLOR          = "bgDark",      -- repos : neutre (pas de violet)
        BUTTON_BORDER_SQUARED_THICKNESS      = 1,          -- px
        BUTTON_SELECTED_COLOR                = "purple",       -- FOND selection : violet assez fonce (texte blanc lisible)
        BUTTON_BORDER_HOVER_COLOR            = "purpleBright", -- bordure au SURVOL

        -- Boutons IMAGE (onglets de donjon...) : liseré de selection (violet clair).
        IMAGE_BUTTON_BORDER_THICKNESS        = 1,
        IMAGE_BUTTON_BORDER_COLOR            = "purpleBright",

        -- Selecteurs custom : select de variante + popups (C.ScrollPopup). Bordure VISIBLE
        -- (pas un bouton "non selectionne" -> garde un contour).
        POPUP_BORDER_COLOR                   = "purple",

        -- Modales / fenetres (C.Window)
        MODAL_BACKGROUND_COLOR               = "windowBg", -- {0.06,0.06,0.07,0.96}
        MODAL_BORDER_COLOR                   = "border",   -- -> noir
        MODAL_BORDER_THICKNESS               = 2,          -- px (applique a l'ouverture/reload)

        -- Couleurs de TEXTE semantiques (le gold est supprime). BASE = texte normal,
        -- EMPHASIZE = texte mis en avant, ERROR = texte d'erreur/invalide.
        BASE_TEXT_COLOR                      = "white",
        EMPHASIZE_TEXT_COLOR                 = "purpleLight",
        ERROR_COLOR                          = "red",
        -- Lignes de separation (dividers / sidebar / sous "Summary")
        SEPARATOR_COLOR                      = "gray40",
        -- Conteneurs internes (panneau Summary/Variantes...)
        CONTAINER_BACKGROUND_COLOR           = "panelBg",  -- {0.08,0.08,0.09,0.98}
        CONTAINER_BORDER_COLOR               = "gray40",
        CONTAINER_BORDER_THICKNESS           = 1,          -- px
        -- Fond noir partage des 3 zones "chrome" : sidebar + boss bar + bandeau titre
        ZONE_BACKGROUND                      = "black",
        -- Fond du cadre principal (global)
        GLOBAL_BACKGROUND                    = "windowBg", -- {0.06,0.06,0.07,0.96}
        -- Voile sombre par-dessus le fond de contenu (degrade vertical, lisibilite timeline)
        CONTENT_DIM_TOP_COLOR                = { 0, 0, 0, 0.3 },   -- haut : depart du degrade (30%)
        CONTENT_DIM_BOTTOM_COLOR             = { 0, 0, 0, 0.9 },   -- bas : plus sombre
        -- Padding interne harmonise des zones de navigation/selection (sidebar + boss bar)
        ZONE_PADDING                         = 10,         -- px
        -- Bloc d'info (C.InfoBox) : cadre explicatif d'une section. Bordure VIOLETTE, fond NOIR
        -- semi-transparent, texte BLANC. (Tokens dedies -> re-thematisables ; fallback default.)
        INFOBOX_BORDER_COLOR                 = "purple",
        INFOBOX_BACKGROUND_COLOR             = { 0, 0, 0, 0.7 },   -- noir, ~70% (un peu transparent)
        INFOBOX_TEXT_COLOR                   = "white",
        INFOBOX_BORDER_THICKNESS             = 1,          -- px
    },

    -- Exemple : meme structure, selection verte + bordure carree plus marquee. Sert a
    -- demontrer le swap (/ecp theme emerald). Duplique/edite pour creer les tiens.
    emerald = {
        BUTTON_BORDER_ROUND_COLOR            = "gray40",
        BUTTON_BORDER_ROUND_THICKNESS        = 8,
        BUTTON_BORDER_SQUARED_COLOR          = "gray10",
        BUTTON_BORDER_SQUARED_THICKNESS      = 2,
        BUTTON_SELECTED_COLOR                = "green",
        BUTTON_BORDER_HOVER_COLOR            = "green",

        IMAGE_BUTTON_BORDER_THICKNESS        = 2,
        IMAGE_BUTTON_BORDER_COLOR            = "green",

        POPUP_BORDER_COLOR                   = "green",

        MODAL_BACKGROUND_COLOR               = "windowBg",
        MODAL_BORDER_COLOR                   = "green",
        MODAL_BORDER_THICKNESS               = 2,

        BASE_TEXT_COLOR                      = "white",
        EMPHASIZE_TEXT_COLOR                 = "green",
        ERROR_COLOR                          = "red",
        SEPARATOR_COLOR                      = "green",
        CONTAINER_BACKGROUND_COLOR           = "panelBg",
        CONTAINER_BORDER_COLOR               = "green",
        CONTAINER_BORDER_THICKNESS           = 1,
        ZONE_BACKGROUND                      = "black",
        GLOBAL_BACKGROUND                    = "windowBg",
        CONTENT_DIM_TOP_COLOR                = { 0, 0, 0, 0.3 },
        CONTENT_DIM_BOTTOM_COLOR             = { 0, 0, 0, 0.9 },
        ZONE_PADDING                         = 10,
    },
}

Theme.active = "default"

-- Abonnements rejoues a chaque changement de theme (les modules s'y inscrivent pour
-- repeindre leurs widgets deja construits — retained mode = pas de reactivite auto).
Theme.callbacks = {}

-- Valeur BRUTE d'un token dans le theme actif (repli sur "default" si absent).
function Theme.Get(token)
    local t = Theme.themes[Theme.active] or Theme.themes.default
    local v = t[token]
    if v == nil and t ~= Theme.themes.default then v = Theme.themes.default[token] end
    return v
end

-- Token COULEUR -> table {r,g,b,a}. Resout un nom de palette via HR.Colors.
function Theme.Color(token)
    local v = Theme.Get(token)
    if type(v) == "table" then return v end
    if type(v) == "string" and HR.Colors then return HR.Colors.Get(v) end
    return HR.Colors and HR.Colors.Get("white") or { 1, 1, 1, 1 }
end

-- Token COULEUR -> r, g, b, a (a defaut 1). Pratique pour SetTextColor / SetColorTexture.
function Theme.Unpack(token)
    local c = Theme.Color(token)
    return c[1], c[2], c[3], c[4] or 1
end

-- Token COULEUR -> code inline "|cffRRGGBB" (pour SetText a couleurs MIXTES dans un meme
-- texte). Refermer avec "|r".
function Theme.Hex(token)
    local c = Theme.Color(token)
    return string.format("|cff%02x%02x%02x",
        math.floor((c[1] or 1) * 255 + 0.5), math.floor((c[2] or 1) * 255 + 0.5), math.floor((c[3] or 1) * 255 + 0.5))
end

-- Token SCALAIRE -> nombre (ex. epaisseur). `default` si le token n'est pas un nombre.
function Theme.Value(token, default)
    local v = Theme.Get(token)
    if type(v) == "number" then return v end
    return default
end

-- Enregistre / remplace un theme complet.
function Theme.Register(name, tbl) Theme.themes[name] = tbl end

-- Surcharge un token du theme actif a chaud (ex. changer juste la couleur de selection).
function Theme.Set(token, value)
    local t = Theme.themes[Theme.active]
    if t then t[token] = value; Theme.Refresh() end
end

-- S'abonner aux changements de theme (re-skin). fn() est rejouee a chaque swap/refresh.
function Theme.OnChange(fn) table.insert(Theme.callbacks, fn) end

-- Rejoue les callbacks (re-skin live) sans changer de theme.
function Theme.Refresh()
    for _, fn in ipairs(Theme.callbacks) do pcall(fn) end
end

-- Change le theme actif puis re-skinne. Renvoie true si le theme existe.
function Theme.SetActive(name)
    if not Theme.themes[name] then return false end
    Theme.active = name
    Theme.Refresh()
    return true
end

-- Noms des themes disponibles (tri alpha).
function Theme.List()
    local out = {}
    for name in pairs(Theme.themes) do out[#out + 1] = name end
    table.sort(out)
    return out
end
