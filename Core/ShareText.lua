-- EiikoCooldownPlanner - Core/ShareText.lua
-- Import des plans produits par un outil EXTERNE (web), au format texte `ecp;2`.
-- Specification complete : PLAN_FORMAT.md (a la racine de l'addon).
--
-- Principe : le format ne transporte que de la DONNEE DE JEU BRUTE (spellID,
-- encounterID, zoneID, specID, identifiants OPAQUES de joueur, talents). Aucune cle
-- interne ECP n'y figure. C'est CET ADDON qui resout :
--   spellID + talents du lanceur  -> defKey ("740" -> "740:0" ou "740:1")
--   roster                        -> externals du groupe + instances #N
--   (spellID de boss, n)          -> occKey
--
-- Trois couches SEPAREES, volontairement :
--   Parse()   : texte -> transcription litterale. Ne connait rien a ECP.
--   Resolve() : transcription -> forme interne (talentSpells/externals/assignments).
--   Apply*()  : ecriture, uniquement si la resolution ET la validation passent.
-- Cette separation rend chaque couche testable seule et cantonne les regles metier
-- a Resolve().
local addonName, HR = ...

HR.ShareText = HR.ShareText or {}
local ST = HR.ShareText

local FORMAT   = 2                -- version de format supportee
local WIRE_B64 = "ecp64:"         -- enveloppe de transport (base64 du document)
local WIRE_TXT = "ecp;"           -- document texte nu

--------------------------------------------------------------------------------
-- Base64 (alphabet STANDARD +/ avec padding), en Lua PUR.
-- Volontairement pas C_EncodingUtil.DecodeBase64 : il faudrait valider en jeu quelle
-- valeur d'Enum.Base64Variant correspond a ce que produit btoa() cote web. 25 lignes
-- ici suppriment cette inconnue.
--------------------------------------------------------------------------------

local B64C = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64R = {}
for i = 1, 64 do B64R[B64C:sub(i, i)] = i - 1 end

local function b64decode(s)
    s = s:gsub("%s", "")
    if s:find("[^A-Za-z0-9%+/=]") then return nil end
    s = s:gsub("=+$", "")
    local out, acc, bits = {}, 0, 0
    for i = 1, #s do
        local v = B64R[s:sub(i, i)]
        if not v then return nil end
        acc, bits = acc * 64 + v, bits + 6
        if bits >= 8 then
            bits = bits - 8
            local p = 2 ^ bits
            out[#out + 1] = string.char(math.floor(acc / p))
            acc = acc % p
        end
    end
    return table.concat(out)
end

local function b64encode(s)
    local out, acc, bits = {}, 0, 0
    for i = 1, #s do
        acc, bits = acc * 256 + s:byte(i), bits + 8
        while bits >= 6 do
            bits = bits - 6
            local p = 2 ^ bits
            local v = math.floor(acc / p)
            acc = acc % p
            out[#out + 1] = B64C:sub(v + 1, v + 1)
        end
    end
    if bits > 0 then
        local v = acc * (2 ^ (6 - bits))
        out[#out + 1] = B64C:sub(v + 1, v + 1)
    end
    local body = table.concat(out)
    return body .. ("="):rep((4 - #body % 4) % 4)
end

ST.B64Decode, ST.B64Encode = b64decode, b64encode

--------------------------------------------------------------------------------
-- Percent-encodage. Jeu SUR : A-Za-z0-9 _ . : # @ -
-- Le decodage est STRICT : un % non suivi de 2 hexa invalide toute la chaine.
--------------------------------------------------------------------------------

local function penc(v)
    return (tostring(v):gsub("[^A-Za-z0-9_%.:#@%-]", function(c)
        return ("%%%02X"):format(c:byte())
    end))
end

local function pdec(s)
    if type(s) ~= "string" then return nil end
    local i = 1
    while true do
        local p = s:find("%%", i)
        if not p then break end
        if not s:sub(p + 1, p + 2):match("^%x%x$") then return nil end
        i = p + 3
    end
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

ST.Encode, ST.Decode = penc, pdec

--------------------------------------------------------------------------------
-- Utilitaires de decoupage
--------------------------------------------------------------------------------

-- Decoupe sur un separateur LITTERAL (plain find) : conserve les champs vides.
local function split(s, sep)
    local out, i = {}, 1
    while true do
        local p = s:find(sep, i, true)
        if not p then out[#out + 1] = s:sub(i); return out end
        out[#out + 1] = s:sub(i, p - 1)
        i = p + #sep
    end
end

-- Liste separee par des virgules -> tableau (les elements vides tombent).
local function splitList(s)
    local out = {}
    for _, v in ipairs(split(s or "", ",")) do
        if v ~= "" then out[#out + 1] = v end
    end
    return out
end

--------------------------------------------------------------------------------
-- COUCHE 1 : Parse — texte -> transcription litterale
--------------------------------------------------------------------------------

-- Cette chaine ressemble-t-elle a un document ecp;2 ? (aiguillage a l'import)
function ST.Looks(str)
    if type(str) ~= "string" then return false end
    str = strtrim(str)
    return str:sub(1, #WIRE_B64) == WIRE_B64 or str:sub(1, #WIRE_TXT) == WIRE_TXT
end

-- ⚠️ INVARIANT : on ne percent-decode QUE les feuilles, APRES tous les decoupages.
-- Tant qu'aucun decodage n'a eu lieu, aucune donnee ne peut contenir un separateur
-- (garanti par le jeu sur). Decoder plus tot reintroduit ';' et ',' dans les donnees
-- et casse le parsing de facon intermittente (seuls les noms exotiques echouent).
--
-- Renvoie (parsed, nil) ou (nil, message d'erreur).
function ST.Parse(str)
    if type(str) ~= "string" then return nil, "Empty import string." end
    str = strtrim(str)

    -- Enveloppe de transport
    if str:sub(1, #WIRE_B64) == WIRE_B64 then
        local raw = b64decode(str:sub(#WIRE_B64 + 1))
        if not raw then return nil, "Corrupted transport data (invalid base64)." end
        str = strtrim(raw)
    end

    local lines = {}
    for _, raw in ipairs(split(str, "\n")) do
        local l = strtrim((raw:gsub("\r", "")))
        if l ~= "" then lines[#lines + 1] = l end
    end
    if #lines == 0 then return nil, "Empty import string." end

    local head = split(lines[1], ";")
    if head[1] ~= "ecp" then return nil, "This is not an ECP plan." end
    local format = tonumber(head[2])
    if not format then return nil, "Malformed header." end
    if format > FORMAT then
        return nil, "This plan was exported by a newer version of the addon."
    end
    local kind = head[3]
    if kind ~= "variant" and kind ~= "boss" then
        return nil, ("Unknown plan type: %s"):format(tostring(kind))
    end

    local p = { format = format, kind = kind, roster = {}, uses = {} }
    local expected

    -- Conversion numerique avec message contextualise.
    local badNum
    local function num(v, what, line)
        local n = tonumber(v)
        if not n then
            badNum = ("Line %d: invalid number for %s (%s)."):format(line, what, tostring(v))
            return nil
        end
        return n
    end
    local function dec(v, what, line)
        local s = pdec(v or "")
        if s == nil then
            badNum = ("Line %d: malformed escape in %s."):format(line, what)
            return nil
        end
        return s
    end

    for i = 2, #lines do
        local f = split(lines[i], ";")
        local t = f[1]
        if t == "z" then
            p.zoneID = num(f[2], "z (zoneID)", i)
        elseif t == "b" then
            p.encID = num(f[2], "b (encounterID)", i)
        elseif t == "n" then
            p.title = dec(f[2], "n (title)", i)
        elseif t == "h" then
            p.healer = dec(f[2], "h (healer)", i)
        elseif t == "k" then
            expected = num(f[2], "k (count)", i)
        elseif t == "r" then
            -- r;<id>;<role>;<class>;<specID>;<spec>;<talents>
            -- `id` est OPAQUE : un jeton d'identite stable, sans signification. Il ne
            -- sert que de cle de jointure entre r;, h; et u;. Aucun nom de joueur.
            local id    = dec(f[2], "r (player id)", i)
            local role  = dec(f[3], "r (role)", i)
            local class = dec(f[4], "r (class)", i)
            local specID
            if f[5] and f[5] ~= "" then specID = num(f[5], "r (specID)", i) end
            local spec  = dec(f[6], "r (spec)", i)
            local talents = {}
            for _, tk in ipairs(splitList(f[7])) do
                local n = num(tk, "r (talent)", i)
                if not n then break end
                talents[#talents + 1] = n
            end
            if id and id ~= "" then
                p.roster[#p.roster + 1] = { id = id, role = (role or ""):upper(),
                                            class = (class or ""):upper(), specID = specID,
                                            spec = spec or "", talents = talents, line = i }
            end
        elseif t == "u" then
            local u = {
                encID     = num(f[2], "u (encounterID)", i),
                bossSpell = num(f[3], "u (boss spell)", i),
                n         = num(f[4], "u (occurrence)", i),
                id        = dec(f[5], "u (player id)", i),
                defSpell  = num(f[6], "u (defensive spell)", i),
                line      = i,
            }
            if f[7] and f[7] ~= "" then u.offset = num(f[7], "u (offset)", i) end
            if u.encID and u.bossSpell and u.n and u.id and u.defSpell then
                p.uses[#p.uses + 1] = u
            end
        end
        -- Type inconnu => ignore (compatibilite ascendante, cf. PLAN_FORMAT.md §13).
        if badNum then return nil, badNum end
    end

    -- Controles de forme
    if not p.healer or p.healer == "" then return nil, "Missing h; (healer) record." end
    if kind == "variant" and not p.zoneID then return nil, "Missing z; (dungeon) record." end
    if kind == "boss" then
        if not p.encID then return nil, "Missing b; (boss) record." end
        for _, u in ipairs(p.uses) do
            if u.encID ~= p.encID then
                return nil, ("Line %d: assignment targets another boss than b;."):format(u.line)
            end
        end
    end

    local byId = {}
    for _, r in ipairs(p.roster) do byId[r.id] = r end
    if not byId[p.healer] then
        return nil, ("h; refers to a player id absent from the roster: %s"):format(p.healer)
    end
    for _, u in ipairs(p.uses) do
        if not byId[u.id] then
            return nil, ("Line %d: unknown player id %s (absent from roster)."):format(u.line, u.id)
        end
    end

    if expected and expected ~= #p.uses then
        return nil, ("Truncated plan: %d assignments read, %d expected."):format(#p.uses, expected)
    end

    p.rosterById = byId
    return p, nil
end

--------------------------------------------------------------------------------
-- COUCHE 2 : Resolve — transcription -> forme interne ECP
--------------------------------------------------------------------------------

-- Index spellID -> { defKey, ... } sur tout HR.defensives. Reconstruit a chaque appel
-- (quelques dizaines d'entrees : le cout est nul et on suit une eventuelle edition).
local function BuildDefIndex()
    local idx = {}
    for key, d in pairs(HR.defensives) do
        local sid = d.spellID or (type(key) == "number" and key or nil)
        if sid then
            idx[sid] = idx[sid] or {}
            table.insert(idx[sid], key)
        end
    end
    for _, list in pairs(idx) do
        table.sort(list, function(a, b) return tostring(a) < tostring(b) end)
    end
    return idx
end

-- Candidats plausibles pour ce lanceur. Filtre :
--   * cote HEAL vs cote EXTERNAL -> leve l'ambiguite de Zephyr (374227), qui existe
--     en deux entrees (role DAMAGER = external, role HEALER = CD de soin) ;
--   * `spec` -> Vampiric Embrace n'est fourni que par un pretre Ombre ;
--   * `class` -> un sort de classe n'est fourni que par cette classe. Indispensable
--     ici et pas seulement au point d'assignation : la derivation des externals (3)
--     ne passe PAS par le controle de classe des lignes u;, et Vampiric Embrace n'a
--     aucun talentReq -> sans ce filtre, un roster annoncant la spe "Shadow" sur une
--     autre classe le ferait declarer comme external du groupe ;
--   * trinkets exclus : ils dependent de l'equipement, que le format ne transporte pas.
local function CandidatesFor(idx, sid, isHealer, spec, class)
    local out = {}
    for _, key in ipairs(idx[sid] or {}) do
        local d = HR.defensives[key]
        if d and not d.trinket then
            local healSide = (d.role == "HEALER")
            if healSide == isHealer
               and (not d.spec  or d.spec  == spec)
               and (not d.class or d.class == class) then
                out[#out + 1] = key
            end
        end
    end
    return out
end

local function TalentSet(r)
    local set = {}
    for _, sid in ipairs(r.talents or {}) do set[sid] = true end
    return set
end

-- Profil de heal d'une identite de roster.
-- ⚠️ On ne peut PAS se contenter de HR.HealProfileKey : elle ignore la spe hors pretre
-- (Data/Roster.lua) et renverrait donc "PALADIN" pour un Vindicte, "DRUID" pour un
-- Farouche... qui passeraient alors pour des soigneurs. Le `specID` fait foi ; a defaut
-- on identifie la spe via SPEC_BY_ID. Une spe totalement inconnue (nouveau patch) garde
-- le comportement historique, tolerant.
local function HealProfileFor(r)
    local function profileBySpecID(sid)
        for _, prof in ipairs(HR.HEAL_PROFILES or {}) do
            if prof.specID == sid then return prof.key end
        end
        return nil
    end
    if r.specID then
        local key = profileBySpecID(r.specID)
        if key then return key end
        -- specID connu du jeu mais absent des profils de soin => ce n'est pas un soigneur
        if HR.SPEC_BY_ID and HR.SPEC_BY_ID[r.specID] then return nil end
    end
    for sid, e in pairs(HR.SPEC_BY_ID or {}) do
        if e.class == r._class and e.spec == r._spec then return profileBySpecID(sid) end
    end
    return HR.HealProfileKey(r._class, r._spec)
end

-- Occurrences d'un boss, indexees par "spellID:n" -> occKey reel (prefixe de variante
-- de timeline inclus). Meme appel que l'editeur de plan (UI/PlanTimeline.lua).
-- `tlFor(boss)` : resolveur OPTIONNEL de variante de timeline. Il DOIT rendre la meme
-- variante que celle affichee par l'editeur (UI.GetViewedTlVariant), sinon les occKey
-- produits ici sont prefixes d'une AUTRE variante que ceux du plan visible : l'import
-- ecraserait le plan sous les yeux du joueur pour en ecrire un qu'il ne voit pas.
local function OccIndex(boss, tlFor)
    local map = {}
    local resolved = HR.ResolveBossTimeline(boss, tlFor and tlFor(boss) or nil)
    for _, o in ipairs(HR.GenerateOccurrences(resolved, HR.FIGHT_LENGTH) or {}) do
        map[tostring(o.spellID) .. ":" .. tostring(o.occIndex)] = o.key
    end
    return map
end

-- Nom lisible d'un sort de defensif (pour les messages).
local function DefName(key)
    local d = HR.defensives[key]
    return (d and d.name) or tostring(key)
end

-- Libelle d'un joueur pour les messages. L'id est OPAQUE (aucun nom de personnage) :
-- on l'accompagne de sa classe/spe pour que l'erreur reste lisible.
local function Who(r)
    if not r then return "?" end
    local sp = (r._spec ~= "" and r._spec) or nil
    local cl = (r._class ~= "" and r._class) or nil
    if cl and sp then return ("%s (%s %s)"):format(r.id, sp, cl) end
    return tostring(r.id)
end

-- Identite EFFECTIVE d'une ligne de roster. `specID` est la SOURCE DE VERITE : ni le
-- role ni le nom de spe ne suffisent a lever l'ambiguite ("Holy" = Paladin OU Pretre,
-- "Restoration" = Druide OU Chaman). Classe et nom de spe transmis servent de
-- redondance : divergence = donnee incoherente, on le signale plutot que de choisir.
-- specID inconnu de la table => on retombe sur ce qui a ete transmis.
local function NormalizeIdentity(r, fail)
    local si = r.specID and HR.SPEC_BY_ID and HR.SPEC_BY_ID[r.specID]
    if si then
        if r.class ~= "" and r.class ~= si.class then
            fail("Line %d: player %s declares class %s but specID %d is %s.",
                 r.line, r.id, r.class, r.specID, si.class)
        end
        r._class, r._spec = si.class, si.spec
    else
        r._class, r._spec = r.class, r.spec
        if r.specID then
            -- Non bloquant : une spe inconnue de la table reste exploitable via
            -- classe + nom de spe. On ne veut pas casser sur une nouvelle spe.
            r._unknownSpec = true
        end
    end
end

-- parsed -> resolved, errors
--   resolved = { dID, dungeon, healerKey, healerId, talentSpells, externals,
--                assignments, tokensByUse, bosses = { [encID] = boss } }
--   errors   = liste de chaines (vide si tout passe)
function ST.Resolve(p, opts)
    opts = opts or {}
    local errors = {}
    local function fail(fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end

    local idx = BuildDefIndex()

    -- (0) Identite effective de chaque joueur (specID prioritaire) -----------
    for _, r in ipairs(p.roster) do NormalizeIdentity(r, fail) end
    if #errors > 0 then return nil, errors end

    -- (1) Donjon cible ------------------------------------------------------
    local dungeon, boss0
    if p.kind == "boss" then
        boss0, dungeon = HR.GetBossByEncounterID(p.encID)
        if not boss0 then
            fail("Unknown boss for this client version (encounterID %d).", p.encID)
            return nil, errors
        end
        if not HR.BossEnabled(boss0) then
            fail("Boss \"%s\" is disabled in this addon: it cannot hold a plan.", boss0.name or "?")
            return nil, errors
        end
    else
        for _, d in ipairs(HR.content) do
            if d.zoneID == p.zoneID then dungeon = d; break end
        end
        if not dungeon then
            fail("Unknown dungeon for this client version (zoneID %d).", p.zoneID)
            return nil, errors
        end
    end

    -- (2) Profil de heal ----------------------------------------------------
    local hr = p.rosterById[p.healer]
    -- `role` sert de controle de coherence : h; doit designer un soigneur.
    if hr.role ~= "" and hr.role ~= "HEALER" then
        fail("h; designates %s, whose role is %s, not HEALER.", Who(hr), hr.role)
        return nil, errors
    end
    local healerKey = HealProfileFor(hr)
    if not healerKey or not HR.GetHealProfile(healerKey) then
        fail("%s is not a healing specialization.", Who(hr))
        return nil, errors
    end

    -- (3) Externals fournis par le groupe, derives du ROSTER ------------------
    -- Un joueur qui a le talent le fournit, qu'il soit assigne ou non.
    local externals, carrierIdx = {}, {}
    local extSpellIDs = {}
    for _, e in ipairs(HR.GetExternals()) do
        local sid = HR.GetDefensiveSpellID(e.key)
        if sid then extSpellIDs[sid] = true end
    end
    for _, r in ipairs(p.roster) do
        if r.id ~= p.healer then
            local tset = TalentSet(r)
            for sid in pairs(extSpellIDs) do
                local key = HR.MatchTalentVariant(CandidatesFor(idx, sid, false, r._spec, r._class), tset)
                if key then
                    externals[key] = (externals[key] or 0) + 1
                    carrierIdx[key] = carrierIdx[key] or {}
                    carrierIdx[key][r.id] = externals[key]       -- ordre du bloc r;
                end
            end
        end
    end

    -- (4) talentSpells du heal ----------------------------------------------
    -- ⚠️ Les TRINKETS sont exclus : GetHealerTalentSpells les inclut volontairement
    -- (toolkit heal), mais ils n'ont ni talentReq ni talentNot -> MatchTalentVariant
    -- les accorderait a n'importe qui, meme avec zero talent. Ils dependent de
    -- l'equipement, que le format ne transporte pas (cf. PLAN_FORMAT.md §12) : les
    -- accorder ici ferait apparaitre un token "@heal" fantome dans le picker et
    -- gonflerait VariantExternalCount pour un trinket que le heal n'a jamais porte.
    local htset = TalentSet(hr)
    local talentSpells = {}
    for _, sp in ipairs(HR.GetHealerTalentSpells(healerKey)) do
        if not sp.trinket then
            local key = HR.MatchTalentVariant(sp.variants, htset)
            if key then talentSpells[sp.spellID] = key end
        end
    end

    -- (5) Utilisations -> assignments ---------------------------------------
    local assignments, occCache, bosses = {}, {}, {}
    local tokensByUse = {}

    for _, u in ipairs(p.uses) do
        local caster   = p.rosterById[u.id]
        local isHealer = (u.id == p.healer)

        -- Boss + occurrence
        local boss = bosses[u.encID]
        if boss == nil then
            local b, dg = HR.GetBossByEncounterID(u.encID)
            if not b then
                fail("Line %d: unknown boss (encounterID %d).", u.line, u.encID)
            elseif dg ~= dungeon then
                fail("Line %d: boss \"%s\" does not belong to %s.", u.line, b.name or "?", dungeon.name)
                b = nil
            elseif not HR.BossEnabled(b) then
                fail("Line %d: boss \"%s\" is disabled.", u.line, b.name or "?")
                b = nil
            end
            -- Sentinelle `false` : un lookup RATE doit rester en cache, sinon la meme
            -- erreur est reportee une fois par ligne u; et noie le reste du rapport.
            boss = b or false
            bosses[u.encID] = boss
        end
        if boss == false then boss = nil end

        local occKey
        if boss then
            occCache[u.encID] = occCache[u.encID] or OccIndex(boss, opts.tlVariantFor)
            occKey = occCache[u.encID][tostring(u.bossSpell) .. ":" .. tostring(u.n)]
            if not occKey then
                fail("Line %d: occurrence #%d of spell %d does not exist on \"%s\".",
                     u.line, u.n, u.bossSpell, boss.name or "?")
            end
        end

        -- Defensif : spellID brut -> defKey, via les talents du LANCEUR
        local token
        local all = idx[u.defSpell]
        if not all or #all == 0 then
            fail("Line %d: spell %d is not a defensive known to the addon.", u.line, u.defSpell)
        else
            local d0 = HR.defensives[all[1]]
            if d0.class and d0.class ~= caster._class then
                fail("Line %d: %s cannot cast %s (%s only).",
                     u.line, Who(caster), DefName(all[1]), d0.class)
            else
                local cands = CandidatesFor(idx, u.defSpell, isHealer, caster._spec, caster._class)
                if #cands == 0 then
                    fail("Line %d: %s cannot provide %s with that specialization.",
                         u.line, Who(caster), DefName(all[1]))
                else
                    local key = HR.MatchTalentVariant(cands, TalentSet(caster))
                    if not key then
                        fail("Line %d: no cooldown variant of %s matches the talents of %s "
                             .. "(incomplete talent list?).", u.line, DefName(all[1]), Who(caster))
                    elseif isHealer then
                        token = tostring(key)
                    else
                        local n = (externals[key] or 0)
                        local i = carrierIdx[key] and carrierIdx[key][caster.id]
                        if not i then
                            fail("Line %d: %s does not provide %s according to the roster.",
                                 u.line, Who(caster), DefName(key))
                        else
                            token = (n > 1) and (tostring(key) .. "#" .. i) or tostring(key)
                        end
                    end
                end
            end
        end

        if token and occKey then
            local enc = assignments[u.encID]
            if not enc then enc = {}; assignments[u.encID] = enc end
            local list = enc[occKey]
            if not list then list = {}; enc[occKey] = list end
            local dup = false
            for _, e in ipairs(list) do if e.token == token then dup = true; break end end
            if not dup then
                local off = math.floor((u.offset or 0) + 0.5)
                local maxMs = (HR.OFFSET_MAX_S or 12) * 1000
                off = math.max(-maxMs, math.min(maxMs, off))
                list[#list + 1] = (off ~= 0) and { token = token, offset = off } or { token = token }
            end
            tokensByUse[#tokensByUse + 1] = { token = token, line = u.line }
        end
    end

    if #errors > 0 then return nil, errors end

    return {
        dID          = dungeon.id,
        dungeon      = dungeon,
        boss         = boss0,
        healerKey    = healerKey,
        healerId     = p.healer,
        talentSpells = talentSpells,
        externals    = externals,
        assignments  = assignments,
        tokensByUse  = tokensByUse,
    }, errors
end

--------------------------------------------------------------------------------
-- COUCHE 3 : validation de compatibilite + ecriture
--------------------------------------------------------------------------------

-- Les tokens resolus sont-ils TOUS placables dans la variante cible ?
-- C'est le controle du CAS 1 : un plan de boss venu d'ailleurs doit etre jouable
-- tel quel dans la variante que le joueur a sous les yeux.
function ST.ValidateAgainstVariant(resolved, variant)
    local errors = {}
    if not variant then
        errors[#errors + 1] = "No variant to overwrite in this dungeon: create one first."
        return errors
    end
    local ok = {}
    for _, e in ipairs(HR.GetPlaceableDefsFor(variant)) do ok[e.token] = true end

    local seen = {}
    for _, t in ipairs(resolved.tokensByUse or {}) do
        if not ok[t.token] and not seen[t.token] then
            seen[t.token] = true
            local key  = HR.DefKeyOf(t.token)
            local name = DefName(key)
            local why
            if not HR.defensives[key] then
                why = "unknown to the addon"
            elseif t.token:find("#") then
                why = "the variant does not declare that many copies of it"
            elseif HR.defensives[key].role == "HEALER" then
                why = "the variant's healer does not play that cooldown variant"
            else
                why = "the variant does not declare it as an available external"
            end
            errors[#errors + 1] = ("%s (%s): %s."):format(name, t.token, why)
        end
    end
    return errors
end

-- CAS 1 : ecrase le plan d'UN boss dans la variante donnee.
-- ClearVariantBossPlan retire la cle EN PLACE -> preserve le lien DB des variantes
-- par defaut (cf. Database.InitDB). On ne remplace JAMAIS la table `assignments`.
function ST.ApplyBoss(resolved, variant, encID)
    if not variant or encID == nil then return false end
    -- ClearVariantBossPlan tolere une variante sans table `assignments` (rows DB
    -- heritees) et sort en silence : il faut donc la creer ici avant d'ecrire.
    variant.assignments = variant.assignments or {}
    HR.ClearVariantBossPlan(variant, encID)
    local incoming = resolved.assignments[encID]
    if incoming and next(incoming) then
        variant.assignments[encID] = incoming
    end
    return true
end

-- CAS 2 : cree une NOUVELLE variante entierement dictee par l'import.
-- Le nom vient de l'utilisateur, pas du payload.
function ST.ApplyVariant(resolved, name)
    return HR.V2_ImportVariant(resolved.dID, name, resolved.healerKey,
                               resolved.externals, resolved.talentSpells,
                               resolved.assignments, nil)
end

-- Compte les assignations d'un tableau assignments (pour les recapitulatifs).
function ST.CountAssignments(asg, encID)
    local n = 0
    for enc, occs in pairs(asg or {}) do
        if encID == nil or enc == encID then
            for _, list in pairs(occs) do n = n + #list end
        end
    end
    return n
end
