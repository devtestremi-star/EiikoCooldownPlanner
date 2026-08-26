-- HealPlanner - Data/Roster.lua
-- Roles et classes pouvant les remplir (WoW Midnight 12.0.5, 13 classes).
-- Sert a la section "Composition" : 5 slots (1 tank / 1 heal / 3 dps).
-- Les tokens de classe sont ceux de UnitClass / CLASS_ICON_TCOORDS (MAJUSCULES).
-- Icones = textures NATIVES du client (pas d'asset externe) :
--   classes -> Interface\TargetingFrame\UI-Classes-Circles + CLASS_ICON_TCOORDS
--   roles   -> Interface\LFGFrame\UI-LFG-ICON-PORTRAITROLES (coords standard)
local addonName, HR = ...


-- Classes capables de tenir chaque role (source : guides de classe Midnight).
HR.ROLE_CLASSES = {
    TANK   = { "WARRIOR", "PALADIN", "DEATHKNIGHT", "MONK", "DRUID", "DEMONHUNTER" },
    HEALER = { "PRIEST", "PALADIN", "MONK", "DRUID", "SHAMAN", "EVOKER" },
    DPS    = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT",
               "SHAMAN", "MAGE", "WARLOCK", "MONK", "DRUID", "DEMONHUNTER", "EVOKER" },
}

--------------------------------------------------------------------------------
-- Icones de classe
--------------------------------------------------------------------------------

local CLASS_ICON_TEX = "Interface\\TargetingFrame\\UI-Classes-Circles"

-- Applique l'icone d'une classe sur une Texture (texture + texcoord).
function HR.ApplyClassIcon(tex, token)
    tex:SetTexture(CLASS_ICON_TEX)
    local c = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[token]
    if c then tex:SetTexCoord(c[1], c[2], c[3], c[4]) end
end

-- Sequence d'echappement |T...|t de l'icone d'une classe (pour les menus).
function HR.ClassIconMarkup(token, size)
    size = size or 16
    local c = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[token]
    if not c then return "" end
    -- Atlas 256x256, coords en fractions 0..1 -> pixels.
    return string.format("|T%s:%d:%d:0:0:256:256:%d:%d:%d:%d|t",
        CLASS_ICON_TEX, size, size,
        c[1] * 256, c[2] * 256, c[3] * 256, c[4] * 256)
end

-- Nom localise d'une classe a partir de son token.
function HR.ClassName(token)
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]) or token
end

-- Couleur de classe au format "ffRRGGBB" (pour |c...|r).
function HR.ClassColorHex(token)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
    return (c and c.colorStr) or "ffffffff"
end

