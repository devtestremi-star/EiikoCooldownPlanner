-- HealPlanner - Util.lua
-- Petites fonctions utilitaires reutilisables.
local addonName, HR = ...

-- Affiche un message dans la fenetre de chat par defaut, prefixe HealPlanner.
function HR:Print(...)
    local msg = ""
    for i = 1, select("#", ...) do
        msg = msg .. tostring(select(i, ...)) .. (i < select("#", ...) and " " or "")
    end
    DEFAULT_CHAT_FRAME:AddMessage(HR.CHAT_PREFIX .. msg)
end

-- Messages de debug, n'apparaissent que si HR.debug est vrai.
function HR:Debug(...)
    if HR.debug then
        self:Print("|cffaaaaaa[debug]|r", ...)
    end
end

-- Copie profonde d'une table (utile pour cloner des defaults).
-- Neutralise le markup d'une chaine d'origine EXTERNE avant affichage.
--
-- POURQUOI : les FontStrings de WoW interpretent `|c` (couleur), `|T...|t` (texture) et
-- surtout `|H...|h` (LIEN CLIQUABLE). Un nom de variante, un pseudo d'auteur ou un handle
-- de reseau social viennent d'une chaine collee, donc de n'importe qui -- et s'affichent
-- chez quelqu'un d'autre. Sans echappement, un nom peut se faire passer pour un lien
-- d'objet, une icone, ou du texte colore dans l'UI d'un tiers.
--
-- Doubler la barre suffit : `||` est rendu comme une barre litterale et ne demarre
-- aucune sequence.
--
-- ⚠️ A L'AFFICHAGE, JAMAIS AU STOCKAGE. Deux raisons : reecrire une donnee stockee est
-- precisement ce que la regle absolue du projet interdit ; et une chaine echappee en base
-- repartirait echappee au re-export, le `||` se composant a chaque cycle. La donnee reste
-- brute, seul le rendu est assaini.
-- Tronque a `maxChars` CARACTERES, pas a maxChars OCTETS, et sans couper dedans un
-- caractere multi-octets.
--
-- ⚠️ `#s` et `s:sub()` comptent des OCTETS. Couper au milieu d'un caractere accentue produit
-- une sequence UTF-8 INVALIDE : le lecteur affiche un losange noir, et surtout
-- `C_EncodingUtil.SerializeCBOR` peut refuser la chaine -- ce qui fait echouer tout un
-- export sur un « Encoding failed » qui n'explique rien. Les noms de variantes portent des
-- accents en permanence, et une saisie bornee a 64 CARACTERES pese jusqu'a 128 octets : le
-- cas n'a rien de theorique.
--
-- En UTF-8 un octet de TETE est < 0x80 (ASCII) ou >= 0xC0 (debut de sequence) ; les octets
-- de continuation sont entre 0x80 et 0xBF. On avance donc de tete en tete.
-- `suffix` (optionnel) n'est ajoute que si la chaine a REELLEMENT ete coupee.
function HR.TruncateUTF8(s, maxChars, suffix)
    if type(s) ~= "string" or type(maxChars) ~= "number" then return s end
    local n, i, len = 0, 1, #s
    while i <= len do
        if n == maxChars then return s:sub(1, i - 1) .. (suffix or "") end
        local b = s:byte(i)
        i = i + ((b < 0x80 and 1) or (b < 0xE0 and 2) or (b < 0xF0 and 3) or 4)
        n = n + 1
    end
    return s
end

function HR.EscapeMarkup(s)
    if type(s) ~= "string" then return s end
    return (s:gsub("|", "||"))
end

function HR.DeepCopy(src)
    if type(src) ~= "table" then return src end
    local dst = {}
    for k, v in pairs(src) do
        dst[k] = HR.DeepCopy(v)
    end
    return dst
end

-- Memorise la position d'une fenetre dans la DB (persiste au /reload) sous `key`.
function HR.SaveFramePos(key, frame)
    if not HR.db or not frame then return end
    HR.db.ui = HR.db.ui or {}
    local point, _, relPoint, x, y = frame:GetPoint(1)
    if point then
        HR.db.ui[key] = { point = point, relPoint = relPoint or point, x = x or 0, y = y or 0 }
    end
end

