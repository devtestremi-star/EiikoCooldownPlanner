-- EiikoCooldownPlanner - Core/Icons.lua
-- FACADE unique de resolution d'icones. Un appelant demande « l'icone de ce donjon » et
-- recoit quelque chose de pret a poser -- sans avoir a savoir si c'est un fichier du
-- dossier Media, un fileID, une icone Blizzard, un ATLAS, ou une planche qui exige des
-- TexCoord.
--
-- POURQUOI : ces trois savoirs etaient disperses et se contredisaient.
--   * un ATLAS se pose avec SetAtlas et NE DOIT PAS recevoir le crop d'icone (il l'ecrase
--     et affiche n'importe quoi) ;
--   * une icone de CLASSE est une planche 4x4 : sans TexCoord, on affiche les 12 classes
--     d'un coup ;
--   * tout le reste veut le crop standard 0.08-0.92 (retirer la bordure des icones).
-- Chaque appelant qui refaisait ce raisonnement dans son coin se trompait tot ou tard.
--
-- ⚠️ CE FICHIER NE RESOUT RIEN LUI-MEME : il DELEGUE aux getters existants
-- (HR.Asset, HR.GetDungeonIcon, HR.HealProfileIcon, HR.GetDefensiveIcon...). Dupliquer
-- leur logique ici recreerait exactement le probleme qu'il corrige -- deux sources de
-- verite qui divergent.
--
-- Consommateurs : l'UI d'ECP, et l'addon compagnon « ECP Packager » via le pont.
local addonName, HR = ...

HR.Icons = HR.Icons or {}
local I = HR.Icons

local CROP = 0.08                       -- crop standard des icones carrees Blizzard
local CLASS_SHEET = "Interface\\TargetingFrame\\UI-Classes-Circles"

--------------------------------------------------------------------------------
-- Resolution
--------------------------------------------------------------------------------

-- Renvoie une DESCRIPTION : { atlas = "..." } ou { texture = <path|fileID>, coords = {l,r,t,b} }.
-- `coords` absent => l'appelant applique le crop standard. nil si rien de resolvable.
--
-- `kind` :
--   "asset"     value = cle du registre (Core/Assets.lua) -- gere fichier/chemin/fileID/atlas
--   "dungeon"   value = table de donjon OU dID
--   "healer"    value = profil de heal OU cle de profil ("PRIEST_HOLY", "NONE"...)
--   "class"     value = jeton de classe ("PRIEST")
--   "defensive" value = defKey
--   "spell"     value = spellID
--   "raw"       value = chemin ou fileID deja resolu
function I.Resolve(kind, value)
    if value == nil then return nil end

    if kind == "asset" then
        local e = HR.Assets and HR.Assets.registry and HR.Assets.registry[value]
        if e and e.atlas then return { atlas = e.atlas } end
        return { texture = HR.Asset(value) }

    elseif kind == "dungeon" then
        local d = value
        if type(d) ~= "table" then                       -- un dID : on retrouve le donjon
            for _, dd in ipairs(HR.content or {}) do
                if dd.id == value then d = dd; break end
            end
        end
        if type(d) ~= "table" then return nil end
        return { texture = HR.GetDungeonIcon(d) }

    elseif kind == "healer" then
        local p = (type(value) == "table") and value or HR.GetHealProfileOrNone(value)
        if not p then return nil end
        local icon = HR.HealProfileIcon(p)               -- icone de SPE si connue
        if icon then return { texture = icon } end
        return I.Resolve("class", p.class)               -- repli : icone de classe

    elseif kind == "class" then
        -- Planche 4x4 : SANS TexCoord on afficherait les douze classes a la fois.
        local c = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[value]
        if not c then return nil end
        return { texture = CLASS_SHEET, coords = { c[1], c[2], c[3], c[4] } }

    elseif kind == "defensive" then
        return { texture = HR.GetDefensiveIcon(value) }

    elseif kind == "spell" then
        return { texture = HR.GetSpellIcon(value) }

    elseif kind == "raw" then
        return { texture = value }
    end
    return nil
end

--------------------------------------------------------------------------------
-- Application
--------------------------------------------------------------------------------

-- Pose l'icone sur une Texture. Renvoie true si quelque chose a ete pose.
-- C'est LA fonction a utiliser : elle sait qu'un atlas ne se croppe pas et qu'une planche
-- exige ses coordonnees.
function I.Apply(tex, kind, value)
    if not tex then return false end
    local d = I.Resolve(kind, value)
    if not d then return false end
    if d.atlas then
        tex:SetAtlas(d.atlas)                            -- surtout PAS de TexCoord ici
        return true
    end
    tex:SetTexture(d.texture)
    if d.coords then
        tex:SetTexCoord(d.coords[1], d.coords[2], d.coords[3], d.coords[4])
    else
        tex:SetTexCoord(CROP, 1 - CROP, CROP, 1 - CROP)
    end
    return true
end

--------------------------------------------------------------------------------
-- Markup (pour les FontString : titres, menus, infobulles)
--------------------------------------------------------------------------------

-- Sequence |T...|t, ou "" si l'icone n'est pas resolvable (jamais nil : le resultat est
-- destine a une concatenation).
--
-- ⚠️ Un ATLAS n'a pas de forme |T...|t exploitable ici -- on rend "" plutot qu'un markup
-- casse qui afficherait un carre vide ou du texte brut au milieu d'une phrase.
function I.Markup(kind, value, size)
    size = size or 16
    local d = I.Resolve(kind, value)
    if not d or d.atlas or not d.texture then return "" end
    if d.coords then
        -- Planche : coordonnees en FRACTIONS chez nous, en PIXELS dans le markup.
        local SHEET = 256
        return ("|T%s:%d:%d:0:0:%d:%d:%d:%d:%d:%d|t"):format(
            tostring(d.texture), size, size, SHEET, SHEET,
            d.coords[1] * SHEET, d.coords[2] * SHEET,
            d.coords[3] * SHEET, d.coords[4] * SHEET)
    end
    -- Icone carree : le crop s'exprime en 64e (5..59 ~= 0.08..0.92).
    return ("|T%s:%d:%d:0:0:64:64:5:59:5:59|t"):format(tostring(d.texture), size, size)
end
