-- EiikoCooldownPlanner - UI/ImportBoss.lua
-- LA route d'import d'un plan de BOSS (memo §14.9). Une seule, partagee par les deux fils :
--   * le format texte web (`ecp;2;boss`)      -> UI/ImportText.lua passe la sortie de ST.Resolve
--   * l'export boss du catalogue (natif)      -> UI.ImportNativeBossPlan adapte le payload
--
-- POURQUOI UNE SEULE : deux ecrans qui confirment le meme geste, avec les memes consequences,
-- pour la meme personne, finissent par diverger -- et cette divergence-la se voit a l'ecran.
--
-- CE QUI LA DISTINGUE DES AUTRES IMPORTS : elle NE ROUTE PAS. Les imports de variante
-- choisissent leur destination (changement de donjon, creation). Ici le joueur doit DEJA etre
-- sur une variante eligible : on ecrase un boss dans ce qu'il a sous les yeux, on ne cree
-- rien, on ne change ni de donjon ni de variante.
--
-- FORME D'ECHANGE : `resolved`, la forme INTERNE ({ dID, dungeon, boss, healerKey,
-- assignments }). Le fil web la produit deja (ST.Resolve est son traducteur : son fil porte
-- de la donnee de JEU -- spellID, roster, occurrences `spellID:n` -- la ou le natif porte des
-- cles INTERNES d'ECP). C'est donc le natif qui s'adapte, pas l'inverse.
local addonName, HR = ...

HR.UI = HR.UI or {}
local UI = HR.UI

-- Donjon AFFICHE. Sert de repli au `dID` de la variante : celles creees avant le correctif
-- §9.1 n'en portent pas.
local function CurrentDungeonID()
    if UI.activeDungeonID then return UI.activeDungeonID end
    local d = HR.content and UI.selDungeon and HR.content[UI.selDungeon]
    return d and d.id or nil
end

--------------------------------------------------------------------------------
-- La route partagee
--------------------------------------------------------------------------------

-- `resolved` : { dID, dungeon, boss, healerKey, assignments }.
-- `encID`    : le boss a ecraser. UN SEUL, toujours.
-- `opts.warn`: bandeau de l'ecran de confirmation (le defaut ne dit que ce qui est vrai
--              pour tous les fils).
-- Renvoie true si un ecran a ete ouvert, false si l'import est refuse.
function UI.ImportBossPlan(resolved, encID, opts)
    local V  = HR.Valid
    local ST = HR.ShareText
    if not (V and ST) then HR:Print("Import unavailable (module missing)."); return false end

    local variant = HR.GetActiveVariant()          -- SANS argument : la variante AFFICHEE

    -- (1) Eligibilite de la cible. Rien n'est lu du plan tant que la destination n'est pas
    --     valide : inutile de detailler des tokens si le joueur n'est meme pas au bon endroit.
    local ok, code = V.CheckEligible(resolved.dID, resolved.healerKey, variant,
                                     CurrentDungeonID())
    if not ok then
        local prof = resolved.healerKey and HR.GetHealProfileOrNone(resolved.healerKey)
        UI.ShowImportReport("This boss plan cannot be applied here. Nothing was imported.", {
            V.EligibleMessage(code, {
                dungeonName = resolved.dungeon and resolved.dungeon.name,
                healerName  = (prof and prof.name) or resolved.healerKey,
                variant     = variant,
            }),
        })
        return false
    end

    -- (2) Structure du bloc : occurrences reelles, defensifs connus. Les occKey sont
    --     resolus contre la variante de TIMELINE AFFICHEE -- la meme que celle de l'editeur,
    --     sinon on validerait contre des cles que le joueur ne voit pas.
    local rep = V.Report()
    local tokens = V.CheckBossPlan(resolved.assignments and resolved.assignments[encID], {
        bossName = resolved.boss and resolved.boss.name or "?",
        occSet   = V.OccKeys(resolved.boss, UI.GetViewedTlVariant),
    }, rep)
    if not tokens then
        UI.ShowImportReport("This boss plan does not match the addon's data. Nothing was "
            .. "imported.", rep:Lines())
        return false
    end

    -- (3) Placabilite dans la variante cible. On ne compare QUE les sorts utilises par le
    --     morceau importe ; ils doivent tous figurer a destination, l'inverse n'est pas exige
    --     (memo §14.3). C'est deja exactement ce que fait ValidateAgainstVariant -- on ne
    --     reecrit pas ce qu'on peut appeler.
    resolved.tokensByUse = tokens
    local verrs = ST.ValidateAgainstVariant(resolved, variant)
    if #verrs > 0 then
        UI.ShowImportReport(
            ("This boss plan is not playable in variant \"%s\". Nothing was imported.")
                :format(HR.EscapeMarkup(variant.name or "?")), verrs)
        return false
    end

    -- (4) Assainissement, APRES la validation et jamais avant (memo §14.7) :
    --     SanitizeAssignments jette en SILENCE ce qu'elle ne reconnait pas. Valider d'abord,
    --     c'est la difference entre un refus explicite et un plan troue sans un mot. Ici elle
    --     ne fait donc plus que borner les offsets et normaliser la forme.
    resolved.assignments = HR.Share.SanitizeAssignments(resolved.dID, resolved.assignments)
    local block = resolved.assignments[encID]
    if not block or not next(block) then
        UI.ShowImportReport("This boss plan is empty. Nothing was imported.",
            { "No placement survived validation." })
        return false
    end

    UI.OpenBossConfirm(resolved, encID, variant, opts)
    return true
end

--------------------------------------------------------------------------------
-- Adaptateur du fil NATIF : payload -> resolved
--------------------------------------------------------------------------------

-- `payload` a deja passe Share.ValidatePayload (donjon connu, profil de heal reel) et porte
-- `bossOnly`. Six lignes de conversion, plus deux gardes.
function UI.ImportNativeBossPlan(payload)
    local V = HR.Valid
    if not V then HR:Print("Import unavailable (module missing)."); return false end

    local encID = payload.bossOnly
    local dungeon = V.CheckDungeon(payload.dID)
    local boss, code = V.CheckEncounter(encID, dungeon)
    if not boss then
        UI.ShowImportReport("This boss plan could not be read. Nothing was imported.",
            { V.Message({ code = code or V.E_ENCOUNTER }) })
        return false
    end

    -- On ne retient QUE le boss declare. Deux effets : on tolere une cle d'encounter arrivee
    -- en chaine (CBOR), et surtout un payload qui transporterait d'autres boss ne peut pas
    -- les faire ecrire -- seul `bossOnly` est atteignable.
    local asg = (type(payload.asg) == "table") and payload.asg or {}
    local block = asg[encID] or asg[tostring(encID)]

    return UI.ImportBossPlan({
        dID         = payload.dID,
        dungeon     = dungeon,
        boss        = boss,
        healerKey   = payload.healer,
        assignments = { [encID] = block },   -- BRUT : on valide avant d'assainir (§14.7)
    }, encID)
end
