# Format d'échange ECP — spécification `ecp;2`

Format texte d'import des plans de l'addon World of Warcraft **EiikoCooldownPlanner**
(ECP). Document de référence pour toute implémentation externe : outil web, script,
autre langage. Il est auto-suffisant — aucune lecture du code Lua n'est nécessaire.

> **Si vous avez lu la version `ecp;1` de ce document, elle est retirée.** Le format a
> changé de nature, pas seulement de détail. Voir l'**annexe B** pour ce qui change et
> pourquoi.

---

## 1. À qui s'adresse ce document

Vous écrivez un outil qui **produit** des plans que l'addon devra importer (typiquement
depuis des données Warcraft Logs). Ce document décrit :

- ce que l'addon fait, pour que les données que vous produisez aient du sens (§2, §3) ;
- le format lui-même, à la ligne près (§5 à §9) ;
- **ce que l'addon fait de vos données** (§10) — indispensable : votre outil fournit de
  la matière première, l'addon en tire des conclusions, et certaines de ces conclusions
  dépendent de la qualité de ce que vous envoyez ;
- les règles qui ne se devinent pas (§11) ;
- les tables de référence pour valider en amont (§14).

---

## 2. Ce que fait l'addon

ECP sert à **planifier l'usage des cooldowns défensifs d'un groupe Mythique+ contre les
capacités des boss**. Concrètement : « sur le deuxième *Discordant Beam* de L'ura, le
prêtre lance *Divine Hymn* et le DK pose *Anti-Magic Zone* ».

Trois faits structurants, qui expliquent la forme du format :

**L'addon connaît les timelines de boss à l'avance.** Chaque capacité de chaque boss est
décrite en dur (premier lancement, période de répétition, durée d'incantation). L'addon
sait donc dire, avant même le pull, que *Discordant Beam* tombera à 25 s, 58 s, 91 s…
C'est ce qui rend la planification possible, et c'est pourquoi vous pouvez désigner une
occurrence par son **numéro d'ordre** (§9, `u;`).

**L'addon ne peut pas lire les cooldowns en jeu.** Depuis le patch 12.0 (Midnight),
l'API `C_Spell.GetSpellCooldown` renvoie des *Secret Values* opaques en combat : le
temps restant d'un sort est illisible. L'addon reconstruit donc la disponibilité
lui-même, à partir de **cooldowns codés en dur**. Or ces cooldowns dépendent des
talents. D'où l'importance centrale des talents dans ce format : sans eux, l'addon ne
sait pas si une *Tranquillité* est à 180 s ou à 150 s, et tout son calcul de
disponibilité est faux.

**Un plan appartient à un groupe précis.** Qui joue quoi, avec quels talents, combien de
Death Knights — tout cela change ce qui est plaçable. Un plan n'a de sens qu'accompagné
de la composition qui l'a produit. C'est pourquoi le format transporte un **roster**.

---

## 3. Vocabulaire

Les termes ci-dessous reviennent partout dans ce document et dans l'addon. Les trois
premiers blocs décrivent des notions de jeu ; le dernier, des notions propres à ECP que
**vous n'avez pas à produire** mais qu'il faut connaître pour comprendre §10.

### Côté jeu

| Terme | Ce que c'est |
|---|---|
| **zoneID** | `instanceID` Blizzard du donjon (ex. `1753` = Seat of the Triumvirate). Identifiant réel, stable, celui que renvoie `GetInstanceInfo`. |
| **encounterID** | Identifiant Blizzard d'un combat de boss (ex. `2068` = L'ura), celui de l'événement `ENCOUNTER_START`. Réel et stable ; c'est aussi celui qu'utilise Warcraft Logs. |
| **spellID** | Identifiant Blizzard d'un sort. Utilisé ici pour trois choses distinctes : les **capacités de boss**, les **défensifs**, et les **talents**. |
| **talent** | Un nœud d'arbre de talents, identifié par son spellID. Sa présence ou son absence modifie le cooldown de certains sorts. |

### Côté planification

| Terme | Ce que c'est |
|---|---|
| **capacité de boss** | Un sort que lance le boss, décrit dans l'addon avec son horaire théorique. C'est la cible d'une planification. |
| **occurrence** | Une instance précise d'une capacité dans le combat. La 1ʳᵉ *Discordant Beam*, la 2ᵉ, la 3ᵉ… Numérotées à partir de **1**, dans l'ordre chronologique. |
| **défensif** | Un sort de réduction de dégâts ou de soin de groupe qu'on planifie contre une occurrence. |
| **external** | Un défensif fourni par un joueur **autre que le soigneur** (Anti-Magic Zone, Rallying Cry, Darkness…). Par opposition aux CD du soigneur lui-même. |
| **assignation** | Le lien « ce joueur lance ce défensif sur cette occurrence ». C'est l'unité de base d'un plan — une ligne `u;` du format. |

### Côté ECP (notions internes)

Vous ne produisez **aucune** de ces valeurs. Elles sont listées parce que §10 explique
comment l'addon les fabrique à partir de ce que vous envoyez, et parce que les messages
d'erreur que verra l'utilisateur les emploient.

| Terme | Ce que c'est |
|---|---|
| **variante** | Un plan complet couvrant **tout un donjon** : un soigneur, ses talents, les externals du groupe, et toutes les assignations de tous les boss. Un joueur peut en avoir plusieurs par donjon (une par composition, une par stratégie…) et choisit celle qui tourne en combat. |
| **profil de heal** | L'identité de soin d'une variante : `MONK`, `PRIEST_HOLY`, `SHAMAN`… Le prêtre est la seule classe à deux profils (Discipline et Sacré ont des sorts et des plans distincts). |
| **defKey** | Clé interne d'un défensif dans le catalogue de l'addon. Soit un spellID nu (`115310`), soit un spellID **suffixé d'un numéro de variante de cooldown** (`740:0` = Tranquillité 180 s, `740:1` = la même à 150 s). |
| **variante de CD** | Le fait qu'un même sort ait plusieurs cooldowns possibles selon les talents. C'est la raison d'être du suffixe `:0`/`:1`. |
| **token** | Une *instance assignable* d'un defKey. Quand deux Death Knights portent AMZ, leurs deux tokens sont `51052:0#1` et `51052:0#2` — c'est ce qui permet de suivre les deux cooldowns séparément. |
| **occKey** | Clé interne d'une occurrence : `<spellID de la capacité>:<numéro>`, par exemple `1265464:2`. |
| **offset** | Décalage fin, en millisecondes, appliqué à une assignation (« lance-le 1,5 s plus tôt »). Borné à ±12 000 ms. |

