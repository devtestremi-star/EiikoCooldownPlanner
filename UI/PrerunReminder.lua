-- HealPlanner - UI/PrerunReminder.lua
-- Rappel PRE-RUN : a la 1re entree dans un donjon (apres l'auto-load de la variante,
-- cf. HR.AutoLoadDefaultVariant), une modale custom (fond noir, titre "ECP Reminder")
-- affiche un RESUME COMPACT de la variante jouee (meme rendu d'icones que le dropdown de
-- selection, via UI.LayoutVariantIcons) + 2 CTA : "Change variant" / "Close".
-- Prefixe "DEFAULT" (rouge) si c'est la variante par defaut. Gere le cas AUCUNE variante.
local addonName, HR = ...
local UI = HR.UI or {}
HR.UI = UI

local REM_W, REM_H = 340, 146
local ICON_SZ = 26
local PAD = 10                                  -- marge unique, condensee

-- Titre "ECP" colore par lettres (moine=E / druide=C / chaman=P, cf. WhatsNew) + " Reminder".
local function ecpTitle()
    local function cl(letter, token)
        local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
        if c and c.colorStr then return "|c" .. c.colorStr .. letter .. "|r" end
        return letter
    end
    return cl("E", "MONK") .. cl("C", "DRUID") .. cl("P", "SHAMAN") .. " Reminder"
end

local function Build()
    if UI.prerun then return UI.prerun end
    local C = UI.Components
    local f = C.Window(UIParent, {
        name        = "ECPReminder",
        width       = REM_W, height = REM_H,
        title       = ecpTitle(),
        titleHeight = 32,                        -- bandeau de titre reduit
        bg          = { 0, 0, 0, 0.94 },         -- fond NOIR (sous la texture ; visible si bg-1 absent)
        bgTexture   = (HR.Assets and HR.Assets.registry["bg-1"]) and HR.Asset("bg-1") or nil,  -- fond d'ecran bg-1
        onMoved     = function(self) HR.SaveFramePos("reminder", self) end,   -- memorise la position au drag
    })
    f:Hide()
    HR.RestoreFramePos("reminder", f)            -- restaure la position memorisee (sinon reste centre)
    f:SetFrameStrata("FULLSCREEN_DIALOG")        -- au-dessus des panneaux de jeu
    f:SetToplevel(true)
    tinsert(UISpecialFrames, "ECPReminder")      -- ESC ferme

    local c = f.content

    -- Nom de la variante jouee (prefixe "DEFAULT" rouge si defaut). Colle en haut a gauche.
    f.varName = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.varName:SetPoint("TOPLEFT", PAD, -PAD)
    f.varName:SetPoint("RIGHT", c, "RIGHT", -PAD, 0)
    f.varName:SetJustifyH("LEFT"); f.varName:SetWordWrap(false); f.varName:SetTextColor(1, 1, 1)

    -- Conteneur du resume d'icones (REUTILISE UI.LayoutVariantIcons du dropdown), juste sous le nom.
    f.icons = CreateFrame("Frame", nil, c)
    f.icons:SetPoint("TOPLEFT", f.varName, "BOTTOMLEFT", 0, -6)
    f.icons:SetPoint("RIGHT", c, "RIGHT", -PAD, 0)
    f.icons:SetHeight(ICON_SZ + 2)
    f.iconPool = {}

    -- Message "aucune variante" (cache par defaut), a la place du nom.
    f.noVar = c:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    f.noVar:SetPoint("TOPLEFT", PAD, -PAD)
    f.noVar:SetPoint("RIGHT", c, "RIGHT", -PAD, 0)
    f.noVar:SetJustifyH("LEFT")
    f.noVar:SetText("No variant set for this dungeon.")
    f.noVar:Hide()

    -- CTA B : Close (bas-droite). CTA A : Change variant (a sa gauche).
    f.btnClose = C.TextButton(c, { text = "Close", autoWidth = true, minWidth = 70, padX = 10, padY = 6, onClick = function() f:Hide() end })
    f.btnClose:SetPoint("BOTTOMRIGHT", -PAD, PAD)

    f.btnChange = C.TextButton(c, { text = "Change variant", autoWidth = true, minWidth = 100, padX = 10, padY = 6, onClick = function()
        local dID = f._dID
        f:Hide()
        if dID then
            UI.ShowDungeonVariant(dID, HR.GetActiveVariant(dID))
            -- Si une variante existe, ouvre directement le selecteur ; sinon la config
            -- affiche l'etat "New" (aucune variante -> le selecteur serait vide/masque).
            if HR.GetActiveVariant(dID) and UI.ToggleVariantPopup then UI.ToggleVariantPopup() end
        end
    end })
    f.btnChange:SetPoint("RIGHT", f.btnClose, "LEFT", -6, 0)

    -- CTA C : Sync (a gauche de "Change variant") -> pousse la variante JOUEE au groupe ;
    -- chez les membres equipes elle est importee et posee active. Masque quand aucune
    -- variante (rien a pousser). Ne fait qu'EMETTRE : le reste vit dans Core/Sync/.
    f.btnSync = C.TextButton(c, { text = "Sync", autoWidth = true, minWidth = 70, padX = 10, padY = 6, onClick = function()
        local dID = f._dID
        local v = dID and HR.GetV2Used(dID)
        -- Un plan RECU n'est pas re-poussable (cf. la gate d'emission de Core/Sync/PlanSync).
        if v and not v.synced then HR.EmitEvent(HR.EV.PLAN_SHARED, { dID = dID, variant = v }) end
    end })
    f.btnSync:SetPoint("RIGHT", f.btnChange, "LEFT", -6, 0)

    UI.prerun = f
    return f
end

-- Affiche le rappel pour le donjon `dID` (variante jouee = HR.GetV2Used).
function UI.ShowPrerunReminder(dID)
    if not (dID and UI.Components and UI.Components.Window) then return end
    local f = Build()
    f._dID = dID

    local v = HR.GetV2Used(dID)          -- variante jouee (auto-chargee, ou ancree lastSeen/1re)

    if v then
        -- Prefixe "DEFAULT" (rouge) si c'est la variante par defaut de la spe pour ce donjon.
        local isDef = HR.IsDefaultVariant and HR.IsDefaultVariant(v.id, dID)
        local nm = (isDef and (HR.Theme.Hex("ERROR_COLOR") .. "DEFAULT|r ") or "") .. v.name
        f.varName:SetText(nm); f.varName:Show()
        f.noVar:Hide()
        f.icons:Show()
        UI.LayoutVariantIcons(f.icons, f.iconPool, 0, 0, v, ICON_SZ, 5)
        f.btnSync:Show()
        -- Grise aussi quand on est SEUL : pousser un plan a soi-meme n'a aucun sens
        -- (cf. Net.GroupChannel, qui refuse l'envoi hors groupe).
        local audience = not (HR.Sync and HR.Sync.Net and HR.Sync.Net.HasAudience)
            or HR.Sync.Net.HasAudience()
        local canSync = (not v.synced) and audience
        f.btnSync:SetEnabled(canSync); f.btnSync:SetAlpha(canSync and 1 or 0.4)
    else
        -- Aucune variante disponible pour ce donjon.
        f.varName:SetText(""); f.varName:Hide()
        for _, it in ipairs(f.iconPool) do it:Hide() end
        if f.icons._moreBtn then f.icons._moreBtn:Hide() end
        f.icons:Hide()
        f.noVar:Show()
        f.btnSync:Hide()
    end

    f:Show(); f:Raise()
    HR.ClampToScreen(f)                  -- garde-fou : recadre si position memorisee hors ecran
end
