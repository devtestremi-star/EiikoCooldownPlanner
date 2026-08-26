-- HealPlanner - Data/Content.lua
-- Contenu : 8 donjons du pool Mythique+ Midnight Saison 1.
--   4 nouveaux : Windrunner Spire, Maisara Caverns, Nexus-Point Xenas, Magister's Terrace
--   4 legacy   : Algeth'ar Academy, Seat of the Triumvirate, Skyreach, Pit of Saron
--
-- Schema :
--   HR.content = liste ordonnee de donjons (8 onglets-icones en haut de la modale)
--   donjon  = { id, name, abbr, icon, iconSpellID, zoneID, bosses = {...}, trash = {...} }
--   boss    = { id (encounterID), name, [enable], abilities = {...} }  OU  { ..., phases = {...} }
--     enable = false => boss DESACTIVE : grise + inaccessible dans la config ; en
--       combat la boite runtime passe en mode BRUT (aucun filtrage, affiche tout ce
--       qui vient, un par un, via l'icone/nom serveur). Absent ou true => boss normal.
--     [timelineVariants] = { { id, name, phases=... (ou abilities=...) }, ... } : un boss
--       qui se joue de PLUSIEURS facons (timelines differentes, ex. L'ura 4-1-1 / 4-2).
--       Le joueur choisit la variante active (selecteur UI) ; les plans des variantes
--       coexistent (cles d'occurrence prefixees). Le bloc `abilities`/`durationGroups` du
--       boss reste commun (matching runtime). Resolu via HR.ResolveBossTimeline avant
--       GenerateOccurrences. Absent => boss a timeline unique (comportement historique).
--     2 representations possibles (GenerateOccurrences dispatche, `phases` prioritaire) :
--     - SIMPLE : `abilities` = liste de { spellID, name, firstAt, period, [aoe] }.
--       1 sort qui se repete (firstAt + k*period). period <= 0 => unique.
--     - RICHE  : `phases` = liste de phases qui se repetent. Une PHASE regroupe
--       plusieurs sorts a offsets fixes (ex. Araknath : 2 Energize + Supernova / 54s) :
--         phase = { [name], firstAt, period, [count], events = {...} }
--           firstAt : debut de la 1re instance (s depuis le pull)
--           period  : la phase se repete tous les `period` s ; nil/<=0 => une fois
--           count   : nb max de repetitions (optionnel)
--           events  = liste de { spellID, name, at (offset s depuis le debut de phase), [aoe] }
--       Le separateur visuel UI numerote les instances de phase (Phase 1/2/3...).
--   trash   = liste { spellID, name } : capacites de TRASH reduites par Zephyr
--             (AoE-flaggees). Section "Trash Info" de la modale, tooltip au survol.
--   ability = { spellID, name, firstAt (s), period (s), [aoe] }  -- period <= 0 => unique
--     aoe : true  = degats AoE-flagges (reduits par Zephyr / la stat Avoidance),
--           false = confirme NON-AoE (Zephyr inutile -> averti dans le picker),
--           nil   = inconnu / pas encore renseigne (aucun avertissement).
--
--   Champs communs a CHAQUE capacite pre-enregistree (abilities ET events de phase) :
--     allowedInPlan   : true => capacite planifiable (visible/assignable dans le plan).
--     allowInTimeline : true => capacite affichee dans la timeline / le runtime.
--     overridenName   : string => nom a afficher a la place de `name` ; nil = `name` brut.
--     customName      : string => nom court affiche (ex. "DOT"/"AOE") ; prioritaire sur
--                       overridenName (route vers overridenName par GenerateOccurrences).
--     cast            : duree du cast (s ; 0/absent = instantane). `at`/`firstAt` = DEBUT
--                       du cast (= temps matchable serveur) ; impact = at + cast.
--     defMarker       : { mode, offset } => QUAND afficher le defensif a utiliser. offset en
--                       MILLISECONDES ; modes : BEFORE_CAST_START / AFTER_CAST_START /
--                       BEFORE_CAST_END / AFTER_CAST_END. Absent => defensif au temps du sort.
--                       Calcule par HR.OccDefTime (Core/Planner.lua).
--
--   MATCHING RUNTIME PAR DUREE :
--     `durations` = { d, ... } : durees (s) sous lesquelles le serveur annonce ce sort
--       sur sa timeline (ENCOUNTER_TIMELINE_EVENT_ADDED.duration arrondie a 0.1). Un
--       sort peut avoir plusieurs durees (pull vs cycle). Sert a identifier un event
--       serveur sans lire son spellID (Secret Value en M+).
--     Les entrees "duration-only" (ayant `durations` mais PAS `firstAt`) sont ignorees
--       par la timeline theorique du plan (GenerateFromAbilities les saute) : elles ne
--       servent qu'au matching runtime. Pour un boss en `phases`, on ajoute ces entrees
--       dans un `abilities` qui coexiste avec `phases` (phases reste prioritaire au plan).
--     `durationGroups` = { [duree] = <regle> } : quand une meme duree designe PLUSIEURS
--       sorts. Le runtime tient un compteur d'occurrences PAR duree (remis a zero au
--       pull) et applique la regle. Deux formes (interpretees par un resolveur generique,
--       jamais de code par boss) :
--       * CYCLE (defaut) : liste ORDONNEE de spellID -> choix = liste[((count-1) % N)+1]
--         (ordre = reste 1 d'abord, ... , reste 0 en dernier ; un spellID peut s'y repeter).
--       * SEUIL : { kind = "threshold", first = spellID, rest = spellID } -> 1ere
--         occurrence = `first`, toutes les suivantes = `rest`. Pour les sorts dont la 1re
--         occurrence (pull) differe du reste de la rotation (ex. Gemellus : 1er = Triplicate).
--     Une duree partagee SANS entree ici reste volontairement ambigue (choix deterministe ;
--       acceptable uniquement entre sorts NON planifies, ex. Nysarra @15s lie au stage).
--
--   TRACKING DE PHASE (boss health-gated multi-phases, ex. Council of Tribes) :
--     Quand une MEME duree = un sort DIFFERENT selon la phase (que le compteur/durationGroups ne
--     peut pas departager car les transitions ne sont pas a temps fixe), on scope par phase :
--     * `phase = N` sur une entree `abilities` : la duree de cette entree ne resout ce sort QUE
--       quand la phase courante = N. Absent => l'entree vaut pour toutes les phases (legacy).
--     * `phaseTransitions = { [duree] = N }` (cle boss) : quand un event de cette duree est detecte
--       en combat, la phase courante avance a N (SENS UNIQUE, seulement si N > phase courante).
--       Une duree-marqueur peut etre AUSSI un vrai sort (le runtime avance la phase PUIS matche).
--     Precedence de resolution : tag `phase` (phase courante) > durationGroups > duree unique.
--     Les deux champs sont OPTIONNELS : un boss sans `phase`/`phaseTransitions` est 100% legacy.
--     Cf. Core/Matcher.lua (byDurPhase, PhaseTransitionFor) + UI/RuntimeBox.lua (s.currentPhase).
--
-- encounterID des boss = ID reel de l'event ENCOUNTER_START (renseigne).
-- zoneID = instanceID de GetInstanceInfo : encore PLACEHOLDER (0) pour certains.
-- ICONES : `icon` = fileID explicite (prioritaire) ; sinon `iconSpellID` = sort de
-- teleportation M+ du donjon, resolu via C_Spell.GetSpellTexture.
local addonName, HR = ...

HR.content = {
    --------------------------------------------------------------------- nouveaux
    {
        id = "WINDRUNNER_SPIRE", name = "Windrunner Spire", abbr = "WRS", icon = 7266215, iconSpellID = 1254840, zoneID = 2805,
        trash = {
            { spellID = 1217010, name = "Ferocious Pounce" },
            { spellID = 1216963, name = "Spore Dispersal" },
            { spellID = 473776,  name = "Fetid Spew" },
        },
        bosses = {
            { id = 3056, name = "Emberdawn", phases = {
                {
                    name = "Setup", firstAt = 6, period = 0,
                    events = {
                        { spellID = 466556, name = "Flaming Updraft", at = 0, cast = 1.5, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, customName = "DOT", allowedInPlan = true, allowInTimeline = true },
                    },
                },
                {
                    name = "Rotation", firstAt = 15, period = 56,
                    events = {
                        { spellID = 465904, name = "Burning Gale",    at = 0,  cast = 3,   defMarker = { mode = "AFTER_CAST_END", offset = 0 }, customName = "AOE", allowedInPlan = true, allowInTimeline = true },
                        { spellID = 466556, name = "Flaming Updraft", at = 30, cast = 1.5, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, customName = "DOT", allowedInPlan = true, allowInTimeline = true },
                        { spellID = 466556, name = "Flaming Updraft", at = 46, cast = 1.5, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, customName = "DOT", allowedInPlan = true, allowInTimeline = true },
                    },
                },
            }, abilities = {
                { spellID = 466556, name = "Flaming Updraft", durations = { 6, 15.5 } },
                { spellID = 466064, name = "Searing Beak",    durations = { 10, 13 } },
                { spellID = 465904, name = "Burning Gale",    durations = { 15, 30 } },
            } },
            { id = 3057, name = "Derelict Duo", phases = {
                {
                    firstAt = 11, period = 58,
                    events = {
                        { spellID = 472745, name = "Splattering Spew", at = 0,  cast = 4, defMarker = { mode = "AFTER_CAST_END", offset = 0 },    customName = "Circle", aoe = true, allowedInPlan = true, allowInTimeline = true },
                        { spellID = 472745, name = "Splattering Spew", at = 27, cast = 4, defMarker = { mode = "AFTER_CAST_END", offset = 0 },    customName = "Circle", aoe = true, allowedInPlan = true, allowInTimeline = true },
                        { spellID = 472795, name = "Heaving Yank",     at = 43, cast = 7, defMarker = { mode = "BEFORE_CAST_START", offset = 0 }, customName = "Hook",   aoe = true, allowedInPlan = true, allowInTimeline = true },
                    },
                },
            }, abilities = {
                { spellID = 472745, name = "Splattering Spew",    durations = { 8, 27.33 } },
                { spellID = 472888, name = "Bone Hack",           durations = { 17.33 } },
                { spellID = 474105, name = "Curse of Darkness",   durations = { 22.67 } },
                { spellID = 472736, name = "Debilitating Shriek", durations = { 48 } },
            } },
            { id = 3058, name = "Commander Kroluk", phases = {
                {
                    firstAt = 60, period = 60, count = 2,
                    events = {
                        { spellID = 468070,  name = "Rallying Bellow", at = 0,  cast = 0, defMarker = { mode = "BEFORE_CAST_START", offset = 0 }, customName = "Rally", aoe = true, allowedInPlan = true, allowInTimeline = true },
                        { spellID = 1270620, name = "Flame Nova",      at = 20, cast = 0, defMarker = { mode = "BEFORE_CAST_START", offset = 0 }, customName = "AOE",   aoe = true, allowedInPlan = true, allowInTimeline = true },
                    },
                },
            }, abilities = {
                { spellID = 467620,  name = "Rampage",            durations = { 3, 30 } },
                { spellID = 470963,  name = "Bladestorm",         durations = { 8, 0 } },
                { spellID = 472081,  name = "Reckless Leap",      durations = { 10, 37 } },
                { spellID = 1253272, name = "Intimidating Shout", durations = { 18, 45 } },
            } },
            { id = 3059, name = "The Restless Heart", phases = {
                {
                    name = "Opener", firstAt = 9, period = 0,
                    events = {
                        { spellID = 472556, name = "Arrow Rain", at = 0, cast = 3, defMarker = { mode = "BEFORE_CAST_START", offset = 0 }, customName = "Arrow", aoe = true, allowedInPlan = true, allowInTimeline = true },
                    },
                },
                {
                    name = "Bullseye Windblast", firstAt = 25, period = 66,
                    events = {
                        { spellID = 468429,  name = "Bullseye Windblast", at = 0,  cast = 7, defMarker = { mode = "BEFORE_CAST_START", offset = 0 }, customName = "Jump",   aoe = true, allowedInPlan = true, allowInTimeline = true },
                        { spellID = 472556,  name = "Arrow Rain",         at = 23, cast = 3, defMarker = { mode = "BEFORE_CAST_START", offset = 0 }, customName = "Arrow",  aoe = true, allowedInPlan = true, allowInTimeline = true },
                        { spellID = 1253986, name = "Gust Shot",          at = 34, cast = 0, defMarker = { mode = "AFTER_CAST_END",   offset = 5000 }, customName = "Circle", aoe = true, allowedInPlan = true, allowInTimeline = true },
                    },
                },
            }, abilities = {
                { spellID = 472556,  name = "Arrow Rain",         durations = { 9, 11 } },
                { spellID = 472662,  name = "Tempest Slash",      durations = { 21 } },
                { spellID = 1253986, name = "Gust Shot",          durations = { 23.5 } },
                { spellID = 468429,  name = "Bullseye Windblast", durations = { 24, 53 } },
                { spellID = 474528,  name = "Bolt Gale",          durations = { 39 } },
            } },
        },
    },
    {
        id = "MAISARA_CAVERNS", name = "Maisara Caverns", abbr = "MC", icon = 7322719, iconSpellID = 1255247, zoneID = 2874,
        trash = {
            { spellID = 1270085, name = "Grim Ward" },
            { spellID = 1259882, name = "Ritual Drums" },
        },
        bosses = {
            { id = 3212, name = "Muro'jin & Nekraxx", enable = false, abilities = {
                { spellID = 1260648, name = "Barrage",          aoe = true, allowedInPlan = true, allowInTimeline = true },
                { spellID = 1246666, name = "Infected Pinions", aoe = true, allowedInPlan = true, allowInTimeline = true, durations = { 12, 45 } },
                { spellID = 1266480, name = "Flanking Spear",   durations = { 5, 45 } },
                { spellID = 1260731, name = "Freezing Trap",    durations = { 20, 45 } },
                { spellID = 1243900, name = "Fetid Quillstorm", durations = { 28, 45 } },
                { spellID = 1260643, name = "Barrage",          durations = { 35, 45 } },
                { spellID = 1249479, name = "Carrion Swoop",    durations = { 41, 45 } },
            }, durationGroups = {
                [45] = { 1266480, 1246666, 1260731, 1243900, 1260643, 1249479 },
            } },
            { id = 3213, name = "Vordaza", phases = {
                {
                    firstAt = 14, period = 95,
                    events = {
                        { spellID = 1251204, name = "Wrest Phantoms",       at = 0,  cast = 4, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, customName = "GHOST", aoe = true, allowedInPlan = true, allowInTimeline = true },
                        { spellID = 1251204, name = "Wrest Phantoms",       at = 32, cast = 4, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, customName = "GHOST", aoe = true, allowedInPlan = true, allowInTimeline = true },
                        { spellID = 1250708, name = "Necrotic Convergence", at = 56, cast = 2, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, customName = "AOE",   aoe = true, allowedInPlan = true, allowInTimeline = true },
                    },
                },
            }, abilities = {
                { spellID = 1251554, name = "Drain Soul",           durations = { 3, 33.5 } },
                { spellID = 1251204, name = "Wrest Phantoms",       durations = { 14.17, 33.5 } },
                { spellID = 1252054, name = "Unmake",              durations = { 25.33, 33.5 } },
                { spellID = 1250708, name = "Necrotic Convergence", durations = { 70 } },
            }, durationGroups = {
                [33.5] = { 1251554, 1251204, 1252054 },
            } },
            { id = 3214, name = "Rak'tul, Vessel of Souls", enable = false, abilities = {
                { spellID = 1251023, name = "Spiritbreaker",     durations = { 4, 26.4 } },
                { spellID = 1252676, name = "Crush Souls",       durations = { 17.2, 26.4 } },
                { spellID = 1253788, name = "Soulrending Roar",  durations = { 70 } },
            }, durationGroups = {
                [26.4] = { 1251023, 1252676, 1251023 },
            } },
        },
    },
    {
        id = "NEXUS_POINT_XENAS", name = "Nexus-Point Xenas", abbr = "NPX", icon = 7553062, iconSpellID = 1255391, zoneID = 2915,
        trash = {
            { spellID = 1269283, name = "Suppression Field" },
            { spellID = 1277557, name = "Burning Radiance" },
        },
        bosses = {
            { id = 3328, name = "Chief Corewright Kasreth", abilities = {
                { spellID = 1257509, name = "Corespark Detonation", firstAt = 38, period = 53, cast = 3, defMarker = { mode = "AFTER_CAST_END", offset = 10000 }, customName = "AOE", allowedInPlan = true, allowInTimeline = true, durations = { 38 } },
                { spellID = 1251579, name = "Leyline Array",        durations = { 1, 11 } },
                { spellID = 1251772, name = "Reflux Charge",        durations = { 5, 12 } },
                { spellID = 1264048, name = "Flux Collapse",        durations = { 10, 13 } },
            } },
            { id = 3332, name = "Corewarden Nysarra", phases = {
                {
                    firstAt = 5, period = 63,
                    events = {
                        { spellID = 1249014, name = "Eclipsing Step",  at = 0,  cast = 0, defMarker = { mode = "AFTER_CAST_END", offset = 7000 },  customName = "DOT", aoe = true, allowedInPlan = true, allowInTimeline = true },
                        { spellID = 1249014, name = "Eclipsing Step",  at = 18, cast = 0, defMarker = { mode = "AFTER_CAST_END", offset = 7000 },  customName = "DOT", aoe = true, allowedInPlan = true, allowInTimeline = true },
                        -- DESYNC : occ.time = firstAt(5)+at(23) = 28 = temps SERVEUR (matchable) ;
                        -- le defensif est ramene au reel (42) par le marqueur (+14000 ms).
                        { spellID = 1247976, name = "Lightscar Flare", at = 23, cast = 0, defMarker = { mode = "AFTER_CAST_END", offset = 14000 }, customName = "AMP", allowedInPlan = true, allowInTimeline = true },
                    },
                },
            }, abilities = {
                { spellID = 1247937, name = "Umbral Lash",         durations = { 3, 16.85 } },
                { spellID = 1249014, name = "Eclipsing Step",      durations = { 5, 18 } },
                { spellID = 1252703, name = "Null Vanguard",       durations = { 15, 61 } },
                { spellID = 1264439, name = "Lightscar Flare",     durations = { 28, 29, 61 } },
                { spellID = 1271684, name = "Devour the Unworthy", durations = { 15 } },
            }, durationGroups = {
                -- 1er Lightscar Flare sort a 28/29 (duree propre). Au cycle 61 : 1er = Null
                -- Vanguard, puis alterne 1 sur 2 avec Lightscar Flare (ordre a reconfirmer en jeu).
                [61] = { 1252703, 1264439 },
                -- 1er 15 = Null Vanguard (ouverture, unique) ; suivants = Devour the Unworthy (P2).
                [15] = { kind = "threshold", first = 1252703, rest = 1271684 },
            } },
            { id = 3333, name = "Lothraxion", phases = {
                {
                    firstAt = 11, period = 62,
                    events = {
                        { spellID = 1253855, name = "Brilliant Dispersion", at = 0,  cast = 4, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, customName = "Circle", aoe = true, allowedInPlan = true, allowInTimeline = true },
                        { spellID = 1253855, name = "Brilliant Dispersion", at = 26, cast = 4, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, customName = "Circle", aoe = true, allowedInPlan = true, allowInTimeline = true },
                    },
                },
            }, abilities = {
                { spellID = 1253950, name = "Searing Rend",         durations = { 2, 26 } },
                { spellID = 1253855, name = "Brilliant Dispersion", durations = { 11, 25 } },
                { spellID = 1255531, name = "Flicker",              durations = { 10, 24 } },
                { spellID = 1257595, name = "Divine Guile",         durations = { 52 } },
            } },
        },
    },
    {
        id = "MAGISTERS_TERRACE", name = "Magister's Terrace", abbr = "MT", icon = 7439625, iconSpellID = 1255433, zoneID = 2811,
        trash = {
            { spellID = 1265977, name = "Consuming Shadows" },
            { spellID = 1254595, name = "Energy Release" },
            { spellID = 1254336, name = "Ignition" },
            { spellID = 473258,  name = "Crowd Dispersal" },
        },
        bosses = {
            { id = 3071, name = "Arcanotron Custos", enable = false, abilities = {
                { spellID = 474496,  name = "Repulsing Slam",     durations = { 5, 22.5 } },
                { spellID = 1214081, name = "Arcane Expulsion",   durations = { 15, 23 } },
                { spellID = 1214032, name = "Ethereal Shackles",  durations = { 22 } },
                { spellID = 474345,  name = "Refueling Protocol", durations = { 45, 48 } },
            } },
            { id = 3072, name = "Seranel Sunlash", enable = false, abilities = {
                { spellID = 1225792, name = "Runic Mark",       aoe = true, allowedInPlan = true, allowInTimeline = true },
                { spellID = 1246446, name = "Null Reaction",    aoe = true, allowedInPlan = true, allowInTimeline = true },
                { spellID = 1225787, name = "Runic Mark",       durations = { 7, 29 } },
                { spellID = 1224903, name = "Suppression Zone", durations = { 17 } },
                { spellID = 1248689, name = "Hastening Ward",   durations = { 26 } },
                { spellID = 1225193, name = "Wave of Silence",  durations = { 51 } },
            } },
            { id = 3073, name = "Gemellus", abilities = {
                { spellID = 1283904, name = "Cosmic Sting", firstAt = 15, period = 41, cast = 4, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, customName = "DOT",  allowedInPlan = true, allowInTimeline = true },
                { spellID = 1224299, name = "Astral Grasp", firstAt = 39, period = 43, cast = 4, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, customName = "GRIP", allowedInPlan = true, allowInTimeline = true, durations = { 29 } },
                { spellID = 1223847, name = "Triplicate",   durations = { 5 } },
                { spellID = 1284954, name = "Cosmic Sting", durations = { 5 } },
                { spellID = 1253709, name = "Neural Link",  durations = { 16 } },
            }, durationGroups = {
                -- 1ere occurrence de duree 5 = Triplicate (pull) ; les suivantes = Cosmic Sting.
                -- (Le 2e Triplicate, a 50% PV, n'est PAS pousse sur la timeline -> aucun event
                --  de duree 5 a tort. Regle exacte : count == 1 => Triplicate, sinon Cosmic Sting.)
                [5] = { kind = "threshold", first = 1223847, rest = 1284954 },
            } },
            { id = 3074, name = "Degentrius", abilities = {
                { spellID = 1215897, name = "Devouring Entropy",     firstAt = 9, period = 24, cast = 0, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, customName = "DOT", aoe = true, allowedInPlan = true, allowInTimeline = true, durations = { 9, 24, 22 } },
                { spellID = 1280113, name = "Hulking Fragment",      durations = { 3, 24, 22 } },
                { spellID = 1215087, name = "Unstable Void Essence", durations = { 15, 24, 22 } },
            }, durationGroups = {
                [24] = { 1280113, 1215897, 1215087 },
                [22] = { 1280113, 1215897, 1215087 },
            } },
        },
    },
    ----------------------------------------------------------------------- legacy
    {
        id = "ALGETHAR_ACADEMY", name = "Algeth'ar Academy", abbr = "AA", icon = 4578414, iconSpellID = 396126, zoneID = 2526,
        trash = {
            { spellID = 388982, name = "Vicious Ambush" },
        },
        bosses = {
            { id = 2562, name = "Vexamus", phases = {
                {
                    firstAt = 15, period = 44,
                    events = {
                        { spellID = 386181, name = "Mana Bomb",         at = 0,  cast = 3, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, customName = "BOMB", aoe = true, allowedInPlan = true, allowInTimeline = true },
                        { spellID = 386181, name = "Mana Bomb (Combo)", at = 18, cast = 3, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, customName = "BOMB", aoe = true, allowedInPlan = true, allowInTimeline = true },
                    },
                },
            }, abilities = {
                { spellID = 386544, name = "Arcane Orbs",      durations = { 2, 18 } },
                { spellID = 385958, name = "Arcane Expulsion", durations = { 5, 18 } },
                { spellID = 386173, name = "Mana Bomb",        durations = { 15, 18 } },
                { spellID = 388537, name = "Arcane Fissure",   durations = { 40 } },
            }, durationGroups = {
                [18] = { 386544, 385958, 386173 },
            } },
            { id = 2563, name = "Overgrown Ancient", phases = {
                {
                    firstAt = 30, period = 60,
                    events = {
                        { spellID = 388623, name = "Branch Out",  at = 0,  cast = 3, defMarker = { mode = "AFTER_CAST_END",   offset = 0 }, customName = "DOT", aoe = true, allowedInPlan = true, allowInTimeline = true },
                        { spellID = 388923, name = "Burst Forth", at = 24, cast = 3, defMarker = { mode = "BEFORE_CAST_START", offset = 0 }, customName = "AOE", aoe = true, allowedInPlan = true, allowInTimeline = true },
                    },
                },
            }, abilities = {
                { spellID = 388544, name = "Barkbreaker", durations = { 9, 28, 29 } },
                { spellID = 388796, name = "Germinate",   durations = { 18, 33 } },
                { spellID = 388623, name = "Branch Out",  durations = { 30 } },
                { spellID = 388923, name = "Burst Forth", durations = { 54, 55 } },
            } },
            { id = 2564, name = "Crawth", enable = false, abilities = {
                { spellID = 376997, name = "Savage Peck",       durations = { 5 } },
                { spellID = 377004, name = "Deafening Screech", durations = { 14 } },
                { spellID = 377034, name = "Overpowering Gust", durations = { 20 } },
            } },
            { id = 2565, name = "Echo of Doragosa", enable = false, abilities = {
                { spellID = 373326,  name = "Arcane Missiles", durations = { 7, 10 } },
                { spellID = 1282251, name = "Astral Blast",    durations = { 9, 12 } },
                { spellID = 374343,  name = "Energy Bomb",     durations = { 14 } },
                { spellID = 388822,  name = "Power Vacuum",    durations = { 28 } },
            } },
        },
    },
    {
        id = "SEAT_TRIUMVIRATE", name = "Seat of the Triumvirate", abbr = "SEAT", icon = 1711340, iconSpellID = 252631, zoneID = 1753,
        trash = {
            { spellID = 1262509, name = "Chains of Subjugation" },
            { spellID = 1262441, name = "Eruption" },
        },
        bosses = {
            { id = 2065, name = "Zuraal the Ascended", abilities = {
                { spellID = 1263399, name = "Oozing Slam",   firstAt = 20, period = 57, cast = 3, defMarker = { mode = "AFTER_CAST_END",  offset = 0 },    customName = "ADDS", aoe = true, allowedInPlan = true, allowInTimeline = true, durations = { 22 } },
                { spellID = 1263297, name = "Crashing Void", firstAt = 48, period = 57, cast = 5, defMarker = { mode = "BEFORE_CAST_END", offset = 2000 }, customName = "AOE",  aoe = true, allowedInPlan = true, allowInTimeline = true, durations = { 50 } },
                { spellID = 1263440, name = "Void Slash",    durations = { 4, 40 } },
                { spellID = 1263282, name = "Decimate",      durations = { 7, 28 } },
                { spellID = 1268916, name = "Null Palm",     durations = { 16 } },
            } },
            { id = 2066, name = "Saprish", abilities = {
                -- Umbral Nova (1263508) retire du plan -> remplace par Phase Dash (releve joueur).
                { spellID = 1263523, name = "Overload",    firstAt = 32, period = 38, cast = 4, defMarker = { mode = "AFTER_CAST_END",  offset = 0 }, customName = "AOE", aoe = true, allowedInPlan = true, allowInTimeline = true, durations = { 32 } },
                { spellID = 1280065, name = "Phase Dash",  firstAt = 20, period = 38, cast = 5, defMarker = { mode = "BEFORE_CAST_END", offset = 0 }, customName = "ORB", allowedInPlan = true, allowInTimeline = true, durations = { 20 } },
                { spellID = 245742,  name = "Shadow Pounce", durations = { 4, 12 } },
                { spellID = 1248219, name = "Void Bomb",     durations = { 6, 10 } },
            } },
            { id = 2067, name = "Viceroy Nezhar", abilities = {
                { spellID = 1263542, name = "Mass Void Infusion", firstAt = 8,  period = 65, cast = 2, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, customName = "CHANNEL",  aoe = true, allowedInPlan = true, allowInTimeline = true, durations = { 12 } },
                { spellID = 1263538, name = "Umbral Tentacles",   firstAt = 26, period = 65, cast = 3, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, customName = "TENTACLE", aoe = true, allowedInPlan = true, allowInTimeline = true, durations = { 26 } },
                { spellID = 1263529, name = "Collapsing Void",    firstAt = 47, period = 65, cast = 9, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, customName = "AOE",      aoe = true, allowedInPlan = true, allowInTimeline = true },
                { spellID = 244750,  name = "Mind Blast",         durations = { 2, 4, 6, 12, 14 } },
                { spellID = 1277358, name = "Gates of the Abyss", durations = { 6, 18 } },
                { spellID = 1263528, name = "Repulse",            durations = { 45 } },
            }, durationGroups = {
                [6]  = { 1277358, 244750, 244750 },
                [12] = { 1263542, 244750 },
            } },
            -- L'ura se joue de DEUX facons selon le groupe -> 2 variantes de timeline.
            -- Le healer en choisit une (selecteur UI) ; les 2 plans sont sauvegardes, seul
            -- l'actif tourne. Le bloc `abilities` (duration-only) + durationGroups restent
            -- communs aux 2 variantes (matching runtime par duree). Cf. ResolveBossTimeline.
            { id = 2068, name = "L'ura", timelineVariants = {
                { id = "4-2", name = "4 - 2 (Regular)", phases = {
                    -- Dirge + 2x Discordant Beam, periode ~96s (releve : Dirge @2 ; Beam @25/58).
                    { firstAt = 2, period = 96, events = {
                        { spellID = 1265421, name = "Dirge of Despair", at = 0,  cast = 4, defMarker = { mode = "AFTER_CAST_END",  offset = 0 },    customName = "DOT",   aoe = true, allowedInPlan = true, allowInTimeline = true },
                        { spellID = 1265464, name = "Discordant Beam",  at = 23, cast = 7, defMarker = { mode = "BEFORE_CAST_END", offset = 2000 }, customName = "LINES", aoe = true, allowedInPlan = true, allowInTimeline = true },
                        { spellID = 1265464, name = "Discordant Beam",  at = 56, cast = 7, defMarker = { mode = "BEFORE_CAST_END", offset = 2000 }, customName = "LINES", aoe = true, allowedInPlan = true, allowInTimeline = true },
                    } },
                } },
                { id = "4-1-1", name = "4 - 1 - 1 (Advanced)", phases = {
                    -- Dirge + 3x Discordant Beam, periode ~131s (releve : Dirge @1 ; Beam @24/57/90).
                    { firstAt = 1, period = 131, events = {
                        { spellID = 1265421, name = "Dirge of Despair", at = 0,  cast = 4, defMarker = { mode = "AFTER_CAST_END",  offset = 0 },    customName = "DOT",   aoe = true, allowedInPlan = true, allowInTimeline = true },
                        { spellID = 1265464, name = "Discordant Beam",  at = 23, cast = 7, defMarker = { mode = "BEFORE_CAST_END", offset = 2000 }, customName = "LINES", aoe = true, allowedInPlan = true, allowInTimeline = true },
                        { spellID = 1265464, name = "Discordant Beam",  at = 56, cast = 7, defMarker = { mode = "BEFORE_CAST_END", offset = 2000 }, customName = "LINES", aoe = true, allowedInPlan = true, allowInTimeline = true },
                        { spellID = 1265464, name = "Discordant Beam",  at = 89, cast = 7, defMarker = { mode = "BEFORE_CAST_END", offset = 2000 }, customName = "LINES", aoe = true, allowedInPlan = true, allowInTimeline = true },
                    } },
                } },
            }, abilities = {
                { spellID = 1265421, name = "Dirge of Despair",               durations = { 1.5 } },
                { spellID = 1264196, name = "Disintegrate",                   durations = { 5, 12 } },
                { spellID = 1265463, name = "Discordant Beam",                durations = { 17, 24 } },
                { spellID = 1265689, name = "Grim Chorus",                    durations = { 28, 35 } },
                { spellID = 1266003, name = "Symphony of the Eternal Night",  durations = { 1.5 } },
                { spellID = 1265999, name = "Siphon Void",                    durations = { 20 } },
            }, durationGroups = {
                [1.5] = { 1265421, 1266003 },
            } },
        },
    },
    {
        id = "SKYREACH", name = "Skyreach", abbr = "SR", icon = 1002596, iconSpellID = 169765, zoneID = 1209,
        trash = {},
        bosses = {
            { id = 1698, name = "Ranjit", abilities = {
                { spellID = 153757,  name = "Fan of Blades",   firstAt = 12, period = 21, cast = 3, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, customName = "DOT", aoe = true, allowedInPlan = true, allowInTimeline = true, durations = { 12, 20 } },
                { spellID = 1252690, name = "Gale Surge",      durations = { 5 } },
                { spellID = 1258152, name = "Wind Chakram",    durations = { 10, 18 } },
                { spellID = 156793,  name = "Chakram Vortex",  durations = { 35 } },
            } },
            { id = 1699, name = "Araknath", phases = {
                {
                    firstAt = 5, period = 54,
                    events = {
                        { spellID = 1252877, name = "Energize",  at = 0,  cast = 0, defMarker = { mode = "AFTER_CAST_END",  offset = 10000 }, customName = "BEAM", aoe = true, allowedInPlan = true, allowInTimeline = true },
                        { spellID = 1252877, name = "Energize",  at = 24, cast = 0, defMarker = { mode = "AFTER_CAST_END",  offset = 10000 }, customName = "BEAM", aoe = true, allowedInPlan = true, allowInTimeline = true },
                        { spellID = 154135,  name = "Supernova", at = 44, cast = 4, defMarker = { mode = "BEFORE_CAST_END", offset = 2000 },  customName = "AOE",  aoe = true, allowedInPlan = true, allowInTimeline = true },
                    },
                },
            }, abilities = {
                { spellID = 154110, name = "Fiery Smash", durations = { 5, 10, 15 } },
                { spellID = 154162, name = "Energize",    durations = { 6, 24 } },
                { spellID = 154135, name = "Supernova",   durations = { 50 } },
            } },
            { id = 1700, name = "Rukhran", phases = {
                {
                    firstAt = 12, period = 47,
                    events = {
                        { spellID = 1253510, name = "Sunbreak", at = 0,  cast = 3, defMarker = { mode = "BEFORE_CAST_END", offset = 1000 }, customName = "BIRD", aoe = true, allowedInPlan = true, allowInTimeline = true },
                        { spellID = 1253510, name = "Sunbreak", at = 21, cast = 3, defMarker = { mode = "BEFORE_CAST_END", offset = 1000 }, customName = "BIRD", aoe = true, allowedInPlan = true, allowInTimeline = true },
                    },
                },
            }, abilities = {
                { spellID = 1253519, name = "Burning Claws",  durations = { 5, 12 } },
                { spellID = 1253510, name = "Sunbreak",       durations = { 21, 12 } },
                { spellID = 159382,  name = "Searing Quills", durations = { 38 } },
            }, durationGroups = {
                [12] = { 1253510, 1253519 },
            } },
            { id = 1701, name = "High Sage Viryx", phases = {
                {
                    firstAt = 5, period = 39,
                    events = {
                        { spellID = 1253543, name = "Scorching Ray", at = 0,  cast = 0, defMarker = { mode = "AFTER_CAST_START", offset = 0 }, customName = "DOT", allowedInPlan = true, allowInTimeline = true },
                        { spellID = 1253543, name = "Scorching Ray", at = 10, cast = 0, defMarker = { mode = "AFTER_CAST_START", offset = 0 }, customName = "DOT", allowedInPlan = true, allowInTimeline = true },
                        { spellID = 1253543, name = "Scorching Ray", at = 20, cast = 0, defMarker = { mode = "AFTER_CAST_START", offset = 0 }, customName = "DOT", allowedInPlan = true, allowInTimeline = true },
                    },
                },
            }, abilities = {
                { spellID = 1253538, name = "Scorching Ray", durations = { 5, 10 } },
                { spellID = 154396,  name = "Solar Blast",   durations = { 8, 12 } },
                { spellID = 153954,  name = "Cast Down",     durations = { 12 } },
                { spellID = 1253840, name = "Lens Flare",    durations = { 30 } },
            }, durationGroups = {
                [12] = { 153954, 154396 },
            } },
        },
    },
    {
        id = "PIT_OF_SARON", name = "Pit of Saron", abbr = "PIT", icon = 343641, iconSpellID = 1255366, zoneID = 658,
        trash = {
            { spellID = 1258802, name = "Dread Pulse" },
            { spellID = 1258820, name = "Torrent of Misery" },
        },
        bosses = {
            { id = 1999, name = "Forgemaster Garfrost", abilities = {
                { spellID = 1261847, name = "Cryostomp",        firstAt = 42, period = 41, cast = 3, defMarker = { mode = "BEFORE_CAST_END", offset = 1000 }, customName = "AOE", aoe = true, allowedInPlan = true, allowInTimeline = true, durations = { 41.5 } },
                { spellID = 1261299, name = "Throw Saronite",   durations = { 7 } },
                { spellID = 1261546, name = "Orebreaker",       durations = { 20 } },
                { spellID = 1262029, name = "Glacial Overload", durations = { 33 } },
            } },
            { id = 2001, name = "Ick & Krick", phases = {
                {
                    firstAt = 0, period = 83,
                    events = {
                        { spellID = 1264027, name = "Shade Shift",      at = 0,  cast = 4,   defMarker = { mode = "BEFORE_CAST_END", offset = 0 },    customName = "DOT", aoe = true, allowedInPlan = true, allowInTimeline = true },
                        { spellID = 1264336, name = "Plague Expulsion", at = 21, cast = 2.5, defMarker = { mode = "BEFORE_CAST_END", offset = 2000 }, customName = "AOE", aoe = true, allowedInPlan = true, allowInTimeline = true },
                        { spellID = 1264336, name = "Plague Expulsion", at = 40, cast = 2.5, defMarker = { mode = "BEFORE_CAST_END", offset = 2000 }, customName = "AOE", aoe = true, allowedInPlan = true, allowInTimeline = true },
                    },
                },
            }, abilities = {
                { spellID = 1264287, name = "Blight Smash",     durations = { 11, 19 } },
                { spellID = 1264336, name = "Plague Expulsion", durations = { 21, 19 } },
                { spellID = 1264027, name = "Shade Shift",      durations = { 28.75 } },
                { spellID = 1264363, name = "Get 'Em, Ick!",    durations = { 50 } },
            }, durationGroups = {
                [19] = { 1264287, 1264336 },
            } },
            { id = 2000, name = "Scourgelord Tyrannus", abilities = {
                { spellID = 1262745, name = "Rime Blast",          aoe = true, allowedInPlan = true, allowInTimeline = true, durations = { 7, 28 } },
                { spellID = 1276948, name = "Ice Barrage",         durations = { 12 } },
                { spellID = 1262582, name = "Scourgelord's Brand", durations = { 14, 28 } },
                { spellID = 1263756, name = "Death's Grasp",       durations = { 24 } },
                { spellID = 1263406, name = "Army of the Dead",    durations = { 52 } },
                { spellID = 1276648, name = "Bone Infusion",       durations = { 28 } },
            }, phases = {
                {
                    firstAt = 0, period = 84,
                    events = {
                        { spellID = 1276648, name = "Bone Infusion",    at = 0,  cast = 3, defMarker = { mode = "BEFORE_CAST_END", offset = 0 }, customName = "DOT",  allowedInPlan = true, allowInTimeline = true },
                        { spellID = 1263406, name = "Army of the Dead", at = 52, cast = 4, defMarker = { mode = "AFTER_CAST_END",  offset = 0 }, customName = "ADDS", aoe = true, allowedInPlan = true, allowInTimeline = true },
                    },
                },
            }, durationGroups = {
                [28] = { 1262745, 1262582, 1276648 },
            } },
        },
    },
}

--------------------------------------------------------------------------------
-- CONTENU STATIQUE PARALLELE PAR VERSION DE CLIENT
--------------------------------------------------------------------------------
-- La data de boss (encounterID, spellID, `durations`, timelines) change d'un patch
-- a l'autre. On tient donc UNE TABLE PAR VERSION du client, indexee par la string
-- complete (`HR.CLIENT_VERSION`, lue via GetBuildInfo dans Core/Constants.lua). Le
-- selecteur en bas remplace `HR.content` par la table de la version courante ; les
-- helpers ci-dessous lisent `HR.content` dynamiquement => ils suivent la bascule.
-- La table 12.0.7 = le contenu live construit ci-dessus (`HR.content`).
--
-- POOL 12.1.0 : VIDE tant que la data du patch n'est pas connue. Un pool vide =>
-- aucun donjon => aucun sidemenu (la boucle de tabs de la modale itere sur {} = no-op,
-- aucun crash : chaque lecture HR.content[i] est deja gardee cote UI).
--
-- A REMPLIR avec les donjons reels de la 12.1.0. Les icones / noms / abbr / zoneID des
-- donjons se listent ICI, un objet par donjon (MEME schema que le pool 12.0.7 ci-dessus).
-- Il n'y a PAS de registre d'icones separe : la liste des donjons visibles EST ce pool.
-- Ajouter des entrees ici fait reapparaitre le sidemenu automatiquement (aucun autre
-- fichier a toucher : tous les consommateurs lisent HR.content). Squelette d'une entree :
--   {
--     id = "NOM_DONJON", name = "Nom Donjon", abbr = "ND",
--     icon = 0, iconSpellID = 0, zoneID = 0,        -- icone + nom du tab du sidemenu
--     trash = { { spellID = 0, name = "" }, ... },
--     bosses = { { id = <encounterID>, name = "", abilities = { ... } }, ... },
--   },
-- POOL 12.1.0 (nouvelle saison PTR). Icones = fileID `texture` de
-- C_ChallengeMode.GetMapUIInfo(mapID) (onglet Donjons Mythique+ du Group Finder).
-- A COMPLETER en jeu : zoneID (instanceID de GetInstanceInfo, via /hp scan) +
-- encounterID des boss + timelines (`abilities`/`phases` + `durations`, via /hp gather).
-- Le `mapID` (ChallengeMode) est note en commentaire : il ne sert PAS au runtime
-- (pas le meme id que zoneID/encounterID), il ne documente que la provenance de l'icone.
local content_1210 = {
    { id = "ALTAR_OF_FANGS",       name = "Altar of Fangs",       abbr = "AOF", icon = 7956176, zoneID = 2993, -- mapID 588
        trash = {
            { spellID = 1308865, name = "Infest" },
        },
        bosses = {
            { id = 3456, name = "Rav'i", phases = {
                -- Ravenous Stomp part au PULL (aucun event serveur pour cette 1re occurrence
                -- -> PushSyntheticPullEvents), d'ou firstAt = 0 : NE PAS le decaler.
                -- Releve joueur (pull a 7'48), 3 cycles -> reconstruction par base de cycle :
                --   base 0   : Stomp 0 | Fresh Meat +6 | Triple Shot +8 | Ssscav +25 | TS +50 | Regurg +55
                --   base 65  : Stomp 0 | Fresh Meat +7 | Triple Shot +8 | Ssscav +22 | TS +44 | Regurg +49
                --   base 125 : Stomp 0 | Fresh Meat +7 | Triple Shot +8 | Ssscav +22
                -- => Le cycle d'OUVERTURE dure 65 s avec des offsets tardifs ETIRES (+25/+50/+55) ;
                --    le regime etabli est a 60 s avec +22/+44/+49. L'ancien modele (64 / 25 / 49 / 54)
                --    encodait l'ouverture -> il derivait sur tous les cycles suivants.
                -- CHOIX : on encode le REGIME ETABLI (60 s), qui couvre les cycles 2..5 d'un combat de
                -- 5 min. Consequence assumee : le cycle 1 est annonce jusqu'a ~6 s TOT sur ses 3
                -- derniers sorts (Ssscavenging, 2e Triple Shot, Regurgitate).
                -- Offset du sort hors-plan, pour memoire : Fresh Meat +6/+7 (ENCOUNTER_WARNING).
                { name = "Rotation", firstAt = 0, period = 60, events = {
                    { spellID = 1307894, name = "Ravenous Stomp", at = 0,  cast = 3, defMarker = { mode = "AFTER_CAST_END",   offset = 0 },     allowedInPlan = true, allowInTimeline = true },
                    { spellID = 1296220, name = "Triple Shot",    at = 8,  cast = 2, defMarker = { mode = "AFTER_CAST_END",   offset = -1000 }, allowedInPlan = true, allowInTimeline = true },
                    { spellID = 1296216, name = "Ssscavenging",   at = 22, cast = 0, defMarker = { mode = "AFTER_CAST_START", offset = 0 },     allowedInPlan = true, allowInTimeline = true },
                    { spellID = 1296220, name = "Triple Shot",    at = 44, cast = 2, defMarker = { mode = "AFTER_CAST_END",   offset = -1000 }, allowedInPlan = true, allowInTimeline = true },
                    { spellID = 1296050, name = "Regurgitate",    at = 49, allowedInPlan = true, allowInTimeline = true },
                } },
            }, -- aucune duree partagee : chaque duree resout un sort unique (pas de durationGroups)
                abilities = {
                    { spellID = 1296220, name = "Triple Shot",    durations = { 8, 24 } },
                    { spellID = 1296216, name = "Ssscavenging",   durations = { 25, 45 } },
                    { spellID = 1296050, name = "Regurgitate",    durations = { 13 } },
                    { spellID = 1307894, name = "Ravenous Stomp", durations = { 23 } },
                    { spellID = 1307703, name = "Fresh Meat" }, -- ENCOUNTER_WARNING, pas de duree serveur
                },
            },
            { id = 3457, name = "The Writhing Coil", phases = {
                -- Releve joueur (pull a 16'49), 2 cycles complets -> period 90 (et non 96.5) :
                --   Synchronized Venom 1 / 91 | Tail Scythe 7 / 97 | Preparing Toxin 14 / 104
                --   Vindictive Onslaught 30 / 120 | Death Rattle 44 / 134
                --   Toxic Atrophy 61 / 152 | Assimilation 76 / 167
                -- => +90 EXACT sur les 5 premiers sorts, +91 sur les 2 derniers. Les offsets des 5
                -- premiers sont confirmes au sort pres ; Toxic Atrophy et Assimilation etaient ~5 s
                -- trop tard (65.7 -> 60.5 et 80.7 -> 75.5).
                -- NB : le boss alterne lui-meme deux segments (les 2 sorts "P2" Toxic Atrophy +
                -- Assimilation apparaissent apres le cast de Death Rattle, puis le segment initial
                -- reprend apres Assimilation). Cette alternance EST le cycle de 90 s -> une seule
                -- phase "Rotation" suffit, pas besoin de phaseTransitions.
                -- PLAN RESTREINT (choix joueur) : seuls Synchronized Venom + Death Rattle. Les 5
                -- autres restent reconnus en live mais MASQUES (allowInTimeline=false ci-dessous) ;
                -- leurs offsets mesures sont conserves en commentaire au cas ou : Tail Scythe +6,
                -- Preparing Toxin +13, Vindictive Onslaught +29, Toxic Atrophy +60.5, Assimilation +75.5.
                { name = "Rotation", firstAt = 1, period = 90, events = {
                    { spellID = 1299154, name = "Synchronized Venom", at = 0,    cast = 2, defMarker = { mode = "AFTER_CAST_END", offset = 0 },     allowedInPlan = true, allowInTimeline = true },
                    { spellID = 1299053, name = "Death Rattle",       at = 43,   cast = 5, defMarker = { mode = "AFTER_CAST_END", offset = -1000 }, allowedInPlan = true, allowInTimeline = true },
                } },
            }, durationGroups = { [10] = { 1310547, 1299154 } }, -- duree 10 partagee, en CYCLE : n impair Toxic Atrophy, n pair Synchronized Venom
                -- NB : Toxic Atrophy reste dans durationGroups MEME masque -- le groupe sert au
                -- MATCHING (depart au modulo), pas a l'affichage. L'en retirer desynchroniserait
                -- la resolution de la duree 10 pour Synchronized Venom, lui bien planifie.
                abilities = {
                    { spellID = 1299154, name = "Synchronized Venom",   durations = { 1, 10 } },
                    { spellID = 1298949, name = "Tail Scythe",          durations = { 7, 16 }, allowInTimeline = false }, -- EXCLURE
                    { spellID = 1310357, name = "Preparing Toxin",      durations = { 14, 23 }, allowInTimeline = false }, -- EXCLURE
                    { spellID = 1299940, name = "Vindictive Onslaught", durations = { 30, 39 }, allowInTimeline = false }, -- EXCLURE
                    { spellID = 1299053, name = "Death Rattle",         durations = { 44, 53 } },
                    { spellID = 1310547, name = "Toxic Atrophy",        durations = { 10 }, allowInTimeline = false }, -- EXCLURE
                    { spellID = 1300686, name = "Assimilation",         durations = { 25 }, allowInTimeline = false }, -- EXCLURE
                    { spellID = 1299130, name = "Burrowing Charge" }, -- UNIT_SPELLCAST, pas de duree serveur
                    { spellID = 1300044, name = "Venom Jet" },        -- UNIT_SPELLCAST, pas de duree serveur
                },
            },
            { id = 3458, name = "Zul'jan", phases = {
                -- Timeline observee en jeu (pull t0) : cycle de 64 s (2 cycles complets mesures) ;
                -- Boneslicer 2x/phase (+32, +46), Chop Down 2x/phase (+26, +56). Ritual of the Fang
                -- part au PULL (aucun event serveur pour cette 1re occurrence).
                -- Releve joueur (pull a 27'31) -> CONFIRME integralement, rien a changer :
                --   Ritual of the Fang 0 / 64 / 127 (1re iteration instantanee et SANS event serveur,
                --     ce qui confirme le besoin de PushSyntheticPullEvents)
                --   Axegrinder 13 / 77 | Chop Down 25 / 55 puis 89 / 119 | Boneslicer 31 / 45 puis 95 / 109
                -- => Axegrinder, Chop Down et Boneslicer donnent +64 EXACT sur leurs 5 intervalles.
                -- Les offsets mesurent tous 1 s sous le modele (13/25/31/45/55 vs 14/26/32/46/56) =
                -- biais systematique du releve, pas un decalage reel -> `at` conserves.
                -- PLAN RESTREINT (choix joueur) : Ritual of the Fang + les DEUX Boneslicer (+32/+46).
                -- Axegrinder (+14) et Chop Down (+26/+56) restent reconnus mais MASQUES.
                { name = "Rotation", firstAt = 0, period = 64, events = {
                    { spellID = 1300876, name = "Ritual of the Fang", at = 0,  cast = 4, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, allowedInPlan = true, allowInTimeline = true },
                    { spellID = 1301413, name = "Boneslicer",         at = 32, cast = 5, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, allowedInPlan = true, allowInTimeline = true },
                    { spellID = 1301413, name = "Boneslicer",         at = 46, cast = 5, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, allowedInPlan = true, allowInTimeline = true },
                } },
            }, durationGroups = { [14] = { 1301111, 1301413 } }, -- duree 14 partagee, en CYCLE : n impair Axegrinder, n pair Boneslicer
                -- NB : Axegrinder reste dans durationGroups MEME masque -- le groupe sert au
                -- MATCHING. L'en retirer casserait la resolution de la duree 14 pour Boneslicer,
                -- lui bien planifie (c'est Axegrinder qui ouvre le cycle sur cette duree).
                abilities = {
                    { spellID = 1300876, name = "Ritual of the Fang", durations = { 64 } },
                    { spellID = 1301111, name = "Axegrinder",         durations = { 14 }, allowInTimeline = false },     -- EXCLURE
                    { spellID = 1301350, name = "Chop Down",          durations = { 26, 30 }, allowInTimeline = false }, -- EXCLURE
                    { spellID = 1301413, name = "Boneslicer",         durations = { 14, 32 } },
                },
            },
        },
    },
    { id = "RUBY_LIFE_POOLS",      name = "Ruby Life Pools",      abbr = "RLP", icon = 4746639, zoneID = 2521, -- mapID 399
        trash = {},
        bosses = {
            { id = 2609, name = "Melidrussa Chillworn", abilities = {
                -- Boss health-gated : ouvre par Hailburst, alterne Hailburst<->Chillstorm (~13 s) jusqu'a
                -- la transition (Awaken Whelps a ~75%/45% PV), MARQUEE par Frost Overload, puis repart par
                -- Hailburst. On ne met en avant QUE Frost Overload (le vrai moment defensif) ; le reste est
                -- reconnu en live (matching par duree) mais MASQUE de la timeline (allowInTimeline=false).
                -- Frost Overload : firstAt/period approximatifs (health-gated, releve ~72 puis ~165 s) ; le
                -- live le recale exactement par sa duree (12 s).
                { spellID = 373686, name = "Frost Overload", firstAt = 72, period = 93, cast = 0, defMarker = { mode = "AFTER_CAST_START", offset = 0 }, aoe = true, allowedInPlan = true, allowInTimeline = true, durations = { 12 } },
                { spellID = 1307297, name = "Hailburst",    durations = { 6, 27 },  allowInTimeline = false }, -- cast 2s / at_cast_end ; timer 6 + 27 (companion)
                { spellID = 1307308, name = "Chillstorm",   durations = { 16, 27 }, allowInTimeline = false }, -- cast 4.5s / at_cast_end ; timer 16 + 27 (companion)
                { spellID = 373046, name = "Awaken Whelps", allowInTimeline = false }, -- transition health-based, pas de duree timeline
            }, durationGroups = {
                [27] = { 1307297, 1307308 }, -- timer companion : alterne Hailburst/Chillstorm (6/16 restent les matchs uniques)
            } },
            { id = 2606, name = "Kokia Blazehoof", abilities = {
                -- Phase = Ritual -> Boulder -> Searing -> Boulder, period 41 s (nette, PAS health-gated) ;
                -- validee sur pull joueur + scan. Chaque sort a une duree d'OUVERTURE != duree de CYCLE
                -- (1er cast vs suivants). On ne met en avant QUE Ritual of Blazebinding ; Boulder + Searing
                -- reconnus en live (matching par duree) mais MASQUES (allowInTimeline=false).
                -- Releve joueur (pull a 15'57) -> CONFIRME, rien a changer :
                --   Ritual of Blazebinding 8 / 49 / 90 -> +41 EXACT (2 intervalles) ; firstAt 8 confirme.
                --   Searing Blows 28 / 69 -> +41 aussi, soit +20 apres le Ritual.
                --   Molten Boulder 19 / 40 / 61 / 82 -> timer PROPRE de 21 s (4 casts, +21 exact),
                --   il ne suit donc pas le cycle 41 : 2 boulders par cycle qui derivent lentement.
                { spellID = 372864, name = "Ritual of Blazebinding", firstAt = 8, period = 41, cast = 5, defMarker = { mode = "AFTER_CAST_END", offset = 5000 }, aoe = true, allowedInPlan = true, allowInTimeline = true, durations = { 8, 40 } },
                { spellID = 372110, name = "Molten Boulder", durations = { 19, 20 }, allowInTimeline = false }, -- cast 2.5s ; ouverture 19 / cycle 20
                { spellID = 372858, name = "Searing Blows",  durations = { 28, 40 }, allowInTimeline = false }, -- ouverture 28 / cycle 40 (partage 40 avec Ritual)
            }, durationGroups = {
                [40] = { 372864, 372858 }, -- duree de cycle partagee Ritual/Searing : alternent (Ritual en 1er)
            } },
            { id = 2623, name = "Kyrakka and Erkhart Stormvein", abilities = {
                -- PAS de phase unique qui boucle : chaque sort tourne sur SON propre timer (periodes proches
                -- ~22-25 s mais differentes -> ils derivent). Timings releves sur le pull joueur (phase sol).
                -- On met en avant 2 sorts au sol (Flamespit/Cloudburst) ; Stormslam + Winds + Roaring = EXCLURE.
                -- Chaque sort a une duree d'OUVERTURE (1er cast) != duree de CYCLE (verifie au scan).
                -- Phase de vol de Kyrakka (~t92+) : Roaring Firebreath en rafale (dur 16 / ~8.5 s), la rotation
                -- d'Erkhart continue en parallele -> pas un vrai swap ; la rafale tombe sous Roaring (masque).
                { spellID = 381512, name = "Stormslam", durations = { 5, 22.5 }, allowInTimeline = false }, -- EXCLURE : retire de la timeline (reconnu live, masque)
                { spellID = 381517, name = "Winds of Change", durations = { 10, 21.5 }, allowInTimeline = false }, -- EXCLURE : retire de la timeline (reconnu live, masque)
                -- ⚠️ Inferno Spit declare 4 durees (9/12/16/20) : son ouverture est ambigue, donc
                -- firstAt/period ci-dessous ne sont PAS derivables des durees.
                -- Releve joueur COMPLET (pull a 23'06, stage 2 a +119 s) -> periodes P1 puis P2 :
                --   Roaring Firebreath      3/23/45/69/90    = 21.75  ||  114/134/151/168/185 = 17
                --   Inferno Spit           13/37/60/83/106   = 23.25  ||  125/142/159/176     = 17
                --   Stormslam               5/30/53/80/104   = 24.75  ||  130/155/182         = 26
                --   Winds of Change        10/33/55/77/101   = 22.75  ||  126/152/177         = 25.5
                --   Interrupting Cloudburst 21/48/73/98      = 25.67  ||  124/149/175         = 25.5
                -- ⚠️ CHANGEMENT STRUCTUREL AU STAGE 2 : les 2 sorts de KYRAKKA (feu : Roaring Firebreath,
                -- Inferno Spit) ACCELERENT de ~22-23 s a 17 s (-26%, net et repete sur 3 intervalles
                -- chacun), tandis que les 3 sorts d'ERKHART (orage : Stormslam, Winds, Cloudburst)
                -- restent a ~25-26 s. Le modele `abilities` ne porte qu'UNE period par sort et ne peut
                -- donc pas exprimer ca. CHOIX ASSUME : period = 21, un COMPROMIS entre les 23 s de P1
                -- et les 17 s de P2 (pondere vers P1, la P2 etant courte). Erreur max ~7 s de chaque
                -- cote, la ou un period=23 collerait a 1 s en P1 mais deriverait de ~23 s en P2.
                -- NE PAS "corriger" vers 23 en relisant les mesures P1 seules.
                -- NB : les 2 firstAt mesurent 2 s sous le modele (13 vs 15, 21 vs 22) = biais
                -- systematique du releve, pas un changement -> firstAt conserves.
                { spellID = 381862, name = "Inferno Spit",            firstAt = 15, period = 21, cast = 2,   defMarker = { mode = "AFTER_CAST_END", offset = 0 }, aoe = true, allowedInPlan = true, allowInTimeline = true, durations = { 9, 12, 16, 20 } },
                { spellID = 381516, name = "Interrupting Cloudburst", firstAt = 22, period = 25, cast = 5,   defMarker = { mode = "AFTER_CAST_END", offset = 0 }, aoe = true, allowedInPlan = true, allowInTimeline = true, durations = { 21, 25 } },
                { spellID = 381525, name = "Roaring Firebreath", durations = { 1, 16, 20 }, allowInTimeline = false }, -- EXCLURE : cycle 20 + rafale 16 (phase de vol Kyrakka)
            }, durationGroups = {
                -- 20 ET 16 sont partagees Roaring/Inferno Spit et alternent (Roaring en 1er) ;
                -- 22.5 / 21.5 / 25 / 9 / 12 restent des matchs uniques.
                [20] = { 381525, 381862 },
                [16] = { 381525, 381862 },
            } },
        },
    },
    { id = "TEMPLE_OF_SETHRALISS", name = "Temple of Sethraliss", abbr = "TOS", icon = 2178734, zoneID = 1877, -- mapID 250
        trash = {},
        bosses = {
            { id = 2124, name = "Adderis and Aspix", abilities = {
                -- Rotation sequentielle Gale Force -> Thunder and Lightning -> Tempest Winds -> Overload qui
                -- reboucle (= transfert du Bouclier de Foudre entre les 2 boss). INCLURE : Tempest Winds +
                -- Overload (cast/marker fournis) ; Gale Force + Thunder and Lightning = EXCLURE. NB : vague
                -- d'adds (Conduction = dur 5 x3 + dur 15/17) non modelisee (hors releve joueur) -> non
                -- reconnue en live pour l'instant.
                -- spellID confirmes via /ecp journal (12.1.0).
                -- Releve joueur (pull a 1'27) -> offsets, en secondes depuis le pull :
                --   Gale Force            5 / 47 / 93 / 138  (42, 46, 45)
                --   Thunder and Lightning 10 / 50 / 95 / 146 (40, 45, 51)
                --   Tempest Winds         26 / 67 / 117      (41, 50)
                --   Overload              36 / 81 / 126      (45, 45)
                -- => cycle commun ~45 s (l'ancien "63-67 s" etait faux) ; les ecarts sort a sort sont du
                -- jitter de releve manuel, on garde une periode UNIQUE de 45 pour les 4 sorts.
                { spellID = 1288864, name = "Tempest Winds", firstAt = 26, period = 45, cast = 3, defMarker = { mode = "AFTER_CAST_END", offset = 0 },     aoe = true, allowedInPlan = true, allowInTimeline = true, durations = { 12, 21, 26 } },
                { spellID = 1288428, name = "Overload",      firstAt = 36, period = 45, cast = 5, defMarker = { mode = "AFTER_CAST_END", offset = -2000 }, aoe = true, allowedInPlan = true, allowInTimeline = true, durations = { 31, 36 } },
                { spellID = 1289059, name = "Gale Force",            durations = { 1, 5 }, allowInTimeline = false }, -- EXCLURE
                { spellID = 1288049, name = "Thunder and Lightning", durations = { 4, 9 }, allowInTimeline = false }, -- EXCLURE
            }, durationGroups = {
                -- dur 42 = timer de cycle PARTAGE par les 4 sorts, dans l'ordre de la rotation.
                [42] = { 1289059, 1288049, 1288864, 1288428 },
                -- NB : une dur 19 existe aussi, mais elle depend de quel boss est encore en vie
                -- (etat non modelisable ici) -> volontairement non declaree.
            } },
            { id = 2125, name = "Merektha", abilities = {
                -- Phase unique qui reboucle, period 81 s. Durees UNIQUES et constantes par sort (pas de
                -- split ouverture/cycle, aucun partage -> pas de durationGroups).
                -- INCLURE : Serpentstorm + Burrow (frise) ; les 4 autres = EXCLURE (reconnus live, masques).
                -- spellID confirmes via /ecp journal (12.1.0).
                -- Releve joueur (pull a 11'32) -> offsets depuis le pull, 2 cycles, ecart CONSTANT de 81 s :
                --   Lightning Bite 5 / 86 | A Knot of Snakes 14 / 94 | Thunder Spit 25 / 107
                --   Serpentstorm 36 / 117 | Hatch 44 / 125 | Burrow 50 / 131
                -- (l'ancien period 73.5 etait faux ; les 4 sorts exclus restent duration-only, leurs offsets
                --  sont notes ici pour memoire.)
                { spellID = 1293048, name = "Serpentstorm", firstAt = 36, period = 81, cast = 3.5, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, aoe = true, allowedInPlan = true, allowInTimeline = true, durations = { 36 } },
                { spellID = 264172,  name = "Burrow",       firstAt = 50, period = 81, cast = 3,   defMarker = { mode = "AFTER_CAST_END", offset = 0 },             allowedInPlan = true, allowInTimeline = true, durations = { 49 } },
                { spellID = 1290797, name = "Lightning Bite",   durations = { 5 },  allowInTimeline = false }, -- EXCLURE
                { spellID = 1290029, name = "A Knot of Snakes", durations = { 13 }, allowInTimeline = false }, -- EXCLURE
                { spellID = 1289109, name = "Thunder Spit",     durations = { 25 }, allowInTimeline = false }, -- EXCLURE
                { spellID = 1289205, name = "Hatch",            durations = { 44 }, allowInTimeline = false }, -- EXCLURE
            } },
            { id = 2126, name = "Galvazzt", abilities = {
                -- 2 sorts, cycle ~26 s. Chaque sort : duree d'OUVERTURE (Spire 6 / Induction 24) != duree de
                -- CYCLE (26, PARTAGEE) -> durationGroups[26]. INCLURE : Induction (cast/marker fournis) ;
                -- Lightning Spire = EXCLURE (timers seuls).
                -- spellID confirmes via /ecp journal (12.1.0).
                -- Timeline devscan (M+, 12.1) : ouverture 20 (= firstAt) confirmee, recast mesure a
                -- 42.7 puis 64.9 -> period 22.45. Lightning Spire ouvre a 5 et tourne sur son propre
                -- timer (5 / 28.1 / 51.2 / 74.2, ~23.05 s) : les deux derivent l'un par rapport a l'autre.
                -- Releve joueur (pull a 18'18) -> CONFIRME le scan : Induction 20 / 42 / 65 (22, 23) et
                -- Lightning Spire 5 / 28 / 51 (23, 23). period arrondie a 22.5.
                { spellID = 1309525, name = "Induction", firstAt = 20, period = 22.5, cast = 2.5, defMarker = { mode = "AFTER_CAST_END", offset = -1000 }, aoe = true, allowedInPlan = true, allowInTimeline = true, durations = { 20, 22 } },
                { spellID = 1291618, name = "Lightning Spire", durations = { 5, 22 }, allowInTimeline = false }, -- EXCLURE (partage dur 22 avec Induction)
            }, durationGroups = {
                [22] = { 1291618, 1309525 }, -- dur de cycle partagee Lightning Spire/Induction (Spire en 1er)
            } },
            { id = 2127, name = "Avatar of Sethraliss", enable = false, -- boss de burn/transition (phases %/health-gated),
                -- non modelisable en timeline temps -> grise en config, mode BRUT runtime (aucun matching).
                abilities = {} },
        },
    },
    { id = "KINGS_REST",           name = "Kings' Rest",          abbr = "KR",  icon = 2178730, zoneID = 1762, -- mapID 249
        trash = {},
        bosses = {
            { id = 2139, name = "The Golden Serpent", phases = {
                -- Cas particulier : chaque sort principal caste 2x/cycle (une fois "court", une fois "long").
                -- Period 65 s. INCLURE = Spit Gold + Serpentine Gust (leurs 2 casts) ; Tail Thrash +
                -- Lucre's Call = EXCLURE (duration-only, masques).
                -- Releve joueur (pull a 3'23) -> offsets depuis le pull, 2 cycles :
                --   Spit Gold 5 / 30 puis 70 / 95 | Tail Thrash 8 / 33 puis 73 / 98
                --   Serpentine Gust 14 / 42 puis 79 / 107 | Lucre's Call 54 puis 119
                -- => +65 EXACT sur les 3 derniers sorts -> period 65 (l'ancien 50 etait faux).
                -- NB : le releve notait le 3e Spit Gold a 80 ; retenu comme 70 (a 80 l'ecart interne du
                -- sort tomberait a 15 s au lieu des 25 s du cycle 1, et les 3 autres sorts disent 65).
                { name = "Rotation", firstAt = 5, period = 65, events = {
                    { spellID = 265773, name = "Spit Gold",       at = 0,    cast = 2, defMarker = { mode = "AFTER_CAST_END", offset = 0 },     aoe = true, allowedInPlan = true, allowInTimeline = true },
                    { spellID = 265781, name = "Serpentine Gust", at = 9,    cast = 3, defMarker = { mode = "AFTER_CAST_END", offset = -2000 }, aoe = true, allowedInPlan = true, allowInTimeline = true },
                    { spellID = 265773, name = "Spit Gold",       at = 25,   cast = 2, defMarker = { mode = "AFTER_CAST_END", offset = 0 },     aoe = true, allowedInPlan = true, allowInTimeline = true },
                    { spellID = 265781, name = "Serpentine Gust", at = 37,   cast = 3, defMarker = { mode = "AFTER_CAST_END", offset = -2000 }, aoe = true, allowedInPlan = true, allowInTimeline = true },
                } },
            }, abilities = {
                -- Timeline devscan (M+, 12.1) : offsets CONFIRMES au scan (Spit Gold 5 puis 30,
                -- Serpentine Gust 14 puis 42, Tail Thrash 8 puis 33, Lucre's Call 54).
                -- ⚠️ Le combat n'a dure que 54 s : aucun 2e cycle observe, le period de 50 s reste
                -- herite de l'ancien releve et n'est pas confirme.
                { spellID = 265773, name = "Spit Gold",       durations = { 5, 25 } },  -- 1er cast dur5, 2e dur25
                { spellID = 265781, name = "Serpentine Gust", durations = { 14, 28 } }, -- 1er cast dur14, 2e dur28
                { spellID = 265910, name = "Tail Thrash",     durations = { 8, 25 }, allowInTimeline = false }, -- EXCLURE (partage dur25 avec Spit Gold)
                { spellID = 265923, name = "Lucre's Call",    durations = { 54 },    allowInTimeline = false }, -- EXCLURE
            }, durationGroups = {
                [25] = { 265773, 265910 }, -- dur partagee Spit Gold/Tail Thrash (Spit Gold en 1er)
            } },
            { id = 2142, name = "Mchimba the Embalmer", phases = {
                -- La rotation ouvre par Drain Fluids (t5). Drain Fluids revient 1x par cycle ; les 3 autres
                -- sorts tournent sur leurs PROPRES timers (ils derivent) -> EXCLURE (reconnus live, masques).
                -- Releve joueur (pull a 14'08) -> offsets depuis le pull :
                --   Drain Fluids     5 / 40 / 79 / 111 / 146  -> (146-5)/4 = 35.25  ** period **
                --   Burn Corruption  20 / 52 / 94 / 161       (un recast ~127 manque au releve)
                --   Awakening Slam   30 / 125                 | Entomb 65 / 134 (~69, soit 2 cycles)
                -- (l'ancien period 32.6 du devscan etait trop court.)
                -- PLAN (choix joueur) : Drain Fluids + Burn Corruption + Awakening Slam. Entomb reste
                -- reconnu mais MASQUE. Il faut DEUX phases car les sorts ne partagent pas un cycle :
                --   * Burn Corruption suit bien le cycle 35.25 -> event de "Rotation" a +15.
                --     Offsets recalcules par base de cycle (5 / 40.25 / 75.5 / 110.75 / 146) :
                --     +15 / +11.75 / +18.5 / (+16.25) / +15  -> moyenne ~15, jitter +-3.5 s.
                --   * Awakening Slam NON : mesure a 30 puis 125, soit 95 s = 2.7 cycles. Il a donc
                --     sa PROPRE phase (firstAt 30, period 95).
                --     ⚠️ 95 ne repose que sur DEUX observations -> a reconfirmer sur un pull plus long.
                -- NB : 2 phases => les instances des deux sont fusionnees puis numerotees par ordre de
                -- debut (GenerateFromPhases), donc les separateurs "Phase N" de l'editeur s'intercalent.
                { name = "Rotation", firstAt = 5, period = 35.25, events = {
                    { spellID = 267618,  name = "Drain Fluids",    at = 0,  cast = 0, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, allowedInPlan = true, allowInTimeline = true },
                    { spellID = 1311956, name = "Burn Corruption", at = 15, cast = 0, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, allowedInPlan = true, allowInTimeline = true },
                } },
                { name = "Awakening Slam", firstAt = 30, period = 95, events = {
                    { spellID = 1312146, name = "Awakening Slam", at = 0, cast = 0, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, allowedInPlan = true, allowInTimeline = true },
                } },
            }, abilities = {
                -- ⚠️ 12.1 : refonte complete des durees (+ un sort de plus, Awakening Slam). Les durees
                -- d'OUVERTURE et de CYCLE different : ouverture 5/20/30/60, cycle 32/30/-/60.
                { spellID = 267618,  name = "Drain Fluids",    durations = { 5, 32 } }, -- ouverture 5 / cycle 32
                { spellID = 1311956, name = "Burn Corruption", durations = { 20, 30 } }, -- ouverture 20 / cycle 30
                { spellID = 1312146, name = "Awakening Slam",  durations = { 30 } },     -- ouverture seulement (partage 30 avec Burn Corruption)
                { spellID = 267702,  name = "Entomb",          durations = { 60 },     allowInTimeline = false }, -- EXCLURE
            }, durationGroups = {
                -- dur 30 : SEUIL, pas cycle. Le 1er 30 du combat est Awakening Slam (ouverture) ;
                -- tous les suivants sont le recast de Burn Corruption.
                [30] = { kind = "threshold", first = 1312146, rest = 1311956 },
            } },
            { id = 2140, name = "The Council of Tribes", enable = false, -- combat de conseil health-gated a 3
                -- phases (transitions non-timeables, sorts qui se chevauchent) -> grise en config, mode BRUT
                -- runtime (aucun matching, affiche tout au fil de l'eau via l'icone/nom serveur).
                abilities = {} },
            { id = 2143, name = "King Dazar", phaseTransitions = { [9] = 2 },
                durationGroups = { [10] = { 269230, 269369 } }, -- P1 : dur 10 = recast partage, cycle n1 Hunting Leap, n2 Deathly Roar
                phases = {
                -- Boss a 2 phases (hard cycles). On ne PLANIFIE QUE la P2 : frise demarre ~1 min apres le
                -- pull (firstAt=60), period 35 s (verifie sur 3 pulls). Quaking Leap (dur 9) = marqueur
                -- d'entree P2 -> phaseTransitions (loggue [rt] phase -> 2). INCLURE (plan) : Quaking Leap +
                -- Gilded Destruction. La P1 est desormais MODELISEE en abilities `phase = 1` (display-only,
                -- allowedInPlan=false) pour l'affichage runtime, PAS pour le plan (GenerateFromPhases ne lit
                -- que `phases`). Le tag de phase departage les durees ambigues entre P1 et P2 :
                --   * Blade Combo : dur 23 (P1) vs dur 38 (P2) ; Gilded Destruction : dur 30 (P1) vs dur 24 (P2).
                -- Gilded Destruction P1 partage son NOM avec l'occurrence planifiee P2 -> allowedInPlan=false
                -- + garde `planOk` (Matcher) empechent son lien plan (sinon fuite du defensif P2 en P1).
                -- spellID (P1 + P2) confirmes via /ecp journal (12.1.0).
                -- Offset P2 mesure au devscan (12.1) : Quaking Leap a 32.8 puis Gilded Destruction a
                -- 47.8 -> at = 15. ⚠️ L'entree en P2 est health-gated (32.8 s sur ce pull, ~60 s sur les
                -- precedents) : firstAt reste une approximation, le runtime recale via phaseTransitions[9].
                -- Releve joueur, repere t0 = ENTREE EN P2 (pas le pull) -> offsets depuis t0 :
                --   Quaking Leap 8 / 55 / 102 | Gilded Destruction 23 / 70
                --   Savage Maul 35 / 82       | Blade Combo 37 / 84
                -- => period 47 EXACTE (4 sorts x 2 intervalles, tous a 47 ; l'ancien 35 etait faux) et
                -- at = 15 pour Gilded Destruction CONFIRME (23-8 = 70-55 = 15). Offsets des 2 sorts
                -- exclus, pour memoire : Savage Maul +27, Blade Combo +29 apres le Quaking Leap.
                -- firstAt (delai pull -> entree P2) non mesure par ce releve -> inchange.
                { name = "P2", firstAt = 60, period = 47, events = {
                    { spellID = 1303327, name = "Quaking Leap",       at = 0, cast = 3,   defMarker = { mode = "AFTER_CAST_END", offset = 0 },             allowedInPlan = true, allowInTimeline = true },
                    { spellID = 1303267, name = "Gilded Destruction", at = 15, cast = 5.5, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, aoe = true, allowedInPlan = true, allowInTimeline = true },
                } },
            }, abilities = {
                -- P1 (phase 1) : cycle ~44 s, sorts affiches en runtime mais NON planifies (allowedInPlan=false).
                { spellID = 269230, name = "Hunting Leap",       durations = { 8, 10 },  phase = 1, allowedInPlan = false, allowInTimeline = true }, -- opener dur 8 puis recast dur 10
                { spellID = 269369, name = "Deathly Roar",       durations = { 14, 10 }, phase = 1, allowedInPlan = false, allowInTimeline = true }, -- opener dur 14 puis recast dur 10
                { spellID = 1303115, name = "Aerial Smash",       durations = { 15 },     phase = 1, allowedInPlan = false, allowInTimeline = true },
                { spellID = 268586,  name = "Blade Combo",        durations = { 23 },     phase = 1, allowedInPlan = false, allowInTimeline = true }, -- P1 : dur 23 (cf. dur 32 en P2)
                { spellID = 1303267, name = "Gilded Destruction", durations = { 30 },     phase = 1, allowedInPlan = false, allowInTimeline = true }, -- P1 opener : dur 30 (cf. dur 18 en P2) ; display-only, pas de lien plan
                -- P2 (phase 2)
                { spellID = 1303327, name = "Quaking Leap",       durations = { 9 },  phase = 2 },  -- marqueur entree P2 (phaseTransitions[9]=2)
                { spellID = 1303267, name = "Gilded Destruction", durations = { 24 }, phase = 2 },  -- P2 cycle (planifie)
                { spellID = 1303488, name = "Savage Maul",        durations = { 36 }, phase = 2, allowInTimeline = false }, -- P2
                { spellID = 268586,  name = "Blade Combo",        durations = { 38 }, phase = 2, allowInTimeline = false }, -- P2 cycle
            } },
        },
    },
    { id = "THE_BLINDING_VALE",    name = "The Blinding Vale",    abbr = "TBV", icon = 7478534, zoneID = 2859, -- mapID 584
        trash = {},
        bosses = {
            { id = 3199, name = "Lightblossom Trinity", phases = {
                -- Timeline observee en jeu (pull t0) : cycle de 45 s. Bedrock Slam toujours avant Lightblossom Beam.
                -- Releve joueur (pull a 6'40) -> CONFIRME le modele au sort pres, rien a changer :
                --   Bedrock Slam 5 / 50 / 95 | Lightsower Dash 20 / 65 / 110
                --   Lightblossom Beam 35 / 80 | Thornblade 8
                -- => +45 exact sur les 3 sorts recurrents ; firstAt 5 et at 30 confirmes, ainsi que
                -- l'ordre du durationGroups (Bedrock +0, Thornblade +3, Lightsower Dash +15).
                { name = "Rotation", firstAt = 5, period = 45, events = {
                    { spellID = 1234753, name = "Bedrock Slam",      at = 0,  cast = 3, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, allowedInPlan = true, allowInTimeline = true },
                    { spellID = 1235564, name = "Lightblossom Beam", at = 30, cast = 3, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, allowedInPlan = true, allowInTimeline = true },
                } },
            }, durationGroups = { [45] = { 1234753, 1235640, 1234850 } }, -- devscan : cycle 45s partage, ordre n1 Bedrock Slam (+0), n2 Thornblade (+3), n3 Lightsower Dash (+15)
                abilities = {
                    { spellID = 1234753, name = "Bedrock Slam",         durations = { 5, 45 } },  -- opener 5, cycle 45
                    { spellID = 1234850, name = "Lightsower Dash",      durations = { 20, 45 } }, -- journal ; affichage seul ; opener 20, cycle 45
                    { spellID = 1234802, name = "Fertile Loam" },
                    { spellID = 1235564, name = "Lightblossom Beam",    durations = { 35, { 43.5, tol = 1.1 } } }, -- opener 35 ; cycle a duree variable (42.6-44.4) -> fenetre elargie
                    { spellID = 1235828, name = "Light-Scorched Earth" },
                    { spellID = 1235640, name = "Thornblade",           durations = { 8, 45 } }, -- affichage seul ; opener 8, cycle 45
                },
            },
            { id = 3200, name = "Ikuzz the Light Hunter", phases = {
                -- Releve joueur (pull a 11'15) -> RESOUT les deux inconnues de ce boss :
                --   Thorncaller Roar   22 / 87 / 152   -> +65 EXACT (2 intervalles)
                --   Bloodthirsty Gaze  50 / 115        -> +65 EXACT
                --   Verdant Stomp      6 / 35 / 64 puis 127 / 164
                -- (1) period = 65. Les anciens devscans donnaient 59.8 et 56.1 (d'ou l'ex-moyenne
                --     57.95) ; ils etaient fausses par l'hypothese "2 Stomp par cycle" ci-dessous.
                --     Ici DEUX sorts independants donnent 65 sur 4 intervalles, sans un ecart.
                -- (2) Verdant Stomp caste 3x PAR CYCLE, a +0 / +29 / +58 (et non 2x a +0/+30.1) :
                --     c'est ce qui expliquait les "6 annonces sur 2 cycles pour 4 prevues".
                --     Cycle 1 mesure a 6/35/64 = les 3 offsets exacts. Les 2 releves suivants
                --     recoupent : 127 (cycle 2 +58 = 129) et 164 (cycle 3 +29 = 165), a ~2 s.
                -- Offset du sort display-only, pour memoire : Bloodthirsty Gaze +44.
                { name = "Rotation", firstAt = 6, period = 65, events = {
                    { spellID = 1236746, name = "Verdant Stomp",    at = 0,  cast = 3, defMarker = { mode = "AFTER_CAST_END", offset = -2000 }, allowedInPlan = true, allowInTimeline = true },
                    { spellID = 1236709, name = "Thorncaller Roar", at = 16, cast = 2, defMarker = { mode = "AFTER_CAST_END", offset = 0 },     allowedInPlan = true, allowInTimeline = true },
                    { spellID = 1236746, name = "Verdant Stomp",    at = 29, cast = 3, defMarker = { mode = "AFTER_CAST_END", offset = -2000 }, allowedInPlan = true, allowInTimeline = true },
                    { spellID = 1236746, name = "Verdant Stomp",    at = 58, cast = 3, defMarker = { mode = "AFTER_CAST_END", offset = -2000 }, allowedInPlan = true, allowInTimeline = true },
                } },
            }, abilities = {
                    { spellID = 1236746, name = "Verdant Stomp",    durations = { 6, 29 } },
                    { spellID = 1236709, name = "Thorncaller Roar", durations = { 22 } },
                    { spellID = 1237090, name = "Bloodthirsty Gaze", durations = { 50 } }, -- spellID journal (ex-1237091) ; affichage seul
                    { spellID = 1237267, name = "Incise" },
                    { spellID = 1272290, name = "Crunched" },
                },
            },
            { id = 3201, name = "Lightwarden Ruia", enable = false, -- combat a phases en % (non modelable en timeline temps) -> mode brut runtime
                abilities = { -- private-auras, durees a confirmer via /hp gather
                    { spellID = 1239825, name = "Lightfire" },
                    { spellID = 1239919, name = "Lightfire Beams" },
                    { spellID = 1241058, name = "Grievous Thrash" },
                    { spellID = 1251345, name = "Blight Resin" },
                    { spellID = 1257094, name = "Pulverized" },
                },
            },
            { id = 3202, name = "Ziekket", phases = {
                -- Timeline devscan (M+, 12.1) : cycle de 50 s (confirme sur 6 occurrences).
                -- Ouvertures relevees : Awaken 4, Lightbloom's Essence 14, Thornspike 26,
                -- Concentrated Lightbeam 40.
                -- Releve joueur (pull a 23'39) -> CONFIRME, rien a changer :
                --   Awaken 3 / 53 / 103 | Lightbloom's Essence 13 / 63 / 113
                --   Thornspike 26 / 75 / 126 | Concentrated Lightbeam 41 / 90 / 139
                -- => +50 sur les 4 sorts (3 occurrences chacun) ; firstAt 4 et at 10 confirmes.
                -- Offsets des 2 sorts display-only, pour memoire : Thornspike +22, Lightbeam +37.
                { name = "Rotation", firstAt = 4, period = 50, events = {
                    { spellID = 1246372, name = "Awaken the Lightbloom", at = 0,  cast = 3, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, allowedInPlan = true, allowInTimeline = true },
                    { spellID = 1246858, name = "Lightbloom's Essence",  at = 10, cast = 2, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, allowedInPlan = true, allowInTimeline = true },
                } },
            }, durationGroups = {
                -- dur 50 = timer de cycle PARTAGE par les 4 sorts, dans l'ordre de la rotation
                -- (confirme sur 6 occurrences consecutives : 54/64/76/90/104/114).
                [50] = { 1246372, 1246858, 1247746, 1246751 },
                [41] = { 1246372, 1246751 },
            },
                abilities = {
                    { spellID = 1246372, name = "Awaken the Lightbloom", durations = { 4, 41, 50 } },
                    { spellID = 1246858, name = "Lightbloom's Essence",  durations = { 14, 37, 50 } },
                    { spellID = 1246751, name = "Concentrated Lightbeam", durations = { 40, 41 } }, -- affichage seul
                    { spellID = 1246753, name = "Lightsap" },
                    { spellID = 1247746, name = "Thornspike",            durations = { 26, 35 } }, -- affichage seul
                },
            },
        },
    },
    { id = "VOIDSCAR_ARENA",       name = "Voidscar Arena",       abbr = "VA",  icon = 7479112, zoneID = 2923, -- mapID 585
        trash = {},
        bosses = {
            { id = 3285, name = "Taz'rah", phases = {
                -- Timeline devscan (M+, 12.1) : cycle 35.1 s, confirme par les QUATRE sorts.
                -- Releve joueur (pull a 6'20) -> offsets depuis le pull, 2 cycles :
                --   Nether Dash 6 / 41 | Umbral Rupture 17 / 52 | Void Blast 25 / 60 | Dark Bloom 31 / 66
                -- => intervalle 35.0 EXACT sur les 4 sorts -> period 35 (le 35.1 du devscan derivait
                -- d'une seconde tous les 10 cycles). firstAt 6 et at 25 (Dark Bloom) confirmes.
                { name = "Rotation", firstAt = 6, period = 35, events = {
                    { spellID = 1222098, name = "Nether Dash", at = 0,  cast = 0, defMarker = { mode = "AFTER_CAST_END", offset = 10000 }, allowedInPlan = true, allowInTimeline = true },
                    { spellID = 1300259, name = "Dark Bloom",  at = 25, cast = 4, defMarker = { mode = "AFTER_CAST_END", offset = -2000 }, allowedInPlan = true, allowInTimeline = true },
                } },
            }, abilities = {
                    { spellID = 1222098, name = "Nether Dash",    durations = { 6 } },
                    { spellID = 1300259, name = "Dark Bloom",     durations = { 31 } }, -- spellID journal ; devscan : 4e sort du cycle @t31 (dur 31, pas 27/28)
                    { spellID = 1296963, name = "Umbral Rupture", durations = { 16 } }, -- journal ; affichage seul (pas de defensif)
                    { spellID = 1297017, name = "Void Blast",     durations = { 25 } }, -- journal ; affichage seul (pas de defensif)
                },
                -- Nether Dash : cast 0 mais hit 10 s plus tard (defMarker +10000).
            },
            { id = 3286, name = "Atroxus", phases = {
                -- Timeline devscan (M+, 12.1) : cycle 50 s CONFIRME sur les 4 sorts (2 cycles chacun) ;
                -- Poison Splash 2x/phase (+0, +20). Offsets et durationGroups[20] valides au scan.
                -- Releve joueur (pull a 13'40), 3 cycles -> CONFIRME le modele, rien a changer :
                --   Poison Splash    5 / 25 | 55 / 75 | 105 / 125   (at 0 et 20, +50 exact)
                --   Monstrous Roar   35 | 85 | 135                  (at 30, +50 exact)
                -- Les 2 sorts display-only tournent aussi sur le cycle 50, 2x chacun (pour memoire) :
                --   Hulking Claw     9 / 29 | 59 / 79 | 109 / 129   (soit +4 et +24 du debut de cycle)
                --   Noxious Breath   15 / 45 | 65 / 95 | 115 / 155  (soit +10 et +40 ; le dernier
                --                    releve a 155 vaut 145 = +50 du precedent, les 5 autres sont nets)
                { name = "Rotation", firstAt = 5, period = 50, events = {
                    { spellID = 1226120, name = "Poison Splash",  at = 0,  cast = 3, defMarker = { mode = "AFTER_CAST_START", offset = 0 },     allowedInPlan = true, allowInTimeline = true },
                    { spellID = 1226120, name = "Poison Splash",  at = 20, cast = 3, defMarker = { mode = "AFTER_CAST_START", offset = 0 },     allowedInPlan = true, allowInTimeline = true },
                    { spellID = 1262497, name = "Monstrous Roar", at = 30, cast = 3, defMarker = { mode = "AFTER_CAST_END",   offset = -1000 }, allowedInPlan = true, allowInTimeline = true },
                } },
            }, durationGroups = { [20] = { 1226120, 1222642 } }, -- duree 20 partagee : n1 Poison Splash (toujours 1er), n2 Hulking Claw
                abilities = {
                    { spellID = 1222642, name = "Hulking Claw",     durations = { 10, 20 } }, -- affichage seul
                    { spellID = 1222721, name = "Noxious Breath",   durations = { 15, 30 } }, -- affichage seul ; devscan : 2 souffles @15s et @45s (dur 30, pas 28)
                    { spellID = 1226120, name = "Poison Splash",    durations = { 5, 20 } },
                    { spellID = 1262497, name = "Monstrous Roar",   durations = { 35 } }, -- spellID journal
                    { spellID = 1222484, name = "Poison Pool" },      -- hors journal actuel
                    { spellID = 1263971, name = "Lingering Poison" }, -- hors journal actuel
                },
            },
            { id = 3287, name = "Charonus", phases = {
                -- Timeline devscan (M+, 12.1) : TROIS cycles complets. Period 52.95 s, confirme par les
                -- CINQ sorts (Unstable Singularity 5/57.9/110.9 ; Cosmic Crash 17/69.9/122.9 ; Gravitic
                -- Orbs 28/80.9/133.9 ; Dark Waves 34/86.9/139.9 ; Void Cascade 43/95.9/148.9).
                -- period = l'intervalle 2->3 (53.0), l'intervalle 1->2 (52.9) pouvant etre biaise
                -- par un pull tombant en milieu de phase.
                -- Releve joueur (pull a 22'27) -> CONFIRME le modele, rien a changer :
                --   Unstable Singularity 5 / 58 | Cosmic Crash 17 / 70 | Gravitic Orbs 28 / 81
                --   Dark Waves 34 / 88 | Void Cascade 44 / 97
                -- => +53 sur 4 sorts sur 5 (Dark Waves a +54) ; firstAt 5 et at 12 confirmes.
                { name = "Rotation", firstAt = 5, period = 53, events = {
                    { spellID = 1282770, name = "Unstable Singularity", at = 0,  cast = 6,   defMarker = { mode = "AFTER_CAST_END", offset = 0 },     allowedInPlan = true, allowInTimeline = true },
                    { spellID = 1227264, name = "Cosmic Crash",         at = 12, cast = 4.5, defMarker = { mode = "AFTER_CAST_END", offset = -1000 }, allowedInPlan = true, allowInTimeline = true },
                } },
            }, abilities = {
                    { spellID = 1282770, name = "Unstable Singularity", durations = { 5 } },
                    { spellID = 1227264, name = "Cosmic Crash",         durations = { 17 } },
                    { spellID = 1263982, name = "Gravitic Orbs",        durations = { 28 } }, -- affichage seul
                    { spellID = 1222755, name = "Void Cascade",         durations = { 43 } }, -- affichage seul
                    { spellID = 1311923, name = "Dark Waves",           durations = { 34 } }, -- affichage seul
                    { spellID = 1264188, name = "Event Horizon" }, -- hors journal actuel, pas dans la liste courante
                },
            },
        },
    },
    { id = "DEN_OF_NALORAKK",      name = "Den of Nalorakk",      abbr = "DON", icon = 7478536, zoneID = 2825, -- mapID 586
        trash = {},
        bosses = {
            { id = 3207, name = "The Hoardmonger", phases = {
                -- Releve joueur (pull a 5'01) -> offsets depuis le pull, 3 cycles :
                --   Ravenous Bellow   7 / 46 / 87   | Earthshatter Slam 17 / 56 / 97
                --   Spoiled Supplies 31 / 71 / 110
                -- => period 40 (les 3 sorts donnent 40 / 40 / 39.5 ; l'ancien 41 derivait).
                -- Offsets internes CONFIRMES : Slam +10 et Supplies +24 apres Ravenous Bellow.
                { name = "Rotation", firstAt = 6, period = 40, events = {
                    { spellID = 1235118, name = "Ravenous Bellow",  at = 0,  cast = 3, defMarker = { mode = "AFTER_CAST_END",   offset = -1000 }, allowedInPlan = true, allowInTimeline = true },
                    { spellID = 1234233, name = "Spoiled Supplies", at = 24, cast = 6, defMarker = { mode = "AFTER_CAST_START", offset = 0 },     allowedInPlan = true, allowInTimeline = true },
                } },
            }, abilities = {
                    { spellID = 1235118, name = "Ravenous Bellow",  durations = { 6 } },
                    { spellID = 1253268, name = "Earthshatter Slam", durations = { 16 } }, -- affichage seul (offset ~10)
                    { spellID = 1234233, name = "Spoiled Supplies", durations = { 30 } },
                },
            },
            { id = 3208, name = "Sentinel of Winter", phases = {
                -- Timeline devscan (M+) : Frozen Tempest = event serveur duree 50 (@50/113s). dur 61 (@68s) et dur 63 = a nommer.
                -- Releve joueur (pull a 16'28) -> offsets depuis le pull, 2 cycles :
                --   Glacial Torment 7 / 70 | Raging Squall 12 / 76
                --   Shattering Frostspike 24 / 88 | Frozen Tempest 49 / 113
                -- => period 63.75 (intervalles 63 / 64 / 64 / 64). Le releve porte un biais systematique
                -- de ~1 s (Squall et Frostspike tombent a -1 de leur `at`) -> `at` 6 et 18 conserves ;
                -- seul Frozen Tempest sort du biais (mesure a +42 puis +43 du Torment, modele 45) -> 43.
                -- PLAN RESTREINT (choix joueur) : Glacial Torment + Frozen Tempest. Raging Squall
                -- (+6) et Shattering Frostspike (+18) restent reconnus mais MASQUES.
                { name = "Rotation", firstAt = 7, period = 63.75, events = {
                    { spellID = 1235548, name = "Glacial Torment",       at = 0,  cast = 1, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, allowedInPlan = true,  allowInTimeline = true },
                    { spellID = 1235656, name = "Frozen Tempest",        at = 43, cast = 4, defMarker = { mode = "AFTER_CAST_END", offset = 0 }, allowedInPlan = true,  allowInTimeline = true }, -- = event serveur duree 50
                } },
            }, abilities = {
                    { spellID = 1235548, name = "Glacial Torment",       durations = { 7 } },
                    { spellID = 1235623, name = "Raging Squall",         durations = { 13 }, allowInTimeline = false }, -- EXCLURE
                    { spellID = 1235783, name = "Shattering Frostspike", durations = { 25 }, allowInTimeline = false }, -- EXCLURE
                    { spellID = 1235656, name = "Frozen Tempest",        durations = { 50 } }, -- devscan @50s/113s (video : c'est LUI le Frozen Tempest, pas la dur 61)
                    -- dur 61 (@68s) = AUTRE sort a nommer ; dur 63 = non identifie (a nommer)
                },
            },
            { id = 3209, name = "Nalorakk", phases = {
                -- Timeline observee en jeu (pull t0) : cycle 65 s. Echoing Maul & Overwhelming Onslaught 2x/cycle.
                -- Releve joueur (pull a 25'13) -> CONFIRME le modele en place, rien a changer :
                --   Echoing Maul 5 / 30 puis 70 / 95 (at 0 et 25, +65 exact)
                --   Overwhelming Onslaught 12 / 38 puis 78 / 103 (at 8 et 32, a ~1 s pres)
                --   Fury of the War God 55 puis 120 (at 49, mesure 50 ; +65 exact)
                { name = "Rotation", firstAt = 5, period = 65, events = {
                    { spellID = 1242860, name = "Echoing Maul",           at = 0,  cast = 4, defMarker = { mode = "AFTER_CAST_END", offset = -1000 }, allowedInPlan = true, allowInTimeline = true },
                    { spellID = 1243569, name = "Overwhelming Onslaught", at = 8,  cast = 7, defMarker = { mode = "AFTER_CAST_END", offset = 0 },     allowedInPlan = true, allowInTimeline = true },
                    { spellID = 1242860, name = "Echoing Maul",           at = 25, cast = 4, defMarker = { mode = "AFTER_CAST_END", offset = -1000 }, allowedInPlan = true, allowInTimeline = true },
                    { spellID = 1243569, name = "Overwhelming Onslaught", at = 32, cast = 7, defMarker = { mode = "AFTER_CAST_END", offset = 0 },     allowedInPlan = true, allowInTimeline = true },
                    { spellID = 1243011, name = "Fury of the War God",    at = 49, cast = 0, defMarker = { mode = "AFTER_CAST_END", offset = 0 },     allowedInPlan = true, allowInTimeline = true }, -- cast/marker non fournis -> defaut
                } },
            }, durationGroups = { [25] = { 1242860, 1243569 } }, -- duree 25 partagee : n1 Echoing Maul (offset 25), n2 Overwhelming Onslaught (offset 33)
                abilities = {
                    { spellID = 1242860, name = "Echoing Maul",           durations = { 5, 25 } },  -- devscan (etait 5,33)
                    { spellID = 1243569, name = "Overwhelming Onslaught", durations = { 13, 25 } },
                    { spellID = 1243011, name = "Fury of the War God",    durations = { 54 } },
                },
            },
        },
    },
    { id = "MURDER_ROW",           name = "Murder Row",           abbr = "MR",  icon = 7467179, zoneID = 2813, -- mapID 587
        trash = {},
        bosses = {
            { id = 3101, name = "Kystia Manaheart", enable = false, -- desactive -> grise en config, mode brut runtime
                abilities = { -- durees devscan + spellID journal (2679)
                    { spellID = 1253811, name = "Fel Spray",         durations = { 8, 27.5 } },
                    { spellID = 474240,  name = "Fel Nova",          durations = { 12 } },
                    { spellID = 1264095, name = "Mirror Images",     durations = { 15, 30 } },
                    { spellID = 1228198, name = "Corroding Spittle" }, -- private aura
                },
            },
            { id = 3102, name = "Zaen Bladesorrow", phases = {
                -- Cycle 43 s. Same-Day Delivery 2x/cycle (a +4 et +20).
                -- Cast/marker fournis pour Killing Spree seulement ; le reste = defaut (cast 0, au trigger).
                -- Releve joueur (pull a 10'56) -> offsets depuis le pull, 2 cycles :
                --   Killing Spree 8 / 51 | Same-Day Delivery 12 / 28 puis 55 / 70
                --   Fire Bomb 18 / 61 | Envenom 26 / 69 | Murder in a Row 36 / 79
                -- => +43 sur les 5 sorts (l'ancien 42 derivait). TOUS les `at` confirmes au sort pres :
                -- Killing Spree 0, Same-Day Delivery 4 et 20, Murder in a Row 28.
                -- Offsets des 2 sorts display-only, pour memoire : Fire Bomb +10, Envenom +18.
                -- PLAN RESTREINT (choix joueur) : Killing Spree + Murder in a Row. Fire Bomb et
                -- Envenom n'etaient deja pas planifies ; Same-Day Delivery (+4/+20) les rejoint en
                -- reconnu-mais-MASQUE.
                { name = "Rotation", firstAt = 8, period = 43, events = {
                    { spellID = 474478,  name = "Killing Spree",     at = 0,  cast = 0, defMarker = { mode = "AFTER_CAST_START", offset = 0 }, allowedInPlan = true, allowInTimeline = true },
                    { spellID = 1218347, name = "Murder in a Row",   at = 28, cast = 0, defMarker = { mode = "AFTER_CAST_END",   offset = 0 }, allowedInPlan = true, allowInTimeline = true },
                } },
            }, abilities = {
                    { spellID = 474478,  name = "Killing Spree",      durations = { 8 } },
                    { spellID = 474765,  name = "Same-Day Delivery",  durations = { 12, 16 }, allowInTimeline = false }, -- EXCLURE
                    { spellID = 1214357, name = "Fire Bomb",          durations = { 18 }, allowInTimeline = false },     -- EXCLURE
                    { spellID = 1222795, name = "Envenom",            durations = { 26 }, allowInTimeline = false },     -- EXCLURE
                    { spellID = 1218347, name = "Murder in a Row",    durations = { 36 } },
                },
            },
            { id = 3103, name = "Xathuux the Annihilator", phases = {
                -- Les trois offsets (0 / 15 / 20) sont confirmes au scan sur deux pulls, PUIS par le
                -- releve joueur (pull a 20'44) : Axe Toss 16 / 72, Infernal Crush 30 / 87 (= +15),
                -- Demonic Rage 35 / 92 (= +20). Legion Strike (display-only) caste 2x/cycle, a -9 et
                -- +18 de l'Axe Toss : 7 / 34 puis 63 / 91.
                -- ⚠️ PERIODE NON REPRODUCTIBLE : 54.3 s sur un pull, 56.9 s sur un autre, 56.7 s au
                -- releve joueur (mesure a chaque fois sur plusieurs sorts independants). Les DEUX
                -- derniers releves concordent a 0.25 s pres -> period = 56.7 (le 54.3 fait figure
                -- d'aberration). Erreur residuelle possible ~1 s par cycle si le 54.3 etait bon.
                { name = "Rotation", firstAt = 15, period = 56.7, events = {
                    { spellID = 1214637, name = "Axe Toss",       at = 0,  cast = 3, defMarker = { mode = "AFTER_CAST_END", offset = 0 },     allowedInPlan = true, allowInTimeline = true },
                    { spellID = 1295453, name = "Infernal Crush", at = 15, cast = 3, defMarker = { mode = "AFTER_CAST_END", offset = 0 },     allowedInPlan = true, allowInTimeline = true },
                    { spellID = 474197,  name = "Demonic Rage",   at = 20, cast = 4, defMarker = { mode = "AFTER_CAST_END", offset = -2000 }, allowedInPlan = true, allowInTimeline = true },
                } },
            }, abilities = {
                    { spellID = 1214637, name = "Axe Toss",       durations = { 15 } },
                    { spellID = 1295453, name = "Infernal Crush", durations = { 30 } },
                    { spellID = 474197,  name = "Demonic Rage",   durations = { 35 } },
                    { spellID = 473898,  name = "Legion Strike",  durations = { 6, 27 } }, -- timer event (affichage runtime) ; pas de defensif (pas de cast timer)
                    { spellID = 474234,  name = "Burning Steps" },
                    { spellID = 1214650, name = "Fel Lightning" }, -- journal (ex-"Fel Light")
                },
            },
            { id = 3105, name = "Lithiel Cinderfury", phases = { -- ID saute 3104
                -- Timeline devscan : Fingers of Gul'dan plannable (opener t15 puis t71/127, cycle ~56 s ;
                -- recontrole en 12.1 : 15 -> 70.7, soit 55.7 s).
                -- Releve joueur (pull a 28'33) : Fingers of Gul'dan 15 / 71 / 126 -> 55.5 s.
                -- => TROIS mesures concordantes (56 / 55.7 / 55.5) -> period 55.7. firstAt 15 confirme.
                -- Les 2 sorts display-only ont leur PROPRE timer et derivent (pour memoire) :
                --   Summon Vilefiend 10 / 68 / 126 (58 s) | Malefic Wave 24 / 84 / 139 (60 puis 55)
                -- NB : Vilefiend (58 s) et Fingers (55.5 s) se rapprochent de ~2.5 s par cycle -> ils
                -- tombent au MEME temps au 3e (126). Coincidence VERIFIEE, pas une erreur de releve.
                { name = "Rotation", firstAt = 15, period = 55.7, events = {
                    { spellID = 1218203, name = "Fingers of Gul'dan", at = 0, cast = 5, defMarker = { mode = "AFTER_CAST_END", offset = -2000 }, allowedInPlan = true, allowInTimeline = true },
                } },
            }, abilities = {
                    { spellID = 1218203, name = "Fingers of Gul'dan", durations = { 15, 55 } },
                    { spellID = 474408,  name = "Summon Vilefiend",   durations = { 10, 57 } }, -- affichage seul, pas de defensif
                    { spellID = 1224478, name = "Malefic Wave",       durations = { 24, 59 } }, -- affichage seul
                },
            },
        },
    },
}

-- Selecteur : cle = version COMPLETE (patch-exact). Au prochain build cible, ajouter
-- son entree ici. Repli `or HR.content` : tout build non liste garde la data ci-dessus.
HR.contentByVersion = {
    ["12.0.7"] = HR.content,
    ["12.1.0"] = content_1210,
}
HR.content = HR.contentByVersion[HR.CLIENT_VERSION] or HR.content

-- Un boss est-il actif ? Absent / true => actif ; seul `enable == false` desactive.
function HR.BossEnabled(boss)
    return boss ~= nil and boss.enable ~= false
end

--------------------------------------------------------------------------------
-- Variantes de TIMELINE d'un boss (ex. L'ura : "4-1-1" / "4-2"). Un boss peut se
-- jouer de plusieurs facons => plusieurs structures de phases. Le joueur en choisit
-- une (selecteur UI) ; les plans des 2 coexistent (cles d'occurrence prefixees par
-- la variante, cf. Planner.NumberOccurrences), seul l'actif tourne en combat.
--------------------------------------------------------------------------------

-- Liste des variantes de timeline d'un boss, ou nil si le boss n'en a pas.
function HR.GetTimelineVariants(boss)
    if boss and boss.timelineVariants and #boss.timelineVariants > 0 then
        return boss.timelineVariants
    end
    return nil
end

-- Id de la variante de timeline active pour un boss (choix persiste, sinon la 1re).
-- nil si le boss n'a pas de variantes.
function HR.GetActiveTimelineVariantId(boss)
    local variants = HR.GetTimelineVariants(boss)
    if not variants then return nil end
    local saved = HR.db and HR.db.bossTimelineVariant and HR.db.bossTimelineVariant[boss.id]
    if saved then
        for _, v in ipairs(variants) do
            if v.id == saved then return saved end       -- valide que le choix existe encore
        end
    end
    return variants[1].id
end

-- Persiste la variante de timeline active choisie pour un boss.
function HR.SetActiveTimelineVariant(encounterID, id)
    if not HR.db then return end
    HR.db.bossTimelineVariant = HR.db.bossTimelineVariant or {}
    HR.db.bossTimelineVariant[encounterID] = id
end

-- Resout la timeline EFFECTIVE d'un boss : sans variantes => le boss tel quel ; sinon
-- une COPIE superficielle dont `phases`/`abilities` viennent d'une variante, avec un tag
-- `_tlVariant` (utilise par le planner pour prefixer les cles d'occurrence).
-- `overrideVariantId` : variante a resoudre (ex. celle VISUALISEE en config) ; nil =>
-- variante JOUEE (persistee). Le bloc `abilities` duration-only du boss est conserve
-- (matching runtime) si la variante n'en fournit pas. A appeler avant GenerateOccurrences.
function HR.ResolveBossTimeline(boss, overrideVariantId)
    local variants = HR.GetTimelineVariants(boss)
    if not variants then return boss end
    local id = overrideVariantId or HR.GetActiveTimelineVariantId(boss)
    local active = variants[1]
    for _, v in ipairs(variants) do
        if v.id == id then active = v; break end
    end
    local copy = {}
    for k, v in pairs(boss) do copy[k] = v end
    copy.phases        = active.phases
    copy.abilities     = active.abilities or boss.abilities  -- garde le duration-only du boss
    copy._tlVariant    = active.id
    copy.timelineVariants = nil                              -- evite toute reentrance
    return copy
end

-- Boss (et son donjon) a partir d'un encounterID. nil si inconnu.
function HR.GetBossByEncounterID(encounterID)
    for _, dungeon in ipairs(HR.content) do
        for _, boss in ipairs(dungeon.bosses) do
            if boss.id == encounterID then
                return boss, dungeon
            end
        end
    end
end

-- Index du donjon correspondant au `zoneID` (instanceID de GetInstanceInfo).
-- nil si aucun donjon connu ne porte cet instanceID.
function HR.GetDungeonIndexByInstance(instanceID)
    if not instanceID or instanceID == 0 then return nil end
    for i, dungeon in ipairs(HR.content) do
        if dungeon.zoneID == instanceID then
            return i
        end
    end
end

-- Index du donjon ou se trouve actuellement le joueur, via GetInstanceInfo
-- (8e retour = instanceID). nil hors instance ou instance inconnue.
function HR.GetCurrentDungeonIndex()
    local _, _, _, _, _, _, _, instanceID = GetInstanceInfo()
    return HR.GetDungeonIndexByInstance(instanceID)
end

-- Icone d'un donjon : `icon` (fileID explicite) sinon texture du sort de
-- teleportation `iconSpellID`. Repli sur le point d'interrogation.
function HR.GetDungeonIcon(dungeon)
    if dungeon then
        if dungeon.icon then return dungeon.icon end
        if dungeon.iconSpellID and C_Spell and C_Spell.GetSpellTexture then
            local tex = C_Spell.GetSpellTexture(dungeon.iconSpellID)
            if tex then return tex end
        end
    end
    return 134400
end

--------------------------------------------------------------------------------
-- Boss de TEST (invente) : ABSENT de HR.content (n'apparait pas dans l'UI). Utilise
-- uniquement par le mode test (bouton "Start test" des options). La variante associee
-- (HR.testVariant) est regeneree a chaque init (HR.BuildTestVariant) et jamais persistee
-- -> toujours presente, non supprimable, invisible.
--------------------------------------------------------------------------------

HR.TEST_ENCOUNTER_ID = 9000001
local TEST_ABILITY1 = 133   -- "toutes les 10s" : AMZ + petit defensif perso
local TEST_ABILITY2 = 116   -- "toutes les 15s" : aucun CD associe

HR.testBoss = {
    id = HR.TEST_ENCOUNTER_ID, name = "Test Boss",
    abilities = {
        { spellID = TEST_ABILITY1, name = "CAST1", firstAt = 10, period = 10, aoe = true, allowedInPlan = true, allowInTimeline = true },
        { spellID = TEST_ABILITY2, name = "CAST2", firstAt = 15, period = 15,            allowedInPlan = true, allowInTimeline = true },
    },
}

-- (Re)genere la variante de test (en memoire) : Anti-Magic Zone (DK, external) + SMALL_DEF
-- (defensif perso) + un CD de HEAL du joueur s'il en a un (pour demo l'alerte "healer cd"),
-- sur CHAQUE occurrence de la capacite 1.
function HR.BuildTestVariant()
    local boss = HR.testBoss
    -- 1er CD de heal (role=HEALER) utilisable par le joueur courant -> demo de l'alerte healer.
    -- Aucun (= non soigneur) : on ne l'ajoute pas (l'alerte healer ne sonnera pas, "healer only").
    local healCD
    for key, d in pairs(HR.defensives) do
        if d.role == "HEALER" and HR.PlayerCanUseDefensive(d) then healCD = key; break end
    end
    local asg = { [boss.id] = {} }
    for _, o in ipairs(HR.GenerateOccurrences(boss, HR.FIGHT_LENGTH)) do
        if o.spellID == TEST_ABILITY1 then
            -- Entrees { token, offset } (format inline). AMZ decale de +3s (demo de l'offset :
            -- son timer apparait 3 s apres l'appel perso). "51052:0" = cle reelle de l'AMZ.
            local defs = { { token = "51052:0", offset = 3000 }, { token = "SMALL_DEF" } }
            if healCD then defs[#defs + 1] = { token = healCD } end   -- + CD de heal du joueur
            asg[boss.id][o.key] = defs
        end
    end
    HR.testVariant = { id = "test", name = "Test", comp = {}, assignments = asg }
end
