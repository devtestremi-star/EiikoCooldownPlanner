-- HealPlanner - Core/Plan2.lua
-- NOUVEAU format. Une VARIANTE est l'unite de base : elle porte SA compo defensive =
--   { id, name, healer (spe heal), externals = {defKey=count}, assignments }.
-- Plus de "setup" global derive de la selection courante : la variante ACTIVE pilote
-- l'affichage (read-only dans le main frame) et le plan. On cree/duplique des variantes
-- via des modales (selection progressive). Stockage : SavedVariable ECPlannerDB (HR.db2)
--   = { variants = { [id] = ... }, active = <id>, nextId = <int> }.
local addonName, HR = ...

-- PAR DONJON. db2 = { dungeons = { [dID] = { variants = {[id]=v}, used, lastSeen } },
--   nextId }. `used` = variante ACTIVE (run en combat) du donjon. `lastSeen` = derniere
--   variante CONSULTEE (affichee). Le DONJON COURANT est pose par l'UI via
--   HR.SetCurrentV2Dungeon ; toutes les fonctions operent dessus par defaut (override par dID).
local currentDungeon

-- Store d'un donjon (cree a la demande).
local function dStore(dID)
    dID = dID or currentDungeon
    local db = HR.db2
    if not db or not dID then return nil end
    db.dungeons = db.dungeons or {}
    local s = db.dungeons[dID]
    if not s then s = { variants = {} }; db.dungeons[dID] = s end
    s.variants = s.variants or {}
    return s
end

-- Pose le donjon courant (+ purge des imports expires). Plus de "Base template" auto-creee :
-- le joueur cree lui-meme sa 1re variante (cf. HR.CleanupBaseVariants).
function HR.SetCurrentV2Dungeon(dID)
    if dID == currentDungeon then return end
    currentDungeon = dID
    if dID then
        HR.PruneExpiredVariants(dID)
        HR.ReconcileVisibleToSpec(dID)   -- recale l'affichage sur ma spe (pas d'autre classe)
    end
end