---

## 4. Principe directeur

> **Vous envoyez des données brutes. L'addon est la source de vérité.**

Le format ne transporte **que de la donnée de jeu réelle** : spellID, encounterID,
zoneID, specID, identifiants **opaques** de joueur, listes de talents. Aucune clé interne
à ECP n'y figure et vous n'avez jamais à en fabriquer une.

C'est l'addon qui, à partir de ces données, décide :

- quelle **variante de cooldown** s'applique (`740` devient `740:0` ou `740:1`) ;
- ce que le groupe **fournit comme externals** ;
- comment numéroter les **instances** quand plusieurs joueurs portent le même sort ;
- à quelle **occurrence interne** correspond votre couple (capacité, numéro).

Corollaire important : la **qualité de vos données conditionne la justesse du plan**.
Une liste de talents incomplète produit un plan syntaxiquement valide mais faux (§11).

Deuxième principe, hérité de la version précédente et conservé :

> **Le texte est le contrat, pas la structure de données.**

Chaque implémentation reconstruit ce qu'elle veut en mémoire ; seule la chaîne fait foi.
Pas d'imbrication, pas de récursion, pas de types — uniquement des découpages de chaîne.

---

## 5. Le format

### 5.1 Enregistrements

Une **ligne** = un enregistrement. Le **premier champ** est son **type**. Les champs
sont séparés par `;`. Dans un champ, `,` sépare les éléments d'une liste.

```
ecp;2;<kind>                 enveloppe        OBLIGATOIRE, première ligne
z;<zoneID>                   donjon           OBLIGATOIRE si kind=variant
b;<encID>                    boss ciblé       OBLIGATOIRE si kind=boss
n;<titre>                    titre proposé    optionnel
r;<id>;<rôle>;<classe>;<specID>;<spé>;<talent>,…   roster       1 ligne par joueur
h;<id>                       le soigneur      OBLIGATOIRE
u;<encID>;<bossSpell>;<n>;<id>;<defSpell>[;<offsetMs>]       assignation, 1 ligne
k;<n>                        nombre de lignes u;   optionnel, fortement recommandé
```

**Deux natures d'import**, portées par `kind` :

- `variant` — un **donjon entier**. À l'import, l'addon crée une nouvelle variante et
  demande son nom à l'utilisateur. Tout le reste est dicté par vos données.
- `boss` — un **seul boss**. À l'import, l'addon **écrase** le plan de ce boss dans la
  variante que l'utilisateur a sous les yeux, sans toucher aux autres boss.

**Tout est plat.** Une assignation = une ligne, sans regroupement ni sous-structure.
C'est plus verbeux qu'un format compact (~4 Ko pour un donjon complet) mais c'est ce qui
rend le format trivial à produire dans n'importe quel langage, et ce qui permet à
l'addon de signaler une erreur au numéro de ligne près.

**Ordre.** La ligne `ecp;` doit être la première ligne non vide. Toutes les autres sont
**indépendantes de l'ordre** — à une exception près, décisive : l'ordre des lignes `r;`
détermine la numérotation des instances (§11.2).

### 5.2 Conventions de valeurs

