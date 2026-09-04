-- EiikoCooldownPlanner - Core/Sync/Stats.lua
-- STATS? / STATS : "que valent vos personnages ?". Meme forme que HELLO / HELLO_ACK
-- (Core/Sync/Handshake.lua) : diffusion au groupe, chacun repond a l'emetteur SEUL sur le
-- canal addon, fermeture a T+WINDOW qui liste les muets.
--
-- POURQUOI un aller-retour reseau plutot qu'une lecture directe : UnitArmor / UnitStat /
-- GetCombatRatingBonus ne fonctionnent QUE pour "player" (verifie dans la doc 12.x) -- on
-- ne peut pas lire l'armure d'un allie. Chaque client lit donc les SIENNES et les envoie.
--
-- POURQUOI un cache HORS COMBAT : ces memes APIs portent le predicat
-- SecretWhenUnitStatsRestricted -> en combat, en encounter, en M+ et en PvP elles rendent
-- des Secret Values. On rafraichit donc hors combat et on repond avec le cache, meme si la
-- demande arrive au milieu d'un donjon. Le champ `age` dit au demandeur si c'est frais.
--
-- AUCUNE ecriture en DB : l'etat est volatile (HR.Sync.stats), comme HR.Sync.roster.
-- Ce fichier n'enregistre AUCUN listener : c'est Core/Sync/Listeners.lua qui l'appelle.
local addonName, HR = ...

HR.Sync = HR.Sync or {}
HR.Sync.Stats = HR.Sync.Stats or {}
local Stats = HR.Sync.Stats
local Net = HR.Sync.Net

local PROTO       = 1     -- version du corps STATS (independante du PROTO de transport)
local WINDOW      = 5     -- (s) duree d'une passe
local REPLY_QUIET = 10    -- (s) on ne repond pas deux fois au meme joueur coup sur coup
local MAX_LIST    = 150   -- bornes de lecture reseau : taille max d'une liste recue.
                          -- Une loadout de talents complete fait ~70 entrees : le plafond
                          -- doit la laisser passer entiere, sinon on tronquerait en silence.

-- Derniers snapshots connus du groupe : stats["Nom-Royaume"] = table decodee.
-- Volatile, remis a zero a chaque passe.
HR.Sync.stats = HR.Sync.stats or {}

local pass = nil          -- passe en cours : { msgId, at, seen = {} }
local answered = {}       -- [expediteur] = GetTime() de notre derniere reponse

-- Nom qualifie "Nom-Royaume". Meme normaliseur que Handshake.lua : les trois sources de
-- nom (reponse addon qualifiee, UnitName nu, UnitFullName) ne se comparent pas brutes.
local function qualified(name, realm)
    if HR.Keys and HR.Keys.QualifiedName then return HR.Keys.QualifiedName(name, realm) end
    if not name or name == "" then return nil end
    if realm and realm ~= "" then return name .. "-" .. realm end
    if name:find("-", 1, true) then return name end
    return name .. "-" .. (GetNormalizedRealmName() or "")
end

--------------------------------------------------------------------------------
-- Lecture des stats locales
--------------------------------------------------------------------------------

-- SEULE porte d'entree des valeurs du jeu. Un Secret Value ne doit JAMAIS atteindre une
-- addition, une comparaison ou une concatenation : on le remplace par `default` ici, une
-- fois, plutot que de proteger chaque site d'usage.
local function num(v, default)
    if v == nil then return default end
    if issecretvalue and issecretvalue(v) then return default end
    if type(v) ~= "number" then return default end
    return v
end

-- GetCombatRatingBonus(nil) leverait : on ne l'appelle que si la constante existe.
local function ratingBonus(cr)
    if type(cr) ~= "number" or not GetCombatRatingBonus then return 0 end
    return num(GetCombatRatingBonus(cr), 0) / 100      -- l'API rend des POURCENTS
end

