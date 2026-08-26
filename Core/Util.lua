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

-- Memorise la position d'une fenetre en l'ancrant TOUJOURS par le coin HAUT-DROIT
-- (TOPRIGHT de UIParent). Re-ancre la frame sans la deplacer visuellement, puis
-- enregistre l'offset : le point de reference reste le coin haut-droit (utile pour
-- les boites runtime/comm, qui doivent rester collees au coin sup. droit de l'ecran).
function HR.SaveFramePosTopRight(key, frame)
    if not HR.db or not frame then return end
    HR.db.ui = HR.db.ui or {}
    local fRight, fTop = frame:GetRight(), frame:GetTop()
    if not fRight or not fTop then return end
    -- L'offset SetPoint est exprime dans l'echelle propre de la frame (les boites ont
    -- leur propre SetScale). On convertit le coin de UIParent dans cette echelle.
    local ratio = UIParent:GetEffectiveScale() / frame:GetEffectiveScale()
    local x = fRight - UIParent:GetRight() * ratio
    local y = fTop  - UIParent:GetTop()   * ratio
    frame:ClearAllPoints()
    frame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", x, y)
    HR.db.ui[key] = { point = "TOPRIGHT", relPoint = "TOPRIGHT", x = x, y = y }
end

-- Comme SaveFramePosTopRight mais ancre par le coin HAUT-GAUCHE (TOPLEFT). Utile pour une
-- barre dont le CONTENU part du haut-gauche (ex. comm bar) : ainsi rescale/resize gardent le
-- coin haut-gauche fixe (sinon le contenu glisse). Re-ancre sans deplacer, puis memorise.
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