| Champ | Forme attendue |
|---|---|
| `zoneID`, `encID`, `bossSpell`, `defSpell`, `talent` | entiers décimaux |
| `n` (numéro d'occurrence) | entier ≥ 1 |
| `offsetMs` | entier signé, millisecondes, borné à ±12000 par l'addon |
| `classe` | jeton majuscule sans espace : `DEATHKNIGHT`, `DEMONHUNTER`, `PRIEST`, `EVOKER`… |
| `spé` | nom anglais de la spécialisation : `Holy`, `Discipline`, `Restoration`, `Preservation`, `Mistweaver`, `Frost`… |
| `id` | jeton d'identité **opaque et stable**. Sert **uniquement de clé de jointure** entre `r;`, `h;` et `u;`. Aucun nom de personnage : l'addon ne le compare à personne en jeu et ne l'affiche que dans ses messages d'erreur. |
| `rôle` | `TANK`, `HEALER` ou `DAMAGER` |
| `specID` | identifiant Blizzard de spécialisation (257 = Prêtre Sacré, 251 = DK Frost…) |
| `titre` | texte libre |

### 5.3 Exemple minimal

```
ecp;2;boss
b;2068
r;p1;DAMAGER;DEATHKNIGHT;251;Frost;51052,374383
r;p2;DAMAGER;DEATHKNIGHT;252;Unholy;51052,374383
r;p3;HEALER;PRIEST;257;Holy;64843,419110,200183
h;p3
u;2068;1265421;1;p1;51052;-1500
u;2068;1265421;1;p3;64843
u;2068;1265464;2;p2;51052
k;3
```

Lecture : sur L'ura, à la **première** *Dirge of Despair*, le soigneur `p3` lance
*Divine Hymn* et le DK `p1` pose une *Anti-Magic Zone* 1,5 s plus tôt ; à la **deuxième**
*Discordant Beam*, le DK `p2` pose la sienne.

Les identifiants `p1`/`p2`/`p3` sont arbitraires : n'importe quel jeton stable convient
(index, hash, GUID). Ils ne servent qu'à relier les trois blocs entre eux.

---

## 5bis. Transport — enveloppe `ecp64:`

Le document `ecp;2` est multi-ligne, ce qui l'expose à trois accidents de copier-coller :
un `\n` avalé, une sélection à la souris qui rate la dernière ligne — or c'est `k;`, le
contrôle d'intégrité — ou un utilisateur qui « corrige » la chaîne à la main parce
qu'elle ressemble à du texte.

Le format canonique reste le texte. Il reçoit une **enveloppe de transport optionnelle** :

```
ecp64:<base64 du document ecp;2 complet>
```

**C'est la forme que doit émettre un outil externe par défaut** : un seul bloc opaque,
monoligne, sélectionnable au triple-clic, tout-ou-rien.

**Paramètres** : alphabet **standard** (`+` et `/`, pas la variante URL-safe — rien ici
ne transite par une URL), padding `=` conservé, aucun retour à la ligne inséré dans le
base64. L'entrée est le document complet, `\n` compris, ligne d'en-tête incluse.

### Le point qui évite un bug classique

Le percent-encodage du §6 garantit que le document `ecp;2` est **purement ASCII 7 bits**.
`btoa()` peut donc être appelé **directement**, sans passer par `TextEncoder` ni par les
contorsions habituelles pour les caractères multi-octets : elles sont déjà faites en
amont, au niveau des feuilles.

```js
const wire = 'ecp64:' + btoa(encodePlan(plan));

function readWire(s) {
  s = s.trim();
  if (s.startsWith('ecp64:')) return decodePlan(atob(s.slice(6)));
  if (s.startsWith('ecp;'))   return decodePlan(s);
  throw new Error('format non reconnu');
}
```

Si votre implémentation lève sur un caractère hors Latin-1 au moment du `btoa`, c'est le
signe que l'encodage des feuilles a été omis quelque part — corrigez là, pas ici.

### Aiguillage à l'import

Trois cas mutuellement exclusifs, testés dans cet ordre :

| Préfixe | Traitement |
|---|---|
| `ecp64:` | décoder le base64 → document `ecp;2` → parseur normal |
| `ecp;` | document `ecp;2` direct |
| autre | Base64/CBOR natif hérité (canal de partage en jeu, annexe A) |

Aucune ambiguïté : `ecp64:` et `ecp;` divergent au 4ᵉ caractère, et l'alphabet Base64 ne
contient ni `;` ni `:`.

---

## 6. Échappement

Jeu de caractères **sûr**, unique et sans exception :

```
A-Z   a-z   0-9   _   .   :   #   @   -
```

Tout autre octet est encodé `%XX` — deux chiffres hexadécimaux **majuscules** —
**octet par octet, en UTF-8**.

Ce jeu laisse lisibles tous les identifiants numériques et la plupart des noms de
identifiants de joueur usuels (`-` et `_` passent intacts). Un identifiant contenant des
accents, des espaces ou des séparateurs devient verbeux, ce qui est sans importance.

`:`, `#` et `@` sont dans le jeu sûr sans être utilisés par `ecp;2` : ils y figurent par
continuité avec la machinerie de parsing, et parce qu'ils apparaissent dans les clés
internes que l'addon affiche dans ses messages. À l'inverse `=` et `~` sont **exclus**
du jeu sûr bien qu'inutilisés : cela réserve leur usage pour de futurs enregistrements
sans imposer un changement de version.

### ⚠️ Ce n'est pas `encodeURIComponent`

`encodeURIComponent` laisse intacts `~ ! ' ( ) *`. Écrivez la fonction vous-même.

**JavaScript**

```js
const SAFE = /[A-Za-z0-9_.:#@-]/;

function enc(value) {
  let out = '';
  for (const b of new TextEncoder().encode(String(value))) {
    const ch = String.fromCharCode(b);
    out += SAFE.test(ch) ? ch : '%' + b.toString(16).toUpperCase().padStart(2, '0');
  }
  return out;
}

function dec(s) {
  if (!/^(?:[^%]|%[0-9A-Fa-f]{2})*$/.test(s)) throw new Error('échappement invalide');
  const bytes = [];
  for (let i = 0; i < s.length; i++) {
    if (s[i] === '%') { bytes.push(parseInt(s.substr(i + 1, 2), 16)); i += 2; }
    else bytes.push(s.charCodeAt(i));
  }
  return new TextDecoder().decode(Uint8Array.from(bytes));
}
```

**Lua** (référence, côté addon)

```lua
local function enc(v)
    return (tostring(v):gsub("[^A-Za-z0-9_%.:#@%-]", function(c)
        return ("%%%02X"):format(c:byte())
    end))
end
```

Les deux opèrent sur des **octets** et produisent donc le même résultat. C'est le seul
point où les langages divergent en surface : Lua manipule nativement des chaînes
d'octets, JavaScript doit passer par `TextEncoder`/`TextDecoder`.

---

## 7. Décodage

Sept étapes, identiques dans tous les langages :

1. Découper la chaîne complète sur `\n`.
2. Par ligne : retirer `\r`, puis les espaces en tête et en queue. Ignorer les lignes vides.
3. Vérifier que la première ligne retenue commence par `ecp;`. Sinon → rejet.
4. Découper la ligne sur `;` → tableau de champs. `champs[0]` = type.
5. Type **inconnu** → **ignorer la ligne** (compatibilité ascendante, §13).
6. Découper les champs de liste sur `,`.
7. **Percent-décoder uniquement les feuilles, à la toute fin.**

### 🔑 L'invariant

L'étape 7 est ce qui rend le format sûr. Tant qu'aucun décodage n'a eu lieu, **aucune
donnée ne peut contenir un séparateur** — c'est garanti mathématiquement par le jeu sûr
du §6. Décoder plus tôt réintroduit `;` et `,` dans les données et casse tout, de façon
intermittente : seuls les plans contenant un identifiant exotique échouent, ce qui est
pénible à diagnostiquer.

**À écrire en commentaire au-dessus de votre parseur.**

---

## 8. Encodage

Le miroir exact :

1. Émettre `ecp;2;<kind>`.
2. Émettre `z;` **ou** `b;` selon le `kind`, puis `n;` si vous en avez un.
3. Émettre une ligne `r;` **par joueur**, dans un ordre **stable** (§11.2).
4. Émettre `h;`.
5. Émettre une ligne `u;` par assignation.
6. Émettre `k;<nombre de lignes u;>`.
7. Joindre par `\n`.
8. **Encoder chaque feuille avec `enc()` avant de la concaténer**, jamais après.

Omettre `offsetMs` quand il vaut 0. Pour que deux exports du même plan soient
comparables octet pour octet, triez les lignes `u;` de façon déterministe (par `encID`,
puis `bossSpell`, puis `n`, puis `id`).

---

## 9. Sémantique champ par champ

### `ecp;<format>;<kind>`

`format` vaut `2`. Un décodeur qui rencontre un format supérieur au sien doit s'arrêter
et le dire clairement, pas tenter de deviner.

`kind` vaut `variant` ou `boss`. Un `kind` inconnu est rejeté, jamais interprété.

### `z;<zoneID>` — le donjon

`instanceID` Blizzard. Obligatoire pour `kind=variant`, où il désigne le donjon que
couvre la variante. Table complète en §14.1.

Inutile pour `kind=boss` : l'addon retrouve le donjon depuis l'`encID`.

### `b;<encID>` — le boss ciblé

Obligatoire pour `kind=boss`. Rend la cible explicite **même quand le plan est vide** —
un import à zéro assignation est légitime et signifie « vide le plan de ce boss ».

Toutes les lignes `u;` doivent porter ce même `encID`, sinon rejet.

### `n;<titre>` — titre proposé

Purement indicatif. Pour un import de variante, l'addon **demande le nom à
l'utilisateur** et se contente de préremplir le champ avec cette valeur. Ne comptez pas
dessus pour identifier quoi que ce soit.

### `r;<id>;<rôle>;<classe>;<specID>;<spé>;<talents>` — le roster

Un joueur du groupe. C'est **la ligne la plus importante du format** : elle alimente
toute la résolution du §10.

- `id` — jeton d'identité **opaque et stable**, sans aucune signification. Clé de
  jointure entre `r;`, `h;` et `u;`, rien d'autre. Aucun nom de personnage n'est
  transmis ni attendu.
- `rôle` — `TANK` / `HEALER` / `DAMAGER`. Sert de contrôle de cohérence sur `h;`.
- `classe` — jeton de classe. Redondant avec `specID`, conservé pour des messages
  d'erreur lisibles ; une divergence entre les deux est signalée comme une donnée
  incohérente.
- `specID` — **source de vérité de l'identité**. Ni le rôle ni le nom de spé ne suffisent
  à identifier une classe (§11.3).
- `spé` — nom anglais de la spécialisation. Redondant avec `specID`, sert de repli si
  celui-ci est inconnu de l'addon (nouvelle spé).
- `talents` — liste de spellID. Elle doit être **complète** : l'absence d'un talent est
  une information (§11.1).

Un joueur qui n'apparaît dans aucune ligne `u;` a toute sa place dans le roster : il
contribue aux externals disponibles du groupe (§10, étape 5).

### `h;<id>` — le soigneur

Référence l'`id` d'une ligne `r;`. L'addon en dérive le profil de heal à partir de la
spécialisation de ce joueur. Le `rôle` de la ligne visée doit être `HEALER`, sinon
l'import est refusé — c'est le garde-fou contre un `h;` qui pointe le mauvais id.

Obligatoire, et pour une bonne raison : c'est ce qui distingue les CD du soigneur des
externals fournis par le reste du groupe, deux catégories que l'addon traite très
différemment. C'est aussi ce qui lève une ambiguïté réelle sur *Zephyr* (§11.4).

Si votre plan n'a pas de soigneur désigné, il n'est pas exprimable dans ce format.

### `u;<encID>;<bossSpell>;<n>;<id>;<defSpell>[;<offsetMs>]` — une assignation

L'unité de base du plan.

- `encID` — le boss. Présent sur chaque ligne pour qu'elle soit auto-suffisante.
- `bossSpell` — spellID de la capacité de boss visée. Liste de référence en §14.4.
- `n` — **numéro d'occurrence**, à partir de 1. `n=2` désigne le deuxième lancement de
  cette capacité dans le combat, pas la deuxième minute ni le deuxième pack.
- `id` — qui lance. Référence l'`id` d'une ligne `r;`.
- `defSpell` — spellID du défensif, **sans aucun suffixe** : envoyez `740`, pas `740:1`.
- `offsetMs` — optionnel. Décalage en millisecondes, négatif pour « plus tôt ».

### `k;<n>` — contrôle d'intégrité

Nombre total de lignes `u;`. Sert exclusivement à détecter un **collage tronqué**, qui
est le mode de défaillance numéro un du copier-coller : sans ce contrôle, un plan coupé
en deux s'importe à moitié sans que personne ne le remarque, et le joueur ne s'en aperçoit
qu'en combat. Discordance → rejet.

---

## 10. Ce que l'addon fait de vos données

Cette section n'est pas de la documentation d'implémentation : elle explique **pourquoi
vos données doivent être ce qu'elles sont**. Chaque étape ci-dessous peut échouer, et
chaque échec produit un rejet visible par l'utilisateur.

**1. Le roster devient des ensembles de talents.**
Chaque ligne `r;` donne un ensemble `{ spellID → présent }`.

**2. `h;` devient un profil de heal.**
`specID` → classe + spé → `PRIEST_HOLY`, `MONK`, `SHAMAN`… Si le rôle du joueur désigné
n'est pas `HEALER`, ou si sa spé n'est pas une spé de soin, rejet.

**3. Chaque `defSpell` devient un defKey, via les talents de son lanceur.**
C'est la conversion centrale. L'addon connaît, pour chaque sort défensif, ses variantes
de cooldown et les talents qui les départagent. Il retient celle dont **tous** les
talents requis sont présents chez ce joueur et **aucun** des talents interdits.

Exemple : `defSpell = 740` lancé par un druide.
- talents contenant `740` mais pas `197073` → `740:0`, cooldown **180 s**
- talents contenant `740` **et** `197073` → `740:1`, cooldown **150 s**

Aucune variante ne correspond → **écart rapporté**, jamais de choix par défaut
silencieux. Le cas typique est une liste de talents incomplète.

**4. Les talents du soigneur deviennent son arsenal.**
L'addon parcourt tous les défensifs de soin de son profil et retient ceux que ses
talents rendent disponibles. C'est ce qui alimente les propositions de l'éditeur de plan
et le calcul de disponibilité.

**5. Les talents des autres deviennent les externals du groupe.**
Ils sont dérivés du **roster**, pas des assignations : un Death Knight qui a AMZ le
fournit qu'il soit assigné ou non. C'est pourquoi il faut lister **tous** les joueurs,
même ceux qui n'apparaissent dans aucune ligne `u;`.

**6. Les porteurs multiples reçoivent un numéro d'instance.**
Deux DK avec AMZ → l'un devient `#1`, l'autre `#2`, dans **l'ordre d'apparition dans le
bloc `r;`**. Ces numéros permettent à l'addon de suivre les deux cooldowns séparément —
si `#1` a posé son AMZ il y a 40 s, il ne peut pas la reposer, mais `#2` le peut.

**7. `(bossSpell, n)` devient une clé d'occurrence.**
L'addon génère sa propre timeline du boss et vérifie que la n-ième occurrence de cette
capacité existe. Sinon, rejet.

**8. Cohérence classe / défensif.**
Le défensif résolu doit appartenir à la classe du lanceur. Un prêtre qui lance
*Anti-Magic Zone* est un écart, pas une donnée à ingérer.

**9. Pour un import de boss uniquement — compatibilité avec la variante cible.**
Les tokens résolus doivent tous être **plaçables dans la variante existante**. Si votre
plan fait poser une AMZ 3 min par un DK alors que la variante du joueur déclare une AMZ
4 min, l'import est refusé avec un message nommant le sort. Rien n'est écrit tant que
tout ne passe pas.

---

## 11. Règles qui ne se devinent pas

### 11.1 La liste de talents doit être complète

Certains défensifs sont définis par l'**absence** d'un talent. *Nature's Swiftness*
(`378081`) n'a aucun talent requis : elle est disponible **sauf si** le chaman a pris
*Ancestral Swiftness* (`443454`), qui la remplace.

Conséquence : envoyer une liste partielle ne dégrade pas la résolution, elle la **fausse**.
Un chaman dont vous auriez omis `443454` se verra attribuer un sort qu'il n'a pas.

Envoyez la liste complète des talents du joueur. L'addon ignore silencieusement ceux
qu'il ne connaît pas — il n'y a aucun coût à en envoyer trop, et un risque réel à en
envoyer trop peu.

### 11.2 L'ordre du roster est contractuel

La numérotation `#1` / `#2` des porteurs multiples suit l'ordre des lignes `r;`.

Si votre outil réordonne le roster entre deux exports du même groupe, réimporter un boss
**intervertit silencieusement** deux joueurs par rapport aux boss déjà planifiés : `p1`
devient `#2` et hérite des assignations de `p2`.

C'est le seul endroit du format où une erreur ne produit **ni rejet, ni message** : le
plan reste valide, il est simplement faux. Fixez un ordre déterministe et tenez-le.

### 11.3 Certains défensifs dépendent de la spé, pas des talents

*Vampiric Embrace* (`15286`) n'a aucun talent associé : il est réservé au prêtre
**Ombre**. Un prêtre Sacré ne peut pas le fournir. C'est la spécialisation qui tranche,
et elle seule — d'où l'importance de renseigner `specID` correctement même pour les
joueurs non-soigneurs.

C'est aussi pourquoi `specID` existe : **ni le rôle ni le nom de spé ne suffisent à
identifier une classe.** *Holy* est à la fois Paladin et Prêtre, *Restoration* à la fois
Druide et Chaman, *Frost* à la fois Mage et Death Knight — et `HEALER` + *Holy* reste
ambigu. Seul `specID` lève l'ambiguïté par construction. Les champs `classe` et `spé`
sont conservés en redondance, pour des messages d'erreur lisibles et comme repli si
l'addon ne connaît pas encore ce `specID` ; une divergence entre les deux est signalée
comme une donnée incohérente plutôt que tranchée en silence.

### 11.4 *Zephyr* est ambigu sans `h;`

*Zephyr* (`374227`) est un talent d'Évocateur. Porté par un Évocateur **DPS**, c'est un
external du groupe. Porté par un Évocateur **Préservation**, c'est un CD de soin — deux
catégories que l'addon range et affiche différemment.

Le seul discriminant est `h;` : si le lanceur est le soigneur désigné, c'est un CD de
soin. C'est l'une des raisons pour lesquelles `h;` est obligatoire.

### 11.5 Le numéro d'occurrence est un rang, pas un horaire

`n=3` signifie « la troisième fois que cette capacité est lancée », dans la timeline que
l'addon connaît. Si votre outil compte les occurrences autrement — en ignorant une phase,
en fusionnant deux sorts proches, en partant de 0 — les plans seront décalés sans être
invalides.

L'addon modélise un combat de **300 secondes** ; les occurrences au-delà n'existent pas
pour lui.

### 11.6 Un import de boss écrase, il ne fusionne pas

`kind=boss` remplace **intégralement** le plan du boss visé dans la variante en cours
d'édition. Les assignations que le joueur avait posées à la main sur ce boss
disparaissent, y compris celles que le format ne sait pas exprimer (§12).

Les autres boss ne sont pas touchés.

### 11.7 Un plan est indexé sur une version de contenu

Les capacités de boss, leurs spellID et leurs horaires changent d'un patch à l'autre, et
le pool de donjons Mythique+ change de saison. L'addon embarque une table de contenu par
version de client et valide vos identifiants contre **celle qui tourne**.

Un plan écrit pour le pool 12.1 est donc rejeté sur un client 12.0, et réciproquement.
Ce n'est pas un bug ; les données n'ont réellement pas cours.

---

## 12. Ce que le format ne peut pas exprimer

**Les appels génériques.** L'addon connaît trois pseudo-défensifs sans spellID :
« Defensive » (demander à tout le monde son défensif personnel), « Empty the bag »
(tout lâcher) et « Ramp » (préparation de soin). Ils ne sont pas représentables, par
choix : le format ne transporte que de vrais sorts. Ces annotations restent posées à la
main dans l'addon — et sont donc **effacées** par un import de boss (§11.6).

**Les trinkets.** Un objet du toolkit soigneur (*Soulcoiler Ritual Vessel*) ne se résout
pas par les talents mais par l'équipement, que le format ne transporte pas. À poser à la
main.

**Les compositions sans soigneur.** `h;` est obligatoire.

**Le partage entre joueurs en jeu.** Il passe par un canal séparé et un encodage
différent (annexe A). Ce format-ci est réservé à l'import externe.

---

## 13. Validation, rejets et compatibilité

L'import **rejette en bloc** plutôt que d'accepter partiellement. Un plan à moitié
importé est pire qu'un import raté : le joueur ne s'en aperçoit qu'en combat.

**Rejet de forme**

- première ligne non vide ≠ `ecp;<format>;<kind>` ;
- `format` supérieur à celui du décodeur → message « exporté par une version plus récente » ;
- `kind` inconnu ;
- `h;` absent, ou `z;`/`b;` absent selon le `kind` ;
- `%` non suivi de deux chiffres hexadécimaux ;
- champ numérique non convertible ;
- `k;` présent et discordant → « plan tronqué » ;
- `kind=boss` avec une ligne `u;` dont l'`encID` diffère de `b;`.

**Rejet de résolution** (§10)

- `zoneID` ou `encID` inconnu du pool de contenu courant ;
- `bossSpell` inconnu de ce boss, ou occurrence `n` hors plage ;
- `defSpell` absent du catalogue ;
- aucune variante ne correspond aux talents du lanceur ;
- lanceur ou soigneur absent du bloc `r;` ;
- spé du soigneur non soignante ;
- classe du défensif ≠ classe du lanceur ;
- pour `kind=boss` : token non plaçable dans la variante cible.

**Compatibilité ascendante**

- Type de ligne inconnu → **ignoré**. C'est le mécanisme d'extension : un enregistrement
  pourra être ajouté sans casser les décodeurs déployés.
- Champs surnuméraires en fin de ligne connue → **ignorés**. Un enregistrement peut
  gagner un champ optionnel sans changer de version.
- Le numéro de format ne change que pour une **rupture** : séparateurs, règle
  d'échappement, ou sémantique d'un champ existant.

N'ajoutez jamais un champ **obligatoire** à un enregistrement existant sans incrémenter
le format.

---

## 14. Données de référence

### 14.1 Donjons et `zoneID`

Le pool dépend de la version du client. Un `zoneID` valide sur un pool ne l'est pas
forcément sur l'autre (§11.7).

**Pool 12.0.x**

| Donjon | zoneID |
|---|---|
| Windrunner Spire | 2805 |
| Maisara Caverns | 2874 |
| Nexus-Point Xenas | 2915 |
| Magister's Terrace | 2811 |
| Algeth'ar Academy | 2526 |
| Seat of the Triumvirate | 1753 |
| Skyreach | 1209 |
| Pit of Saron | 658 |

**Pool 12.1.x**

| Donjon | zoneID |
|---|---|
| Altar of Fangs | 2993 |
| Ruby Life Pools | 2521 |
| Temple of Sethraliss | 1877 |
| Kings' Rest | 1762 |
| The Blinding Vale | 2859 |
| Voidscar Arena | 2923 |
| Den of Nalorakk | 2825 |
| Murder Row | 2813 |

### 14.2 Profils de heal

Dérivés de `classe` + `spé` du joueur désigné par `h;`.

| specID | classe | spé | profil |
|---|---|---|---|
| 105 | `DRUID` | Restoration | `DRUID` |
| 1468 | `EVOKER` | Preservation | `EVOKER` |
| 270 | `MONK` | Mistweaver | `MONK` |
| 65 | `PALADIN` | Holy | `PALADIN` |
| 256 | `PRIEST` | Discipline | `PRIEST_DISC` |
| 257 | `PRIEST` | Holy | `PRIEST_HOLY` |
| 264 | `SHAMAN` | Restoration | `SHAMAN` |

Les spécialisations **non soignantes** comptent aussi : ce sont elles qui fournissent les
externals. L'addon connaît la table complète des specID de toutes les classes ; les plus
utiles ici sont `250/251/252` (Death Knight), `577/581` (Chasseur de démons),
`1467/1473` (Évocateur DPS), `258` (Prêtre Ombre) et `71/72/73` (Guerrier).

Le prêtre est la seule classe à deux profils de soin. Paladin Sacré est une classe à
**une** spé de soin — ne pas confondre les deux situations.

### 14.3 Défensifs reconnus

Ce sont les seules valeurs acceptées pour `defSpell`. Tout autre spellID est un écart.
« Talents décisifs » indique les talents qui départagent les variantes de cooldown : si
vous ne les remontez pas, la résolution échoue ou se trompe (§11.1).

**Externals** — fournis par les non-soigneurs

| defSpell | Sort | Classe | Cooldowns possibles | Talents décisifs |
|---|---|---|---|---|
| 51052 | Anti-Magic Zone | DEATHKNIGHT | 180 s / 240 s | 51052, 374383 |
| 196718 | Darkness | DEMONHUNTER | 300 s / 180 s | 196718, 389783 |
| 374227 | Zephyr | EVOKER | 120 s | 374227 · cf. §11.4 |
| 15286 | Vampiric Embrace | PRIEST | 120 s | aucun — spé **Shadow** requise |
| 97462 | Rallying Cry | WARRIOR | 180 s | 97462 |

**CD de soin** — fournis par le joueur désigné par `h;`

| defSpell | Sort | Classe | Cooldowns possibles | Talents décisifs |
|---|---|---|---|---|
| 740 | Tranquility | DRUID | 180 s / 150 s | 740, 197073 |
| 391528 | Convoke the Spirits | DRUID | 120 s / 60 s | 391528, 393371 |
| 33891 | Incarnation: Tree of Life | DRUID | 180 s / 120 s | 33891, 393371 |
| 132158 | Nature's Swiftness *(druide)* | DRUID | 60 s / 45 s | 132158, 382550 |
| 359816 | Dream Flight | EVOKER | 120 s | 359816 |
| 370537 | Stasis | EVOKER | 90 s | 370537 |
| 363534 | Rewind | EVOKER | 180 s / 120 s | 363534, 381922 |
| 374227 | Zephyr | EVOKER | 120 s | 374227 · cf. §11.4 |
| 115310 | Revival | MONK | 180 s | 115310 |
| 388615 | Restoral | MONK | 180 s | 388615 |
| 443028 | Celestial Conduit | MONK | 90 s | 443028 |
| 322118 | Invoke Yu'lon | MONK | 60 s / 120 s | 322118, 388212 |
| 325197 | Invoke Chi-Ji | MONK | 60 s / 120 s | 325197, 388212 |
| 31821 | Aura Mastery | PALADIN | 180 s / 150 s | 31821, 392911 |
| 31884 | Avenging Wrath | PALADIN | 120 s / 105 s | 31884, 1241511 |
| 216331 | Avenging Crusader | PALADIN | 120 s / 105 s | 216331, 1241511 |
| 375576 | Divine Toll | PALADIN | 45 s / 30 s | 375576, 379391 |
| 114165 | Holy Prism | PALADIN | 45 s / 30 s | 114165, 379391 |
| 64843 | Divine Hymn | PRIEST Holy | 180 s / 120 s | 64843, 419110 |
| 200183 | Apotheosis | PRIEST Holy | 120 s | 200183 |
| 47788 | Guardian Spirit | PRIEST Holy | 120 s | 47788 |
| 472433 | Evangelism | PRIEST Disc | 90 s | 472433 |
| 421453 | Ultimate Penitence | PRIEST Disc | 240 s | 421453 |
| 62618 | Power Word: Barrier | PRIEST Disc | 180 s | 62618 |
| 98008 | Spirit Link Totem | SHAMAN | 180 s | 98008 |
| 114052 | Ascendance | SHAMAN | 120 s / 180 s | 114052, 462440 |
| 108280 | Healing Tide Totem | SHAMAN | 120 s / 180 s | 108280, 462440 |
| 378081 | Nature's Swiftness *(chaman)* | SHAMAN | 60 s | **absence** de 443454 |
| 443454 | Ancestral Swiftness | SHAMAN | 30 s | 443454 |

Certains sorts sont mutuellement exclusifs par choix de talent — Yu'lon **ou** Chi-Ji,
Ascendance **ou** Healing Tide Totem, Restoral **ou** Revival, Ultimate Penitence **ou**
Power Word: Barrier, Avenging Wrath **ou** Avenging Crusader, Incarnation **ou** Convoke,
Divine Toll **ou** Holy Prism.
Une liste de talents cohérente n'en contient jamais deux du même couple.

### 14.4 Capacités de boss

Les `bossSpell` acceptés dépendent du boss. La liste complète — 255 sorts sur les deux
pools, avec donjon, `encounterID`, spellID et nom — est fournie séparément en CSV.

Attention : un boss expose souvent des capacités que l'addon connaît pour la
reconnaissance en combat mais qui n'ont **pas** d'horaire théorique, et ne sont donc
**pas planifiables**. Le CSV les distingue par une colonne dédiée. N'émettez de lignes
`u;` que vers des capacités planifiables.

---

## 15. Exemple commenté

### Import de donjon complet

```
ecp;2;variant
z;1753
n;Seat%20prog%20semaine%202
r;p1;HEALER;PRIEST;257;Holy;64843,419110,200183
r;p2;DAMAGER;DEATHKNIGHT;251;Frost;51052,374383
r;p3;DAMAGER;DEATHKNIGHT;252;Unholy;51052,374383
r;p4;DAMAGER;WARRIOR;72;Fury;97462
r;p5;DAMAGER;EVOKER;1467;Devastation;374227
h;p1
u;2065;1263297;1;p2;51052
u;2065;1263399;1;p1;64843
u;2068;1265421;1;p1;200183
u;2068;1265421;1;p3;51052
u;2068;1265464;2;p4;97462
u;2068;1265464;3;p5;374227
k;6
```

Ce que l'addon en déduit :

- **Profil de heal** : `p1` a le specID 257 → prêtre Sacré → `PRIEST_HOLY`.
- **Arsenal du soigneur** : ses talents donnent *Divine Hymn* en version **120 s** (il a
  `419110`) et *Apotheosis*.
- **Externals du groupe** : AMZ ×2 (`p2` et `p3`), Rallying Cry ×1 (`p4`), Zephyr ×1
  (`p5`, Évocateur DPS → external, pas CD de soin).
- **Instances** : `p2` et `p3` ont tous deux `374383`, donc le **même** defKey `51052:0`
  (180 s) → deux exemplaires du même cooldown, suivis séparément. `p2` apparaît en
  premier dans le bloc `r;` → `#1` ; `p3` → `#2`.
- **Assignations** : réparties sur deux boss (Zuraal et L'ura), rattachées aux
  occurrences numérotées de chaque capacité.

> À noter : si `p3` n'avait **pas** `374383`, son AMZ résoudrait vers `51052:1` (240 s),
> un defKey **différent**. Il n'y aurait alors aucune instance `#N` — juste deux externals
> distincts, chacun en un exemplaire. La numérotation `#N` ne survient qu'entre porteurs
> d'un cooldown strictement identique.

À l'import, l'addon demandera un nom de variante, prérempli avec « Seat prog semaine 2 ».

---

## 16. Implémentation JavaScript de référence

```js
const SAFE = /[A-Za-z0-9_.:#@-]/;
const FORMAT = 2;

function enc(v) {
  let out = '';
  for (const b of new TextEncoder().encode(String(v))) {
    const ch = String.fromCharCode(b);
    out += SAFE.test(ch) ? ch : '%' + b.toString(16).toUpperCase().padStart(2, '0');
  }
  return out;
}

function dec(s) {
  if (!/^(?:[^%]|%[0-9A-Fa-f]{2})*$/.test(s)) throw new Error('échappement invalide: ' + s);
  const bytes = [];
  for (let i = 0; i < s.length; i++) {
    if (s[i] === '%') { bytes.push(parseInt(s.substr(i + 1, 2), 16)); i += 2; }
    else bytes.push(s.charCodeAt(i));
  }
  return new TextDecoder().decode(Uint8Array.from(bytes));
}

const num = (s, what) => {
  const n = Number(s);
  if (!Number.isFinite(n)) throw new Error('nombre invalide (' + what + '): ' + s);
  return n;
};

// --- décodage (§7) --------------------------------------------------------
export function decodePlan(text) {
  const lines = String(text).split('\n')
    .map(l => l.replace(/\r/g, '').trim())
    .filter(l => l.length > 0);
  if (!lines.length) throw new Error('chaîne vide');

  const head = lines[0].split(';');
  if (head[0] !== 'ecp') throw new Error('ce n’est pas un plan ECP');
  const format = num(head[1], 'format');
  if (format > FORMAT) throw new Error('plan exporté par une version plus récente');
  const kind = head[2];
  if (kind !== 'variant' && kind !== 'boss') throw new Error('kind inconnu: ' + kind);

  const out = { format, kind, roster: [], uses: [] };
  let expected = null;

  for (const line of lines.slice(1)) {
    const f = line.split(';');
    switch (f[0]) {
      case 'z': out.zoneID = num(f[1], 'zoneID'); break;
      case 'b': out.encID  = num(f[1], 'encID');  break;
      case 'n': out.title  = dec(f[1]); break;
      case 'h': out.healer = dec(f[1]); break;
      case 'k': expected   = num(f[1], 'k'); break;

      case 'r': out.roster.push({
                  id:      dec(f[1]),
                  role:    dec(f[2]).toUpperCase(),
                  class:   dec(f[3]).toUpperCase(),
                  specID:  f[4] ? num(f[4], 'specID') : undefined,
                  spec:    dec(f[5]),
                  talents: (f[6] || '').split(',').filter(Boolean).map(t => num(t, 'talent')),
                }); break;

      case 'u': {
        const e = {
          encID:     num(f[1], 'encID'),
          bossSpell: num(f[2], 'bossSpell'),
          n:         num(f[3], 'n'),
          id:        dec(f[4]),
          defSpell:  num(f[5], 'defSpell'),
        };
        if (f[6] !== undefined && f[6] !== '') e.offset = num(f[6], 'offset');
        out.uses.push(e);
        break;
      }

      default: break;   // §13 : type inconnu ⇒ ignoré
    }
  }

  if (!out.healer) throw new Error('h; manquant');
  if (kind === 'variant' && out.zoneID === undefined) throw new Error('z; manquant');
  if (kind === 'boss') {
    if (out.encID === undefined) throw new Error('b; manquant');
    if (out.uses.some(u => u.encID !== out.encID))
      throw new Error('une ligne u; ne correspond pas au boss ciblé');
  }
  const ids = new Set(out.roster.map(r => r.id));
  if (!ids.has(out.healer)) throw new Error('h; référence un id absent du roster');
  for (const u of out.uses)
    if (!ids.has(u.id)) throw new Error('u; référence un id absent: ' + u.id);
  if (expected !== null && expected !== out.uses.length)
    throw new Error(`plan tronqué : ${out.uses.length} assignations lues, ${expected} attendues`);

  return out;
}

// --- encodage (§8) --------------------------------------------------------
export function encodePlan(p) {
  const L = [`ecp;${FORMAT};${p.kind}`];
  if (p.kind === 'variant') L.push('z;' + p.zoneID);
  else                      L.push('b;' + p.encID);
  if (p.title) L.push('n;' + enc(p.title));

  for (const r of p.roster)
    L.push(['r', enc(r.id), enc(r.role), enc(r.class),
            r.specID ?? '', enc(r.spec), (r.talents || []).join(',')].join(';'));

  L.push('h;' + enc(p.healer));

  const uses = [...p.uses].sort((a, b) =>
    a.encID - b.encID || a.bossSpell - b.bossSpell || a.n - b.n ||
    a.id.localeCompare(b.id));
  for (const u of uses) {
    const row = ['u', u.encID, u.bossSpell, u.n, enc(u.id), u.defSpell];
    if (u.offset) row.push(u.offset);
    L.push(row.join(';'));
  }

  L.push('k;' + uses.length);
  return L.join('\n');
}
```

---

## 17. Suite de conformité

Le **vecteur de référence** est l'exemple du §15.

**Décodage**

- [ ] l'exemple du §15 se décode en 5 joueurs et 6 assignations
- [ ] `encode(decode(x)) === x` — round-trip idempotent, octet pour octet
- [ ] `\r\n`, lignes vides et espaces parasites tolérés
- [ ] type de ligne inconnu ignoré sans erreur
- [ ] champ surnuméraire en fin de ligne connue ignoré
- [ ] `offsetMs` absent ⇒ pas de champ `offset` dans l'objet ; présent et négatif ⇒ conservé

**Encodage**

- [ ] un `id` avec accents, apostrophe et espace fait un aller-retour intact
- [ ] un `id` avec `;` ou `,` fait un aller-retour intact (échappement)
- [ ] un `id` de la forme `p1-alt_2` reste lisible, `-` et `_` non échappés
- [ ] `specID` vide (champ omis) accepté, la classe et la spé transmises font foi
- [ ] `offset` nul non émis
- [ ] encodage déterministe : deux objets aux mêmes données produisent la même chaîne
- [ ] roster émis dans l'ordre fourni, jamais retrié (§11.2)

**Rejets** — chacun doit lever, pas retourner un objet partiel

- [ ] `k;` incohérent
- [ ] chaîne tronquée
- [ ] échappement malformé (`%2` en fin de champ)
- [ ] format supérieur (`ecp;3;variant`)
- [ ] en-tête absent
- [ ] `kind` inconnu
- [ ] `h;` manquant, ou référençant un id absent du roster
- [ ] `u;` référençant un id absent du roster
- [ ] `h;` désignant un joueur dont le rôle n'est pas `HEALER`
- [ ] `classe` en désaccord avec le `specID` transmis
- [ ] `kind=variant` sans `z;` / `kind=boss` sans `b;`
- [ ] `kind=boss` avec une ligne `u;` d'un autre `encID`

**Transport `ecp64:`** (§5bis)

- [ ] `readWire('ecp64:' + btoa(texte))` donne le même objet que `decodePlan(texte)`
- [ ] la forme texte nue reste acceptée par `readWire`
- [ ] `btoa` sur la sortie de `encodePlan` ne lève jamais, y compris avec des noms
      accentués, à apostrophe ou idéographiques
- [ ] espaces et retours à la ligne autour de la chaîne `ecp64:` tolérés
- [ ] base64 tronqué ou corrompu → rejet propre, pas un objet partiel
- [ ] chaîne ne commençant par aucun des trois préfixes → rejet

---

## Annexe A — le canal natif (pour information)

Le partage de plans **entre joueurs en jeu** n'utilise pas ce format. Il applique un
encodage binaire natif Blizzard (CBOR → Deflate → Base64), découpé en messages addon.
Deux détails non documentés par Blizzard le rendent risqué à réimplémenter :
l'enveloppe exacte du Deflate, et la façon dont le CBOR natif sérialise les clés
numériques d'une table Lua. C'est précisément pourquoi `ecp;2` existe.

Les deux chemins cohabitent à l'import sans ambiguïté possible : une chaîne commençant
par `ecp;` est parsée comme du texte, toute autre est traitée comme du Base64 natif —
l'alphabet Base64 URL-safe ne contient pas de `;`.

## Annexe B — ce qui change depuis `ecp;1`

`ecp;1` transportait des **clés internes ECP** : identifiants de donjon maison, clés de
défensif suffixées (`740:1`), clés d'occurrence, tokens d'instance, profils de heal.
Cela supposait qu'un outil externe puisse reproduire la logique interne de l'addon —
notamment décider seul qu'une Tranquillité est en version 150 s.

C'était une mauvaise répartition des responsabilités. `ecp;2` inverse : vous envoyez de
la donnée de jeu observable, l'addon résout.

| | `ecp;1` | `ecp;2` |
|---|---|---|
| Donjon | identifiant maison (`SEAT_TRIUMVIRATE`) | `zoneID` Blizzard |
| Défensif | clé suffixée (`740:1`) | spellID nu (`740`) |
| Variante de cooldown | à décider par le producteur | résolue par l'addon via les talents |
| Occurrence | clé interne (`1265464:2`) | spellID + numéro d'occurrence |
| Lanceur | token d'instance (`51052:0#2`) | id opaque + roster |
| Talents | map spellID → clé de variante | liste brute par joueur |
| Soigneur | clé de profil (`PRIEST_HOLY`) | nom de joueur, profil déduit |
| Structure | groupée par boss et par occurrence | plate, une assignation par ligne |

**Ce qui est conservé mot pour mot** : l'enveloppe `ecp;<format>;<kind>`, le jeu de
caractères sûr et la règle d'échappement (§6), l'algorithme de découpage et son
invariant (§7), la règle « type inconnu ⇒ ignoré » (§13), et le contrôle `k;`.

Si vous aviez commencé une implémentation `ecp;1`, la couche basse — échappement,
découpage, tolérance aux blancs — est réutilisable telle quelle. Seule la couche
vocabulaire est à refaire.
