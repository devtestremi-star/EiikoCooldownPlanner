-- EiikoCooldownPlanner - UI/ProfileShare.lua
-- Modales Export / Import d'un PROFIL d'affichage. Meme flux d'action que l'export/import
-- de variante (chaine copiable, Ctrl+C qui ferme, champ de collage + bouton Import), mais
-- CANAL SEPARE : ces deux fenetres sont le seul point d'entree des chaines de profil, et
-- UI.ImportVariantString n'en accepte aucune.
--
-- Pourquoi separer : un profil et un plan ne partagent ni store, ni cycle de vie, ni
-- consequence. Un seul champ "colle n'importe quoi" ferait porter a l'utilisateur la charge
-- de savoir ce qu'il colle, alors que c'est justement ce que la machine sait faire. Chaque
-- cote reconnait donc le format de l'autre pour DIRE ou aller, jamais pour l'avaler.
local addonName, HR = ...

HR.UI = HR.UI or {}
local UI = HR.UI

local W, H = 560, 420
local PAD  = 16

--------------------------------------------------------------------------------
-- Fabrique commune aux deux modales (elles ne different que par leur zone de texte et
-- leurs boutons). Evite de repeter le cadre, le fond et l'enregistrement Echap.
--------------------------------------------------------------------------------

local function MakeModal(name, title)
    local C = UI.Components
    local m = C.Window(UIParent, {
        name = name, title = title, width = W, height = H,
        bgTexture = C.ModalBackgroundTexture(),
    })
    C.ModalBackground(m)
    m:SetFrameStrata("FULLSCREEN_DIALOG")
    m:SetToplevel(true)
    tinsert(UISpecialFrames, name)                               -- Echap ferme
    m:Hide()
    return m
end

--------------------------------------------------------------------------------
-- Export : chaine du profil ACTIF (celui que le joueur voit dans le select).
--------------------------------------------------------------------------------

local function BuildExport()
    local C = UI.Components
    local m = MakeModal("ECPProfileExport", "Export profile")
    local c = m.content

    m.lbl = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    m.lbl:SetPoint("TOPLEFT", PAD, -14)
    m.lbl:SetPoint("RIGHT", c, "RIGHT", -PAD, 0)
    m.lbl:SetJustifyH("LEFT")
    m.lbl:SetTextColor(1, 1, 1)

    m.box = C.StringBox(c, {
        readOnly = true,
        onCopy   = function() m:Hide() end,
        onEscape = function() m:Hide() end,
    })
    m.box:SetPoint("TOPLEFT", PAD, -38)
    m.box:SetPoint("BOTTOMRIGHT", -32, 50)

    local close = C.TextButton(c, { text = "Close", width = 120, onClick = function() m:Hide() end })
    close:SetPoint("BOTTOMRIGHT", -PAD, 14)

    UI.profileExportModal = m
    return m
end

function UI.OpenProfileExportModal()
    local name = HR.GetActiveProfileName()
    if not name then HR:Print("No active profile to export."); return end
    local m = UI.profileExportModal or BuildExport()

    local str = HR.ProfileShare and HR.ProfileShare.Encode(name)
    -- Le nom du profil EXPORTE est affiche : le select est peut-etre hors champ derriere la
    -- modale, et une chaine anonyme est exactement ce qu'on ne veut pas coller a l'aveugle.
    m.lbl:SetText(("Profile |cffffd100%s|r -- press Ctrl+C to copy (the window closes automatically):")
        :format(HR.EscapeMarkup(name)))
    m.box:SetString(str or "<export failed: encoding unavailable>")
    m:Show(); m:Raise()
    m.box:SelectAll()                                            -- focus + selection -> Ctrl+C immediat
    if not str then HR:Print("Export failed (encoding unavailable).") end
end

--------------------------------------------------------------------------------
-- Import
--------------------------------------------------------------------------------

-- Decode + cree le profil. Renvoie true si un profil a ete pose (la modale se ferme alors).
-- Aucun profil existant n'est modifie : HR.ProfileShare.Import en CREE un et bascule dessus.
function UI.ImportProfileString(str)
    str = str and strtrim(str) or ""
    if str == "" then HR:Print("Paste a profile string first."); return false end

    local PS = HR.ProfileShare
    if not PS then HR:Print("Import unavailable."); return false end

    -- Les formats TEXTE de plan (`ecp;2` et catalogue) se reconnaissent avant tout decodage
    -- -- ils ne sont meme pas en Base64. Les nommer evite le "chaine corrompue" trompeur.
    if (HR.Catalog and HR.Catalog.Looks(str)) or (HR.ShareText and HR.ShareText.Looks(str)) then
        HR:Print("This is a plan string, not a profile. Import it from the Healer specs panel.")
        return false
    end

    local payload, err = PS.Decode(str)
    if not payload then
        if err == "not_a_profile" then
            HR:Print("This is a plan string, not a profile. Import it from the Healer specs panel.")
        elseif err == "too_large" then
            HR:Print("Import failed: this string is too large to be a profile.")
        elseif err == "unavailable" then
            HR:Print("Import unavailable (encoding library missing).")
        else
            HR:Print("Import failed: invalid or corrupted string.")
        end
        return false
    end

    local name, nOpt, nUI, nSpell = PS.Import(payload)
    if not name then HR:Print("Import failed: the profile could not be created."); return false end

    HR:Print(("Profile \"%s\" imported and activated (%d setting(s), %d window position(s), %d boss spell(s)).")
        :format(name, nOpt, nUI, nSpell))
    if UI.RefreshProfileTab then UI.RefreshProfileTab() end
    return true
end

local function BuildImport()
    local C = UI.Components
    local m = MakeModal("ECPProfileImport", "Import profile")
    local c = m.content

    local lbl = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("TOPLEFT", PAD, -14)
    lbl:SetPoint("RIGHT", c, "RIGHT", -PAD, 0)
    lbl:SetJustifyH("LEFT")
    lbl:SetTextColor(1, 1, 1)
    lbl:SetText("Paste a profile string below, then click Import:")

    m.box = C.StringBox(c, { onEscape = function() m:Hide() end })
    m.box:SetPoint("TOPLEFT", PAD, -38)
    m.box:SetPoint("BOTTOMRIGHT", -32, 74)

    -- Ce que l'import fera, ecrit AVANT qu'il ne le fasse. Un import de profil est
    -- inoffensif, encore faut-il que ca se voie : sans cette ligne, on hesite a cliquer.
    local note = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("BOTTOMLEFT", PAD, 46)
    note:SetPoint("RIGHT", c, "RIGHT", -PAD, 0)
    note:SetJustifyH("LEFT")
    note:SetText("A NEW profile is created and activated. None of your existing profiles "
        .. "is modified, and your plans are never affected.")

    local imp = C.TextButton(c, { text = "Import", width = 120, onClick = function()
        if UI.ImportProfileString(m.box:GetString()) then m:Hide() end
    end })
    imp:SetPoint("BOTTOMRIGHT", -PAD, 14)

    local cancel = C.TextButton(c, { text = "Cancel", width = 120, onClick = function() m:Hide() end })
    cancel:SetPoint("RIGHT", imp, "LEFT", -8, 0)

    UI.profileImportModal = m
    return m
end

function UI.OpenProfileImportModal()
    local m = UI.profileImportModal or BuildImport()
    m.box:SetString("")
    m:Show(); m:Raise()
    m.box:SelectAll()                                            -- cale la largeur + prend le focus
end
