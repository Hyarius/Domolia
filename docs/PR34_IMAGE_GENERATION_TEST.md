# PR34 — Génération manuelle d'illustrations

## Fonctionnement

Une intention [IMAGE] émise par le narrateur ou « Illustrer » après appui
long suit exactement le même pipeline : sélection des événements historiques
avant son identifiant, rapprochement du Lore et des faits confirmés de Live
Memory, mise en scène IA sur une tâche textuelle indépendante, validation
des identifiants de personnages et choix de caméra, puis synthèse visuelle
structurée (sujet, action et décor) et composition d'un prompt graphique.
Les extraits du récit, dialogues et faits mémorisés restent dans le
contexte du metteur en scène ; ils ne sont pas recopiés dans le prompt
du fournisseur graphique. Le détail de l'image permet d'exporter le
prompt historique et ses métadonnées en JSON, sans requête payante. Le générateur d'images est appelé **uniquement après
confirmation explicite du joueur**.

Le choix de la direction artistique est limité à des valeurs structurées ;
il ne peut pas retourner librement de nouveaux objets ou personnages.
Cette validation ne garantit pas la fidélité sémantique d'un modèle
graphique. Les éléments douteux sont mis en quarantaine et non
promus en faits certains.

## Profils et authentification

- OpenAI API : profil personnalisé avec URL
  https://api.openai.com/v1 et clé OpenAI API personnelle. Un compte
  ChatGPT connecté n'autorise pas automatiquement cette API facturable.
  Modèles déclarés : gpt-image-2, gpt-image-2.5-sunburst,
  gpt-image-2.5-flare, gpt-image-2.6-sunburst, gpt-image-2.6-flare.
- OpenUncensored : profil existant, même clé et crédits, API
  https://api.openuncensored.com/v1 avec découverte des modèles
  d'images et génération native, coût réel si renvoyé par le fournisseur.

Le fournisseur d'images et celui de narration peuvent être différents.
Un refus, une erreur ou un timeout n'entraîne jamais une
réorientation implicite ou un retry facturable.

## Stockage, coûts et limites

Les fichiers PNG/JPEG/WebP sont copiés dans le stockage applicatif
Android ; SQLite v14 conserve uniquement leurs métadonnées, les identifiants
des intentions, leurs prompts, les exclusions visuelles appliquées et les coûts effectivement rapportés.
Le contrôle de l'historique empêche une image tardive d'être ajoutée à
une scène rewound. Les fichiers orphelins sont purgés lors de la
réouverture de la Partie.

Coût estimé avant génération : **inconnu**, sauf borne fiable du
fournisseur. Un plafond demandé mais non vérifiable bloque la génération.
La mise en scène fait également appel à une IA facturable. Les requêtes
expirées peuvent avoir été facturées : aucun retry automatique.

Limitations : extraction sémantique heuristique, modèle graphique
susceptible de ne pas respecter un détail malgré le prompt, coût OpenAI
non automatiquement reconstitué, API d'édition et références de personnage
non incluses. La persistance Web attend une implémentation IndexedDB ;
le dépôt existant ne fournit pas de plateforme Web prête à compiler.

## Validation manuelle — Le Registre de Sel

1. Installer la préversion de la branche après un workflow Android APK vert.
2. Choisir un narrateur ChatGPT et un metteur en scène ChatGPT dans les
   profils IA textuels ; choisir un fournisseur graphique OpenUncensored.
3. Dans Paramètres > Génération d'images, sélectionner le profil,
   le modèle graphique et le metteur en scène uniquement. Vérifier la
   surcharge de connexion par Partie. Dans l'éditeur du Livre > Images,
   choisir taille, qualité, style, nombre d'images et exclusions (negative
   prompt). Vérifier que l'export JSON conserve ces choix sans clé API.
4. Jouer jusqu'à une intention [IMAGE] : vérifier qu'elle ne déclenche
   pas d'appel graphique automatique.
5. Cliquer sur Générer l'illustration, confirmer le coût potentiellement
   inconnu, suivre les étapes de l'Illustrateur au-dessus de la saisie.
   Sans configuration graphique, vérifier l'erreur explicite et son
   raccourci vers les réglages.
6. Appuyer longuement sur « Soren referme lentement le tiroir derrière lui. ».
   Choisir Illustrer : une intention doit apparaître juste après, sans
   facturation graphique. Cliquer ensuite pour générer l'image.
7. Tester le pinceau au-dessus du bouton d'envoi ; lorsqu'aucune intention
   n'est proposée, vérifier la confirmation explicite pour en créer une.
8. Ouvrir l'image en grand, lire le prompt, modèle et fournisseur, exporter
   l'image. Redémarrer Android et retrouver les illustrations.
9. Rejouer avec OpenAI API comme fournisseur graphique, sans changer le
   narrateur ; comparer prompts, images et coûts connus.
10. Contrôler les garde-fous : Léa Monel n'est pas Léa Monnel ;
    le jeton 62 non accepté ne doit pas être dans la main du joueur ;
    une rumeur concernant la gardienne du fanal n'est pas avérée ;
    un dossier scellé ne dévoile pas son contenu et une promesse
    conditionnelle n'est pas accomplie.
11. Tester rewind en cours de requête, double clic, réseau déconnecté,
    clé invalide, solde insuffisant et refus du fournisseur.
    Ne pas réessayer automatiquement une opération facturable.
12. Depuis le chat, utiliser le bouton Lore dans la barre supérieure,
    modifier une fiche puis revenir à la même Partie.
13. Depuis l'éditeur du Livre > Livre, générer une couverture : vérifier
    la description préremplie depuis le JSON, l'annulation sans requête,
    la confirmation facturable, l'indicateur de progression, puis la
    couverture JPEG de moins de 1 Mio. Une erreur conserve l'ancienne
    couverture. Exporter et réimporter le Livre pour vérifier la
    description, la direction artistique et la couverture.
14. Importer template/livre_template.json, vérifier son onglet Images,
    puis enregistrer/exporter. Un ancien Livre v1/v2 reçoit les
    réglages graphiques par défaut sans perdre ses données.

### Tests sans crédit réel

Les simulations HTTP des tests Flutter retournent des octets de PNG
déterministes. Elles ne réalisent aucun appel vers les fournisseurs.
La génération réelle nécessite une clé et un consentement à la dépense ;
une simulation n'est jamais annoncée comme une génération graphique réelle.

### Canal de mise à jour

Branche : feat/pr34-image-generation

Canal exact de la préversion :
preview-feat-pr34-image-generation-ad8f3c0682

APK : Domolia-preview.apk, publié seulement après une CI réussie.
Le canal dev-latest concerne main, pas cette PR.

### Checks attendus

flutter pub get, flutter analyze (aucun problème), flutter test,
compilation Android, signature et release de préversion.
La PR reste en brouillon et n'est pas fusionnée sans autorisation.