-- Memorise la position d'une fenetre en l'ancrant par le coin HAUT-GAUCHE (TOPLEFT de
-- UIParent) : le CONTENU part du haut-gauche, donc rescale/resize gardent ce coin fixe
-- (sinon le contenu glisse). Re-ancre sans deplacer visuellement, puis memorise l'offset.
-- C'est l'ancre HARMONISEE de toutes les fenetres HUD au drag/reset ; l'exception est la
-- banniere d'annonce, centree, qui passe par SaveFramePosTop.
-- (Une variante TOPRIGHT a existe : supprimee, plus aucun appelant. RestoreFramePos reste
-- compatible en LECTURE avec les positions TOPRIGHT deja enregistrees chez les joueurs.)
function HR.SaveFramePosTopLeft(key, frame)
    if not HR.db or not frame then return end
    HR.db.ui = HR.db.ui or {}
    local fLeft, fTop = frame:GetLeft(), frame:GetTop()
    if not fLeft or not fTop then return end
    local ratio = UIParent:GetEffectiveScale() / frame:GetEffectiveScale()
    local x = fLeft - UIParent:GetLeft() * ratio
    local y = fTop  - UIParent:GetTop()  * ratio
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", x, y)
    HR.db.ui[key] = { point = "TOPLEFT", relPoint = "TOPLEFT", x = x, y = y }
end

-- Comme SaveFramePosTopLeft mais ancre par le HAUT-CENTRE (TOP). Utile pour une BANNIERE centree
-- (ex. Announcement) : le contenu grandit symetriquement -> reste centre horizontalement au
-- rescale/changement de largeur. Re-ancre sans deplacer, puis memorise.
function HR.SaveFramePosTop(key, frame)
    if not HR.db or not frame then return end
    HR.db.ui = HR.db.ui or {}
    local fLeft, fRight, fTop = frame:GetLeft(), frame:GetRight(), frame:GetTop()
    if not fLeft or not fRight or not fTop then return end
    local ratio = UIParent:GetEffectiveScale() / frame:GetEffectiveScale()
    local fCenterX = (fLeft + fRight) / 2
    local upCenterX = (UIParent:GetLeft() + UIParent:GetRight()) / 2 * ratio
    local x = fCenterX - upCenterX
    local y = fTop - UIParent:GetTop() * ratio
    frame:ClearAllPoints()
    frame:SetPoint("TOP", UIParent, "TOP", x, y)
    HR.db.ui[key] = { point = "TOP", relPoint = "TOP", x = x, y = y }
end

-- Restaure la position memorisee d'une fenetre (relative a UIParent). Sans effet si
-- aucune position n'est sauvegardee (la fenetre garde son ancrage par defaut).
function HR.RestoreFramePos(key, frame)
    local p = HR.db and HR.db.ui and HR.db.ui[key]
    if not p or not frame then return end
    frame:ClearAllPoints()
    frame:SetPoint(p.point, UIParent, p.relPoint or p.point, p.x or 0, p.y or 0)
end

-- Garde-fou anti "position pourrie" : si la frame deborde de l'ecran (position
-- memorisee d'un ancien layout, resolution differente...), on la repositionne pour
-- qu'elle reste entierement visible. A appeler quand la frame est AFFICHEE (sinon
-- GetRect peut etre nil). Sans effet si la frame tient deja a l'ecran.
function HR.ClampToScreen(frame)
    if not frame then return end
    local l, b, w, h = frame:GetRect()
    if not l or not w then return end
    local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
    local nx = math.min(math.max(l, 0), math.max(0, sw - w))
    local ny = math.min(math.max(b, 0), math.max(0, sh - h))
    if math.abs(nx - l) > 0.5 or math.abs(ny - b) > 0.5 then
        frame:ClearAllPoints()
        frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", nx, ny)
    end
end

-- Change l'echelle d'une frame SANS la deplacer a l'ecran. Les offsets de SetPoint
-- sont exprimes dans l'echelle de la frame : a scale change, l'ancrage bouge a l'ecran.
-- On compense en multipliant les offsets par ancienne/nouvelle echelle.
function HR.SetFrameScaleInPlace(frame, newScale)
    if not frame then return end
    newScale = newScale or 1
    local old = frame:GetScale() or 1
    frame:SetScale(newScale)
    if old ~= newScale then
        local point, rel, relPoint, x, y = frame:GetPoint(1)
        if point then
            frame:SetPoint(point, rel, relPoint, (x or 0) * old / newScale, (y or 0) * old / newScale)
        end
    end
end

-- Fusionne recursivement `defaults` dans `target` sans ecraser les valeurs
-- existantes. Renvoie `target`. Sert a appliquer DB_DEFAULTS apres une mise a jour.
function HR.ApplyDefaults(target, defaults)
    if type(target) ~= "table" then target = {} end
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            target[k] = HR.ApplyDefaults(target[k], v)
        elseif target[k] == nil then
            target[k] = v
        end
    end
    return target
end