-- Buffs presents QUI COMPTENT : ceux que Data/SpellEffects.lua decrit comme PERMANENT.
-- Tant que la table est vide, la liste l'est aussi -- c'est correct, elle se remplira au
-- fur et a mesure de la saisie.
--
-- Renvoie AUSSI le nombre d'auras effectivement LUES. Sans ce second compteur, une liste
-- vide serait ambigue : "rien a suivre" et "la lecture des auras ne marche pas" (API
-- absente, spellId secret) donnent tous les deux zero. Le compteur les separe.
local function ActiveTrackedBuffs()
    local out, seen = {}, 0
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return out, seen end
    for i = 1, 100 do
        local a = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
        if not a then break end
        seen = seen + 1
        local id = num(a.spellId, nil)
        local e = id and HR.spellEffects[id]
        if e and e.uptime == "PERMANENT" then out[#out + 1] = id end
    end
    return out, seen
end

-- Snapshot complet. TOUTES les valeurs "en pourcent" sont normalisees en FRACTIONS
-- (0..1) : une seule regle d'unite dans tout le modele, pas de melange % / fraction.
-- Renvoie nil en combat : les stats y sont secretes, on ne fabrique pas un snapshot faux.
function Stats.Build()
    if InCombatLockdown and InCombatLockdown() then return nil end

    local _, class = UnitClass("player")
    local _, race  = UnitRace("player")
    local level    = num(UnitLevel("player"), 0)

    local specID
    if GetSpecialization and GetSpecializationInfo then
        local idx = GetSpecialization()
        if idx then specID = num(GetSpecializationInfo(idx), nil) end
    end

    -- Hors combat ne suffit pas : sur une carte a restrictions (donjon, raid) les stats
    -- peuvent rester secretes, et `num` les remplacerait alors par des zeros -- on mettrait
    -- en cache un personnage a 0 PV et 0 armure, servi ensuite comme une mesure. Un PV max
    -- nul est impossible pour un vrai personnage : c'est le temoin qu'on refuse le snapshot.
    local hpMax = num(UnitHealthMax("player"), 0)
    if hpMax <= 0 then return nil end

    local _, effectiveArmor = UnitArmor("player")
    effectiveArmor = num(effectiveArmor, 0)

    local armorDR = 0
    if C_PaperDollInfo and C_PaperDollInfo.GetArmorEffectiveness then
        armorDR = num(C_PaperDollInfo.GetArmorEffectiveness(effectiveArmor, level), 0)
    end

    local stagger = 0
    if C_PaperDollInfo and C_PaperDollInfo.GetStaggerPercentage then
        stagger = num(C_PaperDollInfo.GetStaggerPercentage("player"), 0) / 100
    end

    -- TOUS les talents actifs (HR.GetLocalActiveTalents rend un set { spellID = RANG }),
    -- pas seulement ceux que HR.defensives interroge aujourd'hui : la table d'effets va
    -- grandir, et un talent absent du snapshot serait invisible le jour ou on en aura
    -- besoin. Une loadout complete fait ~70 ids, soit quelques centaines d'octets que
    -- Net.Send decoupe tout seul -- le cout est nul face a une collecte incomplete.
    --
    -- DEUX formes conservees : `talents` = liste TRIEE d'ids (ordre stable pour l'encodage et
    -- l'affichage), `talentRanks` = table id -> rang (acces direct pour la resolution des
    -- `amounts[rang]` cote Core/SpellData.lua). L'une sans l'autre obligerait a re-parcourir.
    local talents, talentRanks = {}, {}
    for id, rank in pairs(HR.GetLocalActiveTalents and HR.GetLocalActiveTalents() or {}) do
        talents[#talents + 1] = id
        talentRanks[id] = num(rank, 1)
    end
    table.sort(talents)

    local buffs, buffsSeen = ActiveTrackedBuffs()

    return {
        -- primaires (UnitStat : 1 force, 2 agilite, 3 endurance, 4 intelligence)
        str = num(UnitStat("player", 1), 0),
        agi = num(UnitStat("player", 2), 0),
        sta = num(UnitStat("player", 3), 0),
        int = num(UnitStat("player", 4), 0),
        -- secondaires (fractions)
        crit  = num(GetCritChance and GetCritChance(), 0) / 100,
        haste = num(GetHaste and GetHaste(), 0) / 100,
        mast  = num(GetMasteryEffect and GetMasteryEffect(), 0) / 100,
        vers  = ratingBonus(CR_VERSATILITY_DAMAGE_DONE),
        -- tertiaires (fractions)
        versDR    = ratingBonus(CR_VERSATILITY_DAMAGE_TAKEN),
        avoidance = ratingBonus(CR_AVOIDANCE),
        leech     = ratingBonus(CR_LIFESTEAL),
        speed     = ratingBonus(CR_SPEED),
        -- survie
        hpMax   = hpMax,
        armor   = effectiveArmor,
        armorDR = armorDR,
        stagger = stagger,
        block   = num(GetBlockChance and GetBlockChance(), 0) / 100,
        -- identite
        class = class, race = race, specID = specID, level = level,
        ilvl  = num(select(2, GetAverageItemLevel()), 0),
        -- contexte
        talents     = talents,
        talentRanks = talentRanks,
        trinkets = { num(GetInventoryItemID("player", 13), 0), num(GetInventoryItemID("player", 14), 0) },
        buffs    = buffs,
        buffsSeen = buffsSeen,   -- diagnostic LOCAL, pas transporte (cf. Stats.Encode)
        at       = GetTime(),
    }
end

--------------------------------------------------------------------------------
-- Cache
--------------------------------------------------------------------------------

local cache, dirty = nil, true

-- Marque le cache PERIME sans le jeter. Appele par Core/Sync/Listeners.lua sur sortie de
-- combat, changement d'equipement et changement de spe.
--
-- On ne met surtout pas `cache = nil` : PLAYER_EQUIPMENT_CHANGED fire aussi EN COMBAT, ou
-- Build() ne peut rien produire (stats secretes). On perdrait un snapshot valide pour ne
-- rien avoir a la place, et on repondrait "no data" a un demandeur.
function Stats.Invalidate()
    dirty = true
end

-- Snapshot a jour si on a pu le refaire, sinon le dernier connu. nil seulement si on n'a
-- JAMAIS reussi a en prendre un (connexion en plein combat, par exemple).
function Stats.Mine()
    if dirty then
        local fresh = Stats.Build()
        if fresh then
            cache, dirty = fresh, false
        end
    end
    return cache
end

--------------------------------------------------------------------------------
-- Encodage
--------------------------------------------------------------------------------
-- Format `cle=valeur;cle=valeur`. Pas de CBOR : le corps est minuscule, et un format a
-- CLES survit a une difference de version -- un client plus ancien ignore un champ qu'il
-- ne connait pas au lieu de tout decaler, ce qu'un format positionnel ne permet pas.

local function n0(v) return ("%d"):format(math.floor(num(v, 0) + 0.5)) end
local function n4(v) return ("%.4f"):format(num(v, 0)) end

function Stats.Encode(s)
    if type(s) ~= "table" then return nil end
    local t = {
        "v=" .. PROTO,
        "str=" .. n0(s.str), "agi=" .. n0(s.agi), "sta=" .. n0(s.sta), "int=" .. n0(s.int),
        "crit=" .. n4(s.crit), "haste=" .. n4(s.haste), "mast=" .. n4(s.mast), "vers=" .. n4(s.vers),
        "vdr=" .. n4(s.versDR), "avo=" .. n4(s.avoidance), "lee=" .. n4(s.leech), "spd=" .. n4(s.speed),
        "hp=" .. n0(s.hpMax), "arm=" .. n0(s.armor), "adr=" .. n4(s.armorDR),
        "stg=" .. n4(s.stagger), "blk=" .. n4(s.block),
        "lvl=" .. n0(s.level), "ilvl=" .. n0(s.ilvl),
        "age=" .. n0(math.max(0, GetTime() - (s.at or GetTime()))),
    }
    if s.class then t[#t + 1] = "cls=" .. s.class end
    if s.race then t[#t + 1] = "race=" .. s.race end
    if s.specID then t[#t + 1] = "spec=" .. n0(s.specID) end
    -- Talents en `id:rang`. Le rang est TOUJOURS ecrit, meme a 1 : l'omettre economiserait
    -- deux octets par entree au prix d'une forme ambigue a relire, sur un corps que le
    -- transport decoupe de toute facon.
    if s.talents and #s.talents > 0 then
        local ranks = s.talentRanks or {}
        local out = {}
        for _, id in ipairs(s.talents) do
            out[#out + 1] = ("%d:%d"):format(id, num(ranks[id], 1))
        end
        t[#t + 1] = "tal=" .. table.concat(out, ",")
    end
    if s.trinkets then t[#t + 1] = "trk=" .. table.concat(s.trinkets, ",") end
    if s.buffs and #s.buffs > 0 then t[#t + 1] = "buf=" .. table.concat(s.buffs, ",") end
    return table.concat(t, ";")
end

-- Decode un corps recu. ENTREE RESEAU : on ne fait confiance a rien. Cles bornees a un
-- alphabet, valeurs bornees en type ET en taille, listes plafonnees. Une cle inconnue est
-- ignoree, jamais utilisee pour indexer quoi que ce soit.
local function parseList(str)
    local out = {}
    for v in tostring(str):gmatch("[^,]+") do
        local n = tonumber(v)
        if n then out[#out + 1] = n end
        if #out >= MAX_LIST then break end
    end
    return out
end

-- `id:rang,id:rang,...` -> liste triee d'ids + table id -> rang. Un `id` nu (emetteur d'une
-- version anterieure au rang) vaut rang 1 : on lit l'ancienne forme sans la reclamer.
local function parseTalents(str)
    local ids, ranks = {}, {}
    for entry in tostring(str):gmatch("[^,]+") do
        local id, rank = entry:match("^(%d+):(%d+)$")
        if not id then id, rank = entry:match("^(%d+)$"), "1" end
        id, rank = tonumber(id), tonumber(rank)
        if id and rank and rank > 0 and rank < 20 and not ranks[id] then
            ids[#ids + 1] = id
            ranks[id] = rank
        end
        if #ids >= MAX_LIST then break end
    end
    return ids, ranks
end

function Stats.Decode(body)
    if type(body) ~= "string" or #body > 2048 then return nil end
    local raw = {}
    for k, v in body:gmatch("([%w_]+)=([^;]*)") do raw[k] = v end
    if tonumber(raw.v) ~= PROTO then return nil end

    local talentIds, talentRanks = parseTalents(raw.tal or "")

    local function f(key) return tonumber(raw[key]) or 0 end
    local function word(key)
        local v = raw[key]
        return (type(v) == "string" and v:match("^[%w_]+$") and #v <= 20) and v or nil
    end

    return {
        str = f("str"), agi = f("agi"), sta = f("sta"), int = f("int"),
        crit = f("crit"), haste = f("haste"), mast = f("mast"), vers = f("vers"),
        versDR = f("vdr"), avoidance = f("avo"), leech = f("lee"), speed = f("spd"),
        hpMax = f("hp"), armor = f("arm"), armorDR = f("adr"),
        stagger = f("stg"), block = f("blk"),
        level = f("lvl"), ilvl = f("ilvl"), specID = tonumber(raw.spec),
        class = word("cls"), race = word("race"),
        talents     = talentIds,
        talentRanks = talentRanks,
        trinkets = parseList(raw.trk or ""),
        buffs    = parseList(raw.buf or ""),
        age = f("age"),
    }
end

--------------------------------------------------------------------------------
-- Emission
--------------------------------------------------------------------------------

-- Abrege un gros nombre (PV, armure) : "3.4M" / "45.0k". Aucune dependance -- le projet
-- n'a pas de formateur, et AbbreviateNumbers est localise donc peu lisible en debug.
local function short(n)
    n = num(n, 0)
    if n >= 1e6 then return ("%.1fM"):format(n / 1e6) end
    if n >= 1e3 then return ("%.1fk"):format(n / 1e3) end
    return ("%d"):format(n)
end

local function describe(name, s, late)
    local cls = s.class or "?"
    if s.class and HR.ClassColorHex then
        cls = "|c" .. HR.ClassColorHex(s.class) .. s.class .. "|r"
    end
    -- `age` vient du reseau ; pour NOTRE propre snapshot (seed local) il n'y en a pas, on
    -- le derive de `at`.
    local age = math.floor(s.age or (s.at and math.max(0, GetTime() - s.at)) or 0)
    return ("  %-24s %s  hp %s  armor %s (%.1f%%)  versDR %.1f%%  avoid %.1f%%  ilvl %d  %ds ago%s")
        :format(name, cls, short(s.hpMax), short(s.armor), (s.armorDR or 0) * 100,
                (s.versDR or 0) * 100, (s.avoidance or 0) * 100, s.ilvl or 0, age,
                late and (" " .. HR.COLORS.YELLOW .. "(late)" .. HR.COLORS.RESET) or "")
end

-- Detail COMPLET de notre propre snapshot. Il ne passe par aucun reseau : c'est la seule
-- partie de la collecte qui marche seul, et c'est aussi la seule facon de verifier d'un
-- coup d'oeil que la lecture des stats fonctionne (ce que la ligne resumee ne montre pas).
-- Renvoie le snapshot, ou nil s'il n'a pas pu etre pris.
function Stats.PrintMine()
    local s = Stats.Mine()
    if not s then
        HR:Print(HR.COLORS.RED .. "Your stats are unreadable right now." .. HR.COLORS.RESET
            .. " Armor and ratings are secret values in combat and in restricted instances --"
            .. " step out of combat and try again.")
        return nil
    end
    -- Une stat par ligne, libelle en CAPITALES. Valeurs BRUTES (pas de "3.4M") : cet
    -- affichage sert a comparer champ par champ avec la feuille de personnage -- un chiffre
    -- abrege ne se compare pas. La ligne resumee du groupe, elle, garde `short`.
    local function asInt(v) return ("%d"):format(math.floor(num(v, 0) + 0.5)) end
    local function asPct(v) return ("%.2f%%"):format(num(v, 0) * 100) end

    local rows = {
        { "STRENGTH",        asInt(s.str) },
        { "AGILITY",         asInt(s.agi) },
        { "STAMINA",         asInt(s.sta) },
        { "INTELLECT",       asInt(s.int) },
        { "CRITICAL STRIKE", asPct(s.crit) },
        { "HASTE",           asPct(s.haste) },
        { "MASTERY",         asPct(s.mast) },
        { "VERSATILITY",     asPct(s.vers) },
        { "AVOIDANCE",       asPct(s.avoidance) },
        { "LEECH",           asPct(s.leech) },
        { "SPEED",           asPct(s.speed) },
        { "MAX HEALTH",      asInt(s.hpMax) },
        { "ARMOR",           asInt(s.armor) },
        { "ARMOR DR",        asPct(s.armorDR) },
        { "VERSATILITY DR",  asPct(s.versDR) },
        { "STAGGER",         asPct(s.stagger) },
        { "BLOCK",           asPct(s.block) },
        { "CLASS",           tostring(s.class) },
        { "SPEC",            tostring(s.specID) },
        { "RACE",            tostring(s.race) },
        { "LEVEL",           asInt(s.level) },
        { "ITEM LEVEL",      asInt(s.ilvl) },
        { "TRINKETS",        table.concat(s.trinkets, " / ") },
        -- Le nombre d'auras LUES separe "rien a suivre" (table d'effets encore vide) de
        -- "la lecture des auras ne marche pas" -- les deux donnent 0 suivi sans ce chiffre.
        { "TRACKED BUFFS",   ("%d  (out of %d auras read)"):format(#s.buffs, s.buffsSeen or 0) },
        { "TALENTS",         asInt(#s.talents) },
    }

    local age = math.floor(math.max(0, GetTime() - (s.at or GetTime())))
    HR:Print(("Your stats (%ds ago):"):format(age))
    for _, r in ipairs(rows) do
        HR:Print(("  %s%-16s%s %s"):format(HR.COLORS.YELLOW, r[1], HR.COLORS.RESET, r[2]))
    end

    -- Les listes d'ids passent APRES le tableau et sur leurs propres lignes : une loadout
    -- fait ~70 entrees, ca ne tient pas dans une colonne. Par paquets de 10, pour rester
    -- lisible et copiable depuis le chat.
    -- `ranks` optionnel : un talent pris a 2/2 s'affiche "123456:2". Le rang n'est montre que
    -- s'il depasse 1 -- l'ecrire partout noierait les rares cas qui comptent vraiment.
    local function printIds(label, ids, ranks)
        if not ids or #ids == 0 then return end
        HR:Print(("  %s%s%s (%d) :"):format(HR.COLORS.YELLOW, label, HR.COLORS.RESET, #ids))
        for i = 1, #ids, 10 do
            local slice = {}
            for j = i, math.min(i + 9, #ids) do
                local id = ids[j]
                local r = ranks and ranks[id]
                slice[#slice + 1] = (r and r > 1) and ("%d:%d"):format(id, r) or tostring(id)
            end
            HR:Print("    " .. table.concat(slice, " "))
        end
    end
    printIds("TALENT IDS", s.talents, s.talentRanks)
    printIds("TRACKED BUFF IDS", s.buffs)
    return s
end

-- Ouvre une passe : affiche NOS stats, puis diffuse STATS? et arme la fermeture.
function Stats.Broadcast(reason)
    -- Les siennes d'abord, toujours : elles ne dependent d'aucun groupe et d'aucun reseau.
    -- Sortir avant de les lire (ce que faisait la premiere version en solo) rendait la
    -- commande muette pour le seul joueur dont on est SUR de pouvoir tout lire.
    local mine = Stats.PrintMine()

    local channel, target = Net.GroupChannel()
    if not channel then
        HR:Print("Not in a party or raid -- nobody else to ask.")
        return
    end
    local selfEcho = (channel == "WHISPER")

    wipe(HR.Sync.stats)
    local msgId = Net.NewMsgId()
    pass = { msgId = msgId, at = GetTime(), seen = {} }

    if not Net.Send("STATS?", "", channel, target, msgId) then
        pass = nil
        HR:Print("Stats request failed to send.")
        return
    end

    HR.RebuildGroup()
    HR:Debug("[sync] stats request", tostring(reason), msgId)
    HR:Print(("Stats requested from %s (%d member%s). Replies:")
        :format(selfEcho and "yourself (solo)" or channel,
                #HR.group, (#HR.group == 1) and "" or "s"))

    -- On ne recoit pas ses PROPRES messages addon en groupe : sans ce seed, l'emetteur se
    -- listerait lui-meme en "no data" a la fermeture. Aucune ligne imprimee ici -- PrintMine
    -- vient de le faire, en detail. En solo l'echo local fait le tour, on le laisse faire.
    if not selfEcho and mine then
        local me = qualified(UnitFullName("player"))
        if me then
            HR.Sync.stats[me] = mine
            pass.seen[me] = true
        end
    end

    C_Timer.After(WINDOW, function() Stats.Close(msgId) end)
end

--------------------------------------------------------------------------------
-- Reception
--------------------------------------------------------------------------------

-- Quelqu'un demande nos stats : on repond a LUI SEUL sur le canal addon.
-- Silencieux si on n'a jamais pu prendre de snapshot (connexion en plein combat) : mieux
-- vaut apparaitre "no data" chez le demandeur qu'envoyer des zeros credibles.
function Stats.OnRequest(from, body, msgId)
    if type(from) ~= "string" or from == "" then return end
    local now = GetTime()
    if answered[from] and (now - answered[from]) < REPLY_QUIET then
        HR:Debug("[sync] STATS? throttled for", from)
        return
    end
    local mine = Stats.Mine()
    if not mine then
        HR:Debug("[sync] STATS? from", from, "-- no snapshot yet (in combat since login?)")
        return
    end
    answered[from] = now
    Net.Send("STATS", Stats.Encode(mine), "WHISPER", from, msgId)
end

-- Une reponse arrive : on l'imprime tout de suite et on la memorise. Une reponse hors
-- passe courante est imprimee (late) plutot que jetee.
function Stats.OnReply(from, body, msgId)
    local name = qualified(from)
    if not name then return end
    local s = Stats.Decode(body)
    if not s then
        HR:Debug("[sync] STATS from", from, "-- malformed body")
        return
    end

    local late = not (pass and pass.msgId == msgId)
    if not late then
        if pass.seen[name] then return end
        pass.seen[name] = true
    end

    HR.Sync.stats[name] = s
    HR:Print(describe(name, s, late))
end

-- Fermeture de la passe : liste ceux dont on n'a rien. PAS de repli par inspect, PAS de
-- valeurs par defaut -- un chiffre invente aurait l'air aussi credible qu'une mesure.
function Stats.Close(msgId)
    if not pass or pass.msgId ~= msgId then return end
    pass = nil

    HR.RebuildGroup()
    local total, got = 0, 0
    for _, m in ipairs(HR.group) do
        local qn = m.unit and qualified(UnitFullName(m.unit))
        if qn then
            total = total + 1
            if HR.Sync.stats[qn] then
                got = got + 1
            else
                HR:Print(("  %-24s %sno data%s"):format(qn, HR.COLORS.RED, HR.COLORS.RESET))
            end
        end
    end
    HR:Print(("Stats collected: %d/%d."):format(got, total))
end
