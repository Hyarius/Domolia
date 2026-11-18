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

Dès qu'une intention [IMAGE] existe dans la Partie, l'action de
génération est disponible sur son slot. Le metteur en scène fournit
uniquement une direction artistique structurée et ne décide pas de la
recevabilité de l'illustration. Le format historique `illustratable`
est ignoré s'il est encore renvoyé par un ancien modèle.
La validation porte sur la structure technique et la fidélité aux faits ;
elle ne peut pas retourner librement de nouveaux objets ou personnages.
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

## Réinitialisation des réglages — conservation des données et des clés API

Dans Paramètres > Application > **Réinitialiser les réglages** :

1. Ouvrir la confirmation, puis choisir Annuler : rien ne change.
2. Créer un Livre, une Partie, de la Live Memory et une illustration, puis
   personnaliser le narrateur, le modèle graphique et le canal de mise à jour.
3. Confirmer « Réinitialiser les réglages ». L’application redémarre avec
   OpenUncensored et ses choix automatiques. Les Livres, Parties, illustrations,
   mémoires, diagnostics, fichiers et clés API sont conservés.
4. Dans Crédits IA, vérifier que l’historique et les soldes connus des clés
   OpenUncensored restent présents, et que les modèles avancés sont remis
   à leurs valeurs par défaut.
5. Vérifier que tous les profils API et leurs clés restent disponibles,
   même si une autre clé était associée à l’ancien profil par défaut.
6. En présence d’un paiement OpenUncensored en attente, la réinitialisation
   est refusée sans perdre les informations de suivi.
7. Simuler un échec de sauvegarde des profils chiffrés : les préférences
   restent intactes et aucune donnée utilisateur n’est supprimée.

Cette commande remet les **préférences** à zéro ; elle ne remplace pas
la suppression volontaire des Livres ou Parties.

## Réglages d’images automatiques

Avec uniquement une clé OpenUncensored active, sans configurer séparément la
génération graphique, le choix du profil et du metteur en scène doit être
automatique. Le modèle graphique par défaut vient du catalogue retourné par
OpenUncensored, avec préférence pour `z-image-turbo` lorsqu'il est disponible.
Une sélection explicite conserve sa priorité ; un modèle explicitement
sélectionné mais disparu est signalé sans requête facturable.

Tester un Livre ancien ayant `quality: "high"` avec OpenUncensored : ce champ
non pris en charge est omis des appels d'images, y compris pour la couverture.
La génération manuelle nécessite toujours la confirmation de facturation.
Tester également le refus du fournisseur, un modèle indisponible et un solde
insuffisant sans retry automatique.
