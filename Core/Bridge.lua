-- EiikoCooldownPlanner - Core/Bridge.lua
-- PONT vers l'addon compagnon « ECP Packager » (outil d'AUTEUR, optionnel et separe).
--
-- POURQUOI UNE GLOBALE, alors que la regle du projet est de n'exposer dans `_G` que ce que
-- le client EXIGE : parce qu'aucune API de lecture de table privee n'a pu etre confirmee sur
-- ce client, et que toute la reutilisation de l'UI par le Packager en depend. Une globale
-- DELIBEREE et versionnee est garantie de marcher, et c'est deja le pattern qu'ECP emploie
-- pour dialoguer avec EllesmereUI / BigWigs / DBM (duck-typing sur `_G`, pcall, no-op si
-- absent). C'est donc une exception ASSUMEE a la regle, pas un oubli.
--
-- SENS DE LA DEPENDANCE : le Packager connait ECP, ECP ne connait PAS le Packager. Ce
-- fichier ne fait que POSER la table ; il ne lit rien du compagnon, ne l'appelle jamais,
-- et son absence ne change rien. Ne JAMAIS inverser ce sens.
--
-- 🚫 LE COMPAGNON N'ECRIT JAMAIS DANS NOS TABLES. Il LIT, point. Rien ne l'en empeche
-- techniquement -- meme etat Lua, `private` est la table REELLE et pas une copie, une
-- ecriture passerait sans erreur -- d'ou cette regle ecrite.
--   Si une ecriture devient necessaire, elle ne part PAS du compagnon : c'est ICI, dans
--   ECP, qu'on ajoute une fonction qui la realise, et le compagnon l'appelle.
--   Raison : ECP reste seul gardien de SES invariants (compteur d'id monotone, coherence
--   dID / rangement, canEdit, filtres de plan). Une ecriture directe venue du dehors les
--   contourne tous, en silence. Et le point d'ecriture reste unique et relisable.
--   ⚠️ Une telle fonction s'ecrit dans les termes d'ECP (« poser tel champ sur telle
--   variante »), JAMAIS dans ceux du compagnon (« faire l'operation de pack ») -- sinon on
--   inverse le sens de dependance que tout ce fichier protege. Elle fait alors partie du
--   contrat : l'ajouter ou la changer releve de `apiVersion`.
--
-- CONTRAT : `apiVersion` ne bouge que si la FORME du pont change (pas a chaque release
-- d'ECP). Le Packager refuse de s'accrocher a une version qu'il ne connait pas, ce qui
-- transforme un decalage entre les deux addons en message clair plutot qu'en erreur Lua.
local addonName, HR = ...

_G.ECPBridge = {
    apiVersion = 1,

    -- Nom de DOSSIER de l'ECP qui repond. Les deux copies (publiee et Dev) peuvent
    -- coexister et declarent les MEMES SavedVariables -- elles ne doivent jamais etre
    -- actives ensemble. Le Packager affiche cette valeur pour qu'on voie immediatement
    -- a laquelle on est accroche.
    addonName  = addonName,
    version    = HR.VERSION,

    -- Table privee d'ECP. Le Packager y prend `UI.Components` (widgets + theme),
    -- `HEAL_PROFILES`, `content`, et LIT `db2`. Il n'y ECRIT jamais : ses propres donnees
    -- (packs, composition, profil createur, snapshots) vivent dans SA SavedVariable.
    private    = HR,
}
