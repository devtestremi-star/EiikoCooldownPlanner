-- HealPlanner - Core/Colors.lua
-- Color Manager : registre central des couleurs de l'addon. Meme esprit que
-- Core/Assets.lua : les modules demandent une CLE LOGIQUE (semantique) et recoivent
-- une couleur prete a l'emploi. Source unique de verite + swap facile + coherence.
--
-- Une couleur = table { r, g, b, a } (a optionnel, defaut 1). L'ALPHA de la palette
-- n'est qu'un defaut : un call-site peut passer son propre alpha (ex. un violet a 0.18
-- pour un wash de selection) en lisant r,g,b via Unpack et en fournissant son a.
--
-- Usage :
--   local c = HR.Colors.Get("purpleLight")   -- { r,g,b,a }
--   tex:SetColorTexture(HR.Colors.Unpack("purpleLight"))     -- r,g,b,a
--   local r,g,b = HR.Colors.Unpack("purpleLight"); tex:SetColorTexture(r,g,b,0.18)
--   HR.Colors.Register("brand", { 0.2, 0.6, 1, 1 })
local addonName, HR = ...

HR.Colors = HR.Colors or {}
local Colors = HR.Colors

local FALLBACK = { 1, 1, 1, 1 }     -- couleur si cle inconnue (blanc plein)

-- Palette seedee depuis l'inventaire exhaustif des .lua actifs (Archive / texcoords /
-- durations / RAID_CLASS_COLORS exclus). Garde l'alpha le plus courant comme defaut.
Colors.registry = {
    -- Statut ------------------------------------------------------------------
    ["danger"]          = { 1, 0.2, 0.2, 1 },    -- timer critique
    ["dangerHover"]     = { 1, 0.3, 0.3, 1 },    -- survol croix / delete
    ["force"]           = { 1, 0.5, 0, 1 },      -- bordure "force"
    ["forceBg"]         = { 0.9, 0.5, 0.1, 0.85 },
    ["forceHover"]      = { 1, 0.6, 0.15, 1 },
    ["destructiveBg"]   = { 0.55, 0.12, 0.12, 0.75 },
    ["destructiveHover"]= { 0.78, 0.16, 0.16, 0.95 },

    -- Neutres (rampe de gris) -------------------------------------------------
    ["black"]           = { 0, 0, 0, 1 },
    ["gray10"]          = { 0.10, 0.10, 0.10, 1 },
    ["gray15"]          = { 0.15, 0.15, 0.15, 1 },
    ["gray20"]          = { 0.2, 0.2, 0.2, 1 },
    ["gray40"]          = { 0.4, 0.4, 0.4, 1 },
    ["gray45"]          = { 0.45, 0.45, 0.45, 1 },
    ["gray60"]          = { 0.6, 0.6, 0.6, 1 },
    ["gray70"]          = { 0.7, 0.7, 0.7, 1 },
    ["gray75"]          = { 0.75, 0.75, 0.75, 1 },
    ["gray80"]          = { 0.8, 0.8, 0.8, 1 },
    ["gray85"]          = { 0.85, 0.85, 0.85, 1 },
    ["gray90"]          = { 0.9, 0.9, 0.9, 1 },
    ["white"]           = { 1, 1, 1, 1 },

    -- Surfaces (fonds sombres) ------------------------------------------------
    ["windowBg"]        = { 0.06, 0.06, 0.07, 0.96 },
    ["panelBg"]         = { 0.08, 0.08, 0.09, 0.98 },
}

-- Alias semantiques : un nom "intention" -> une cle de la rampe ci-dessus. Resolus
-- a la lecture (Get suit la chaine d'alias). Permet d'ecrire "border"/"selection"
-- sans figer la teinte exacte.
Colors.aliases = {
    ["accent"]    = "purpleLight",   -- accent = violet (gold supprime)
    ["selection"] = "purpleLight",
    ["border"]    = "black",
    ["bgDark"]    = "gray15",
    ["bgDarker"]  = "gray10",
    ["textNormal"]= "white",
    ["textMuted"] = "gray80",
    ["separator"] = "gray40",
}

-- Resout les alias (avec garde anti-boucle) puis renvoie la cle de registre finale.
local function resolve(name)
    local seen = 0
    while Colors.aliases[name] and seen < 8 do
        name = Colors.aliases[name]
        seen = seen + 1
    end
    return name
end

-- Renvoie la table { r,g,b,a } d'une couleur (alias resolus). Cle inconnue -> FALLBACK.
function Colors.Get(name)
    return Colors.registry[resolve(name)] or FALLBACK
end

-- Renvoie r, g, b, a (a defaut 1). Pratique pour SetColorTexture / SetTextColor / etc.
function Colors.Unpack(name)
    local c = Colors.Get(name)
    return c[1], c[2], c[3], c[4] or 1
end

-- Ajoute / remplace une couleur (ou un alias si def est une string).
function Colors.Register(name, def)
    if type(def) == "string" then
        Colors.aliases[name] = def
    else
        Colors.registry[name] = def
    end
end

-- Raccourci pratique : HR.Color("cle") == HR.Colors.Get("cle").
function HR.Color(name) return Colors.Get(name) end
