# HealPlanner — guide projet

Addon World of Warcraft pour l'extension **Midnight (patch 12.0.5)**.
But : **planifier l'usage des défensifs de heal** par rapport aux capacités des
boss (quel défensif sur quelle occurrence), avec contrôle de disponibilité selon
le cooldown théorique.

## Cible client

- **Interface : `120005`** (Midnight 12.0.5). Mettre à jour `## Interface:` à
  chaque patch.
- Tester en jeu avec `/reload` après chaque modification `.lua`/`.toc`.
- Activer les erreurs Lua : `/console scriptErrors 1`.

## Structure

```
HealPlanner.toc          # métadonnées + ordre de chargement
Core/
  Constants.lua          # namespace partagé HR, defaults DB, FIGHT_LENGTH (300s)
  Util.lua               # Print/Debug, DeepCopy, ApplyDefaults
  Database.lua           # init SavedVariables (HealPlannerDB / *CharDB)
  Planner.lua            # GenerateOccurrences + IsSpellReady
  Plans.lua              # lecture/écriture des placements du joueur
  BossSettings.lua       # réglages joueur par sort de boss (Activer/nom custom/son),
                         #   store DB par encounterID→spellID ; ApplyBossSpellSettings
                         #   (nom custom + flag) + FilterTimeline + GetBossSpells
  Matcher.lua            # reconnaissance d'un event serveur par sa DURÉE (HR.MatchByDuration :
                         #   cycle/seuil via durationGroups + compteur par durée) + HR.PlanIdFor
                         #   (lien sort reconnu → occurrence du plan, mappé par NOM)
  Core.lua               # OnInitialize, point d'entrée
  Events.lua             # frame d'événements unique + dispatch (multi-handlers)
  Capture.lua            # /hp scan : capture encounterID/zoneID (ENCOUNTER_START)
  Macros.lua             # macros EHP_ /yell des CD externes (init: purge EHP_* + recrée)
  Share.lua              # CODEC de plan (serialisation CBOR->Deflate->Base64, validation,
                         #   assainissement, import). AUCUN transport : le partage par lien a ete
                         #   RETIRE au profit du canal de synchro. Consommateurs : Core/Sync/
                         #   PlanSync.lua et les modales Export/Import de UI/HealerSpecs.lua.
  ForeignBars.lua        # option `hideOtherBossMods` : masque les timers des AUTRES bossmods
                         #   qui font doublon. BigWigs/LittleWigs = message `BigWigs_BarCreated`
                         #   (loader, RegisterMessage avec un POINT) + `bar:Stop()` sur key
                         #   numerique OU barre du plugin Timeline (module/key nil + eventId).
                         #   DBM = callback `DBM_TimerBegin` (PAS `DBM_TimerStart`, supprime)
                         #   + `DBT:CancelBar(id)` sur simpType cd/cast/target. Timeline
                         #   Blizzard = reparent de `EncounterTimeline` (hors combat, seul
                         #   etat stateful -> `FB.Apply`). Pull/break/respawn/stages/custom
                         #   intacts. JAMAIS d'ecriture dans la DB/CVar d'un autre addon.
  Sync/                  # canal de SYNCHRO des plans (prefixe addon `ECPSync`), separe du
                         #   codec de Share.lua. Ordre de chargement impose.
    Bus.lua              #   bus d'evenements INTERNE : `HR.EV` (noms) + `HR.EmitEvent(nom,
                         #   payload)` / `HR.OnEvent(nom, fn)`. pcall par handler (entree reseau).
    Net.lua              #   transport : trame `proto \t kind \t msgId \t seq \t total \t body`,
                         #   file d'envoi 1 msg/frame, reassemblage. En SOLO, `Net.GroupChannel`
                         #   renvoie **nil** (l'appelant refuse : rien a pousser) -- l'echo local
                         #   (message addon adresse a soi-meme, qui exerce toute la chaine sans
                         #   second client) ne subsiste que sous `HR.debug`, sinon on se creait un
                         #   doublon `SYNC` de son propre plan. `Net.HasAudience()` = etat du bouton
                         #   Sync cote UI. Canal : categorie
                         #   `LE_PARTY_CATEGORY_HOME` UNIQUEMENT (RAID/PARTY) -- un groupe de FILE
                         #   (donjon aleatoire/LFR) est hors perimetre : on ne pousse pas un plan
                         #   auto-importe a des inconnus. La categorie est passee EXPLICITEMENT :
                         #   `IsInGroup()` nu repond oui pour un groupe de file, et le serveur
                         #   jetterait alors le message PARTY sans erreur.
                         #   `msgId` = `<royaume+5 hex du GUID>:<compteur DB>` :
                         #   racine STABLE entre sessions (GetTime repartait a zero) + compteur qui
                         #   separe deux poussees successives (sinon l'accuse de l'une valide
                         #   l'autre). Le GUID entier n'est PAS transporte : l'entete voyage sur
                         #   CHAQUE morceau et un message addon est plafonne a 255 o -> la taille
                         #   utile est CALCULEE depuis l'entete reel (CHUNK 220 = plafond).
    PlanSync.lua         #   message `PLAN` : le bouton Sync pousse la variante affichee ; chez le
                         #   destinataire elle est importee SANS clic et posee ACTIVE. Cible d'ecriture
                         #   bornee par l'index `db2.syncImports[dID]["<emetteur>:<id distant>"]` ->
                         #   variante locale (les id sont des compteurs LOCAUX : ecrire a l'id brut
                         #   detruirait un plan personnel). Autodelete 24h comme l'import manuel.
    Handshake.lua        #   HELLO / HELLO_ACK : qui a l'addon, en quelle version. Reponse sur le
                         #   canal ADDON adressee a l'emetteur (invisible dans le chat). Affichage
                         #   IMMEDIAT de chaque reponse, fermeture a T+5s qui liste les `no addon`
                         #   (reponse hors passe = `(late)`). Etat VOLATILE (`HR.Sync.roster`).
    Listeners.lua        #   SEUL site d'enregistrement de listeners du canal (RegisterEvent +
                         #   OnEvent). Ignore ses propres messages sauf echo solo / debug.
  Keybind.lua            # raccourci clavier d'ouverture (action `ECPLANNER_OPEN`, defaut **ALT-P**).
                         #   Declare dans `Bindings.xml` (RACINE de l'addon, charge tout seul par
                         #   le client : **jamais** dans le .toc). Globales exigees par le client :
                         #   `BINDING_NAME_ECPLANNER_OPEN` (libelle de la ligne) et
                         #   `EiikoCooldownPlanner_OnKeybind` (le corps d'un <Binding> ne voit que
                         #   `_G` -- meme statut que `HealPlanner_OnAddonCompartmentClick`).
                         #   ⚠️ Le GROUPE du menu Touches = attribut `category` du XML, resolu en
                         #   `_G[category]` avec repli sur la chaine brute -> on y met le nom de
                         #   l'addon EN CLAIR. `category="ADDONS"` resout la globale Blizzard du
                         #   meme nom et l'entree devient introuvable (verifie en jeu).
                         #   Action : fenetre fermee -> `UI.Toggle()` (= `/ecp`) ; ouverte hors
                         #   accueil -> `UI.ShowHomePage()` ; deja a l'accueil -> RIEN (fermer
                         #   reste Echap / la croix). Defaut pose UNE fois (`db.keybindSeeded`,
                         #   cle additive a la RACINE de la DB, hors profil) et SEULEMENT si ALT-P
                         #   est libre : une touche prise n'est JAMAIS volee. API `KB.CurrentLabel/
                         #   Set/Clear` (l'UI ne touche a aucune API de binding) ; `UPDATE_BINDINGS`
                         #   resynchronise la rangee des options. Charge APRES `Core/Events.lua`.
  Commands.lua           # slash /ecp (alias /hp)
Data/
  Defensives.lua         # défensifs (spellID -> cooldown, class, role)
  Content.lua            # 8 donjons M+ Midnight S1 + boss (encounterID réels).
                         #   zoneID = PLACEHOLDER. Abilities (timelines) : partiel.
  Roster.lua             # rôles/classes + icônes (classe/rôle), GetGroupComp, SortComp
  HealerDefaults.lua     # plan de base par healer (variante non supprimable + import)
UI/
  ConfigFrame.lua        # modale B (donjons) / A (boss + Trash Info) / C (occurrences / liste trash)
                         #   2 boutons-icones de vue (haut droite) : Defensive list (UI.viewMode
                         #   plein largeur) + Options (engrenage). Indicateur "Not Zephyrable"
                         #   (rouge) sur les occurrences aoe~=true du planner.
                         #   Bouton "Settings" a cote du nom du boss (UI.bossSettings) : bascule
                         #   plan <-> reglages du boss (UI.RenderBossSettings : 1 ligne/sort
                         #   dedup par id = case Activer + nom editable + Play sound + selecteur
                         #   de son). Reset au changement de boss/donjon/vue/trash.
  VariantBar.lua         # barre de variantes (menu, compo, actions) + modale création
  SettingsFrame.lua      # fenêtre Options (bouton à droite des onglets) — vide pour l'instant
  SyncFrame.lua          # modale de PROGRESSION d'une poussee (bouton Sync) : 1 ligne par membre
                         #   du groupe + spinner (8 points, zero texture) jusqu'au verdict —
                         #   `Sync success` (SYNC_OVER recu) / `Sync failed` (SYNC_START mais pas
                         #   SYNC_OVER) / `Addon missing` (muet). Timeout 5 s. N'affiche que :
                         #   l'etat lui est pousse par Core/Sync/PlanSync.lua.
  RuntimeBox.lua         # affichage combat : Upcoming bar + Communication bar + reconnaissance
                         #   des events serveur (ENCOUNTER_TIMELINE) par durée (partagée TimelineBox)
  TimelineBox.lua        # Timeline défilante (vue alternative, option timelineMode) : colonne
                         #   boss (sorts reconnus via s.recognized) + colonne défensifs planifiés
```

### Namespace partagé

Chaque fichier reçoit `local addonName, HR = ...`. `HR` est la table privée
commune. On n'expose dans `_G` que ce que le client exige (SavedVariables,
`SlashCmdList`, `HealPlanner_OnAddonCompartmentClick`, et les deux globales du raccourci
clavier : `BINDING_NAME_ECPLANNER_OPEN` et `EiikoCooldownPlanner_OnKeybind` — cf.
`Core/Keybind.lua`).

## Modèle de données

- **Contenu** (statique, à terme importable) : `HR.content` = liste de donjons.
  Un boss peut porter `enable = false` (`HR.BossEnabled` ; absent/`true` = actif) :
  **désactivé** = grisé + inaccessible dans la config, et en combat la boîte runtime
  passe en **mode brut** (aucun filtrage, affiche tout ce qui vient un par un).
  Un boss se décrit par l'une de **2 représentations** (`GenerateOccurrences`
  dispatche, `phases` prioritaire) :
  - **SIMPLE** — `abilities` = `{ spellID, name, firstAt, period, [aoe] }` : un sort
    qui se répète (`firstAt + k*period`). `period<=0` => unique.
  - **RICHE** — `phases` = liste de phases qui se répètent ; une **phase** regroupe
    plusieurs sorts à offsets fixes : `phase = { [name], firstAt, period, [count],
    events = { {spellID, name, at, [aoe]}, … } }`. `at` = offset (s) depuis le début
    de la phase. Ex. Araknath (Skyreach) : 2 Energize + Supernova toutes les 54 s.
    Les instances de phase sont numérotées par ordre de début (séparateur UI).
  `aoe` (tri-état) : `true` = dégâts AoE-flaggés (réduits par Zephyr / la stat
  Avoidance), `false` = confirmé non-AoE, `nil` = inconnu/à renseigner. Propagé sur
  chaque occurrence. Chaque capacité (ability OU event de phase) porte aussi :
  `allowedInPlan` (bool, true par défaut sur le contenu pré-enregistré) = planifiable
  dans le plan du boss ; `allowInTimeline` (bool, idem) = affichée dans la
  timeline/runtime ; `overridenName` (string|nil) = nom affiché à la place de `name`
  (nil = `name` brut) ; `customName` (string|nil) = nom court (« DOT »/« AOE »…),
  prioritaire (routé vers `overridenName` par GenerateOccurrences). **Sync défensive
  précise** : `at`/`firstAt` = **début du cast** (= temps matchable serveur, `occ.time`) ;
  `cast` = durée du cast (impact = `at+cast`) ; `defMarker = { mode, offset(ms) }` (modes
  `BEFORE/AFTER` × `CAST_START/CAST_END`) = **quand afficher le défensif**, calculé par
  `HR.OccDefTime(occ[, castStart])` — l'icône défensive se place à ce temps (découplé de
  l'icône boss). Sans `defMarker` => défensif au temps du sort (rétro-compatible).
  Ces champs sont des **défauts statiques** ; les **réglages
  joueur** (case Activer / nom custom / son) sont stockés en DB par
  `Core/BossSettings.lua` (`HR.db.bossSpells[encounterID][spellID]`, matching par id)
  et fusionnés dans `GenerateOccurrences` via `HR.ApplyBossSpellSettings` (nom custom
  + `o.allowInTimeline` résolu + `o.playSound`/`o.sound`). Le **plan** affiche tous
  les sorts (nom custom appliqué) ; la **timeline runtime** est filtrée par
  `HR.FilterTimeline` (côté RuntimeBox : `s.planned` live + test). ⚠️ En **live**, la
  colonne brute du TimelineBox vient des events serveur (`spellID` = Secret Value
  illisible) → non filtrable par id ; mais l'Upcoming bar l'est, via le matching sur
  `s.planned`. **Matching runtime par DUREE** (data en place, branchement à venir) :
  chaque capacité peut porter `durations = {…}` (durée d'annonce serveur arrondie 0.1,
  lisible même quand le spellID est secret en M+) → on identifie un event par sa durée.
  Une entrée **« duration-only »** (a `durations` mais PAS `firstAt`) ne sert qu'au
  runtime : `GenerateFromAbilities` la **saute** (zéro pollution du plan) ; pour un boss
  en `phases`, ces entrées vivent dans un `abilities` qui **coexiste** avec `phases`.
  Quand une durée désigne plusieurs sorts (rotation du boss),
  `boss.durationGroups[duree] = {spellID,…}` donne l'ordre du cycle (count % N : reste 1
  → … → reste 0) pour départager au modulo. D'autres champs viendront. `occIndex`/`key`
  = compteur chronologique par sort (`spellID:N`, stable) dans les deux représentations. Chaque donjon a aussi `trash = { {spellID,
  name}, … }` : capacités de TRASH réduites par Zephyr (AoE), affichées dans la
  section **Trash Info** (bouton sous la liste des boss ; `UI.viewTrash`), tooltip
  du sort au survol de l'icône. Vide pour l'instant, à remplir.
- **Profils de heal** (`Data/Roster.lua`, `HR.HEAL_PROFILES`) : une **identité de
  heal** jouable. La plupart des classes de heal n'ont qu'une spe → profil = classe
  (`key` == jeton de classe). Le **prêtre a DEUX spes heal** (Discipline, Holy) →
  deux profils `"PRIEST_DISC"`/`"PRIEST_HOLY"` (icône de spe, sorts et plans
  distincts). ⚠️ Ne PAS confondre avec Paladin Holy = classe à 1 spe heal. Helpers :
  `HR.HealProfileKey(class, spec)`, `HR.VariantHealKey(v)`, `HR.GetHealProfile(key)`.
  Le profil est l'unité du sélecteur de heal, des variantes par défaut, du filtrage
  et du choix de spe à la création.
- **Variantes par donjon** : `HR.db.dungeons[dungeonID] = { usedVariant = <id>,
  variants = { variant, ... } }`. Une `variant = { id, name, comp, spec, assignments }`
  couvre TOUT le donjon. `comp` = tableau positionnel aligné sur `HR.COMP_SLOTS`
  (1 tank, 1 heal, 3 dps → jetons de classe), **trié à l'enregistrement** par rôle
  puis par jeton de classe (`HR.SortComp`). `spec` = spe heal du **prêtre**
  (`"Holy"`/`"Discipline"`), `nil` sinon — le heal reste un **jeton de classe** dans
  `comp[2]` (pour l'icône et le matching de compo via `GetGroupComp`, qui ne lit pas
  la spe des autres membres) ; `spec` est le discriminant heal-only. L'identité de
  heal d'une variante = `HR.VariantHealKey(v)`. `assignments[encounterID][occKey] =
  { defID, ... }`. `usedVariant` = variante jouée par le runtime (bouton ★).
  Migration de l'ancien `HR.db.plans` à plat → variante « Importe » (cf. Plans.lua).
- **Variantes par défaut** (`Data/HealerDefaults.lua`, `HR.healerDefaults[profileKey]`) :
  une par **profil de heal** (donc DEUX pour le prêtre), comp = ce heal seul,
  id `"default:KEY"`, `isDefault=true`, `spec` pour le prêtre. DATA non supprimable,
  base quand ce profil est dans la compo. Un **sélecteur de profil heal** (icônes,
  façon onglets ; le prêtre = deux onglets de spe) filtre le dropdown : variante par
  défaut du profil choisi + variantes utilisateur dont `VariantHealKey` correspond.
  À la création, le slot heal liste les **profils** (prêtre en Discipline + Holy) ;
  case « Importer le plan de base du heal » → copie les `assignments` du profil.
  (Édition in-game d'un défaut = **persistée** : `Database.InitDB` relie les
  `assignments` de chaque `healerDefaults[key]` à `HR.db.healerDefaults[key]`, seedé
  une fois depuis la base `.lua`. La table `healerDefaults` reste reconstruite depuis
  le `.lua` à chaque load — seuls les `assignments` sont DB-backés.)
- **Défensifs** : `HR.defensives[key] = { name, cooldown, [class], [role], [spec],
  [charges], [itemId], [icon], [spellID], [aoeOnly] }`. `key` = spellID, ou chaîne
  synthétique (variantes de CD / entrées génériques comme `"SMALL_DEF"` (cd 90, nom
  « Defensive » = **appel défensif perso GÉNÉRIQUE unique** ; la nuance small/big a été
  retirée, `BIG_DEF` supprimé) / `"EMPTY_BAG"` (cd 0, tête de mort) = appels de défensif
  perso, sans classe ni rôle). `spec` (nom EN, ex. `"Holy"`/`"Discipline"`/`"Shadow"`) :
  filtre par spe — un sort de spe heal (`role="HEALER"`+`spec`) n'est proposé dans le
  picker que si la variante est de cette spe (cf. `HR.IsDefensiveForComp(.., healSpec)`) ;
  le runtime filtre les CD de classe par spe via `HR.PlayerCanUseDefensive`. `aoeOnly=true` (Zephyr) :
  ne réduit que les dégâts AoE-flaggés → le picker affiche `(pas AoE)`/`(AoE ?)` et
  un « ! » + ligne de tooltip si placé sur une capacité `aoe=false`
  (`HR.IsAoEOnlyDefensive`). Avertit, ne bloque pas (placements manuels).

Tout est en tables Lua pures → prêt pour un export/import (string) ultérieur.
La clé d'occurrence est `spellID:index` (stable aux édits voisins).

### Codec de plan (`Core/Share.lua`)

- **Payload** : `{ v=PROTO(2), kind="variant", dID, name, healer, ext, tsp, asg, tlv }`.
  La data statique (defID, encounterID, occKey) est commune aux deux joueurs (même
  addon) → on ne transmet que le nom, le profil de heal et les placements.
- **Encodage natif 12.0, zéro lib** : `C_EncodingUtil.SerializeCBOR` →
  `CompressString(Deflate)` → `EncodeBase64`. Tout sous `pcall` (entrée réseau =
  non fiable). Decode = inverse ; payload re-validé (`ValidatePayload`) et
  assignments filtrés (`SanitizeAssignments` : encounterID du donjon, occKey en
  string, defID connu de `HR.defensives`).
- **Aucun transport ici.** Le partage par lien (`|Hhealplanner:|h`, `hooksecurefunc
  ("SetItemRef")`, aperçu `UI/ShareFrame.lua`, `/ecp share`, diffusion sur le préfixe
  `HealPlanner`) a été **entièrement retiré** : le canal de synchro (bouton **Sync**,
  `Core/Sync/`) le remplace. Ne pas le réintroduire — un plan se pousse, il ne se
  publie plus.
- Consommateurs : `Core/Sync/PlanSync.lua` (poussée + réception) et les modales
  **Export / Import** de `UI/HealerSpecs.lua` (chaîne copiable). Le format texte
  `ecp;2` est un autre chemin, dans `Core/ShareText.lua` + `UI/ImportText.lua`.

### Synchro des plans (`Core/Sync/*`) — REGLE D'ARCHITECTURE

Tout ce qui est ajoute sous `Core/Sync/` suit deux regles, sans exception :

1. **Aucun listener dans le code metier.** Les listeners sont des fonctions du fichier
   `Core/Sync/Listeners.lua`, seul site de `HR:RegisterEvent` / `HR.OnEvent` pour ce canal.
   Elles **appellent** le code existant ; le code existant ne doit **jamais** appeler dedans.
2. **`HR.EmitEvent(HR.EV.X, payload)` est autorise partout** dans l'addon — c'est le seul
   point de contact avec le canal. Ex. `Core/Commands.lua` (`/ecp handshake`) ne fait que
   `HR.EmitEvent(HR.EV.HANDSHAKE_REQUEST, { reason = "slash" })`.

Sens des dependances : `Listeners → Handshake → Net → Bus → code existant`. Les fichiers
s'**auto-amorcent au chargement** (pas d'appel depuis `Core/Core.lua`, qui reste ignorant du
canal). ⚠️ `PLAYER_LOGIN` est inutilisable comme amorcage : `Core/Events.lua` le consomme pour
`OnInitialize` et sort avant le dispatch.

Messages livres :

- `HELLO` / `HELLO_ACK` (`/ecp handshake`) — qui a l'addon, en quelle version. Reponse adressee
  sur le canal ADDON (pas un chuchotement visible), **zero ecriture en DB**.
- `PLAN` (bouton **Sync** du panneau Healer specs, `UI/HealerSpecs.lua` — PAS `VariantBar.lua`,
  dont l'UI est construite puis MASQUEE) — pousse la variante
  affichee ; le destinataire l'importe **sans rien demander** et la pose **active** (★). Encodage
  reutilise TEL QUEL (`HR.Share.EncodeVariant`) ; l'id distant voyage dans le corps de la trame,
  pas dans le CBOR, pour ne rien changer au canal de partage deja deploye. ⚠️ **Premier code qui
  ecrit dans la DB d'un autre joueur depuis le reseau** : l'ecriture ne peut viser QUE une variante
  creee par ce mecanisme et indexee dans `db2.syncImports` (cle additive, creee a la volee) ; une
  variante que le joueur a ecrite lui-meme n'y figure jamais. Payload valide (`ValidatePayload`) et
  assaini (`SanitizeAssignments` / `SanitizeExternals`) avant la DB. **Pas encore d'autorisation** :
  n'importe qui dans le groupe peut pousser — c'est l'objet du lot suivant.
  **Deux gates** : (1) a l'EMISSION, on ne pousse que SON PROPRE plan — un plan recu
  (`v.synced`) a son bouton Sync grise, il faut le **dupliquer** pour se l'approprier
  (`HR.V2_DuplicateVariant` ne recopie JAMAIS `synced`/`syncFrom` : c'est l'echappatoire) ;
  (2) a la RECEPTION, un plan dont la cle `(emetteur, id distant)` n'est PAS dans
  `db2.syncImports` ouvre une fenetre d'accord — une modale MAISON (`UI.Components.Window`
  + fond `bg-variant`, `UI/SyncFrame.lua`), pas une StaticPopup : la decision engage la DB du
  joueur. Une demande a l'ecran a la fois, les suivantes font la file ; fermer vaut refus.
  Rien n'est ecrit tant que le joueur n'a pas repondu. L'entree d'index EST l'autorisation :
  une fois acceptee, les poussees suivantes de CE plan par CE joueur s'appliquent sans rien
  demander. La modale porte **deux cases** (infobulle au survol, DECOCHEES par defaut) :
  *Delete this variant in 24h* (TTL optionnel — meme mecanisme que l'import manuel,
  `db2.imports[dID][id]` + `HR.PruneExpiredVariants` ; une variante acceptee SANS TTL n'en
  recoit jamais un aux poussees suivantes) et *Trust this author* (whitelist
  `db2.syncTrust[<auteur qualifie>]`, cle additive — plus aucune demande pour CE joueur,
  meme pour un plan jamais vu).
  ⚠️ L'etat renvoye a l'emetteur est un **champ de la reponse**, pas un evenement
  de plus : `SYNC_START` porte `""` (recu) ou `"PENDING"` (j'attends mon joueur -> la ligne
  affiche « Pending approval… » et echappe au verdict des 5 s), `SYNC_OVER` porte `"OK"`
  (applique) ou `"DENIED"` (« Declined », pas « Sync failed »).
  Une variante recue porte deux champs **additifs** : `synced = true` et
  `syncFrom = { name = "<auteur qualifie>", at = <timestamp serveur> }` (trace de l'auteur).
  Consequence UI : elle **n'apparait PAS** dans la liste normale du selecteur — il faut cocher
  **« Show sync plans »**, qui n'affiche QU'ELLES et court-circuite « Show current spec only »
  (option `showSyncedPlans`, `UI/HealerSpecs.lua`). Chaque ligne porte un prefixe vert `SYNC`.
- `SYNC_START` / `SYNC_OVER` — accuses renvoyes par le DESTINATAIRE a l'emetteur seul, avec le
  `msgId` de la poussee. `SYNC_START` part **avant tout decodage** (« j'ai recu »), `SYNC_OVER`
  **seulement** au bout du chemin d'import : c'est ce qui permet a la modale de distinguer un
  client sans addon (muet) d'un import casse en route. Cote metier on ne fait qu'emettre les
  evenements de bus du meme nom ; `Listeners.lua` les met sur le fil.

📄 **Documentation de reference** : `Interface/docs/EiikoCooldownPlanner/plan-sync.md` decrit
le systeme LIVRE (transport, messages, gates, cles de DB, UI, checklist de test, et ce qui
n'est PAS fait). Il **fait foi**. `plan-sync-vivante.md` reste le plan d'INTENTION d'origine.

Restent a faire (cf. §9 de `plan-sync.md`) : UI de revocation de la whitelist (le garde-fou
« autorisation revocable » n'est donc pas tenu), verrou de lecture seule sur une variante recue,
`HAS?` (savoir qui est en retard avant de pousser), garde de combat. Ils s'ajouteront comme un
`kind` de plus dans `OnNetMessage`.

## Logique clé

- `GenerateOccurrences(boss, fightLength)` : déroule la timeline sur 5 min, triée
  chronologiquement, chaque occurrence portant un `phase` (n° de cycle).
  - `abilities` (simple) : `GenerateFromAbilities` ; `phase` basé sur l'**ancre**
    (capacité au plus petit `firstAt`) — chacune de ses réapparitions démarre une phase.
  - `phases` (riche) : `GenerateFromPhases` ; chaque **instance** de phase (déroulée
    sur `firstAt + k*period`) est numérotée par ordre de début → `phase`. Un même sort
    peut apparaître plusieurs fois par phase (offsets `at`).
  L'UI (`ConfigFrame.RefreshRows`) insère un séparateur « Phase N » (ou `phaseName N`)
  à chaque changement de `phase`, seulement si le boss boucle (`maxPhase > 1`).
- `HR.NewPlan_TokenState(token, atTime, uses)` (`Core/Plan2.lua`, ex-`IsSpellReady`) : un défensif
  est prêt si le nombre d'usages conflictuels `< charges`. Fenêtre **symétrique** : un usage placé
  avant (encore en CD) OU après (qu'on rendrait trop précoce) compte, dès que
  `abs(atTime - use) < cooldown`. Sémantique **exactement au CD = prêt**
  (`< cooldown`, pas `<=`). L'usage à `atTime` même (la même occurrence) est
  ignoré. Les temps comparés sont les **temps d'USAGE effectifs** = `HR.OccDefTime(occ)` (defMarker
  inclus) **+ l'offset par-assignation** (`e.offset`, ajouté dans `HR.NewPlan_Uses`) : décaler un CD
  via son offset met donc bien à jour sa dispo. La feature « Force » a été retirée → dans le sélecteur
  un défensif pas prêt est **quand même cliquable** (grisé + `(-Xs)` = manque affiché), on le décale
  ensuite via l'offset pour le rendre dispo.

## Décisions de conception (verrouillées)

- 🚫 **NE JAMAIS toucher aux données sauvegardées (RÈGLE ABSOLUE, jamais enfreinte).**
  L'addon est **publié et utilisé par des joueurs** : leurs plans existants
  (`HealPlannerDB` / `*CharDB` : variantes, `assignments`, tokens, options,
  positions) sont **sacrés**. INTERDIT : changer le **format/schéma** d'une donnée
  persistée, renommer/retyper une clé, migrer/réécrire/purger des `assignments` ou
  des tokens, ou tout code qui **modifie en masse** la DB d'un joueur. Un bug de
  lecture se corrige **au point de lecture** (ex. normaliser un token via
  `HR.DefKeyOf` à la lecture — JAMAIS en réécrivant le token stocké). Toute
  évolution doit rester **rétro-compatible en lecture seule** avec les DB
  existantes. En cas de doute : ne pas écrire dans la DB.
- **PROFILS d'affichage** (`Core/Database.lua` : `HR:InitProfiles`/`ActivateProfile`
  + API `ListProfiles`/`CreateProfile`/`RenameProfile`/`DeleteProfile`/`SwitchProfile`).
  Les réglages d'**affichage** (`options` + `ui` positions + `bossSpells` incl. `barColor`)
  sont groupés en **profils nommés stockés au COMPTE** (`HealPlannerDB.profiles[nom]`).
  Le profil **actif est PAR PERSONNAGE** (`HealPlannerCharDB.profile`). Les **plans**
  (variantes/donjons/`healerDefaults`) restent au compte, **hors profil** (partagés).
  Implémentation non invasive : `ActivateProfile` **re-pointe** `HR.db.options/ui/bossSpells`
  vers les sous-tables du profil actif → tout le code lisant `HR.db.options…` suit le profil.
  Migration **additive** au 1er init (pas de bump de schéma) : profil **"Default"** créé
  depuis les réglages racine existants. **Split init** : le *mandatory once* (câblage
  `ActivateProfile`, création des frames, macros, comm sécurisée) est séparé du *ré-applicable*
  `HR.ApplyActiveProfile()` (positions `RestoreFramePos` ×6 + `Apply{UIScale,Upcoming,Announce,
  Timeline,Progress,Comm}Options` + `UpdateVisibility` + `RefreshRows`). `SwitchProfile` =
  **LIVE hors combat** (`ActivateProfile` + `ApplyActiveProfile`, reconstruit le panneau
  Settings) ; **`ReloadUI` en combat** (comm bar sécurisée non repositionnable). UI : onglet
  **Profile** des Settings (`UI/ConfigFrame.lua`) = select CUSTOM (`MakeSelect` + `C.ScrollPopup`,
  delete/ligne) + modale custom `BuildProfileNewModal` + confirm `ConfirmDeleteProfile`.
- **Pas d'autoplanner** : placements 100 % manuels via le bouton `[ + ]`.
- **Première installation = tout au CENTRE** : on ne PRÉ-PLACE PAS les fenêtres UI aux coins.
  `Core/Database.lua` (`InitDB`) détecte l'install fraîche (`freshInstall` = DB absente / bump de
  schéma) et **seede `db.ui[key] = {CENTER,0,0}`** pour toutes les fenêtres (`config`, `runtime`,
  `comm`, `timeline`, `progress`, `announce`) dans le profil actif. Les frames restaurent ces
  coords au PreBuild. **N'affecte JAMAIS les joueurs existants** (schéma déjà bon → `db.ui` intact).
  Le joueur place ensuite via *Show anchors* → drag.
- **Un TANK ne reçoit JAMAIS de directive de CD PERSO** (l'appel générique `SMALL_DEF` /
  « Defensive ») : seulement les **externals** qu'il fournit (AMZ, Rally, Darkness…), quand il
  y en a. Règle appliquée au **point de décision « mien »** : `HR.TokenIsMine` (`Core/Schedule.lua`)
  renvoie `false` pour `SMALL_DEF` si `HR.GetPlayerRole() == "TANK"` → propagé à l'annonce, au glow
  Upcoming, aux `liveDefs` et au container 2 « tes CD » (`EMPTY_BAG` reste, ce n'est pas un CD perso).
- **CD hardcodés** (les talents/hâte ne sont pas lisibles de façon fiable en
  Midnight — cf. Secret Values).
- `firstAt` / `period` **hardcodés** par capacité.

## ⚠️ Spécificités API Midnight 12.0

- **Secret Values** : santé/puissance et surtout `C_Spell.GetSpellCooldown`
  (`startTime`/`duration`) deviennent opaques en combat → le temps restant d'un
  CD n'est pas lisible. On reconstruit la dispo soi-même (cast + CD hardcodé).
- **`GetSpellBaseCooldown(spellID)`** reste lisible (CD *non modifié*, ignore
  talents/hâte).
- **`C_EncounterTimeline`** (lecture) : `GetSortedEventList`, `GetEventInfo`,
  `GetEventTimeRemaining`, events `ENCOUNTER_TIMELINE_EVENT_ADDED/REMOVED/...`.
  Source serveur fiable pour la synchro runtime (tranche suivante). L'injection
  (`AddScriptEvent`) est marquée restreinte — à valider en jeu.
- **Annonce chat : un addon ne peut PAS `/yell`/`/say` en combat** (drop silencieux,
  `C_ChatInfo.SendChatMessage` renvoie ok mais rien ne part). Contournement =
  **macros joueur** `EHP_<SHORT>` (`Core/Macros.lua`, recréées à chaque init) dont le
  corps fait `/yell Next Cooldown : <nom>`, déclenchées par un clic (event matériel).
- UI = autorisée (« look & feel » non restreint).
- **Boutons sécurisés en combat** : un `SecureActionButtonTemplate` (`type=macro`)
  exécute une macro au clic (event matériel) — seul moyen de `/yell` en combat.
  ⚠️ **Vérifié en jeu (12.0.5)** : `macrotext` (`/yell …` en dur) **ne crie PAS**, et
  `macro=<nom>` **non plus** ; seul `macro=<INDEX>` (la vraie macro EHP_ pointée par
  son index via `GetMacroIndexByName`) fonctionne. Et il faut
  `RegisterForClicks("AnyUp","AnyDown")` : le handler sécurisé n'agit que sur le bord
  correspondant à `ActionButtonUseKeyDown`, donc `AnyUp` seul est inerte si le joueur
  a « lancer à l'appui de la touche ». Le handler s'auto-régule → un seul `/yell`.
  Mais `SetAttribute`/`SetPoint`/`Show`/`Hide` sont **protégés** (interdits en combat
  sur le bouton ou son parent). Décisions verrouillées :
  - La **boîte runtime** (`UI/RuntimeBox.lua`) contient la rangée d'appel sécurisée
    (1 bouton par `HR.externalMacros`) → **construite + configurée + affichée HORS
    COMBAT à l'init** (`HR.Runtime.PreBuild`, après `HR.SetupMacros`) et **jamais
    `Hide()`** (toujours affichée, au repos = « En attente »).
  - **Trick alpha** : `SetAlpha()` n'est PAS protégé → utilisé à la place de
    `Show/Hide` pour les transitions en combat. (Réserve : alpha 0 reçoit toujours
    les clics ; `EnableMouse(false)` est protégé sur un bouton sécurisé.)
  - Le **drag** de la boîte est gardé par `InCombatLockdown` (déplacer le parent
    bougerait les boutons sécurisés).

## Reste à faire

- Contenu des 8 donjons : noms + encounterID (id) reels + icones + `zoneID`
  (instanceID de GetInstanceInfo) OK. Reste : renseigner les `abilities`
  (timelines) par boss. Le `zoneID` sert a l'auto-selection du donjon courant a
  l'ouverture de la modale (`HR.GetCurrentDungeonIndex` -> `UI.Toggle`), repli sur
  le 1er donjon.
- ⚠️ **Détection auto IMPOSSIBLE en 12.0** : (1) `COMBAT_LOG_EVENT_UNFILTERED` ne
  fire plus pour les addons ; (2) `C_EncounterTimeline` fire bien
  (`ENCOUNTER_TIMELINE_EVENT_ADDED/...`) MAIS `spellID`/`spellName`/`iconFileID` du
  payload sont des **Secret Values** illisibles (seuls `id` et `duration` le sont).
  => on ne peut PAS relier un event serveur à un défensif planifié. (Vérifié en jeu
  sur Zuraal : events OK, valeurs secrètes.)
- On peut **AFFICHER** une Secret Value (la passer à `Texture:SetTexture` /
  `FontString:SetText` l'affiche sans la lire) ; interdit : arithmétique/comparaison
  dessus. `id`/`duration` de la timeline sont lisibles ; `spellID`/`spellName`/
  `iconFileID` sont lisibles **hors contenu restreint** mais secrets en M+/raid.
  (Vérifié : en non-restreint `spellID=1263399` lu correctement.)
- ⚠️ Le `spellID` de la timeline est **affichable mais inutilisable** (clé de table /
  comparaison → erreur), même en M+ où il "se lit". Donc **on ne lit JAMAIS le
  spellID** côté runtime.
- Runtime LIVE (`RuntimeBox.lua`, `ENCOUNTER_START`) : piloté par
  `ENCOUNTER_TIMELINE_EVENT_ADDED/REMOVED`. Variante jouée = `usedVariant` (★) sinon
  1re variante du donjon. Chaque `ADDED` :
  **(1) reconnaissance par DURÉE** `HR.MatchByDuration(boss, eventInfo.duration, s.durCounters)`
  → spellID (robuste aux phases, ne lit aucun Secret Value ; cf. `Core/Matcher.lua`) ;
  **(2)** mémorisé dans `s.recognized[eventID]` (nom custom + actif) pour le TimelineBox ;
  **(3) lien** : `HR.PlanIdFor` (par nom) → occurrence de CE sort la plus proche en TEMPS
  dans `s.planned` (plus de confusion inter-sorts ; un sort désactivé est absent de
  `s.planned` filtré → ignoré) ; **(4) repli** si durée inconnue : ancien matching global
  par temps dans `TOLERANCE`s. L'affichage (icône/nom/défensifs/`/yell`) vient de NOS
  données — zéro Secret Value touchée. `/hp debug` logge `[rt] dur|time <nom> @Ns defs=K`.
  **Sorts au PULL sans event Blizzard** (ex. Ick & Krick) : certains sorts démarrent
  dès le début du combat et le serveur n'émet **aucun** `ADDED` pour eux → invisibles.
  RÈGLE : au `StartLive`, `PushSyntheticPullEvents` parcourt `s.planned` et **pousse
  telle quelle** toute occurrence dont le temps théorique `< 2 s` (eventID synthétique
  `"SYNTH:<occKey>"`, `endTime = pullTime + occ.time`), peuplant `recognized`/`active`/
  `liveDefs` comme un vrai event (occurrence connue → pas de matching par durée). Lecture
  seule côté DB. `/hp debug` logge `[rt] synth pull <nom> @Ns defs=K`.
  Le **TimelineBox** live affiche sa colonne boss via `s.recognized` (nos icône/nom,
  sorts désactivés masqués ; repli brut serveur si non reconnu). Un défensif dont la `class` == celle du
  joueur (`UnitClass("player")`) est mis en **surbrillance** = c'est le tien. Glow
  centralisé dans `Core/Glow.lua` (`HR.SetupGlow`/`HR.ApplyGlow`) : **glow proc
  NATIF** = atlas flipbook `UI-HUD-ActionBar-Proc-Loop-Flipbook` animé par une
  AnimationGroup `FlipBook` (grille 6×5 = 30 images, à ajuster si découpé). Fallback
  pulsation `IconAlert` si l'atlas manque. Aucune lib ; on évite
  `ActionButton_ShowOverlayGlow` (taint).
  - **DEUX fenêtres déplaçables séparément** (positions persistées `HR.SaveFramePos` :
    clés `"runtime"` et `"comm"`) :
    * **Upcoming bar** (`UI.runtimeBox`) — **avertissement « hit imminent »** déclenché
      dans les `WARN_WINDOW` (5) dernières secondes (`CurrentWarn` scanne `s.active`/
      `s.timeline`, prend le prochain hit AVEC défensifs ≤5s ; `RenderUpcoming`) :
      **(1)** nom du sort de boss (masquable, option) ; **(2)** séparateur ; **(3)**
      **colonne** de défensifs planifiés (`LayoutDefColumn`) + **compte à rebours** (temps
      avant le hit) à droite. Hors fenêtre → « Waiting… ». Pilotée par `s.active`
      (rempli en continu par le handler `ADDED`), donc fonctionne même Timeline masquée.
      Plus AUCUN enfant sécurisé → `SetHeight`/`SetScale`/drag libres même en combat.
    * **Communication bar** (`UI.commBar`) : la rangée de **boutons-macros sécurisés**
      (`RefreshCallButtons`, hors combat) ; layout en **grille de N colonnes** (option
      `Columns`, `HR.Runtime.CommColumns` : 1 = vertical, 9 = horizontale ; remplace l'ancien
      `commLayout`, inféré une fois depuis lui si `commColumns` absent) ;
      drag gardé par `InCombatLockdown`.
  - **Ancrage HARMONISÉ** (`Core/Util.lua`) : positions dans `HR.db.ui[key]` (clés `runtime`,
    `comm`, `announce`, `timeline`, `progress`, `config`). Règle unique : au **drag/reset** →
    `HR.SaveFramePosTopLeft` (rect à jour → toutes les fenêtres HUD ancrées **TOPLEFT**) ; au
    **scale** → `HR.SaveFramePos` (GetPoint, sûr à l'init : le rect n'est pas encore à jour). Le
    rescale garde le coin haut-gauche fixe via `HR.SetFrameScaleInPlace` (compense l'offset ×
    old/new) = **rescale in place** cohérent partout. `RestoreFramePos` reste rétro-compatible
    avec les anciennes sauvegardes (TopRight/raw). **EXCEPTION Announcement** : bannière **centrée**
    → ancre **HAUT-CENTRE** (`HR.SaveFramePosTop`, point `TOP`) pour rester centrée horizontalement
    quand la largeur du contenu change (`SavePosForMode` mode `"TOP"`).
  - **« Show anchors »** (option `showAnchors`, onglet General ; `HR.Runtime.AnchorsVisible()` =
    `showAnchors` **OU** mode test) : montre les **poignées de déplacement** de chaque fenêtre HUD
    et les **force visibles** (mode arrangement) pour les placer. Le **mode test force les ancres
    sans toucher l'option**. Le drag n'est possible **qu'en mode ancres**. ⚠ **En mode test, aucun
    son** (`HR.Alerts.Tick` sort tôt si `state.mode == "test"`) ; le visuel (glow/upcoming) reste.
  - **Options** (vue `UI.viewMode == "options"` dans la modale ; `UI.RenderOptions`/
    `BuildOptionsPanel`/`OptionBinders`) en **ONGLETS** (⚠ `TAB_NAMES` fixe l'ORDRE, le contenu est
    attaché par **index** de `panels[]` — un réordonnancement d'onglet impose de re-mapper les index) :
    **1 General** (`BuildGeneralTab` : boutons Reset position + Start/Stop test en en-tête, puis
    colonnes **Alert** (`colX 0`) | **Glow** (`COL2_X 360`) | **Keybinding** (`COL3_X 720` :
    `keybindRow`, seul widget de CAPTURE de touche du codebase — clavier confisqué uniquement
    pendant la capture, Échap annule, bouton *Clear*, cf. `Core/Keybind.lua`)),
    **2 Announcements** (`panels[2]`, compo `announce`),
    **3 Personal Timeline** (`panels[3]`, compo `upcoming` ; Enable = `upcomingEnabled` ;
    `upcomingMax` = nb max de sorts A VENIR affiches, **0 = tous** — lu au tick par
    `RenderUpcoming`, plafond historique de 4 conserve en mode test quand l'option vaut 0),
    **4 Communication Bar** (`panels[4]`, compo `comm` ; **Disable Communication Bar** = `commDisabled`,
    Columns, reverse, filtre, non-healer), **5 Bars and Timeline** (`panels[5]`, 2 colonnes timeline
    d'icônes | progress bars), **6 Profiles** (`panels[6]`). Chaque onglet peut porter un **bloc d'info**
    en tête (`opts.info` → `C.InfoBox`, cadre violet/gris). Timeline et Upcoming sont des **interrupteurs indépendants**
    (`UpdateVisibility` ; le moteur de reconnaissance tourne quoi qu'il arrive). Valeurs
    dans `HR.db.options` ; appliquées à chaud par `ApplyUpcomingOptions`/`ApplyTimelineOptions`/
    `ApplyCommOptions`/`UpdateVisibility`. (`SettingsFrame.lua` = ancienne modale, inutilisée.)
    NB : l'ancien **bandeau de rappel CD perso** (`UpdateReminder`) et l'affichage entête
    icône/nom/timer (`UpdateDisplay`) sont remplacés par ce layout (code conservé mais
    inutilisé, à nettoyer).
  - **Announcement** (`UI.announceBox`, ancre haut-centre, onglet Announcement) : bannière
    d'**ICÔNES accumulées** — chaque défensif **mien** (`HR.Schedule.Active` filtré `e.mine`) sous
    `announceThreshold` (3-15 s) = **une icône distincte** avec son **décompte overlay AU CENTRE**
    (`MineAnnounceEntries` : dédup `occKey|token`, tri par temps restant). Rangée **horizontale
    centrée** ; plusieurs événements **s'accumulent sans concaténation** (`[Def 5s] [Rev 8s]`).
    **Plus aucun texte de nom.** Les icônes sont des **Frames** (texture + FontString timer + glow)
    → `AcquireAnnounceIcon`. Options : `announceIconSize` (le timer suit, police = ~0.42×taille),
    compo `announce.textColor` (= couleur du **timer**), `announceGlowMine` (glow proc via
    `HR.StartGlow`/`HR.CompGlow`), `announceDisabled`. Rendu `RenderAnnounce`/`RenderAnnounceIdle`,
    piloté par l'OnUpdate de la box réelle (`UpdateAnnouncement`) ; `ApplyAnnounceOptions` ne fait
    plus que `UpdateVisibility` (taille/couleur/glow appliqués au rendu par tick).
  - **Boss désactivé** (`enable=false` → `s.passthrough`) : mode BRUT. Aucun matching,
    chaque `ADDED` est stocké tel quel (`raw=true`, `icon=eventInfo.iconFileID`,
    `name=eventInfo.spellName` — possiblement Secret Values, **affichées** via
    `SetTexture`/`SetText` sans être lues, jamais de `or`/comparaison dessus) et la
    boîte déroule tout ce qui vient un par un (`UpdateDisplayRaw`), sans défensif.
- Runtime TEST (`/hp test`) : timeline THÉORIQUE (`firstAt`/`period`) + bouton **Sync**.
- **Mode test dédié** (bouton *Start/Stop test*, onglet General) : `HR.Runtime.StartTestMode`
  sur un **boss inventé** `HR.testBoss` (ABSENT de `HR.content` → invisible) + une variante
  `HR.testVariant` régénérée à chaque init (`HR.BuildTestVariant`, en mémoire, jamais
  persistée, non supprimable). Capacité 1 toutes les 10 s = **AMZ (51052) + SMALL_DEF** ;
  capacité 2 toutes les 15 s = sans CD. `state.warnOverride = 10` force le threshold de
  l'Upcoming bar à 10 s pendant le test. Respecte les toggles Timeline/Upcoming
  (`UpdateVisibility`). `s.timeline` pilote Timeline + Upcoming (CurrentWarn).
- `/hp gather` (`Capture.lua`) : logge `ENCOUNTER_TIMELINE_EVENT_ADDED` secret-safe
  (pcall par champ → `<secret>` si illisible).
- Export / import des plans (schéma déjà prêt).

## Références

- [Patch 12.0.0 API changes — Warcraft Wiki](https://warcraft.wiki.gg/wiki/Patch_12.0.0/API_changes)
- [C_EncounterTimeline.GetSortedEventList](https://warcraft.wiki.gg/wiki/API_C_EncounterTimeline.GetSortedEventList)
- [TOC format](https://warcraft.wiki.gg/wiki/TOC_format)
