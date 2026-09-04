-- EiikoCooldownPlanner - Core/SpellData.lua
-- Accesseurs des deux tables du modele de degats (Data/SpellEffects.lua et
-- Data/SpellDamage.lua). Elles sont indexees par spellID ; le PLAN, lui, stocke des
-- JETONS de defensif ("51052:0", "374227:heal", "SMALL_DEF"). Tout ce fichier existe pour
-- traduire l'un dans l'autre -- et pour dire, via /ecp audit, ce qui reste a saisir.
--
-- Les fichiers Data/ restent de la DATA PURE : aucune fonction n'y vit.
-- LECTURE SEULE de bout en bout : rien ici n'ecrit dans une table ni dans la DB.
local addonName, HR = ...

--------------------------------------------------------------------------------
-- Jointure jeton -> spellID
--------------------------------------------------------------------------------

-- spellID derriere un jeton de defensif, nil si le jeton n'en designe pas.
--
-- Trois formes coexistent dans HR.defensives, d'ou les deux etapes :
--   "51052:0" / "374227:heal"  cle synthetique (variante de talent) -> champ `spellID`
--   15286                      cle numerique   -> la cle EST le spellID
--   "SMALL_DEF" / "EMPTY_BAG"  placeholder     -> nil, et c'est correct : ce ne sont pas
--                              des sorts, ils sont HORS MODELE (decide).
--
-- HR.DefKeyOf (Core/Plan2.lua) fait le premier travail : il enleve les suffixes d'INSTANCE
-- ("#2", "@heal") et reconvertit une cle numerique en nombre. On s'appuie dessus plutot
-- que de redecouper le jeton nous-memes -- c'est lui qui connait le format des plans
-- deja sauvegardes chez les joueurs.
function HR.SpellIdForDef(token)
    if token == nil then return nil end
    local key = HR.DefKeyOf and HR.DefKeyOf(token) or token
    local d = HR.defensives and HR.defensives[key]
    if not d then return nil end
    return d.spellID or tonumber(key)
end

-- Entree d'effets d'un jeton de defensif, nil si inconnue.
function HR.EffectsForDef(token)
    local id = HR.SpellIdForDef(token)
    return id and HR.spellEffects[id] or nil
end

-- Entree d'effets d'un spellID (buffs permanents : pas de jeton de defensif derriere).
function HR.EffectsForSpell(spellID)
    return spellID and HR.spellEffects[spellID] or nil
end

-- Entree de degats d'une capacite de boss. `ability` = une entree de Data/Content.lua
-- (event de phase ou ability) ; son spellID est deja un spellID, aucune traduction.
function HR.DamageForAbility(ability)
    local id = ability and ability.spellID
    return id and HR.spellDamage[id] or nil
end

function HR.DamageForSpell(spellID)
    return spellID and HR.spellDamage[spellID] or nil
end

--------------------------------------------------------------------------------
-- Resolution des effets
--------------------------------------------------------------------------------
-- Une entree de HR.spellEffects n'est pas directement exploitable : elle peut porter des
-- `variants` departagees par les talents du joueur, et des `amounts` indexes par le RANG du
-- talent. Tout lecteur passe par ici -- sinon la variante et le rang seraient oublies une
-- fois sur deux, et de facon invisible.

-- Rang d'un talent chez ce joueur (1 par defaut : la grande majorite des talents n'a qu'un
-- rang, et un emetteur d'une version anterieure n'envoie pas de rang du tout).
local function rankOf(snapshot, spellID)
    local ranks = snapshot and snapshot.talentRanks
    local r = ranks and ranks[spellID]
    return (type(r) == "number" and r > 0) and r or 1
end

-- Le joueur a-t-il TOUS les talentReq et AUCUN talentNot ? Meme semantique que la selection
-- de variante de HR.defensives (cf. Core/Plan2.lua, MatchTalentVariant).
local function variantMatches(v, taken)
    for _, t in ipairs(v.talentReq or {}) do if not taken[t] then return false end end
    for _, t in ipairs(v.talentNot or {}) do if taken[t] then return false end end
    return true
