-- EiikoCooldownPlanner - Core/Catalog.lua
-- CATALOGUE recu : stockage et import des packs publies par l'addon compagnon
-- « ECP Packager ». Cf. memo §13.
--
-- Le catalogue est une table A PART de `db2.dungeons`, precisement pour ne pas noyer le
-- joueur sous des variantes qu'il n'a pas demandees (memo §1).
--
-- ⚠️ DEUX endroits SEULEMENT touchent `db2.dungeons`, tous deux en fin de fichier :
-- `Cat.Promote` (le joueur adopte une entree) et `Cat.PropagateUpdates` (l'auteur met a
-- jour ce qu'il a deja adopte). Les deux sont bornes par le `catalogVariantId` -- une
-- variante ecrite par le joueur n'en porte pas et reste donc hors d'atteinte. Ne pas
-- ajouter de troisieme site d'ecriture ailleurs.
--
-- Cle ADDITIVE dans ECPlannerDB. ⚠️ Ne JAMAIS bumper DB_SCHEMA pour ca : un bump efface
-- les trois SavedVariables, donc tous les plans de tous les joueurs.
local addonName, HR = ...

HR.Catalog = HR.Catalog or {}
local Cat = HR.Catalog

local WIRE_FORMAT = 3          -- doit correspondre au Packager (Core/Codec.lua)
local WIRE_KIND   = "catalog"
local MAX_ENTRIES = 100        -- memo §12.4
local TEXT_MAX    = 64         -- memo §12.4 : on tronque ce qui s'affiche

--------------------------------------------------------------------------------
-- Stockage
--------------------------------------------------------------------------------

-- db2.catalog = {
--   creators = { [creatorId] = { id, name, at, twitch, x, discord } },
--   packs    = { [packId]    = { packId, creatorId, spec, dID, name, at, entries = {...} } },
-- }
--
-- Les packs sont a PLAT, pas ranges par createur : la recherche part du DONJON et
-- balaie tous les auteurs (memo §13.1). Un rangement par createur obligerait a traverser
-- deux niveaux pour la requete la plus frequente.
function Cat.Store()
    local db = HR.db2
    if not db then return nil end
    db.catalog = db.catalog or {}
    db.catalog.creators = db.catalog.creators or {}
    db.catalog.packs    = db.catalog.packs or {}
    return db.catalog
end

function Cat.Creator(creatorId)
    local s = Cat.Store()
    return s and s.creators[creatorId] or nil
end

-- Le catalogue contient-il quelque chose a MONTRER ? C'est ce qui deverrouille la feature
-- cote joueur : tant que rien n'a ete importe, l'icone de la barre laterale et le bouton
-- « Browse catalogue » restent masques (un ecran vide n'explique rien, et une entree de
-- menu qui ne mene nulle part est pire que pas d'entree du tout). Le PREMIER import ouvre
-- l'acces.
--
-- On compte les ENTREES, pas les packs : un pack vide est un geste de suppression (memo
-- §10.6) et peut parfaitement subsister sans rien a afficher.
--
-- VERROU A SENS UNIQUE. La valeur reste DERIVEE -- rien n'est ecrit en DB, `_has` vit en
-- memoire et un /reload la recalcule depuis la seule verite, la table elle-meme. Mais le
-- catalogue ne se vide pas dans la vie normale : il se remplit. Une fois trouve du contenu,
-- on ne rebalaie donc plus, alors que l'appel arrive a chaque redessin de la barre laterale.
--
-- ⚠️ TROIS points d'invalidation, tous dans CE fichier, et c'est ce qui rend le cache sur :
-- `Cat.Apply` (un instantane peut RETIRER des entrees), `Cat.DeletePack`, `Cat.DeleteCreator`
-- -- plus `Cat.Reset`, l'outil de test. Toute nouvelle voie qui retire du contenu doit poser
-- `Cat._has = nil`. Elle sera forcement ecrite ici, a cote de celles-la.
Cat._has = nil        -- nil = a redecouvrir ; true = verrouille ouvert

function Cat.HasContent()
    if Cat._has then return true end
    local s = Cat.Store()
    if not s then return false end
    for _, p in pairs(s.packs) do
        if type(p.entries) == "table" and next(p.entries) then
            Cat._has = true
            return true
        end
    end
    return false
end

-- OUTIL DE TEST (`/ecp catalog reset`). Vide la table du catalogue, et RIEN d'autre.
--
-- ⚠️ Portee volontairement etroite : `db2.catalog` uniquement. On ne touche PAS a
-- `db2.dungeons`. Les variantes deja promues RESTENT, en l'etat, en lecture seule -- c'est
-- la regle « on ne supprime jamais rien chez le joueur » (memo §10.9), et elles deviennent
-- simplement ORPHELINES : leur `catalogVariantId` ne correspond plus a aucune entree, donc
-- elles cessent de recevoir les mises a jour. C'est un etat DERIVE, jamais stocke, donc il
-- n'y a rien a nettoyer -- et ce reset est justement le moyen le plus simple d'exercer ce
-- chemin-la en jeu.
function Cat.Reset()
    local db = HR.db2
    if not db then return false end
    db.catalog = nil
    Cat._has = nil
    Cat.Store()
    return true
end

--------------------------------------------------------------------------------
-- Assainissement
--------------------------------------------------------------------------------

local function text(s)
    if type(s) ~= "string" then return nil end
    s = strtrim(s)
    if s == "" then return nil end
    -- Sur les CARACTERES : `s:sub(1, n)` coupe des OCTETS et casserait un accent en deux
    -- (losange noir a l'ecran, et CBOR possiblement refuse). Cf. HR.TruncateUTF8.
    return HR.TruncateUTF8(s, TEXT_MAX)
end

-- Donjon connu de CE client ? Le pool de contenu est patch-exact (Data/Content.lua) : un
-- pack publie sur une autre version peut porter des donjons qu'on ne connait pas.
local function knownDungeon(dID)
    for _, d in ipairs(HR.content or {}) do
        if d.id == dID then return true end
    end
    return false
end

-- Une entree du fil -> une entree stockee, ou nil + raison.
-- ⚠️ Chaque entree se valide SEULE (le `healer` est de-factorise, memo §12.1) : une
-- entree invalide est ecartee avec son motif, elle n'empoisonne pas le lot.
local function sanitizeEntry(w, packDID)
    if type(w) ~= "table" then return nil, "malformed" end
    if type(w.cid) ~= "string" then return nil, "missing id" end

    -- Le donjon de l'entree, avec REPLI sur celui du pack.
    -- ⚠️ Necessaire, pas defensif par principe : une entree est l'instantane d'une variante,
    -- et les variantes d'ECP ne portaient pas encore leur `dID` (memo §2.4/§9.1, correctif
    -- applique depuis). Les packs deja publies avant ce correctif ont donc des entrees sans
    -- donjon -- alors que le PACK, lui, le declare et qu'il est l'instantane d'UN donjon.
    -- Sans ce repli, tout un catalogue serait rejete pour « donjon inconnu ».
    local dID = w.dID or packDID
    if not knownDungeon(dID) then return nil, "unknown dungeon" end
    -- En revanche, une entree qui declare un AUTRE donjon que son pack est incoherente :
    -- on refuse plutot que de choisir. Un pack est l'instantane d'un seul donjon.
    if w.dID and packDID and w.dID ~= packDID then return nil, "dungeon mismatch" end
    w = { cid = w.cid, nm = w.nm, hl = w.hl, dID = dID,
          ext = w.ext, tsp = w.tsp, asg = w.asg }
    -- Clef de heal REELLE : une clef inconnue creerait une entree fantome, invisible dans
    -- les selecteurs (qui n'iterent que HEAL_PROFILES + NO_HEALER) donc inatteignable.
    if not HR.GetHealProfileOrNone(w.hl) then return nil, "unknown healer spec" end

    return {
        cid          = w.cid,
        name         = text(w.nm) or "?",
        healer       = w.hl,
        dID          = w.dID,
        externals    = HR.Share.SanitizeExternals(w.ext),
        talentSpells = (type(w.tsp) == "table") and HR.DeepCopy(w.tsp) or {},
        assignments  = HR.Share.SanitizeAssignments(w.dID, w.asg),
    }
end

--------------------------------------------------------------------------------
-- Lecture d'une chaine
--------------------------------------------------------------------------------

-- Cette chaine ressemble-t-elle a un catalogue ? (aiguillage a l'import)
function Cat.Looks(str)
    if type(str) ~= "string" then return false end
    return strtrim(str):match("^ecp;%d+;" .. WIRE_KIND) ~= nil
end

-- Chaine -> payload valide, ou (nil, message). Ne touche a RIEN : c'est la lecture seule
-- qui alimente l'ecran de recapitulatif (memo §13.4).
function Cat.Decode(str)
    if type(str) ~= "string" then return nil, "Empty string." end
    -- ⚠️ On retire les CR AVANT de decouper. Une chaine copiee depuis un site, Discord
    -- ou le Bloc-notes arrive en CRLF : `kind` capturait alors « catalog<CR> »,
    -- `Cat.Looks` repondait quand meme oui (le CR est APRES le mot), et l'import
    -- echouait sur « Unexpected type: catalog » -- un message qui accuse la chaine
    -- d'etre corrompue alors qu'elle est parfaite. Le parseur du format texte fait
    -- deja ce menage (Core/ShareText.lua).
    str = str:gsub("\r", "")
    local fmt, kind, b64 = strtrim(str):match("^ecp;(%d+);([^\n]*)\n(.*)$")
    if not fmt then return nil, "This is not an ECP catalogue string." end
    if kind ~= WIRE_KIND then return nil, ("Unexpected type: %s"):format(tostring(kind)) end
    if tonumber(fmt) ~= WIRE_FORMAT then
        return nil, "This catalogue was exported by a different version of the addon."
    end

    local payload, why = HR.Share.DecodeRaw((b64:gsub("%s", "")))
    if why == "too_large" then
        return nil, "This catalogue is far too large to be genuine. Nothing was read."
    end
    if type(payload) ~= "table" then return nil, "Unreadable or corrupted catalogue." end
    if type(payload.cr) ~= "table" or type(payload.cr.id) ~= "string" then
        return nil, "This catalogue has no creator identity."
    end
    if type(payload.pk) ~= "table" then return nil, "This catalogue contains no pack." end
    return payload
end

--------------------------------------------------------------------------------
-- Analyse AVANT ecriture (alimente l'ecran de recapitulatif, memo §13.4)
--------------------------------------------------------------------------------

-- Renvoie un rapport :
--   { creator = <carte>, creatorKnown = bool, older = bool,
--     dungeons = { { dID, dungeon, count, added, updated, removed }, ... },
--     total = <entrees qui seront ecrites>, rejected = { "motif", ... } }
--
-- Rien n'est ecrit ici. C'est ce qui permet de MONTRER ce qui va changer avant de le
-- faire -- le pendant, cote joueur, du point de controle qu'a le createur avant publication.
function Cat.Analyse(payload)
    local s = Cat.Store()
    if not s then return nil end

    local rep = { creator = payload.cr, dungeons = {}, rejected = {}, total = 0, removals = 0 }
    local known = s.creators[payload.cr.id]
    rep.creatorKnown = known ~= nil

    -- DEUX horodatages, DEUX questions -- ils etaient confondus, et le second ne pouvait
    -- donc jamais repondre.
    --
    -- 1. `cardOlder` : la carte createur est-elle perimee ? Elle se compare a ELLE-MEME
    --    (memo §7.5) : `cr.at` date le PROFIL, pas la publication, pour qu'importer un
    --    vieux pack apres un recent n'ecrase pas des reseaux a jour.
    rep.cardOlder = (known and known.at and payload.cr.at and payload.cr.at < known.at) or false

    -- 2. `older` : ce CATALOGUE est-il plus ancien que ce que j'ai deja ? C'est
    --    l'avertissement consultatif du §12.2, et il se calcule sur l'horodatage des PACKS
    --    (rempli plus bas, dans la boucle). Il portait jusqu'ici sur `cr.at` -- or
    --    `Creator.Set` ne bump ce champ que si l'auteur EDITE son profil : dix publications
    --    sans y toucher emettaient dix fois la meme date, et l'avertissement ne pouvait
    --    litteralement jamais se declencher.
    rep.older = false

    for _, wp in ipairs(payload.pk) do
        -- `pid` sert de CLE d'ecriture dans `s.packs` (Cat.Apply) : sans lui, l'ecriture
        -- leve « table index is nil » APRES que la carte createur a deja ete posee, donc
        -- sur un store a moitie mis a jour. Et `ent` est parcouru en ipairs. Deux types a
        -- verifier ici, avec les autres : ce fichier traite son entree comme non fiable.
        if type(wp) == "table" and type(wp.pid) == "string" and knownDungeon(wp.dID)
           and (wp.ent == nil or type(wp.ent) == "table") then
            local existing = s.packs[wp.pid]
            -- Ce pack-la recule-t-il dans le temps ? Un seul suffit a poser l'avertissement.
            if existing and existing.at and wp.at and wp.at < existing.at then
                rep.older = true
            end
            local before = {}
            for _, e in ipairs((existing and existing.entries) or {}) do before[e.cid] = true end

            local kept, added = {}, 0
            for _, w in ipairs(wp.ent or {}) do
                local e, why = sanitizeEntry(w, wp.dID)
                if e then
                    kept[#kept + 1] = e
                    if not before[e.cid] then added = added + 1 end
                    before[e.cid] = nil
                else
                    -- Le nom vient de la chaine : BORNE (`text`) et ECHAPPE a
                    -- l'affichage, comme partout ailleurs (memo §7.4 / §12.4). Brut, il
                    -- laissait injecter un faux lien cliquable -- ou plusieurs kilo-octets
                    -- -- dans le recapitulatif d'import.
                    local nm = (type(w) == "table" and text(w.nm)) or "?"
                    rep.rejected[#rep.rejected + 1] =
                        ("%s: %s"):format(HR.EscapeMarkup(nm), tostring(why))
                end
            end
            local removed = 0
            for _ in pairs(before) do removed = removed + 1 end

            local dungeon
            for _, d in ipairs(HR.content or {}) do if d.id == wp.dID then dungeon = d end end

            rep.dungeons[#rep.dungeons + 1] = {
                dID     = wp.dID,
                dungeon = dungeon,
                count   = #kept,
                added   = added,
                updated = #kept - added,
                removed = removed,
                _pack   = wp,
                _kept   = kept,
            }
            rep.total = rep.total + #kept
            -- Total des SUPPRESSIONS, a cote du total des ecritures. L'ecran d'import gate
            -- sur les deux : un pack vide n'ecrit rien mais RETIRE, et c'est un geste
            -- legitime -- la retractation de l'auteur (memo §10.6).
            rep.removals = rep.removals + removed
        elseif type(wp) == "table" then
            rep.rejected[#rep.rejected + 1] =
                ("dungeon %s is unknown to this version"):format(tostring(wp.dID))
        end
    end

    -- Borne du memo §12.4. Verifiee APRES la deserialisation : c'est le filet de la
    -- borne de taille, pour ce qui serait bien compresse mais absurde en structure.
    if rep.total > MAX_ENTRIES then
        return nil, ("This catalogue declares %d variants (limit %d). Nothing was read.")
            :format(rep.total, MAX_ENTRIES)
    end
    return rep
end

--------------------------------------------------------------------------------
-- Ecriture (seul chemin qui touche la DB)
--------------------------------------------------------------------------------

-- Applique un rapport produit par Cat.Analyse.
--
-- ⚠️ DEUX NIVEAUX D'ABSENCE, a ne jamais confondre (memo §10.5, §13) :
--   * une ENTREE absente d'un pack de donjon => elle est SUPPRIMEE (le pack est
--     l'instantane de ce donjon) ;
--   * un DONJON absent du conteneur => on n'y touche PAS.
-- C'est ce qui fait qu'importer le pack KR ne detruit jamais celui de BV.
function Cat.Apply(rep)
    local s = Cat.Store()
    if not (s and rep) then return false end
    -- Le contenu change dans les DEUX sens : un instantane ajoute, mais il RETIRE aussi
    -- (une entree absente du pack a ete supprimee par l'auteur, memo §10.5). On rend donc
    -- la main au calcul plutot que de supposer que ca ne peut qu'augmenter.
    Cat._has = nil

    -- Carte createur : remplacee seulement si plus recente (ou inconnue). On teste
    -- `cardOlder`, pas `older` : la fraicheur du profil et celle des packs sont deux
    -- questions distinctes, et un catalogue en retard peut tres bien porter une carte a jour.
    if not rep.cardOlder then
        local c = rep.creator
        s.creators[c.id] = {
            id      = c.id,
            name    = text(c.name),
            at      = c.at,
            twitch  = text(c.twitch),
            x       = text(c.x),
            discord = text(c.discord),
        }
    end

    for _, d in ipairs(rep.dungeons) do
        local wp = d._pack
        s.packs[wp.pid] = {
            packId    = wp.pid,
            creatorId = rep.creator.id,
            spec      = nil,                 -- rempli plus bas depuis les entrees
            dID       = wp.dID,
            name      = text(wp.nm),
            at        = wp.at,
            entries   = d._kept,             -- REMPLACEMENT integral : instantane du donjon
        }
        -- La spe du pack se DEDUIT de ses entrees (elles portent chacune leur `healer`
        -- depuis la de-factorisation, §12.1). Pas de champ declare a croire sur parole.
        local sp = d._kept[1] and d._kept[1].healer
        s.packs[wp.pid].spec = sp
    end

    -- Les variantes DEJA PROMUES suivent la mise a jour (memo §10.9). C'est le seul
    -- moment ou l'import touche `db2.dungeons`, et la cible est bornee par le
    -- `catalogVariantId` : une variante ecrite par le joueur n'en porte pas.
    local touched = Cat.PropagateUpdates(rep)
    return true, touched
end

--------------------------------------------------------------------------------
-- Requetes (alimentent l'ecran de recherche, memo §13.2)
--------------------------------------------------------------------------------

-- Toutes les entrees d'un donjon, tous createurs confondus.
-- Balayage direct : quelques centaines d'entrees au maximum (memo §13.1), aucun index.
-- Chaque element : { entry, pack, creator }.
function Cat.EntriesForDungeon(dID)
    local s = Cat.Store()
    local out = {}
    if not (s and dID) then return out end
    for _, p in pairs(s.packs) do
        if p.dID == dID then
            for _, e in ipairs(p.entries or {}) do
                out[#out + 1] = { entry = e, pack = p, creator = s.creators[p.creatorId] }
            end
        end
    end
    return out
end

-- Compte par donjon, pour la liste de premier niveau. Le donjon est le SEUL niveau ou le
-- vide est une information (« personne n'a rien ici ») -- ailleurs on ne propose que ce
-- qui donne des resultats (memo §13.2).
function Cat.CountsByDungeon()
    local s = Cat.Store()
    local counts = {}
    if not s then return counts end
    for _, p in pairs(s.packs) do
        counts[p.dID] = (counts[p.dID] or 0) + #(p.entries or {})
    end
    return counts
end

-- Spes REELLEMENT presentes dans un donjon (liste derivee, memo §13.2).
function Cat.SpecsForDungeon(dID)
    local seen, out = {}, {}
    for _, it in ipairs(Cat.EntriesForDungeon(dID)) do
        local k = it.entry.healer
        if k and not seen[k] then seen[k] = true; out[#out + 1] = k end
    end
    return out
end

-- Filtrage. `query` = { dID, spec, spells, creatorId }.
--
-- ⚠️ `spells` NIL OU VIDE = AUCUNE CONTRAINTE, tout passe (memo §13.2). Surtout pas
-- « ensemble vide donc zero resultat » -- c'est le piege habituel de ce genre de filtre.
--
-- TODO(§13.7) — La SEMANTIQUE du filtre de sorts n'est PAS tranchee. Trois lectures
-- possibles, qui ne servent pas le meme besoin :
--     * « contient »        : la variante declare ce sort ;
--     * « jouable par moi » : tout ce qu'elle exige, je l'ai (la plus utile ; ECP sait
--                             deja scanner le groupe via HR.ScanGroupExternals) ;
--     * « exclut »          : la variante ne depend PAS de ce sort.
-- En attendant la decision, le filtre est INERTE : il laisse tout passer. Ne pas deviner
-- ici -- le mauvais choix se verrait tard et fausserait la recherche en silence.
function Cat.Search(query)
    query = query or {}
    local out = {}
    for _, it in ipairs(Cat.EntriesForDungeon(query.dID)) do
        local ok = true
        if query.spec and it.entry.healer ~= query.spec then ok = false end
        if ok and query.creatorId and it.pack.creatorId ~= query.creatorId then ok = false end
        -- if ok and query.spells then ... end   -- cf. TODO ci-dessus
        if ok then out[#out + 1] = it end
    end
    -- TODO(§13.7) — ORDRE PAR DEFAUT non tranche (par createur ? par fraicheur ? par
    -- nombre de placements ?). Avec plusieurs auteurs sur un donjon, ce tri decide de qui
    -- est vu en premier : ce n'est pas neutre. Tri par nom en attendant, faute de mieux.
    table.sort(out, function(a, b) return (a.entry.name or "") < (b.entry.name or "") end)
    return out
end

-- Createurs presents dans un resultat, avec leur compte. Derive du resultat DEJA filtre
-- (memo §13.2) : le createur est un resserrement, pas un filtre de meme rang. Proposer un
-- auteur sans correspondance ne serait qu'une impasse.
function Cat.CreatorFacet(results)
    local byId, out = {}, {}
    for _, it in ipairs(results or {}) do
        local id = it.pack.creatorId
        if not byId[id] then
            byId[id] = { creatorId = id, creator = it.creator, count = 0 }
            out[#out + 1] = byId[id]
        end
        byId[id].count = byId[id].count + 1
    end
    table.sort(out, function(a, b)
        return ((a.creator and a.creator.name) or "") < ((b.creator and b.creator.name) or "")
    end)
    return out
end

--------------------------------------------------------------------------------
-- PROMOTION : entree de catalogue -> variante JOUABLE (memo §10.9)
--
-- ⚠️ SEUL endroit de ce fichier qui ecrit dans `db2.dungeons`. Tout le reste vit dans la
-- table catalogue, a part. C'est ici que se concentre le risque, donc ici que les regles
-- doivent etre tenues :
--
--   * la variante promue est en LECTURE SEULE (`catalogVariantId` -> HR.CanEditVariant) ;
--   * elle recoit les mises a jour de son auteur AUTOMATIQUEMENT ;
--   * pour l'editer, on la DUPLIQUE -- la copie ne reprend pas `catalogVariantId`
--     (V2_DuplicateVariant construit champ par champ), donc elle est libre et sort du
--     perimetre des ecrasements futurs. C'est l'echappatoire, et c'est la seule ;
--   * ON NE SUPPRIME JAMAIS RIEN CHEZ LE JOUEUR : si l'auteur retire l'entree, la
--     variante promue RESTE, en l'etat, et cesse simplement d'etre mise a jour. L'etat
--     « liee / orpheline » se DEDUIT (l'entree existe-t-elle encore ?), il ne se stocke
--     pas -- un etat derive ne peut pas deriver.
--------------------------------------------------------------------------------

-- La variante promue correspondant a cette entree, ou nil. Le `catalogVariantId` etant
-- unique au monde (nanoid), le chercher dans le donjon de l'entree suffit -- et c'est ce
-- qui garantit qu'on ne touchera jamais la variante d'un autre auteur, ni celle du joueur
-- (qui n'en porte pas).
function Cat.PromotedVariant(cid, dID)
    local s = HR.db2 and HR.db2.dungeons and HR.db2.dungeons[dID]
    if not (s and s.variants and cid) then return nil end
    for _, v in pairs(s.variants) do
        if v.catalogVariantId == cid then return v end
    end
    return nil
end

-- Promeut une entree. Renvoie (variante, "created") ou (variante, "exists"), ou nil.
function Cat.Promote(entry, creator)
    if type(entry) ~= "table" or not entry.dID then return nil end

    -- Deja promue : on ne cree PAS un doublon. Le joueur voulait sans doute la retrouver.
    local existing = Cat.PromotedVariant(entry.cid, entry.dID)
    if existing then return existing, "exists" end

    local v = HR.V2_ImportVariant(entry.dID, entry.name, entry.healer,
                                  entry.externals, entry.talentSpells,
                                  entry.assignments, nil)   -- pas de TTL : choix du joueur
    if not v then return nil end

    v.catalogVariantId = entry.cid          -- LE LIEN : verrou + cible des mises a jour
    -- Trace de provenance : un FAIT HISTORIQUE, fige (memo §7.2). Elle enregistre ce qui
    -- etait vrai a l'adoption et ne perime pas, meme si l'auteur se renomme ensuite.
    v.catalogFrom = {
        creatorId = creator and creator.id,
        name      = creator and creator.name,
        at        = (GetServerTime and GetServerTime()) or time(),
    }
    return v, "created"
end

-- Repercute sur les variantes PROMUES les entrees qu'on vient d'ecrire.
-- Appele depuis Cat.Apply : c'est le « les mises a jour s'appliquent automatiquement ».
--
-- ⚠️ La cible est bornee par le `catalogVariantId`. Une variante que le joueur a ecrite
-- lui-meme n'en porte pas et ne peut donc JAMAIS etre atteinte ici. On ecrit les
-- assignments DANS la table existante (vidage + remplissage) plutot que de la substituer,
-- meme precaution que HR.ClearVariantBossPlan.
function Cat.PropagateUpdates(rep)
    local n = 0
    for _, d in ipairs((rep and rep.dungeons) or {}) do
        for _, e in ipairs(d._kept or {}) do
            local v = Cat.PromotedVariant(e.cid, e.dID)
            if v then
                v.name         = e.name
                v.healer       = e.healer
                v.externals    = HR.DeepCopy(e.externals or {})
                v.talentSpells = HR.DeepCopy(e.talentSpells or {})
                v.assignments  = v.assignments or {}
                wipe(v.assignments)
                -- COPIE, jamais la reference : `e` vit dans `db2.catalog`, et l'affecter
                -- telle quelle ferait pointer la variante du joueur et le catalogue sur
                -- les MEMES sous-tables. Rien ne les mute aujourd'hui (CanEditVariant
                -- bloque tous les ecrivains), mais un seul futur ecrivain qui oublie le
                -- garde corromprait aussi le catalogue. Les deux lignes au-dessus copient.
                for encID, occs in pairs(e.assignments or {}) do
                    v.assignments[encID] = HR.DeepCopy(occs)
                end
                n = n + 1
            end
        end
    end
    return n
end

--------------------------------------------------------------------------------
-- Suppression (droit du joueur -- rien ici n'est automatique)
--------------------------------------------------------------------------------

function Cat.DeletePack(packId)
    local s = Cat.Store()
    if s and packId then s.packs[packId] = nil; Cat._has = nil end
end

-- Retire tout ce qui vient d'un auteur, carte comprise.
function Cat.DeleteCreator(creatorId)
    local s = Cat.Store()
    if not (s and creatorId) then return end
    for id, p in pairs(s.packs) do
        if p.creatorId == creatorId then s.packs[id] = nil end
    end
    s.creators[creatorId] = nil
    Cat._has = nil
end
