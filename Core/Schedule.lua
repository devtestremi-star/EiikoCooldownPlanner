-- HealPlanner - Core/Schedule.lua
-- Moteur de planning HEADLESS (sans UI) : source de verite du timing des defensifs planifies.
-- L'Upcoming bar, l'Announcement et le son/TTS l'INTERROGENT (au lieu de dependre des events
-- emis par la TimelineBox visible). Lit l'etat runtime courant (HR.Runtime.state) :
--   * TEST : occurrences theoriques s.timeline (chaque occ porte o.defs = entrees d'assignment).
--   * LIVE : defensifs lies aux events serveur reconnus (s.liveDefs, timing live + marqueur).
-- Chaque entree renvoyee : { token, occKey, baseTime (absolu, GetTime), offset (ms), mine, bossName }.
--   baseTime = temps du defensif SANS offset (HR.OccDefTime). L'offset (decalage par
--   assignment) est applique par les CONSOMMATEURS (eff = baseTime + offset/1000). La timeline
--   visible ignore l'offset (positionne par baseTime) -> elle reste "intacte".
local addonName, HR = ...

HR.Schedule = HR.Schedule or {}
local S = HR.Schedule

local LINGER = 2   -- (s) on garde un defensif un court instant apres son temps effectif

-- "Mien" : ce token de defensif PLANIFIE m'est-il attribue ? ROLE-conscient (indispensable
-- pour les defensifs PARTAGES par plusieurs roles au MEME spellID) :
--   * SMALL_DEF          -> appel perso generique, mien SAUF si je suis TANK (regle : un tank ne
--                           recoit JAMAIS de directive de CD perso, uniquement les externals).
--   * suffixe "@heal"    -> copie portee par le HEAL (ex. trinket Vessel) : mienne si je SUIS heal.
--   * trinket (token nu) -> copie portee par un DPS : mienne si je NE suis PAS heal.
--   * sinon              -> classe + role + spe via HR.PlayerCanUseDefensive (gere Zephyr
--                           "374227:heal" role=HEALER vs "374227" external role=DAMAGER, et
--                           tous les CD de classe ; un CD sans role reste class-only comme avant).
local function isMine(token)
    token = tostring(token or "")
    if token == "SMALL_DEF" then return HR.GetPlayerRole() ~= "TANK" end
    if token == "RAMP" then return HR.GetPlayerRole() == "HEALER" end
    if token:find("@heal", 1, true) then return HR.GetPlayerRole() == "HEALER" end
    local d = HR.defensives[HR.DefKeyOf(token)]
    if not d then return false end
    if d.trinket then return HR.GetPlayerRole() ~= "HEALER" end
    return HR.PlayerCanUseDefensive(d) == true
end
HR.Schedule.IsMine = isMine
HR.TokenIsMine = isMine   -- alias public (Upcoming bar / glow, handler liveDefs)

-- Liste des defensifs planifies VIVANTS (futur + court linger), avec leur timing.
function S.Active(now)
    now = now or GetTime()
    local s = HR.Runtime and HR.Runtime.state
    local out = {}
    if not s then return out end
    if s.mode == "test" then
        for _, occ in ipairs(s.timeline or {}) do
            local baseTime = (s.pullTime or now) + HR.OccDefTime(occ)
            for _, e in ipairs(occ.defs or {}) do
                local token  = HR.EntryToken(e)
                local offset = HR.EntryOffset(e)
                if baseTime + offset / 1000 + LINGER >= now then
                    out[#out + 1] = { token = token, occKey = occ.key, baseTime = baseTime,
                                      offset = offset, mine = isMine(token), bossName = occ.name }
                end
            end
        end
    else
        for _, ld in ipairs(s.liveDefs or {}) do
            local offset = ld.offset or 0
            if ld.defTime + offset / 1000 + LINGER >= now then
                out[#out + 1] = { token = ld.defID, occKey = ld.occKey, baseTime = ld.defTime,
                                  offset = offset, mine = ld.mine, bossName = ld.bossName }
            end
        end
    end
    return out
end

