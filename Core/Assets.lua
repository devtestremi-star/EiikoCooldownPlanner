-- HealPlanner - Core/Assets.lua
-- Asset manager : registre central des assets de l'addon. Les modules NE hardcodent
-- PLUS de chemin ; ils demandent une CLE LOGIQUE et recoivent une valeur prete pour
-- SetTexture (ou un atlas via Apply). Source unique de verite + swap facile.
--
-- Format d'une entree du registre (un seul des champs) :
--   { file   = "sous\\chemin.tga" }  -> Interface\AddOns\<Addon>\Media\sous\chemin.tga
--   { path   = "Interface\\Icons\\..." } -> chemin complet utilise tel quel (icone Blizzard)
--   { fileID = 134400 }              -> fileID numerique
--   { atlas  = "nom-atlas" }         -> atlas Blizzard (via Apply / SetAtlas)
local addonName, HR = ...

HR.Assets = HR.Assets or {}
local A = HR.Assets

-- Prefixe Media construit depuis le nom du dossier d'addon (resiste au renommage).
local BASE = "Interface\\AddOns\\" .. addonName .. "\\Media\\"
local FALLBACK = 134400     -- icone "?" si cle inconnue / entree vide

-- Registre des assets. Cle logique -> definition. (Les entrees "path" pointent pour
-- l'instant vers des icones Blizzard ; remplace par { file = "icons\\xxx.tga" } quand
-- tu as les assets custom, cf. docs/EiikoCooldownPlanner/media-textures.md.)
A.registry = {
    ["mainframe-bg"]  = { file = "mainframe-bg.tga" },

    -- Fond de la zone de contenu PAR DONJON : une entree par shortname (abbr), rangee par
    -- version de pool : Media\Background\<VER>\bg-<abbr>.tga (absent/illisible => transparent).
    -- cf. UI.UpdateContentBg ("bg-" .. dungeon.abbr) et UI/HomePage.dungeonArt.
    -- ⚠️ La CLE est en MAJUSCULES (elle vient de dungeon.abbr) mais le NOM DE FICHIER est en
    -- MINUSCULES. Les deux ne se correspondent donc PAS : respecter la casse REELLE du fichier
    -- sur le disque. Windows ne voit pas la difference, un client Mac affiche un fond vide --
    -- c'etait le cas des 8 fonds du pool 12.1.0 jusqu'au 2026-08-26.
    -- Pool 12.1.0
    ["bg-AOF"]  = { file = "Background\\1210\\bg-aof.tga" },   -- Altar of Fangs
    ["bg-RLP"]  = { file = "Background\\1210\\bg-rlp.tga" },   -- Ruby Life Pools
    ["bg-TOS"]  = { file = "Background\\1210\\bg-tos.tga" },   -- Temple of Sethraliss
    ["bg-KR"]   = { file = "Background\\1210\\bg-kr.tga" },    -- Kings' Rest
    ["bg-TBV"]  = { file = "Background\\1210\\bg-tbv.tga" },   -- The Blinding Vale
    ["bg-VA"]   = { file = "Background\\1210\\bg-va.tga" },    -- Voidscar Arena
    ["bg-DON"]  = { file = "Background\\1210\\bg-don.tga" },   -- Den of Nalorakk
    ["bg-MR"]   = { file = "Background\\1210\\bg-mr.tga" },    -- Murder Row
    -- (Pool 12.0.7 : fonds SUPPRIMES le 2026-08-26 avec les assets de la saison precedente.
    --  ⚠️ PORTEE REELLE, plus large qu'il n'y parait : `HR.content =
    --  HR.contentByVersion[CLIENT_VERSION] or HR.content` (Data/Content.lua) retombe sur le
    --  pool 12.0.7 pour TOUT build non liste -- donc un futur 12.1.1 sert la liste 12.0.7,
    --  desormais SANS fond. Degradation propre (UI.UpdateContentBg et UI/HomePage.dungeonArt
    --  testent la cle avant de poser la texture : ni erreur, ni icone "?"), mais visible.
    --  Le vrai correctif est d'ajouter une entree dans contentByVersion a chaque build cible.)

    -- Fond de la vue SETTINGS (Media\Background\bg-1.tga ; absent => transparent).
    ["bg-settings"] = { file = "Background\\bg-1.tga" },
    -- Fond des modales de plan (Media\Background\bg-2.tga ; cover). Consommateurs :
    -- UI/HealerSpecs.lua (New/Duplicate/Export/Import), UI/SyncFrame.lua, UI/WhatsNew.lua.
    ["bg-variant"]  = { file = "Background\\bg-2.tga" },
    -- Fond generique bg-1 (Media\Background\bg-1.tga ; absent => transparent).
    ["bg-1"]        = { file = "Background\\bg-1.tga" },

    -- Icones d'outils de la sidebar : icones Blizzard natives (bordure rognee par le
    -- defaut crop). Anciennes textures custom (Media\Icons\faq.tga / wheel.tga) retirees
    -- car le format TGA re-sauve par l'editeur (RLE color-mapped) faisait CRASHER le client
    -- (ERROR #123 buffer overflow) au chargement de la texture.
    ["icon-faq"]   = { path = "Interface\\Icons\\INV_Misc_Book_09" },
    ["icon-wheel"] = { path = "Interface\\Icons\\Trade_Engineering" },
    -- Bouton HOME (haut de la sidebar) : REPLI seulement. L'icone visee est celle du HOUSING
    -- de Midnight, resolue a l'execution par A.ApplyHomeIcon (son atlas n'est pas stable d'un
    -- patch a l'autre). Repli = Pierre de foyer ("rentrer chez soi"), lisible sans texte.
    ["icon-home"]  = { path = "Interface\\Icons\\INV_Misc_Rune_01" },

    ["icon-defs"]     = { path = "Interface\\Icons\\ability_warrior_defensivestance" },
    ["icon-settings"] = { path = "Interface\\Icons\\inv_misc_gear_01" },
    ["icon-trash"]    = { path = "Interface\\Icons\\inv_misc_bone_skull_02" },
}

-- Ajoute / remplace une entree a l'execution (ex. un module enregistre ses assets).
function A.Register(key, def)
    A.registry[key] = def
end

-- Valeur prete pour Texture:SetTexture (chemin Media / chemin / fileID). Pour un atlas
-- ou une cle inconnue -> FALLBACK (preferer A.Apply pour gerer les atlas).
function A.Path(key)
    local e = A.registry[key]
    if not e then return FALLBACK end
    if e.file   then return BASE .. e.file end
    if e.path   then return e.path end
    if e.fileID then return e.fileID end
    return FALLBACK
end

-- Applique l'asset a une Texture (gere fichier/chemin/fileID ET atlas).
function A.Apply(tex, key)
    if not tex then return end
    local e = A.registry[key]
    if e and e.atlas then tex:SetAtlas(e.atlas) else tex:SetTexture(A.Path(key)) end
end

-- Raccourci pratique : HR.Asset("cle") == HR.Assets.Path("cle").
function HR.Asset(key) return A.Path(key) end

-- Icone HOME (bouton de la page d'accueil) : on veut la maison du HOUSING de Midnight, mais
-- son atlas n'est ni documente ni stable d'un patch a l'autre. On le RESOUT a l'execution,
-- dans cet ordre :
--   1. l'atlas REELLEMENT porte par le bouton Housing du micro-menu (source de verite : si
--      Blizzard le renomme, on suit sans rien changer ici) ;
--   2. quelques noms candidats, VALIDES par C_Texture.GetAtlasInfo (nil = atlas inexistant,
--      donc on ne pose jamais une texture vide) ;
--   3. repli sur l'icone de fichier "icon-home" (toujours presente).
-- Un atlas ecrase les TexCoord du crop d'icone, ce qui est voulu : on ne rogne pas un atlas.
function A.ApplyHomeIcon(tex)
    if not tex then return end
    local btn = _G.HousingMicroButton
    local nt  = btn and btn.GetNormalTexture and btn:GetNormalTexture()
    local atlas = nt and nt.GetAtlas and nt:GetAtlas()
    if not atlas and C_Texture and C_Texture.GetAtlasInfo then
        for _, name in ipairs({
            "UI-HUD-MicroMenu-Housing-Up",
            "housing-microbutton-up",
            "housing-icon-house",
            "Housing-Dashboard-Icon",
        }) do
            if C_Texture.GetAtlasInfo(name) then atlas = name; break end
        end
    end
    if atlas then tex:SetAtlas(atlas) else tex:SetTexture(A.Path("icon-home")) end
end
