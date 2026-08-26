-- HealPlanner - Data/Defensives.lua
-- Liste curee (hardcodee) des defensifs de zone / CD de raid, toutes classes.
-- Format : [spellID] = { name, cooldown = <s>, [charges = n], [itemId = n],
--                        [class = "TOKEN"], [role = "TANK"|"HEALER"|"DPS"] }
-- `class` : jeton de classe en MAJUSCULES (cf. UnitClass : "DRUID", "DEMONHUNTER"...).
-- `role`  : rôle/spé qui fournit le sort. Si present, le sort n'est propose que si
--   la composition contient un slot de CETTE classe ET de CE role (ex. Tranquility
--   = Druide en slot Heal ; un Druide Tank ne l'a pas). Si ABSENT, le sort est un
--   CD de classe dispo quelle que soit la spe (ex. Rallying Cry, Anti-Magic Zone) :
--   n'importe quel slot de cette classe suffit. Sans `class` (trinket) => toujours.
-- Le CD est la valeur THEORIQUE non modifiee (cf. discussion : les talents/hate
-- ne sont pas lisibles de facon fiable en Midnight, on hardcode).
local addonName, HR = ...

-- IMPORTE depuis defensives.csv (source de verite pour heal + external). Variantes de CD
-- (reduction par talent) => cle "spellID:0" / "spellID:1" + champ spellID (icone/tooltip).
--   talentReq = { spellID, ... } : TOUS doivent etre actifs.
--   talentNot = { spellID, ... } : AUCUN ne doit etre actif.
-- (Matching par membre = a brancher dans ScanGroupExternals ; cf. note.)
HR.defensives = {
    ----------------------------------------------------------------------------
    -- EXTERNALS
    ----------------------------------------------------------------------------
    ["51052:0"]   = { name = "Anti-Magic Zone (3 min)", cooldown = 180, class = "DEATHKNIGHT", short = "AMZ", spellID = 51052, external = true, talentReq = { 51052, 374383 } },
    ["51052:1"]   = { name = "Anti-Magic Zone (4 min)", cooldown = 240, class = "DEATHKNIGHT", short = "AMZ", spellID = 51052, external = true, talentReq = { 51052 }, talentNot = { 374383 } },
    ["196718:0"]  = { name = "Darkness (5 min)",        cooldown = 300, class = "DEMONHUNTER", short = "Dark", spellID = 196718, external = true, talentReq = { 196718 }, talentNot = { 389783 } },
    ["196718:1"]  = { name = "Darkness (3 min)",        cooldown = 180, class = "DEMONHUNTER", short = "Dark", spellID = 196718, external = true, talentReq = { 196718, 389783 } },
    -- Zephyr : MEME talent (spellID 374227) porte par un Evoker DPS (external, role DAMAGER) OU
    -- par un Evoker HEAL (Preservation) -> traite comme un CD de heal (entree ":heal", role HEALER).
    -- Le token distingue les deux ("374227" external vs "374227:heal"). cf. HR.TokenIsMine.
    [374227]      = { name = "Zephyr",                  cooldown = 120, class = "EVOKER", role = "DAMAGER", aoeOnly = true, short = "Zeph", external = true, talentReq = { 374227 } },
    ["374227:heal"] = { name = "Zephyr",                cooldown = 120, class = "EVOKER", role = "HEALER", aoeOnly = true, short = "Zeph", spellID = 374227, talentReq = { 374227 } },
    [15286]       = { name = "Vampiric Embrace",        cooldown = 120, class = "PRIEST", spec = "Shadow", short = "Vamp", external = true },
    [97462]       = { name = "Rallying Cry",            cooldown = 180, class = "WARRIOR", short = "Rally", external = true, talentReq = { 97462 } },
    -- Trinket HEALER-ONLY : `trinket = true` SANS `external` => propose uniquement dans le toolkit
    -- healer (HR.GetHealerTalentSpells) via token "@heal", jamais dans les externals raid.
    [1291894]     = { name = "Soulcoiler Ritual Vessel", cooldown = 120, itemId = 270162, icon = 7956752, short = "Vessel", trinket = true },

    ----------------------------------------------------------------------------
    -- HEALS (CD de spe soin)
    ----------------------------------------------------------------------------
    -- Druid
    ["740:0"]     = { name = "Tranquility (3 min)",     cooldown = 180, class = "DRUID", role = "HEALER", short = "Tranq", spellID = 740, talentReq = { 740 }, talentNot = { 197073 } },
    ["740:1"]     = { name = "Tranquility (2 min 30)",  cooldown = 150, class = "DRUID", role = "HEALER", short = "Tranq", spellID = 740, talentReq = { 740, 197073 } },
    -- choiceNode = 2 : Incarnation et Convoke sont un CHOIX de talent (un seul des deux).
    ["391528:0"]  = { name = "Convoke the Spirits",     cooldown = 120, class = "DRUID", role = "HEALER", short = "Conv", spellID = 391528, choiceNode = 2, talentReq = { 391528 }, talentNot = { 393371 } },
    ["391528:1"]  = { name = "Convoke the Spirits",     cooldown = 60,  class = "DRUID", role = "HEALER", short = "Conv", spellID = 391528, choiceNode = 2, talentReq = { 391528, 393371 } },
    ["33891:0"]   = { name = "Incarnation: Tree of Life (3 min)", cooldown = 180, class = "DRUID", role = "HEALER", short = "Inc", spellID = 33891, choiceNode = 2, talentReq = { 33891 }, talentNot = { 393371 } },
    ["33891:1"]   = { name = "Incarnation: Tree of Life (2 min)", cooldown = 120, class = "DRUID", role = "HEALER", short = "Inc", spellID = 33891, choiceNode = 2, talentReq = { 33891, 393371 } },
    -- Nature's Swiftness du DRUIDE (132158). Homonyme du sort CHAMAN (378081) plus bas :
    -- deux sorts distincts, jamais proposes au meme profil de heal. Reduit a 45 s par 382550.
    ["132158:0"]  = { name = "Nature's Swiftness (1 min)",  cooldown = 60, class = "DRUID", role = "HEALER", short = "NS", spellID = 132158, talentReq = { 132158 }, talentNot = { 382550 } },
    ["132158:1"]  = { name = "Nature's Swiftness (45 sec)", cooldown = 45, class = "DRUID", role = "HEALER", short = "NS", spellID = 132158, talentReq = { 132158, 382550 } },
    -- Monk
    -- choiceNode = 4 : Restoral et Revival sont un CHOIX de talent (un seul des deux).
    [388615]      = { name = "Restoral",               cooldown = 180, class = "MONK", role = "HEALER", short = "Res", choiceNode = 4, talentReq = { 388615 } },
    [115310]      = { name = "Revival",                cooldown = 180, class = "MONK", role = "HEALER", short = "Rev", choiceNode = 4, talentReq = { 115310 } },
    [443028]      = { name = "Celestial Conduit",      cooldown = 90,  class = "MONK", role = "HEALER", short = "Cond", talentReq = { 443028 } },
    -- choiceNode = 1 : Yu'lon et Chi-Ji sont un CHOIX de talent (un seul des deux).
    ["322118:0"]  = { name = "Invoke Yu'lon (1 min)",  cooldown = 60,  class = "MONK", role = "HEALER", short = "Yulon", spellID = 322118, choiceNode = 1, talentReq = { 322118, 388212 } },
    ["322118:1"]  = { name = "Invoke Yu'lon (2 min)",  cooldown = 120, class = "MONK", role = "HEALER", short = "Yulon", spellID = 322118, choiceNode = 1, talentReq = { 322118 }, talentNot = { 388212 } },
    ["325197:0"]  = { name = "Invoke Chi-Ji (1 min)",  cooldown = 60,  class = "MONK", role = "HEALER", short = "Chi", spellID = 325197, choiceNode = 1, talentReq = { 325197, 388212 } },
    ["325197:1"]  = { name = "Invoke Chi-Ji (2 min)",  cooldown = 120, class = "MONK", role = "HEALER", short = "Chi", spellID = 325197, choiceNode = 1, talentReq = { 325197 }, talentNot = { 388212 } },
    -- Paladin
    ["31821:0"]   = { name = "Aura Mastery (3 min)",    cooldown = 180, class = "PALADIN", role = "HEALER", short = "Aura", spellID = 31821, talentReq = { 31821 }, talentNot = { 392911 } },
    ["31821:1"]   = { name = "Aura Mastery (2 min 30)", cooldown = 150, class = "PALADIN", role = "HEALER", short = "Aura", spellID = 31821, talentReq = { 31821, 392911 } },
    -- choiceNode = 5 : Avenging Wrath et Avenging Crusader sont un CHOIX de talent.
    ["31884:0"]   = { name = "Avenging Wrath (2 min)",  cooldown = 120, class = "PALADIN", role = "HEALER", short = "AW", spellID = 31884, choiceNode = 5, talentReq = { 31884 }, talentNot = { 1241511 } },
    ["31884:1"]   = { name = "Avenging Wrath (1 min 45)", cooldown = 105, class = "PALADIN", role = "HEALER", short = "AW", spellID = 31884, choiceNode = 5, talentReq = { 31884, 1241511 } },
    ["216331:0"]  = { name = "Avenging Crusader (1 min)", cooldown = 120, class = "PALADIN", role = "HEALER", short = "AC", spellID = 216331, choiceNode = 5, talentReq = { 216331 }, talentNot = { 1241511 } },
    ["216331:1"]  = { name = "Avenging Crusader (52,5 sec)", cooldown = 105, class = "PALADIN", role = "HEALER", short = "AC", spellID = 216331, choiceNode = 5, talentReq = { 216331, 1241511 } },
    -- choiceNode = 8 : Divine Toll et Holy Prism sont un CHOIX de talent (un seul des deux).
    -- Le talent porte le MEME spellID que le sort -> talentReq = le sort lui-meme.
    -- Les DEUX sont reduits de 15 s par le talent 379391 : 45 s de base, 30 s avec.
    ["375576:0"]  = { name = "Divine Toll (45 sec)",   cooldown = 45,  class = "PALADIN", role = "HEALER", short = "Toll", spellID = 375576, choiceNode = 8, talentReq = { 375576 }, talentNot = { 379391 } },
    ["375576:1"]  = { name = "Divine Toll (30 sec)",   cooldown = 30,  class = "PALADIN", role = "HEALER", short = "Toll", spellID = 375576, choiceNode = 8, talentReq = { 375576, 379391 } },
    ["114165:0"]  = { name = "Holy Prism (45 sec)",    cooldown = 45,  class = "PALADIN", role = "HEALER", short = "Prism", spellID = 114165, choiceNode = 8, talentReq = { 114165 }, talentNot = { 379391 } },
    ["114165:1"]  = { name = "Holy Prism (30 sec)",    cooldown = 30,  class = "PALADIN", role = "HEALER", short = "Prism", spellID = 114165, choiceNode = 8, talentReq = { 114165, 379391 } },
    -- Priest
    ["64843:0"]   = { name = "Divine Hymn (3 min)",    cooldown = 180, class = "PRIEST", spec = "Holy", role = "HEALER", short = "Hymn", spellID = 64843, talentReq = { 64843 }, talentNot = { 419110 } },
    ["64843:1"]   = { name = "Divine Hymn (2 min)",    cooldown = 120, class = "PRIEST", spec = "Holy", role = "HEALER", short = "Hymn", spellID = 64843, talentReq = { 64843, 419110 } },
    [200183]      = { name = "Apotheosis",             cooldown = 120, class = "PRIEST", spec = "Holy", role = "HEALER", short = "Apo", talentReq = { 200183 } },
    [47788]       = { name = "Guardian Spirit",        cooldown = 120, class = "PRIEST", spec = "Holy", role = "HEALER", short = "GS", talentReq = { 47788 } },
    [472433]      = { name = "Evangelism",             cooldown = 90,  class = "PRIEST", spec = "Discipline", role = "HEALER", short = "Eva", talentReq = { 472433 } },
    -- choiceNode = 6 : Ultimate Penitence et Power Word: Barrier sont un CHOIX de talent.
    -- ⚠️ Le vrai spellID est 421453 ; la CLE reste 421543 (valeur erronee d'origine).
    -- On ne la renomme PAS : c'est elle qui est stockee dans les plans deja sauvegardes
    -- des joueurs. La corriger casserait leurs placements en lecture (token "421543"
    -- introuvable). On corrige au point de lecture : `spellID` donne l'icone, le tooltip
    -- et l'entree d'index pour les imports externes ; `talentReq` matche le vrai talent.
    [421543]      = { name = "Ultimate Penitence",     cooldown = 240, class = "PRIEST", spec = "Discipline", role = "HEALER", short = "UP", spellID = 421453, choiceNode = 6, talentReq = { 421453 } },
    [62618]       = { name = "Power Word: Barrier",    cooldown = 180, class = "PRIEST", spec = "Discipline", role = "HEALER", short = "PWB", choiceNode = 6, talentReq = { 62618 } },
    -- Shaman
    [98008]       = { name = "Spirit Link Totem",      cooldown = 180, class = "SHAMAN", role = "HEALER", short = "SLT", talentReq = { 98008 } },
    -- choiceNode = 7 : Ascendance et Healing Tide Totem sont un CHOIX de talent.
    -- Ascendance avec 2 talents (114052 + 462440) = version reduite a 2 min (120 s).
    ["114052:0"]  = { name = "Ascendance (2 min)",     cooldown = 120, class = "SHAMAN", role = "HEALER", short = "Asc", spellID = 114052, choiceNode = 7, talentReq = { 114052, 462440 } },
    ["114052:1"]  = { name = "Ascendance (3 min)",     cooldown = 180, class = "SHAMAN", role = "HEALER", short = "Asc", spellID = 114052, choiceNode = 7, talentReq = { 114052 }, talentNot = { 462440 } },
    ["108280:0"]  = { name = "Healing Tide Totem (2 min)", cooldown = 120, class = "SHAMAN", role = "HEALER", short = "HTT", spellID = 108280, choiceNode = 7, talentReq = { 108280, 462440 } },
    ["108280:1"]  = { name = "Healing Tide Totem (3 min)", cooldown = 180, class = "SHAMAN", role = "HEALER", short = "HTT", spellID = 108280, choiceNode = 7, talentReq = { 108280 }, talentNot = { 462440 } },
    -- Nature's Swiftness = BASELINE (prochain sort instantane). Remplace par Ancestral Swiftness
    -- quand le talent 443454 est pris -> n'existe que SANS 443454 (talentNot). Ancestral Swiftness
    -- (443454) = la version talentee, n'existe qu'AVEC 443454 (talentReq). Mutuellement exclusifs.
    [378081]      = { name = "Nature's Swiftness",     cooldown = 60,  class = "SHAMAN", role = "HEALER", short = "NS",   talentNot = { 443454 } },
    [443454]      = { name = "Ancestral Swiftness",    cooldown = 30,  class = "SHAMAN", role = "HEALER", short = "AncS", talentReq = { 443454 } },
    -- Evoker (Preservation)
    -- choiceNode = 3 : Stasis et Dream Flight sont un CHOIX de talent (un seul des deux).
    [370537]      = { name = "Stasis",                 cooldown = 90,  class = "EVOKER", role = "HEALER", short = "Sta", choiceNode = 3, talentReq = { 370537 } },
    [359816]      = { name = "Dream Flight",           cooldown = 120, class = "EVOKER", role = "HEALER", short = "DF", choiceNode = 3, talentReq = { 359816 } },
    ["363534:0"]  = { name = "Rewind (3 min)",         cooldown = 180, class = "EVOKER", role = "HEALER", short = "Rew", spellID = 363534, talentReq = { 363534 }, talentNot = { 381922 } },
    ["363534:1"]  = { name = "Rewind (2 min)",         cooldown = 120, class = "EVOKER", role = "HEALER", short = "Rew", spellID = 363534, talentReq = { 363534, 381922 } },

    ----------------------------------------------------------------------------
    -- GENERIQUES (appels de CD perso / tout lacher) -- inchanges
    ----------------------------------------------------------------------------
    -- Appel defensif perso GENERIQUE unique (la nuance small/big a ete retiree). CD 1m30.
    -- Icone PLACEHOLDER = Defensive Stance du guerrier (spellID 71).
    ["SMALL_DEF"] = { name = "Defensive", cooldown = 90, short = "Def",
                      icon = "Interface\\Icons\\ability_warrior_defensivestance" },
    ["EMPTY_BAG"] = { name = "Empty the bag", cooldown = 0, short = "Bag",
                      icon = "Interface\\Icons\\inv_misc_bone_skull_02" },
    -- Sort heal GENERIQUE de preparation (ramp) : sans CD, dispo pour TOUS les heals
    -- (pas de `class`). role=HEALER => traite comme un sort de heal (son heal, kind heal).
    -- Icone PLACEHOLDER (a ajuster).
    ["RAMP"] = { name = "Ramp", cooldown = 0, short = "Ramp", role = "HEALER",
                 icon = "Interface\\Icons\\spell_holy_prayerofhealing02" },
}

-- Defensifs PERSONNELS par classe/spe. Table SEPAREE de HR.defensives : le role "personal"
-- n'est pas un role de groupe (TANK/HEALER/DPS), donc ces sorts ne passent pas les filtres
-- par role et ne polluent pas le picker. Usage runtime : quand le heal place l'appel generique unique
-- SMALL_DEF, on resout LE sort perso du joueur (filtre classe + spe courante) via
-- HR.GetPersonalDefensives() -> [1].
-- Format : [spellID] = { name, cooldown = <s>, class = "TOKEN", [specs = { "SpecName", ... }], [main] }.
--   (Categorie UNIQUE "def" : la nuance small/big a ete retiree -> plus de champ defType.)
--   `specs` : si present, le sort n'est dispo que pour ces spes (noms EN, cf.
--             GetSpecializationInfo) ; absent => toute spe de la classe.
--   `main`  : true = defensif PRINCIPAL de la classe (ou de la spe si l'entree est `specs`-gated).
--             Resout l'appel generique SMALL_DEF ("Defensive") -> HR.GetMainPersonalDefensive().
--             Une classe a 1 seul perso => principal implicite (repli), pas besoin du flag.
-- CD = valeur THEORIQUE non modifiee (talents/hate non lisibles en Midnight).
HR.personalDefensives = {
    -- Death Knight
    [48707]  = { name = "Anti-Magic Shell",      cooldown = 45,  class = "DEATHKNIGHT" },
    [48792]  = { name = "Icebound Fortitude",    cooldown = 120, class = "DEATHKNIGHT", main = true },
    [48743]  = { name = "Death Pact",            cooldown = 120, class = "DEATHKNIGHT" },
    -- Demon Hunter
    [198589] = { name = "Blur",                  cooldown = 60,  class = "DEMONHUNTER" },
    -- Druid
    [22812]  = { name = "Barkskin",              cooldown = 60,  class = "DRUID", main = true },
    [61336]  = { name = "Survival Instincts",    cooldown = 180, class = "DRUID",   specs = { "Feral" } },
    -- Evoker
    [363916] = { name = "Obsidian Scales",       cooldown = 90,  class = "EVOKER" },
    -- Hunter
    [186265] = { name = "Aspect of the Turtle",  cooldown = 180, class = "HUNTER" },
    [109304] = { name = "Exhilaration",          cooldown = 120, class = "HUNTER" },
    [264735] = { name = "Survival of the Fittest", cooldown = 180, class = "HUNTER", main = true },
    -- Mage
    [45438]  = { name = "Ice Block",             cooldown = 240, class = "MAGE", main = true },
    [11426]  = { name = "Ice Barrier",           cooldown = 30,  class = "MAGE",    specs = { "Frost" } },
    [235313] = { name = "Blazing Barrier",       cooldown = 30,  class = "MAGE",    specs = { "Fire" } },
    [235450] = { name = "Prismatic Barrier",     cooldown = 30,  class = "MAGE",    specs = { "Arcane" } },
    [342245] = { name = "Alter Time",            cooldown = 60,  class = "MAGE" },
    -- Monk
    [243435] = { name = "Fortifying Brew",       cooldown = 120, class = "MONK", main = true },
    [122470] = { name = "Touch of Karma",        cooldown = 90,  class = "MONK",    specs = { "Windwalker" } },
    -- Paladin
    [498]    = { name = "Divine Protection",     cooldown = 60,  class = "PALADIN", specs = { "Holy" }, main = true },
    [403876] = { name = "Divine Protection",     cooldown = 60,  class = "PALADIN", specs = { "Retribution" }, main = true },
    [642]    = { name = "Divine Shield",         cooldown = 300, class = "PALADIN" },
    -- Priest
    [47585]  = { name = "Dispersion",            cooldown = 120, class = "PRIEST",  specs = { "Shadow" } },
    [19236]  = { name = "Desperate Prayer",      cooldown = 90,  class = "PRIEST",  specs = { "Discipline", "Holy" } },
    -- Rogue
    [31224]  = { name = "Cloak of Shadows",      cooldown = 120, class = "ROGUE" },
    -- Shaman
    [108271] = { name = "Astral Shift",          cooldown = 90,  class = "SHAMAN" },
    -- Warlock
    [104773] = { name = "Unending Resolve",      cooldown = 180, class = "WARLOCK", main = true },
    [108416] = { name = "Dark Pact",             cooldown = 60,  class = "WARLOCK" },
    -- Warrior
    [118038] = { name = "Die by the Sword",      cooldown = 120, class = "WARRIOR", specs = { "Arms" } },
    [184364] = { name = "Enraged Regeneration",  cooldown = 120, class = "WARRIOR", specs = { "Fury" } },
}

-- Icone par defaut (point d'interrogation) si rien n'est trouvable.
local FALLBACK_ICON = 134400

-- Vrai spellID d'un defensif a partir de sa cle (pour icone/tooltip). Si l'entree
-- porte un champ `spellID` (cle synthetique, ex. variantes de CD), on l'utilise ;
-- sinon la cle EST le spellID.
function HR.GetDefensiveSpellID(key)
    key = HR.DefKeyOf(key)   -- token -> defKey (gere "1291894"/"@heal"/"#N" -> 1291894)
    local d = HR.defensives[key]
    return (d and d.spellID) or key
end

-- Renvoie le fileID de l'icone d'un defensif (sort, ou objet si itemId).
-- En Midnight l'icone (texture) reste lisible meme si le CD est opaque.
function HR.GetDefensiveIcon(key)
    key = HR.DefKeyOf(key)   -- token -> defKey (sinon un trinket/itemId comme Vessel rate son icone)
    local d = HR.defensives[key]
    if d and d.icon then
        return d.icon                       -- fileID ou chemin de texture explicite
    end
    if d and d.itemId then
        return C_Item.GetItemIconByID(d.itemId) or FALLBACK_ICON
    end
    local realID = HR.GetDefensiveSpellID(key)
    return (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(realID)) or FALLBACK_ICON
end

-- Renvoie le fileID de l'icone d'un sort quelconque (capacite de boss).
function HR.GetSpellIcon(spellID)
    return (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(spellID)) or FALLBACK_ICON
end

-- Liste des "externals" : CD de groupe HORS heal (flag `external = true`), triee par
-- nom. Sert a la section "Available Externals" (ce que le groupe apporte comme CD
-- externe). UI seulement pour l'instant ; le lien avec la planification viendra.
function HR.GetExternals()
    local list = {}
    for key, d in pairs(HR.defensives) do
        if d.external then
            list[#list + 1] = { key = key, name = d.name, cooldown = d.cooldown }
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- Resout une cle d'external/defensif en son entree HR.defensives. Gere les cles BRUTES
-- (spellID numerique) qui ne matchent pas quand le sort a des VARIANTES de CD
-- ("51052:0"/"51052:1") : repli sur la 1re variante de meme spellID. Renvoie def, key.
function HR.ResolveDefEntry(key)
    if key == nil then return nil end
    key = HR.DefKeyOf(key)   -- token -> defKey ("443028" -> 443028, "51052:240#2" -> "51052:240")
    local d = HR.defensives[key]
    if d then return d, key end
    if type(key) == "number" then
        for k, def in pairs(HR.defensives) do
            if def.spellID == key then return def, k end
        end
    end
    return nil
end

-- Le joueur peut-il utiliser ce defensif, vu sa CLASSE, son ROLE et sa SPEC active ?
--   - sans `class` (SMALL_DEF/BIG_DEF/EMPTY_BAG/trinket) => generique, vrai.
--   - `class` : doit etre celle du joueur.
--   - `role`  : si present, doit == le role du joueur (HEALER/TANK/DAMAGER).
--   - `spec` (chaine) ou `specs` (liste) : si present, la spec active doit en faire partie.
-- Detection runtime (rangee de rappel) : evite de proposer un CD que la spec n'a pas
-- (ex. Vampiric Embrace = Shadow uniquement).
function HR.PlayerCanUseDefensive(def)
    if not def then return false end
    if not def.class then return true end                       -- generique
    local _, pClass = UnitClass("player")
    if def.class ~= pClass then return false end
    if def.role and def.role ~= HR.GetPlayerRole() then return false end
    if def.spec or def.specs then
        local sp = HR.GetPlayerSpecName()
        if not sp then return false end
        if def.spec == sp then return true end
        if def.specs then
            for _, s in ipairs(def.specs) do if s == sp then return true end end
        end
        return false
    end
    return true
end

-- Defensifs PERSONNELS jouables par le joueur (classe + role + spe COURANTE).
-- Categorie UNIQUE "def" (la nuance small/big a ete retiree). Renvoie une liste triee par nom.
function HR.GetPersonalDefensives()
    local list = {}
    for id, d in pairs(HR.personalDefensives) do
        if HR.PlayerCanUseDefensive(d) then
            list[#list + 1] = { spellID = id, name = d.name, cooldown = d.cooldown }
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- Defensif perso PRINCIPAL du joueur : l'entree flaggee `main` JOUABLE (classe + spe courante).
-- Repli sur le 1er (par nom) si aucun main jouable pour la spe. Sert a resoudre l'appel
-- generique SMALL_DEF ("Defensive") vers le VRAI sort du joueur.
function HR.GetMainPersonalDefensive()
    local list = HR.GetPersonalDefensives()
    for _, e in ipairs(list) do
        local d = HR.personalDefensives[e.spellID]
        if d and d.main then return e end
    end
    return list[1]
end

-- TAMPON : icone d'AFFICHAGE d'un token de defensif. Pour l'appel generique "personal"
-- SMALL_DEF ("Defensive"), renvoie l'icone du defensif perso PRINCIPAL du joueur (flag `main`,
-- via HR.GetMainPersonalDefensive) au lieu de l'icone generique -> le joueur voit SON sort.
-- Repli sur l'icone generique si aucun perso jouable. Tout autre token => icone normale.
function HR.GetDirectiveIcon(token)
    if HR.DefKeyOf(token) == "SMALL_DEF" then
        local pers = HR.GetMainPersonalDefensive()
        if pers then return HR.GetDefensiveIcon(pers.spellID) end
    end
    return HR.GetDefensiveIcon(token)
end