-- Plan COMPLET du combat (vue d'ensemble), pour la "personal timeline" de l'Upcoming bar.
-- Source UNIQUE : aucun consommateur ne recalcule un temps de defensif lui-meme. Chaque entree
-- porte son temps EFFECTIF `eff` (absolu, GetTime) = baseTime + offset, IDENTIQUE a S.Active
-- pour un meme defensif -> what's next et personal timeline ne peuvent PAS diverger.
--   * LIVE : un defensif deja lie a un event boss matche utilise son temps REEL (s.liveDefs) ;
--            sinon son temps THEORIQUE (occurrence du plan). `matched` distingue les deux.
--   * TEST : tout est theorique (matched = true : le theorique EST la verite en test).
function S.PlanAll(now)
    now = now or GetTime()
    local s = HR.Runtime and HR.Runtime.state
    local out = {}
    if not s then return out end
    -- Index des defensifs DEJA matches (temps reel), par occKey|token.
    local liveByKey = {}
    if s.mode ~= "test" and s.liveDefs then
        for _, ld in ipairs(s.liveDefs) do
            liveByKey[tostring(ld.occKey) .. "|" .. tostring(ld.defID)] = ld
        end
    end
    local occs, getDefs
    if s.mode == "test" then
        occs, getDefs = s.timeline or {}, function(o) return o.defs or {} end
    else
        occs, getDefs = s.planned or {}, function(o) return HR.GetAssignments(s.variant, s.encounterID, o.key) end
    end
    for _, occ in ipairs(occs) do
        local theoBase = (s.pullTime or now) + HR.OccDefTime(occ)
        for _, e in ipairs(getDefs(occ)) do
            local token  = HR.EntryToken(e)
            local offset = HR.EntryOffset(e)
            local ld     = liveByKey[tostring(occ.key) .. "|" .. token]
            local baseTime = ld and ld.defTime or theoBase
            out[#out + 1] = {
                token = token, occKey = occ.key, baseTime = baseTime, offset = offset,
                eff = baseTime + offset / 1000, mine = isMine(token),
                bossName = occ.name, matched = (ld ~= nil) or (s.mode == "test"),
            }
        end
    end
    return out
end

-- Purge des liveDefs perimes + EDGE (one-shot) : diffuse l'event { type="threshold", defID }
-- sur le bus quand un defensif passe sous le seuil PARTAGE (max upcoming/announce). NB : le
-- son/TTS d'alerte ne consomme PLUS cet event -> il a son propre moteur autonome avec son
-- propre seuil (HR.Alerts, cf. Core/TTS.lua). Cet event ne sert donc qu'au debug. Reset au pull.
local fired, firedPull = {}, nil
function S.Tick(now)
    now = now or GetTime()
    local s = HR.Runtime and HR.Runtime.state
    if not s then return end
    if firedPull ~= s.pullTime then fired = {}; firedPull = s.pullTime end
    -- Purge des defensifs LIVE perimes (le TimelineBox ne le fait plus : il lit le moteur).
    -- Une seule fois par frame (Tick = appele par le seul OnUpdate de la box reelle).
    if s.liveDefs then
        local kept = {}
        for _, ld in ipairs(s.liveDefs) do
            if ld.defTime + (ld.offset or 0) / 1000 + LINGER >= now then kept[#kept + 1] = ld end
        end
        s.liveDefs = kept
    end
    local o   = (HR.db and HR.db.options) or {}
    local thr = math.max(o.upcomingThreshold or 5, o.announceThreshold or 5)
    for _, e in ipairs(S.Active(now)) do
        local eff = e.baseTime + e.offset / 1000
        local rem = eff - now
        if rem <= thr and rem > -0.5 then
            local key = tostring(e.token) .. "@" .. tostring(e.occKey)
            if not fired[key] then
                fired[key] = true
                if HR.Runtime.FireTimelineEvent then
                    HR.Runtime.FireTimelineEvent({
                        type = "threshold", threshold = thr, isBoss = false,
                        defID = e.token, occKey = e.occKey, mine = e.mine,
                        bossName = e.bossName, endTime = eff, offset = e.offset,
                    })
                end
            end
        end
    end
end