-- Toutes les variantes du donjon (defaut = courant), triees par id.
function HR.V2_GetVariants(dID)
    local s = dStore(dID); if not s then return {} end
    local list = {}
    for _, v in pairs(s.variants) do list[#list + 1] = v end
    table.sort(list, function(a, b) return (a.id or 0) < (b.id or 0) end)
    return list
end

-- Clef de profil de heal de la SPE ACTIVE du joueur (pretre => PRIEST_HOLY/PRIEST_DISC,
-- token de classe sinon). Sert a scoper les choix "actif/joue" PAR SPE : les variantes
-- restent partagees au COMPTE, seul le choix courant est memorise par spe.
function HR.MyHealKey()
    local _, class = UnitClass("player")
    return class and HR.HealProfileKey(class, HR.GetPlayerSpecName()) or nil
end

-- Le joueur joue-t-il un profil de HEAL connu ? ⚠️ HR.MyHealKey renvoie le TOKEN DE CLASSE
-- brut pour un non-healer ("WARRIOR", "MAGE"...), qui n'est JAMAIS une clef de
-- HR.HEAL_PROFILES -> toute comparaison `v.healer == MyHealKey()` serait fausse pour lui.
-- Sert a neutraliser le scope-par-spe-heal : un DPS/TANK n'a pas de "sa" spe heal, il
-- consulte les plans des autres (typiquement importes via le partage).
function HR.IsHealerPlayer()
    return HR.GetHealProfile(HR.MyHealKey()) ~= nil
end

-- 1re variante (id le plus petit) de MA spe dans le donjon, ou nil. Une variante SANS heal
-- compte comme mienne (elle n'appartient a aucune spe). Pour un NON-HEALER, aucune notion de
-- "ma spe" n'existe -> on prend la 1re variante du donjon, toutes spes confondues (repli
-- d'AFFICHAGE seul : ne designe rien comme actif/defaut, cf. GetActiveVariant).
local function firstVariantOfMySpec(s)
    local anyVariant = not HR.IsHealerPlayer()
    local key = HR.MyHealKey()
    if not (anyVariant or key) then return nil end
    local best
    for _, v in pairs(s.variants) do
        if (anyVariant or v.healer == key or HR.IsNoHealerVariant(v))
           and (not best or (v.id or 0) < (best.id or 0)) then best = v end
    end
    return best
end

-- Variante SELECTIONNEE (affichee/editee) du donjon = sa lastSeen. Repli POUR L'AFFICHAGE
-- seulement : la variante ACTIVE explicite (GetV2Used), sinon la 1re de ma spe (pour toujours
-- montrer/pouvoir editer qqch) -- SANS la designer "active" ni "defaut". Jamais une autre classe.
function HR.GetActiveVariant(dID)
    local s = dStore(dID); if not s then return nil end
    if s.lastSeen and s.variants[s.lastSeen] then return s.variants[s.lastSeen] end
    local used = HR.GetV2Used(dID)
    if used then s.lastSeen = used.id; return used end
    local first = firstVariantOfMySpec(s)
    if first then s.lastSeen = first.id; return first end
    return nil
end

-- "Consulter" une variante => la flague lastSeen du donjon (restauree au retour sur le donjon).
-- Peut pointer une variante d'une AUTRE spe (parcours libre du popup) ; le recalage par spe
-- (HR.ReconcileVisibleToSpec) n'intervient qu'au changement de donjon.
function HR.SelectVariant(id, dID)
    local s = dStore(dID)
    if s and s.variants[id] then s.lastSeen = id end
end

-- Variante ACTIVE (★ jouee en combat / auto-load) du donjon, RESOLUE POUR MA SPE.
-- EXPLICITE UNIQUEMENT (aucune auto-designation), DEUX etapes : (1) choix memorise pour ma
-- spe (bouton "Use") -> (2) defaut de ma spe (bouton "Default") -> sinon nil.
-- PAS de repli "1re variante" : sans choix explicite, rien n'est actif/defaut, et le pull
-- affiche la timeline du boss SANS defensif (l'affichage editable, lui, retombe sur la 1re
-- via GetActiveVariant -- c'est de l'UI, pas du combat).
-- (Une 3e etape lisait l'ancien champ `s.used`, non scope par spe : supprimee le 2026-08-26.
--  Consequence assumee : un joueur dont le choix ne vivait QUE la doit recliquer "Use" une
--  fois. On ne migre pas `s.used` vers `usedByKey` -- ce serait reecrire la DB du joueur.)
function HR.GetV2Used(dID)
    local s = dStore(dID); if not s then return nil end
    local key = HR.MyHealKey()
    local uid = key and s.usedByKey and s.usedByKey[key]
    if uid and s.variants[uid] then return s.variants[uid] end
    local specID = HR.PlayerSpecID()
    local vid = specID and HR.GetDefaultVariantId(dID, specID)
    if vid and s.variants[vid] then return s.variants[vid] end
    return nil
end
-- Definit la variante active MEMORISEE POUR MA SPE. ⚠️ La clef est celle du JOUEUR
-- (HR.MyHealKey), PAS celle de la variante : HR.GetV2Used lit `usedByKey[MyHealKey()]`, donc
-- ecrire sous `v.healer` rendait le choix illisible des que la variante n'etait pas de ma spe
-- (cas d'un plan importe chez un DPS/TANK : "Use" n'ancrait rien). Pour un healer qui choisit
-- une variante de SA spe, les deux clefs coincident -> comportement inchange.
function HR.SetV2Used(id, dID)
    local s = dStore(dID); local v = s and s.variants[id]
    if not v then return end
    local key = HR.MyHealKey()
    if key then
        s.usedByKey = s.usedByKey or {}
        s.usedByKey[key] = id
    end
end

-- Recale le pointeur de navigation (lastSeen) sur MA spe s'il pointe une AUTRE classe.
-- Appele au CHANGEMENT DE DONJON uniquement -> ne casse pas le parcours cross-spec en cours.
function HR.ReconcileVisibleToSpec(dID)
    local s = dStore(dID); if not s then return end
    -- NON-HEALER : aucune "spe heal a lui" -> rien a recaler. Sans cette garde, un DPS/TANK
    -- perdait a CHAQUE changement de donjon la variante qu'il consultait (typiquement un plan
    -- IMPORTE, qui porte le heal de l'EXPEDITEUR) : `cur.healer == key` etait toujours faux.
    if not HR.IsHealerPlayer() then return end
    local key = HR.MyHealKey()
    local cur = s.lastSeen and s.variants[s.lastSeen]
    -- deja ma spe (ou variante SANS heal, qui n'appartient a personne) -> conserver le choix
    if cur and (HR.IsNoHealerVariant(cur) or (key and cur.healer == key)) then return end
    local used = HR.GetV2Used(dID)
    s.lastSeen = used and used.id or nil
end

--------------------------------------------------------------------------------
-- Variante par DEFAUT (auto-chargee a l'entree du donjon) : UNE par (donjon, spe
-- JOUEE). Stockage HR.db2.defaultVariants["<dID>:<specID>"] = variantId. La cle
-- string garantit l'unicite (redefinir = ecraser). specID = celui de la spe ACTIVE
-- DU JOUEUR (preference personnelle "quoi auto-charger quand je joue cette spe"),
-- et non celui du profil heal de la variante -> un DPS/TANK peut aussi en poser un.
--------------------------------------------------------------------------------

-- specID de la spe ACTIVE du joueur (nil si indeterminee).
function HR.PlayerSpecID()
    local idx = GetSpecialization()
    return idx and GetSpecializationInfo(idx) or nil
end

-- Le joueur peut-il DEFINIR `v` comme defaut ? Le defaut est une preference PERSONNELLE
-- ("quelle variante auto-charger quand JE joue cette spe") : il est donc clef sur MA specID,
-- pas sur celle de la variante. ⚠️ L'ancienne regle exigeait `specIDOfVariant(v) ==
-- PlayerSpecID()`, ce qui interdisait TOUT defaut a un DPS/TANK (une variante de heal n'a
-- jamais leur specID) -> aucun auto-load possible sur un plan importe.
function HR.CanSetDefault(v)
    return v ~= nil and HR.PlayerSpecID() ~= nil
end

function HR.DefaultVariantKey(dID, specID)
    if not dID or not specID then return nil end
    return tostring(dID) .. ":" .. tostring(specID)
end

-- Marque `id` comme variante par defaut de MA spe active dans `dID`. Ecrase l'ancienne.
-- Clef = specID du JOUEUR (cf. HR.CanSetDefault) : pour un healer marquant une variante de sa
-- propre spe, identique a avant ; un DPS/TANK peut desormais epingler un plan importe.
function HR.SetDefaultVariant(id, dID)
    dID = dID or currentDungeon
    local s = dStore(dID); local v = s and s.variants[id]
    local specID = HR.PlayerSpecID()
    if not (v and specID and HR.db2) then return false end
    HR.db2.defaultVariants = HR.db2.defaultVariants or {}
    HR.db2.defaultVariants[HR.DefaultVariantKey(dID, specID)] = id
    return true
end

function HR.GetDefaultVariantId(dID, specID)
    local m = HR.db2 and HR.db2.defaultVariants
    return m and m[HR.DefaultVariantKey(dID, specID)] or nil
end

-- `id` est-il le defaut auto-charge POUR MA spe active ? RELATIF AU JOUEUR (pas a la spe
-- de la variante) : une variante d'une AUTRE classe/spe n'est jamais "mon" defaut, meme si
-- elle est le defaut de SA propre spe. Comme un defaut ne se pose que sur une variante de sa
-- spe, comparer au defaut de MA spe suffit (l'id renvoye est forcement de ma spe).
function HR.IsDefaultVariant(id, dID)
    dID = dID or currentDungeon
    local specID = HR.PlayerSpecID()
    return specID ~= nil and HR.GetDefaultVariantId(dID, specID) == id
end

-- Toggle OFF : retire `id` s'il est MON defaut. Clef = specID du JOUEUR, symetrique de
-- HR.SetDefaultVariant / HR.IsDefaultVariant (qui lit deja HR.PlayerSpecID).
function HR.ClearDefaultVariant(id, dID)
    dID = dID or currentDungeon
    local specID = HR.PlayerSpecID()
    local m = HR.db2 and HR.db2.defaultVariants
    if not (specID and m) then return end
    local k = HR.DefaultVariantKey(dID, specID)
    if m[k] == id then m[k] = nil end
end

-- Delai (secondes) avant de re-forcer le defaut sur un MEME donjon (+ meme spe). En deca,
-- un choix manuel (ex. variante B) survit a une sortie/re-entree rapide du donjon.
local AUTOLOAD_TTL = 2 * 3600   -- 2h

-- Charge la variante par defaut de MA spe pour le donjon courant, si spe heal + defaut connu.
-- Deux gardes DISTINCTES :
--   * RAPPEL pre-run : a chaque entree "franche" (donjon != dernier vu ; les corpse runs ne
--     changent pas de donjon -> pas de re-pop). Garde in-memory HR._reminderShownDID.
--   * AUTO-APPLICATION du defaut : gatee par un enregistrement PERSISTE { dID, specID, at }
--     (HR.db2.autoLoad). On ne re-applique le defaut sur le MEME (donjon, spe) que si l'ecart
--     avec la 1re autoactivation depasse AUTOLOAD_TTL -> une sortie/re-entree rapide NE reforce
--     PAS le defaut (le choix manuel est conserve). `force` (changement de spe) bypasse le TTL.
function HR.AutoLoadDefaultVariant(force)
    local idx = HR.GetCurrentDungeonIndex(); if not idx then HR._reminderShownDID = nil; return end
    local dID = HR.content[idx] and HR.content[idx].id; if not dID then HR._reminderShownDID = nil; return end

    local freshEntry = (HR._reminderShownDID ~= dID)   -- entree franche (pour le rappel)

    -- Gate d'auto-application (TTL) : contexte = (donjon, spe active).
    local specIdx = GetSpecialization()
    local specID  = specIdx and GetSpecializationInfo(specIdx)
    local now = time()
    HR.db2 = HR.db2 or {}
    local st        = HR.db2.autoLoad
    local sameCtx   = st and st.dID == dID and st.specID == specID
    local withinTTL = st and st.at and (now - st.at) < AUTOLOAD_TTL
    local applyDefault = force or not (sameCtx and withinTTL)

    if HR.debug then
        HR:Debug(("[autoload] dID=%s spec=%s rec=%s within=%s apply=%s force=%s")
            :format(tostring(dID), tostring(specID),
                st and (tostring(st.dID) .. ":" .. tostring(st.specID) .. "@" .. tostring(st.at)) or "nil",
                tostring(withinTTL and true or false), tostring(applyDefault and true or false),
                tostring(force and true or false)))
    end

    if applyDefault and specID then
        local vid = HR.GetDefaultVariantId(dID, specID)
        local s   = HR.db2.dungeons and HR.db2.dungeons[dID]
        if vid and s and s.variants[vid] then
            HR.SetCurrentV2Dungeon(dID)
            HR.SetV2Used(vid, dID)          -- jouee en combat (★)
            HR.SelectVariant(vid, dID)      -- affichee/editee
            HR.db2.autoLoad = { dID = dID, specID = specID, at = now }  -- (re)demarre la fenetre TTL
            local UI = HR.UI
            if UI and UI.frame and UI.frame:IsShown() and UI.RefreshRows then UI.RefreshRows() end
        end
    end

    -- Rappel PRE-RUN (une fois par entree franche, healer uniquement) : resume de la variante
    -- jouee, ou message "aucune variante". Differe (ecran de chargement encore actif a
    -- PLAYER_ENTERING_WORLD -> une frame ouverte pile-poil ne s'afficherait pas).
    if freshEntry then
        HR._reminderShownDID = dID
        if HR.GetPlayerRole and HR.GetPlayerRole() == "HEALER"
           and HR.UI and HR.UI.ShowPrerunReminder then
            HR.SetCurrentV2Dungeon(dID)
            C_Timer.After(0.5, function() HR.UI.ShowPrerunReminder(dID) end)
        end
    end
end

-- Une variante contient-elle AU MOINS un defensif place (n'importe quel boss / occurrence) ?
-- Une variante VIDE ne "connait" que la classe du soigneur (aucun plan) -> candidate au nettoyage.
function HR.VariantHasPlacements(v)
    if not v or not v.assignments then return false end
    for _, byOcc in pairs(v.assignments) do
        for _, list in pairs(byOcc) do
            if type(list) == "table" and #list > 0 then return true end
        end
    end
    return false
end

-- NETTOYAGE au login : le concept de "Base template" (variante PRE-FOURNIE par l'addon) est
-- retire. On parcourt toutes les variantes `base` de tous les donjons :
--   * vide de tout defensif       -> SUPPRIMEE (coquille sans plan) ;
--   * au moins un defensif place   -> CONVERTIE en variante normale (flag `base` retire) : le
--                                     joueur garde son plan et peut la renommer/supprimer.
-- Action explicite (auteur) ; ne touche JAMAIS une variante non-`base`. Idempotent (apres coup,
-- plus aucune variante `base` -> no-op).
function HR.CleanupBaseVariants()
    local db = HR.db2; if not db or not db.dungeons then return end
    local deleted, converted = 0, 0
    for _, s in pairs(db.dungeons) do
        local variants = s.variants
        if variants then
            for id, v in pairs(variants) do        -- retirer la cle courante pendant pairs() est sur
                if v.base then
                    if HR.VariantHasPlacements(v) then
                        v.base = nil               -- devient une variante normale (plan conserve)
                        converted = converted + 1
                    else
                        variants[id] = nil          -- coquille vide -> supprimee
                        if s.lastSeen == id then s.lastSeen = nil end
                        deleted = deleted + 1
                    end
                end
            end
        end
    end
    if deleted + converted > 0 then
        HR:Debug(("Base templates cleanup: %d deleted, %d converted"):format(deleted, converted))
    end
end

-- Importe une variante PARTAGEE dans un donjon (insertion directe, format V2). `deleteAt`
-- (timestamp serveur) => auto-suppression au prune (nil = permanente). Renvoie la variante.
-- L'echeance d'auto-suppression est une donnee PERSONNELLE : on ne la stocke PAS sur la
-- variante (donc elle ne peut pas fuiter dans un re-partage) mais dans une table a part
-- `db.imports[dID][id] = deleteAt` (cf. PruneExpiredVariants).
function HR.V2_ImportVariant(dID, name, healer, externals, talentSpells, assignments, deleteAt)
    local db = HR.db2; if not db then return nil end
    local s = dStore(dID); if not s then return nil end   -- garantit le store du donjon
    db.nextId = db.nextId or 1
    local id = db.nextId; db.nextId = id + 1
    local v = {
        id = id, name = name, healer = healer,
        externals    = HR.DeepCopy(externals or {}),
        talentSpells = HR.DeepCopy(talentSpells or {}),
        assignments  = HR.DeepCopy(assignments or {}),
        imported     = true,
    }
    s.variants[id] = v
    s.lastSeen = id                            -- la variante importee devient l'affichee
    if deleteAt then
        db.imports = db.imports or {}
        db.imports[dID] = db.imports[dID] or {}
        db.imports[dID][id] = deleteAt         -- echeance personnelle, hors variante
    end
    return v
end

-- Supprime les variantes importees EXPIREES. La table des echeances `db.imports[dID][id]`
-- (timestamp) est la source de verite ; on scanne ca. Appelee a l'init (tous les donjons)
-- et a l'entree d'un donjon. Ne touche jamais aux Base templates.
function HR.PruneExpiredVariants(dID)
    local db = HR.db2; if not db or not db.imports then return end
    local now = (GetServerTime and GetServerTime()) or time()
    local function pruneStore(d, map)
        if not map then return end
        local s = db.dungeons and db.dungeons[d]
        for id, deleteAt in pairs(map) do
            if now > deleteAt then
                if s and s.variants then
                    local v = s.variants[id]
                    if v and not v.base then
                        s.variants[id] = nil
                        if s.lastSeen == id then s.lastSeen = nil end
                    end
                end
                map[id] = nil                  -- echeance honoree -> on l'oublie
            end
        end
        if not next(map) then db.imports[d] = nil end
    end
    if dID then pruneStore(dID, db.imports[dID])
    else for d, map in pairs(db.imports) do pruneStore(d, map) end end
end

-- Cree une variante (healer + externals). importBase => part de la Base template du heal.
-- (Prefixe V2_ : vestige de la coexistence avec le store V1, supprime le 2026-08-26.)
-- opts = { isTemplate = bool, copyTemplateId = id } : copyTemplateId => le plan (assignments)
-- est copie depuis CE template ; sinon plan vide.
function HR.V2_CreateVariant(name, healer, externals, talentSpells, opts)
    local db = HR.db2; if not db then return nil end
    local s = dStore(); if not s then return nil end
    db.nextId = db.nextId or 1
    local id = db.nextId; db.nextId = id + 1
    opts = opts or {}
    local assignments = {}
    if opts.copyTemplateId and s.variants[opts.copyTemplateId] then
        assignments = HR.DeepCopy(s.variants[opts.copyTemplateId].assignments or {})
    end
    local v = {
        id = id, name = name, healer = healer,
        externals    = HR.DeepCopy(externals or {}),
        talentSpells = HR.DeepCopy(talentSpells or {}),   -- { [spellID] = cle_de_variante }
        isTemplate   = opts.isTemplate or nil,
        assignments  = assignments,
    }
    s.variants[id] = v
    s.lastSeen = id                                       -- la nouvelle variante devient l'affichee
    return v
end

-- Un token PLACE est-il encore valide pour la compo de la variante v ? Sert au scan d'orphelins
-- en EDITION (talent decoche, external dont le count baisse/tombe a 0, trinket retire). COUNT-aware
-- pour le schema external nu vs "#i" : un placement nu reste valide tant que count>=1, "#i" valide
-- tant que i<=count -> AUGMENTER un count n'orpheline JAMAIS un placement existant.
function HR.IsTokenPlaceable(v, token)
    if not v or token == nil then return false end
    local t = tostring(token)
    if t == "SMALL_DEF" or t == "EMPTY_BAG" then return true end          -- generiques : toujours
    local defKey = HR.DefKeyOf(token)
    local d = HR.defensives[defKey]
    if t:find("@heal", 1, true) then                                     -- trinket porte par le HEAL
        if not (d and d.trinket) then return false end
        for _, val in pairs(v.talentSpells or {}) do if val == defKey then return true end end
        return false
    end
    for _, cd in ipairs(HR.GetVariantHealerCDs(v)) do                    -- CD de heal (talent choisi)
        if cd.key == defKey then return true end
    end
    local n = (v.externals or {})[defKey] or 0                          -- external (count d'instances)
    if n <= 0 then return false end
    local suf = HR.TokenSuffix(token)
    if suf then return (tonumber(suf:match("#(%d+)")) or 1) <= n end
    return true                                                          -- token nu : valide tant que n>=1
end

-- Edite une variante EXISTANTE : change name + externals + talents (le HEAL reste VERROUILLE),
-- puis SCANNE le plan et SUPPRIME EN PLACE les defensifs devenus orphelins (token plus placable
-- avec la nouvelle compo). Suppression en place => preserve le lien DB. Action 100% user
-- (validation de la modale). Renvoie v, nbRetire.
function HR.V2_UpdateVariant(id, name, externals, talentSpells)
    local s = dStore(); if not s then return nil end
    local v = id and s.variants[id]; if not v then return nil end
    if name and name ~= "" then v.name = name end
    v.externals    = HR.DeepCopy(externals or {})
    v.talentSpells = HR.DeepCopy(talentSpells or {})
    local removed = 0
    for _, byOcc in pairs(v.assignments or {}) do
        for _, list in pairs(byOcc) do
            for i = #list, 1, -1 do
                if not HR.IsTokenPlaceable(v, HR.EntryToken(list[i])) then
                    table.remove(list, i); removed = removed + 1
                end
            end
        end
    end
    return v, removed
end

-- Duplique la variante active (compo defensive + plan EXACTS) avec un nouveau nom.
-- (Prefixe V2_ : vestige de la coexistence avec le store V1, supprime le 2026-08-26.)
--
-- ⚠️ La copie est l'oeuvre de CELUI QUI DUPLIQUE : les marqueurs de synchro (`synced`,
-- `syncFrom`) ne doivent JAMAIS etre repris. Les recopier ferait deux degats : la copie
-- resterait bloquee au bouton Sync (gate d'emission : on ne pousse que son propre plan),
-- et elle serait ecrasee a la prochaine poussee de l'auteur d'origine. C'est justement
-- l'echappatoire offerte au joueur qui veut personnaliser un plan recu. La construction
-- CHAMP PAR CHAMP ci-dessous garantit ca -- ne pas la remplacer par un DeepCopy(cur).
function HR.V2_DuplicateVariant(name)
    local cur = HR.GetActiveVariant()
    if not cur then return nil end
    local db = HR.db2; local s = dStore(); if not s then return nil end
    db.nextId = db.nextId or 1
    local id = db.nextId; db.nextId = id + 1
    local v = {
        id = id, name = name, healer = cur.healer,
        externals    = HR.DeepCopy(cur.externals or {}),
        talentSpells = HR.DeepCopy(cur.talentSpells or {}),
        assignments  = HR.DeepCopy(cur.assignments or {}),
        -- PAS de `synced` ni de `syncFrom` : cf. l'avertissement ci-dessus.
    }
    s.variants[id] = v
    s.lastSeen = id
    return v
end

-- Supprime une variante. Si c'etait l'affichee, repli sur la 1re variante dispo du donjon
-- (sinon rien : etat "aucune variante", le joueur en recree une).
function HR.V2_DeleteVariant(id)
    local s = dStore(); if not s then return false end
    local v = s.variants[id]
    if not v or v.base then return false end               -- garde defensive (plus de variante base)
    s.variants[id] = nil
    -- Purge des entrees "variante par defaut" pointant sur cet id (ids uniques => purge par valeur).
    local m = HR.db2 and HR.db2.defaultVariants
    if m then for k, vid in pairs(m) do if vid == id then m[k] = nil end end end
    -- Purge du choix "actif par spe" pointant sur cet id.
    if s.usedByKey then for k, vid in pairs(s.usedByKey) do if vid == id then s.usedByKey[k] = nil end end end
    if s.lastSeen == id then
        s.lastSeen = nil
        HR.GetActiveVariant()                              -- repare lastSeen sur la 1re dispo (ou nil)
    end
    return true
end

-- token <-> defKey + suffixe #N ("51052:240#2" -> defKey "51052:240", suffixe "#2").
-- IMPORTANT : on reconvertit un defKey NUMERIQUE en nombre, car HR.defensives est indexe
-- par NOMBRE pour les spellID ("443028" string -> 443028). Les cles synthetiques
-- ("51052:240", "SMALL_DEF") restent des chaines (tonumber renvoie nil).
function HR.DefKeyOf(token)
    if type(token) ~= "string" then return token end
    -- suffixes d'INSTANCE : "#N" (external en plusieurs exemplaires) ou "@heal" (trinket
    -- porte par le HEAL, distinct du meme trinket porte par un DPS en external).
    local base = token:match("^(.-)#%d+$") or token:match("^(.-)@%a+$") or token
    return tonumber(base) or base
end
function HR.TokenSuffix(token)
    if type(token) ~= "string" then return nil end
    return token:match("(#%d+)$")
end

-- Placements d'une occurrence pour une variante DONNEE (lecture pure, jamais d'ecriture).
-- ⚠️ La variante est EXPLICITE parce que le runtime travaille sur celle capturee au pull
-- (`s.variant`), qui peut differer de celle affichee si le joueur change de variante en
-- plein combat. Appelants : UI/RuntimeBox.lua, Core/Schedule.lua, Core/BossModAttach.lua.
function HR.GetAssignments(variant, encounterID, key)
    if not variant or not variant.assignments then return {} end
    local enc = variant.assignments[encounterID]
    local v = enc and enc[key]
    if v == nil then return {} end
    if type(v) == "table" then return v end
    return { v }                              -- securite (ancien format a plat)
end

-- Placements d'une occurrence pour la VARIANTE ACTIVE. Chaque element est une ENTREE
-- INLINE { token, offset (ms, optionnel) } -- l'offset (decalage temporel du defensif)
-- est stocke directement sur l'entree, pas dans une table parallele.
function HR.NewPlan_Get(encounterID, occKey)
    return HR.GetAssignments(HR.GetActiveVariant(), encounterID, occKey)
end

-- Ajoute un token (entree { token }). Dedup par token.
function HR.NewPlan_Add(encounterID, occKey, token)
    local v = HR.GetActiveVariant()
    if not v then return false end
    v.assignments[encounterID] = v.assignments[encounterID] or {}
    local list = v.assignments[encounterID][occKey]
    if not list then list = {}; v.assignments[encounterID][occKey] = list end
    for _, e in ipairs(list) do if e.token == token then return true end end   -- dedup
    list[#list + 1] = { token = token }
    return true
end

function HR.NewPlan_Remove(encounterID, occKey, token)
    local v = HR.GetActiveVariant()
    if not v or not v.assignments[encounterID] then return end
    local list = v.assignments[encounterID][occKey]
    if list then
        for i, e in ipairs(list) do if e.token == token then table.remove(list, i); break end end
    end
end

-- Remet a ZERO la planification d'UN boss pour la variante donnee : vide tous ses placements,
-- les AUTRES boss restant intacts. Modifie la table `assignments` EN PLACE (on retire juste la
-- cle encounterID) -> preserve le lien DB des variantes par defaut (cf. Database.InitDB). Action
-- 100% user, declenchee uniquement apres confirmation. Renvoie true si quelque chose a ete vide.
function HR.ClearVariantBossPlan(variant, encounterID)
    if not variant or encounterID == nil or not variant.assignments then return false end
    if variant.assignments[encounterID] == nil then return false end
    variant.assignments[encounterID] = nil
    return true
end

-- Decalage temporel (ms, signe) d'un defensif place. Stocke INLINE sur l'entree
-- (e.offset). Clamp +-OFFSET_MAX_S. 0 => champ absent. Opere sur la variante ACTIVE
-- (editee) ; le runtime lit l'offset directement sur l'entree de la variante JOUEE (★).
HR.OFFSET_MAX_S = 12
local OFFSET_MAX_MS = HR.OFFSET_MAX_S * 1000

local function findEntry(enc, occKey, token)
    local v = HR.GetActiveVariant()
    local list = v and v.assignments[enc] and v.assignments[enc][occKey]
    if not list then return nil end
    for _, e in ipairs(list) do if e.token == token then return e end end
    return nil
end

function HR.NewPlan_GetOffset(enc, occKey, token)
    local e = findEntry(enc, occKey, token)
    return (e and e.offset) or 0
end

function HR.NewPlan_SetOffset(enc, occKey, token, ms)
    local e = findEntry(enc, occKey, token)
    if not e then return 0 end
    ms = math.max(-OFFSET_MAX_MS, math.min(OFFSET_MAX_MS, math.floor((ms or 0) + 0.5)))
    e.offset = (ms ~= 0) and ms or nil
    return ms
end

function HR.NewPlan_NudgeOffset(enc, occKey, token, deltaMs)
    return HR.NewPlan_SetOffset(enc, occKey, token, HR.NewPlan_GetOffset(enc, occKey, token) + (deltaMs or 0))
end

-- Normalisation d'une ENTREE d'assignment, robuste : entree { token, offset } (format V2
-- courant) OU ancien token brut (string/number, plans V1/legacy -> offset 0). Tous les
-- consommateurs (runtime + editeur) lisent les listes d'assignments via ces deux helpers.
function HR.EntryToken(e)  return (type(e) == "table") and e.token or e end
function HR.EntryOffset(e) return (type(e) == "table" and e.offset) or 0 end

-- Temps d'USAGE EFFECTIF de chaque TOKEN pour la variante active sur ce boss.
-- `timeOf` = map occKey -> temps de reference (s) : passer HR.OccDefTime(occ) (prend le defMarker).
-- On ajoute l'offset PROPRE a chaque entree (e.offset, en ms) -> le temps d'usage reel du CD, pour
-- que le calcul de dispo (cooldown) tienne compte des decalages. Renvoie { token = { t1, t2, ... } }.
-- (Cle par TOKEN : chaque instance #N d'un external = un CD independant.)
function HR.NewPlan_Uses(encounterID, timeOf)
    local v = HR.GetActiveVariant()
    local uses = {}
    if v and v.assignments[encounterID] then
        for occKey, entries in pairs(v.assignments[encounterID]) do
            local t = timeOf[occKey]
            if t then
                for _, e in ipairs(entries) do
                    uses[e.token] = uses[e.token] or {}
                    uses[e.token][#uses[e.token] + 1] = t + HR.EntryOffset(e) / 1000
                end
            end
        end
    end
    return uses
end

-- Etat d'un token a `atTime` vu ses autres placements :
--   "ready"   : disponible ;  "blocked" : indisponible (encore en CD).
-- (La feature "force" a ete retiree : on decale desormais le defensif via un offset pour
-- le rendre dispo, plutot que de forcer un placement.)
-- Fenetre symetrique du CD ; usage a `atTime` ignore ; charges prises en compte.
-- Renvoie (state, shortfall) : shortfall = secondes restantes avant dispo (0 si pret).
function HR.NewPlan_TokenState(token, atTime, uses)
    local d = HR.defensives[HR.DefKeyOf(token)]
    local cd = (d and d.cooldown) or 0
    if cd <= 0 then return "ready", 0 end
    local charges = (d and d.charges) or 1
    local conflicts, minDelta = 0, cd
    for _, useTime in ipairs((uses and uses[token]) or {}) do
        if useTime ~= atTime then
            local dt = math.abs(atTime - useTime)
            if dt < cd then
                conflicts = conflicts + 1
                if dt < minDelta then minDelta = dt end
            end
        end
    end
    if conflicts < charges then return "ready", 0 end
    return "blocked", cd - minDelta
end

-- Items PLACABLES selon la VARIANTE ACTIVE : sorts de sa spe heal + ses externals
-- (instances #N si quantite > 1) + appels generiques. {token, defKey, label, group}.
function HR.GetPlaceableDefs()
    return HR.GetPlaceableDefsFor(HR.GetActiveVariant())
end

-- Idem pour une variante DONNEE (et pas seulement l'active). Sert a valider qu'un plan
-- importe de l'exterieur est jouable dans une variante precise (cf. Core/ShareText.lua).
function HR.GetPlaceableDefsFor(v)
    if not v then return {} end
    local out = {}

    -- Healer CDs = UNIQUEMENT les talents CHOISIS dans la variante (variante retenue +
    -- son cooldown), pas tous les sorts de la classe. Respecte la selection de la compo.
    for _, cd in ipairs(HR.GetVariantHealerCDs(v)) do
        out[#out + 1] = { token = tostring(cd.key), defKey = cd.key, label = cd.name, group = 1 }
    end
    -- Trinket(s) porte(s) par le HEAL (Vessel...) : c'est un CD du heal -> section Healer CDs.
    -- Token suffixe "@heal" => distinct du MEME trinket porte par un DPS (external), pour ne
    -- pas confondre les deux copies et tracker leurs cooldowns separement. (Depuis le retrait
    -- de Litany, plus aucun trinket n'est `external` -> le cas ne se presente plus, la
    -- distinction reste en place pour un futur trinket a la fois heal et external.)
    for _, key in pairs(v.talentSpells or {}) do
        local d = HR.defensives[key]
        if d and d.trinket then
            out[#out + 1] = { token = tostring(key) .. "@heal", defKey = key, label = d.name, group = 1 }
        end
    end
    -- Ramp : sort heal generique dispo pour TOUS les heals (independant de la compo).
    if HR.defensives["RAMP"] then
        out[#out + 1] = { token = "RAMP", defKey = "RAMP",
                          label = HR.defensives["RAMP"].name, group = 1 }
    end

    local ext = v.externals or {}
    for _, e in ipairs(HR.GetExternals()) do
        local n = ext[e.key] or 0
        if n == 1 then
            out[#out + 1] = { token = tostring(e.key), defKey = e.key, label = e.name, group = 2 }
        elseif n > 1 then
            for i = 1, n do
                out[#out + 1] = { token = tostring(e.key) .. "#" .. i, defKey = e.key,
                                  label = e.name .. " #" .. i, group = 2 }
            end
        end
    end

    for _, k in ipairs({ "SMALL_DEF", "EMPTY_BAG" }) do
        local d = HR.defensives[k]
        if d then out[#out + 1] = { token = k, defKey = k, label = d.name, group = 3 } end
    end

    table.sort(out, function(a, b)
        if a.group ~= b.group then return a.group < b.group end
        return a.label < b.label
    end)
    return out
end

local HEAL_CLASSES = { DRUID = true, EVOKER = true, MONK = true, PALADIN = true, PRIEST = true, SHAMAN = true }

-- Spe d'une unite : SURE pour le joueur local ; allies seulement si deja inspecte
-- (GetInspectSpecialization renvoie 0 sinon). nil = inconnu.
local function unitSpecName(unit)
    if UnitIsUnit(unit, "player") then
        local i = GetSpecialization and GetSpecialization()
        if i and GetSpecializationInfo then return (select(2, GetSpecializationInfo(i))) end
        return nil
    end
    if GetInspectSpecialization then
        local id = GetInspectSpecialization(unit)
        if id and id > 0 and GetSpecializationInfoByID then return (select(2, GetSpecializationInfoByID(id))) end
    end
    return nil
end

-- Role d'une unite. Pour le joueur LOCAL on le tire de la SPE (fiable meme sans role
-- assigne, ex. hors donjon) ; pour les allies, du role assigne du groupe.
local function unitRole(unit)
    if UnitIsUnit(unit, "player") and GetSpecialization and GetSpecializationInfo then
        local i = GetSpecialization()
        if i then
            local _, _, _, _, role = GetSpecializationInfo(i)
            if role then return role end
        end
    end
    return (UnitGroupRolesAssigned and UnitGroupRolesAssigned(unit)) or "NONE"
end

-- Liste des unites du groupe (raid/party/solo).
local function groupUnits()
    local u = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do u[#u + 1] = "raid" .. i end
    elseif IsInGroup() then
        u[#u + 1] = "player"
        for i = 1, GetNumGroupMembers() - 1 do u[#u + 1] = "party" .. i end
    else
        u[#u + 1] = "player"
    end
    return u
end

-- Talents ACTIFS du joueur local : set { spellID = true }. Sert a deviner la variante
-- de CD (ex. AMZ 3 min talente vs 4 min base). Hors combat/donjon, le loadout de talents
-- est generalement lisible (a confirmer en jeu ; cf. docs/EiikoCooldownPlanner/external-scan.md). Tout est
-- garde defensivement : APIs absentes -> set vide -> on retombe sur le defaut.
function HR.GetLocalActiveTalents()
    local set = {}
    if not (C_ClassTalents and C_ClassTalents.GetActiveConfigID and C_Traits) then return set end
    local cfgID = C_ClassTalents.GetActiveConfigID()
    if not cfgID then return set end
    local cfg = C_Traits.GetConfigInfo(cfgID)
    if not cfg or not cfg.treeIDs then return set end
    for _, treeID in ipairs(cfg.treeIDs) do
        for _, nodeID in ipairs(C_Traits.GetTreeNodes(treeID) or {}) do
            local node = C_Traits.GetNodeInfo(cfgID, nodeID)
            if node and node.activeEntry and (node.activeEntry.rank or 0) > 0 then
                local entry = C_Traits.GetEntryInfo(cfgID, node.activeEntry.entryID)
                if entry and entry.definitionID then
                    local def = C_Traits.GetDefinitionInfo(entry.definitionID)
                    if def and def.spellID then set[def.spellID] = true end
                end
            end
        end
    end
    return set
end

-- Set { spellID=true } des talents actifs d'un config de traits (local OU inspect).
local function talentSetFromConfig(cfgID)
    local set = {}
    if not (C_Traits and cfgID) then return set end
    local cfg = C_Traits.GetConfigInfo(cfgID)
    if not cfg or not cfg.treeIDs then return set end
    for _, treeID in ipairs(cfg.treeIDs) do
        for _, nodeID in ipairs(C_Traits.GetTreeNodes(treeID) or {}) do
            local node = C_Traits.GetNodeInfo(cfgID, nodeID)
            if node and node.activeEntry and (node.activeEntry.rank or 0) > 0 then
                local entry = C_Traits.GetEntryInfo(cfgID, node.activeEntry.entryID)
                if entry and entry.definitionID then
                    local def = C_Traits.GetDefinitionInfo(entry.definitionID)
                    if def and def.spellID then set[def.spellID] = true end
                end
            end
        end
    end
    return set
end

-- Sorts du HEALER (profil) lies a un talent. Inclut les sorts a UNE variante (toggle
-- on/off "le heal a ce talent") ET ceux a PLUSIEURS variantes (choix de duree de CD).
-- Inclut aussi les TRINKETS du toolkit heal (`trinket=true`, toute classe) -> scan d'ITEM.
-- Renvoie { { spellID, variants = { key, ... }, [trinket], [itemId] }, ... }.
function HR.GetHealerTalentSpells(profileKey)
    local prof = HR.GetHealProfile(profileKey)
    if not prof then return {} end
    local groups = {}
    for key, d in pairs(HR.defensives) do
        local healerTalent = d.role == "HEALER" and d.class == prof.class
            and (not d.spec or d.spec == prof.spec) and (d.talentReq or d.talentNot)
        if healerTalent or d.trinket then              -- trinket toolkit = dispo pour tout healer
            local sid = HR.GetDefensiveSpellID(key)
            groups[sid] = groups[sid] or {}
            table.insert(groups[sid], key)
        end
    end
    local out = {}
    for sid, keys in pairs(groups) do
        if #keys >= 1 then                              -- 1 variante = toggle ; 2+ = choix de duree
            table.sort(keys)
            local d0 = HR.defensives[keys[1]]
            out[#out + 1] = { spellID = sid, variants = keys, choiceNode = d0.choiceNode,
                              trinket = d0.trinket, itemId = d0.itemId }
        end
    end
    -- Ordre d'affichage (priorites) :
    --   1. variantes d'un meme spellID cote a cote -> deja garanti (boucle sp.variants)
    --   2. sorts d'un meme choiceNode cote a cote   -> tri par choiceNode d'abord
    --   3. le reste (sans choiceNode) ensuite       -> choiceNode nil = +inf
    table.sort(out, function(a, b)
        local ca, cb = a.choiceNode or math.huge, b.choiceNode or math.huge
        if ca ~= cb then return ca < cb end
        return a.spellID < b.spellID
    end)
    return out
end

-- Parmi des cles de variante, celle dont TOUS les talentReq sont dans `tset` et AUCUN
-- talentNot ; nil si aucune ne matche.
function HR.MatchTalentVariant(keys, tset)
    for _, key in ipairs(keys) do
        local d = HR.defensives[key]
        if d then
            local ok = true
            if d.talentReq then for _, t in ipairs(d.talentReq) do if not tset[t] then ok = false; break end end end
            if ok and d.talentNot then for _, t in ipairs(d.talentNot) do if tset[t] then ok = false; break end end end
            if ok then return key end
        end
    end
    return nil
end

-- Signature d'une variante (chaine deterministe, comparable par ==) : healer + talents
-- choisis -> "quel template s'applique". On matche les templates sur HealerSig seul.
function HR.HealerSig(healer, talentSpells)
    local parts = {}
    for sid, key in pairs(talentSpells or {}) do parts[#parts + 1] = tostring(sid) .. "=" .. tostring(key) end
    table.sort(parts)
    return (healer or "") .. "|" .. table.concat(parts, ",")
end

-- Nombre d'exemplaires d'un external a AFFICHER pour une variante (recap/summary) : la compo
-- (externals) + le trinket du HEAL (talents), qui compte comme un porteur de plus.
function HR.VariantExternalCount(externals, talentSpells, key)
    local n = (externals or {})[key] or 0
    local d = HR.defensives[key]
    if d and d.trinket and (talentSpells or {})[HR.GetDefensiveSpellID(key)] then
        n = n + 1
    end
    return n
end

-- CD propres au HEAL selon ses talents choisis (talentSpells), avec le cooldown de la
-- VARIANTE retenue. Hors trinkets (montres cote externals). Ordre = rangee talents
-- (groupe par choiceNode). Renvoie { { key, cooldown, name }, ... }.
function HR.GetVariantHealerCDs(v)
    local out = {}
    if not v or not v.healer then return out end
    for _, sp in ipairs(HR.GetHealerTalentSpells(v.healer)) do
        local key = (v.talentSpells or {})[sp.spellID]
        local d = key and HR.defensives[key]
        if d and not d.trinket then
            out[#out + 1] = { key = key, cooldown = d.cooldown, name = d.name }
        end
    end
    return out
end

-- Templates (variantes isTemplate) de MEME HealerSig (meme healer + memes talents).
-- Sert au "Copy selected" de la creation de variante.
function HR.GetMatchingTemplates(healerKey, talentSpells)
    local s, out = dStore(), {}
    if not s then return out end
    local sig = HR.HealerSig(healerKey, talentSpells)
    for _, v in pairs(s.variants) do
        if v.isTemplate and HR.HealerSig(v.healer, v.talentSpells) == sig then
            out[#out + 1] = v
        end
    end
    table.sort(out, function(a, b) return (a.name or "") < (b.name or "") end)
    return out
end

-- Le `unit` a-t-il le trinket `itemId` equipe (slots 13/14) ? Lisible pour "player" et,
-- dans la fenetre d'inspect, pour un allie inspecte.
function HR.HasTrinket(itemId, unit)
    unit = unit or "player"
    if not itemId then return false end
    for _, slot in ipairs({ 13, 14 }) do
        if GetInventoryItemID(unit, slot) == itemId then return true end
    end
    return false
end

-- "Discover" : trouve le healer du groupe, lit ses talents (local = direct, allie = inspect
-- async) et appelle cb(talentSet, err, healerName, unit). `unit` sert au scan de TRINKET.
function HR.ScanHealerTalents(cb)
    local unit
    for _, u in ipairs(groupUnits()) do
        if UnitExists(u) then
            local _, class = UnitClass(u)
            if class and HEAL_CLASSES[class] and unitRole(u) == "HEALER" then unit = u; break end
        end
    end
    if not unit then return cb(nil, "Aucun healer dans le groupe.") end
    if UnitIsUnit(unit, "player") then return cb(HR.GetLocalActiveTalents(), nil, UnitName(unit), unit) end
    if not (CanInspect and CanInspect(unit)) then return cb(nil, "Healer non inspectable (portee ?).") end
    local guid, done = UnitGUID(unit), false
    local f = CreateFrame("Frame")
    f:RegisterEvent("INSPECT_READY")
    f:SetScript("OnEvent", function(_, _, g)
        if done or (g and g ~= guid) then return end
        done = true
        f:UnregisterEvent("INSPECT_READY")
        local icfg = Constants and Constants.TraitConsts and Constants.TraitConsts.INSPECT_TRAIT_CONFIG_ID
        cb(talentSetFromConfig(icfg), nil, UnitName(unit), unit)
        if ClearInspectPlayer then ClearInspectPlayer() end
    end)
    NotifyInspect(unit)
    C_Timer.After(2, function()
        if not done then done = true; f:UnregisterEvent("INSPECT_READY"); cb(nil, "Pas de reponse (inspect, portee ?).") end
    end)
end

-- Spe heal du groupe -> clef de profil heal. Priorite au joueur LOCAL s'il heal (spe
-- exacte), sinon 1er allie HEALER (spe via inspect si dispo, sinon defaut du profil).
function HR.ScanGroupHealer()
    local fallback
    for _, unit in ipairs(groupUnits()) do
        if UnitExists(unit) then
            local _, class = UnitClass(unit)
            if class and HEAL_CLASSES[class] and unitRole(unit) == "HEALER" then
                local key = HR.HealProfileKey(class, unitSpecName(unit))
                if UnitIsUnit(unit, "player") then return key end   -- local = exact, prioritaire
                fallback = fallback or key
            end
        end
    end
    return fallback
end

-- Scan du groupe -> quantite par EXTERNAL ({ defKey = count }). Compte par CLASSE
-- (+ filtre de spe/role pour les spe-gated). Pour les sorts a plusieurs variantes de CD
-- (AMZ 3/4 min), on tente la detection par TALENT pour le joueur LOCAL : si une variante
-- porte `cdTalent` et que ce talent est actif -> cette variante ; sinon le local prend la
-- variante de base. Les allies (talents non lisibles) tombent sur la variante par defaut.
function HR.ScanGroupExternals()
    local talents = HR.GetLocalActiveTalents()
    local members = {}
    for _, unit in ipairs(groupUnits()) do
        if UnitExists(unit) then
            local _, class = UnitClass(unit)
            if class then
                members[#members + 1] = {
                    class = class, spec = unitSpecName(unit), role = unitRole(unit),
                    isLocal = UnitIsUnit(unit, "player"), unit = unit,
                }
            end
        end
    end

    local function provides(mb, d)
        if mb.class ~= d.class then return false end
        if d.role and mb.role ~= d.role then return false end   -- external reserve a un role (ex. Zephyr DAMAGER) : jamais compte pour le heal
        if not d.spec then return true end
        if mb.spec then return mb.spec == d.spec end
        return mb.role == "DAMAGER"
    end

    -- Variantes regroupees par sort reel (ordre = GetExternals, par nom).
    local groups = {}
    for _, e in ipairs(HR.GetExternals()) do
        local sid = HR.GetDefensiveSpellID(e.key)
        groups[sid] = groups[sid] or {}
        table.insert(groups[sid], { key = e.key, d = HR.defensives[e.key] })
    end

    local function chooseVariant(entries, mb)
        if #entries == 1 then return entries[1] end
        if mb.isLocal then
            for _, en in ipairs(entries) do
                if en.d.cdTalent and talents[en.d.cdTalent] then return en end   -- variante talentee active
            end
            local hasTalented = false
            for _, en in ipairs(entries) do if en.d.cdTalent then hasTalented = true; break end end
            if hasTalented then
                for _, en in ipairs(entries) do if not en.d.cdTalent then return en end end  -- local sans talent -> base
            end
        end
        return entries[1]   -- defaut (allie / pas de data talent) : 1re par nom
    end

    local result = {}
    for _, e in ipairs(HR.GetExternals()) do result[e.key] = 0 end
    for _, entries in pairs(groups) do
        local d0 = entries[1].d
        if not d0.trinket then                       -- trinkets : pas de classe -> traites a part
            for _, mb in ipairs(members) do
                if provides(mb, d0) then
                    local en = chooseVariant(entries, mb)
                    result[en.key] = (result[en.key] or 0) + 1
                end
            end
        end
    end

    -- TRINKETS externals : aucune classe -> comptage par ITEM equipe (slots 13/14), tout
    -- role. On EXCLUT le healer (son trinket vit cote talents/HealerSig + repli ExternalsSig)
    -- pour ne pas le compter deux fois. Fiable pour le joueur LOCAL ; pour un allie, lisible
    -- seulement si son equipement l'est (inspect prealable) -- sinon a ajouter a la main.
    for _, e in ipairs(HR.GetExternals()) do
        local d = HR.defensives[e.key]
        if d.trinket and d.itemId then
            for _, mb in ipairs(members) do
                if mb.role ~= "HEALER" and HR.HasTrinket(d.itemId, mb.unit) then
                    result[e.key] = (result[e.key] or 0) + 1
                end
            end
        end
    end
    return result
end

-- Scan ASYNC des trinkets EXTERNALS du groupe : inspecte SEQUENTIELLEMENT chaque membre
-- NON-heal (le joueur local est lu direct, sans inspect) pour lire ses trinkets equipes,
-- puis appelle cb({ [defKey] = count }). Le healer est ignore (son trinket = cote talents).
-- A chainer APRES l'inspect des talents du heal pour ne pas se disputer la file d'inspect.
function HR.ScanGroupTrinkets(cb)
    local trinkets = {}
    for key, d in pairs(HR.defensives) do
        -- external seulement : un trinket healer-only (trinket sans external, ex. Vessel) ne doit
        -- PAS etre compte chez les DPS (sinon cle morte ecrite dans draftExternals cote HealerSpecs).
        if d.trinket and d.itemId and d.external then trinkets[#trinkets + 1] = { key = key, itemId = d.itemId } end
    end
    local counts = {}
    for _, t in ipairs(trinkets) do counts[t.key] = 0 end
    if #trinkets == 0 then return cb(counts) end

    local units = {}
    for _, u in ipairs(groupUnits()) do
        if UnitExists(u) then
            local _, class = UnitClass(u)
            if class and unitRole(u) ~= "HEALER" then units[#units + 1] = u end
        end
    end

    local function tally(unit)
        for _, t in ipairs(trinkets) do
            if HR.HasTrinket(t.itemId, unit) then counts[t.key] = counts[t.key] + 1 end
        end
    end

    local i, f, timer = 0, CreateFrame("Frame"), nil
    local nextUnit
    local function finish()
        f:UnregisterAllEvents(); f:SetScript("OnEvent", nil)
        if timer then timer:Cancel(); timer = nil end
        cb(counts)
    end
    nextUnit = function()
        i = i + 1
        local unit = units[i]
        if not unit then return finish() end
        if UnitIsUnit(unit, "player") then tally(unit); return nextUnit() end
        if not (CanInspect and CanInspect(unit)) then return nextUnit() end
        local guid, handled = UnitGUID(unit), false
        f._on = function(g)
            if handled or (g and g ~= guid) then return end
            handled = true
            if timer then timer:Cancel(); timer = nil end
            tally(unit)
            if ClearInspectPlayer then ClearInspectPlayer() end
            nextUnit()
        end
        timer = C_Timer.NewTimer(2, function()           -- pas de reponse a temps -> on saute
            if not handled then handled = true; nextUnit() end
        end)
        NotifyInspect(unit)
    end
    f:RegisterEvent("INSPECT_READY")
    f:SetScript("OnEvent", function(_, _, g) if f._on then f._on(g) end end)
    nextUnit()
end