--------------------------------------------------------------------------------
-- Profils de heal (identites de heal jouables)
--------------------------------------------------------------------------------
-- La plupart des classes de heal n'ont qu'UNE spe -> 1 profil = la classe. Le
-- PRETRE a DEUX spes heal (Discipline, Holy) avec des sorts et des plans
-- differents -> DEUX profils distincts. Le profil est l'unite du selecteur de
-- heal, des variantes par defaut, du filtrage des variantes et du choix de spe a
-- la creation. (NE PAS confondre avec Paladin Holy : c'est une classe a 1 spe heal.)
--   key   : identifiant stable (token de classe, ou "PRIEST_DISC"/"PRIEST_HOLY")
--   class : token de classe (icone + matching de compo)
--   spec  : nom EN de la spe heal (nil hors pretre) -> filtre les sorts par spe
--   icon  : texture du profil (icone de spe pour le pretre ; sinon icone de classe)
-- specID : ID de specialisation (icone de SPE via GetSpecializationInfoByID).
HR.HEAL_PROFILES = {
    { key = "DRUID",       class = "DRUID",   specID = 105 },   -- Restoration
    { key = "EVOKER",      class = "EVOKER",  specID = 1468 },  -- Preservation
    { key = "MONK",        class = "MONK",    specID = 270 },   -- Mistweaver
    { key = "PALADIN",     class = "PALADIN", specID = 65 },    -- Holy
    { key = "PRIEST_DISC", class = "PRIEST", spec = "Discipline", specID = 256 },
    { key = "PRIEST_HOLY", class = "PRIEST", spec = "Holy",       specID = 257 },
    { key = "SHAMAN",      class = "SHAMAN",  specID = 264 },   -- Restoration
}

-- Profil PSEUDO "pas de heal" : une variante de DPS/TANK (plan d'externals seul, aucun
-- soigneur designe). Volontairement HORS de HR.HEAL_PROFILES (iteree par le selecteur de
-- profil, les defauts par heal et le V1 legacy) : on ne pollue pas la liste des vrais
-- profils. `icon` EXPLICITE => HR.HealProfileIcon le renvoie directement et
-- HR.ApplyHealProfileIcon n'atteint jamais `p.class` (nil ici). Cf. HealProfileIcon plus bas.
HR.NO_HEALER = "NONE"
HR.NO_HEAL_PROFILE = {
    key  = HR.NO_HEALER,
    name = "No healer",
    icon = "Interface\\Icons\\INV_Misc_QuestionMark",
}

local PROFILE_BY_KEY = {}
for _, p in ipairs(HR.HEAL_PROFILES) do
    -- name = libelle de heal (sans "Default") : "Druid", "Holy Priest"...
    p.name = p.name or (p.spec and (p.spec .. " " .. HR.ClassName(p.class))) or HR.ClassName(p.class)
    PROFILE_BY_KEY[p.key] = p
end

-- Profil de heal par sa clef. nil si inconnue.
-- ⚠️ Renvoie nil pour HR.NO_HEALER : le pseudo-profil n'est PAS dans PROFILE_BY_KEY, pour
-- que tout le code existant garde par `if prof then` continue d'omettre proprement l'icone
-- de spe. Les sites qui doivent AFFICHER "No healer" traitent la clef explicitement.
function HR.GetHealProfile(key) return PROFILE_BY_KEY[key] end

-- Une variante sans soigneur designe ? Elle n'appartient a aucune spe -> jamais recalee
-- ni filtree par spe (elle est "de tout le monde").
function HR.IsNoHealerVariant(v)
    return v ~= nil and v.healer == HR.NO_HEALER
end

-- Profil de heal OU pseudo-profil "No healer" : pour les sites d'AFFICHAGE (libelle + icone)
-- qui doivent savoir representer une variante sans heal.
function HR.GetHealProfileOrNone(key)
    if key == HR.NO_HEALER then return HR.NO_HEAL_PROFILE end
    return PROFILE_BY_KEY[key]
end

--------------------------------------------------------------------------------
-- specID Blizzard -> (classe, spe EN). Source de VERITE pour identifier un joueur
-- d'un import externe : ni le role ni le NOM de spe ne suffisent ("Holy" = Paladin
-- OU Pretre, "Restoration" = Druide OU Chaman, "Frost" = Mage OU DK).
-- Utilise par Core/ShareText.lua. Un specID absent de cette table => on retombe sur
-- la classe et la spe transmises telles quelles (tolerant aux nouvelles spes).
--------------------------------------------------------------------------------
HR.SPEC_BY_ID = {
    [250]  = { class = "DEATHKNIGHT", spec = "Blood" },
    [251]  = { class = "DEATHKNIGHT", spec = "Frost" },
    [252]  = { class = "DEATHKNIGHT", spec = "Unholy" },
    [577]  = { class = "DEMONHUNTER", spec = "Havoc" },
    [581]  = { class = "DEMONHUNTER", spec = "Vengeance" },
    [1480] = { class = "DEMONHUNTER", spec = "Devourer" },   -- 3e spe DH, ajoutee en Midnight
    [102]  = { class = "DRUID",       spec = "Balance" },
    [103]  = { class = "DRUID",       spec = "Feral" },
    [104]  = { class = "DRUID",       spec = "Guardian" },
    [105]  = { class = "DRUID",       spec = "Restoration" },
    [1467] = { class = "EVOKER",      spec = "Devastation" },
    [1468] = { class = "EVOKER",      spec = "Preservation" },
    [1473] = { class = "EVOKER",      spec = "Augmentation" },
    [253]  = { class = "HUNTER",      spec = "Beast Mastery" },
    [254]  = { class = "HUNTER",      spec = "Marksmanship" },
    [255]  = { class = "HUNTER",      spec = "Survival" },
    [62]   = { class = "MAGE",        spec = "Arcane" },
    [63]   = { class = "MAGE",        spec = "Fire" },
    [64]   = { class = "MAGE",        spec = "Frost" },
    [268]  = { class = "MONK",        spec = "Brewmaster" },
    [269]  = { class = "MONK",        spec = "Windwalker" },
    [270]  = { class = "MONK",        spec = "Mistweaver" },
    [65]   = { class = "PALADIN",     spec = "Holy" },
    [66]   = { class = "PALADIN",     spec = "Protection" },
    [70]   = { class = "PALADIN",     spec = "Retribution" },
    [256]  = { class = "PRIEST",      spec = "Discipline" },
    [257]  = { class = "PRIEST",      spec = "Holy" },
    [258]  = { class = "PRIEST",      spec = "Shadow" },
    [259]  = { class = "ROGUE",       spec = "Assassination" },
    [260]  = { class = "ROGUE",       spec = "Outlaw" },
    [261]  = { class = "ROGUE",       spec = "Subtlety" },
    [262]  = { class = "SHAMAN",      spec = "Elemental" },
    [263]  = { class = "SHAMAN",      spec = "Enhancement" },
    [264]  = { class = "SHAMAN",      spec = "Restoration" },
    [265]  = { class = "WARLOCK",     spec = "Affliction" },
    [266]  = { class = "WARLOCK",     spec = "Demonology" },
    [267]  = { class = "WARLOCK",     spec = "Destruction" },
    [71]   = { class = "WARRIOR",     spec = "Arms" },
    [72]   = { class = "WARRIOR",     spec = "Fury" },
    [73]   = { class = "WARRIOR",     spec = "Protection" },
}