end

-- Effets APPLICABLES d'un sort pour un joueur donne : la premiere variante qui matche
-- REMPLACE les `effects` de base, puis chaque `amounts` est reduit a l'`amount` du rang.
-- Renvoie une NOUVELLE liste -- la table de data n'est jamais modifiee.
-- nil si le sort n'a pas d'entree.
function HR.ResolveEffects(spellID, snapshot)
    local entry = spellID and HR.spellEffects[spellID]
    if not entry then return nil end

    local taken = (snapshot and snapshot.talentRanks) or {}
    local list = entry.effects
    for _, v in ipairs(entry.variants or {}) do
        if variantMatches(v, taken) then list = v.effects; break end
    end
    if not list then return nil end

    local rank = rankOf(snapshot, spellID)
    local out = {}
    for _, e in ipairs(list) do
        local copy = {}
        for k, val in pairs(e) do copy[k] = val end
        if e.amounts then
            -- Rang au-dela de ce que la data decrit : on prend la derniere valeur connue
            -- plutot que nil, qui ferait disparaitre l'effet en silence.
            copy.amount = e.amounts[rank] or e.amounts[#e.amounts]
            copy.amounts = nil
        end
        if type(copy.amount) == "function" then
            -- Variation qui scale (ex. un bouclier en % des PV max) : la data la decrit en
            -- Lua, on la resout ici pour que le moteur ne voie jamais qu'un nombre. pcall
            -- parce qu'une entree fautive ne doit pas casser un calcul en plein combat.
            local ok, val = pcall(copy.amount, snapshot)
            if ok and type(val) == "number" then
                copy.amount = val
            else
                HR:Debug("[spelldata] amount() failed for", tostring(spellID), tostring(val))
                copy.amount = 0
            end
        end
        out[#out + 1] = copy
    end
    return out
end

-- Effets PASSIFS que ce joueur porte en permanence du fait de ses TALENTS.
--
-- ⚠️ Le filtre sur `uptime == "PASSIVE"` n'est pas une precaution, c'est la correction d'un
-- piege : plus de 50 entrees de Data/Defensives.lua portent `talentReq`, et pour beaucoup
-- `talentReq = { le sort lui-meme }`. Anti-Magic Zone (51052) figure donc dans la liste de
-- talents du DK qui l'a prise. Sans ce filtre, on lui crediterait les 20 % de reduction
-- magique d'AMZ EN PERMANENCE, au lieu des 10 secondes ou le plan la pose.
function HR.PassiveEffectsFor(snapshot)
    local out = {}
    if not (snapshot and snapshot.talents) then return out end
    for _, id in ipairs(snapshot.talents) do
        local entry = HR.spellEffects[id]
        if entry and entry.uptime == "PASSIVE" then
            for _, e in ipairs(HR.ResolveEffects(id, snapshot) or {}) do
                out[#out + 1] = e
            end
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- Parcours du contenu
--------------------------------------------------------------------------------

-- Appelle fn(ability, boss, dungeon) pour chaque capacite qui PRODUIT une occurrence,
-- toutes variantes de timeline comprises. Ce sont celles-la, et elles seules, qui ont
-- besoin d'une entree de degats.
--
-- Une entree "duration-only" (`durations` mais PAS de `firstAt`) ne sert qu'au matching
-- runtime : GenerateFromAbilities la saute deja, on la saute aussi -- sinon l'audit
-- reclamerait des degats pour des sorts qui n'apparaissent dans aucun plan.
function HR.ForEachPlannedAbility(fn)
    for _, dungeon in ipairs(HR.content or {}) do
        for _, boss in ipairs(dungeon.bosses or {}) do
            -- Le boss tel quel, PLUS chacune de ses variantes de timeline : une capacite
            -- peut n'exister que dans une variante.
            local timelines = { boss }
            for _, v in ipairs(HR.GetTimelineVariants(boss) or {}) do
                timelines[#timelines + 1] = v
            end
            for _, tl in ipairs(timelines) do
                for _, phase in ipairs(tl.phases or {}) do
                    for _, e in ipairs(phase.events or {}) do fn(e, boss, dungeon) end
                end
                for _, a in ipairs(tl.abilities or {}) do
                    if a.firstAt then fn(a, boss, dungeon) end
                end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- /ecp audit
--------------------------------------------------------------------------------
-- Les deux tables vivent a cote de l'existant sans y etre reliees : un defensif ajoute
-- dans Data/Defensives.lua sans entree d'effets deviendrait SILENCIEUSEMENT non chiffrable.
-- C'est le prix de la separation ; cette commande le rend visible.

local MAX_LIST = 12   -- au-dela, on compte sans lister (le chat n'est pas un rapport)

local function printList(label, list, color)
    if #list == 0 then return end
    HR:Print(("  %s%s%s (%d) :"):format(color or HR.COLORS.YELLOW, label, HR.COLORS.RESET, #list))
    for i = 1, math.min(#list, MAX_LIST) do
        HR:Print("    " .. list[i])
    end
    if #list > MAX_LIST then
        HR:Print(("    ... and %d more"):format(#list - MAX_LIST))
    end
end

function HR.PrintSpellDataAudit()
    ----------------------------------------------------------------- defensifs
    local defMissing, placeholders = {}, {}
    local seenDef = {}
    for token, d in pairs(HR.defensives or {}) do
        local id = HR.SpellIdForDef(token)
        if not id then
            -- Pas de spellID : placeholder (SMALL_DEF / EMPTY_BAG). Hors modele, pas un manque.
            placeholders[#placeholders + 1] = ("%s (%s)"):format(tostring(token), tostring(d.name))
        elseif not seenDef[id] then
            seenDef[id] = true
            if not HR.spellEffects[id] then
                defMissing[#defMissing + 1] = ("%d  %s"):format(id, tostring(d.name))
            end
        end
    end
    local defTotal = 0
    for _ in pairs(seenDef) do defTotal = defTotal + 1 end

    ----------------------------------------------------------------- sorts de boss
    local dmgMissing, mismatch = {}, {}
    local seenAb = {}
    HR.ForEachPlannedAbility(function(ability, boss, dungeon)
        local id = ability.spellID
        if not id or seenAb[id] then return end
        seenAb[id] = true
        local dmg = HR.spellDamage[id]
        if not dmg then
            dmgMissing[#dmgMissing + 1] = ("%d  %s  (%s / %s)")
                :format(id, tostring(ability.name), tostring(dungeon.abbr or dungeon.name), tostring(boss.name))
        elseif ability.aoe ~= nil and dmg.avoidable ~= nil and ability.aoe ~= dmg.avoidable then
            -- Les deux disent la meme chose ; s'ils divergent, l'un des deux a ete edite seul.
            mismatch[#mismatch + 1] = ("%d  %s  content.aoe=%s  damage.avoidable=%s")
                :format(id, tostring(ability.name), tostring(ability.aoe), tostring(dmg.avoidable))
        end
    end)
    local abTotal = 0
    for _ in pairs(seenAb) do abTotal = abTotal + 1 end

    ----------------------------------------------------------------- rapport
    HR:Print(("Spell data audit -- effects %d/%d, damage %d/%d")
        :format(defTotal - #defMissing, defTotal, abTotal - #dmgMissing, abTotal))
    printList("defensives without an effects entry", defMissing)
    printList("boss abilities without a damage entry", dmgMissing)
    printList("aoe / avoidable disagreements", mismatch, HR.COLORS.RED)
    if #placeholders > 0 then
        HR:Print(("  %splaceholders ignored%s (%d) : %s")
            :format(HR.COLORS.GREEN, HR.COLORS.RESET, #placeholders, table.concat(placeholders, ", ")))
    end
    if #defMissing == 0 and #dmgMissing == 0 and #mismatch == 0 then
        HR:Print("  " .. HR.COLORS.GREEN .. "Nothing missing." .. HR.COLORS.RESET)
    end
end