-- Clef de profil de heal pour (classe, spe). spec ignore hors pretre.
-- Pretre sans spe precisee => Discipline par defaut.
function HR.HealProfileKey(class, spec)
    if not class then return nil end
    if class == "PRIEST" then
        return (spec == "Holy") and "PRIEST_HOLY" or "PRIEST_DISC"
    end
    return class
end

-- Icone d'un profil de heal : icone de SPE (via specID), repli sur p.icon explicite,
-- puis sur l'icone de classe si rien n'est resolvable.
function HR.HealProfileIcon(p)
    if p.specID and GetSpecializationInfoByID then
        local _, _, _, specIcon = GetSpecializationInfoByID(p.specID)
        if specIcon then return specIcon end
    end
    return p.icon
end

-- Markup |T...|t de l'icone d'un profil de heal (icone de spe, sinon classe).
function HR.HealProfileIconMarkup(p, size)
    size = size or 16
    local icon = HR.HealProfileIcon(p)
    if icon then
        return string.format("|T%s:%d:%d:0:0:64:64:5:59:5:59|t", icon, size, size)
    end
    return HR.ClassIconMarkup(p.class, size)
end

-- Applique l'icone d'un profil de heal sur une Texture (icone de spe, sinon classe).
function HR.ApplyHealProfileIcon(tex, p)
    local icon = HR.HealProfileIcon(p)
    if icon then
        tex:SetTexture(icon)
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    else
        HR.ApplyClassIcon(tex, p.class)
    end
end

--------------------------------------------------------------------------------
-- Icones de role
--------------------------------------------------------------------------------

local ROLE_ICON_TEX = "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES"
-- Coords en pixels sur l'atlas 64x64 (valeurs standard de GetTexCoordsForRole).
local ROLE_TCOORDS = {
    TANK   = { 0,  19, 22, 41 },
    HEALER = { 20, 39,  1, 20 },
    DPS    = { 20, 39, 22, 41 },
}

--------------------------------------------------------------------------------
-- Composition du groupe (live) et signature
--------------------------------------------------------------------------------

-- Role du joueur deduit de sa SPEC ACTIVE (fiable, contrairement au role assigne
-- en donjon) : "TANK" / "HEALER" / "DAMAGER". nil si la spec n'est pas encore lue.
-- La spec ne peut pas changer en combat -> resultat stable pendant un pull.
function HR.GetPlayerRole()
    local spec = GetSpecialization and GetSpecialization()
    if not spec then return nil end
    return GetSpecializationRole and GetSpecializationRole(spec) or nil
end

-- Nom de la spec ACTIVE du joueur (ex. "Shadow", "Feral"). nil si non lisible.
-- ⚠️ Nom LOCALISE (GetSpecializationInfo) -> a comparer a des noms EN dans la data
--    (HR.defensives.spec / HR.personalDefensives.specs) : OK en client EN seulement.
function HR.GetPlayerSpecName()
    local idx = GetSpecialization and GetSpecialization()
    if not idx then return nil end
    local _, name = GetSpecializationInfo(idx)
    return name
end
