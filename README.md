# Domolia

Application Android de jeu de rôle narratif, en cours de développement.

## Identité visuelle

![Icône Domolia](assets/images/domolia_emblem.png)

Le thème de l'application reprend les couleurs de l'emblème **D, bouclier et lauriers** :

| Usage | Couleur |
| --- | --- |
| Fond de l'application | Vert forêt `#061B10` |
| Menus et panneaux | Vert profond `#0D2A1B` |
| Éléments interactifs | Or chaud `#F6CC69` |
| Titres et accents | Or clair `#FFE6A5` |
| Texte principal | Crème `#F5EDD6` |

La palette et les thèmes des boutons, champs, menus et barres d'en-tête sont centralisés dans `lib/theme/domolia_theme.dart`. L'emblème est affiché dans l'application et copié dans les ressources du launcher Android par `tool/install_launcher_icon.py` après `flutter create` (c'est également fait automatiquement dans la CI).

## Télécharger Domolia pour Android

**[Télécharger l'APK de développement — dev-latest](https://github.com/Hyarius/Domolia/releases/download/dev-latest/Domolia-dev.apk)**

[Voir la release dev-latest et ses notes](https://github.com/Hyarius/Domolia/releases/tag/dev-latest) · [Toutes les versions](https://github.com/Hyarius/Domolia/releases) · [Dernière compilation GitHub Actions](https://github.com/Hyarius/Domolia/actions/workflows/android-apk.yml)

Le lien direct télécharge toujours `Domolia-dev.apk`, sans ouvrir l'onglet Actions ni décompresser un artifact ZIP. **La première release dev-latest apparaîtra après la fusion de la PR d'initialisation et le premier push sur `main`.**

### Fonctionnement des versions de développement

Chaque commit poussé sur **`main`** (la branche principale de ce dépôt, équivalent de `master`) lance GitHub Actions. Après succès des tests et de la compilation Android :

1. L'APK du build est envoyé dans les artifacts GitHub Actions.
2. Le tag mobile **`dev-latest`** pointe sur ce commit.
3. La GitHub Release **dev-latest** (préversion) est créée ou mise à jour, et son fichier **`Domolia-dev.apk`** est remplacé.
4. Le lien de téléchargement en haut de cette page reste identique.

### Tester une branche de travail

Chaque **push sur une branche de travail** (par exemple `feat/accueil`) produit, après réussite de la compilation et des tests, une **GitHub Release de préversion** propre à cette branche :

- Le tag est permanent pour cette branche : `preview-<nom-de-branche>-<hash>`.
- Le fichier est directement téléchargeable : **`Domolia-preview.apk`**.
- Les commits suivants remplacent l'APK de cette même préversion.
- La branche `main` publie son propre canal **`dev-latest`**.
- Les tags `v*` produisent des **releases officielles**, séparées des préversions.

**[Voir toutes les préversions téléchargeables](https://github.com/Hyarius/Domolia/releases)**

Le lien propre à une branche apparaît aussi dans le récapitulatif de l'exécution GitHub Actions ayant publié l'APK. Les Pull Requests construisent également un APK de test dans les artifacts, mais ne créent pas de release par le seul événement `pull_request` (les commits poussés sur une branche du dépôt créent leur préversion).

**Attention :** « release » désigne ici une **compilation Flutter optimisée en mode release** et une GitHub Release marquée comme **préversion**. Cela ne veut pas dire « version officielle ». Tant que les secrets de signature ne sont pas configurés, l'APK n'offre pas de mise à jour fiable de l'installation précédente.

> Un canal à tag mobile nécessite que les **releases immuables** ne soient pas activées pour ce dépôt : GitHub interdit alors de modifier le tag et les assets d'une release existante.

### Installer sur Android

1. Ouvrir le [lien APK direct](https://github.com/Hyarius/Domolia/releases/download/dev-latest/Domolia-dev.apk) depuis le téléphone.
2. Autoriser l'installation depuis le navigateur/gestionnaire de fichiers si Android le demande.
3. Installer `Domolia-dev.apk` et lancer Domolia.

À partir de la première version contenant PR02, Domolia **vérifie automatiquement la présence de mises à jour après son lancement**, télécharge tout APK plus récent en affichant une progression discrète, vérifie SHA-256 et la compatibilité Android, puis ouvre l'installateur système. Android conserve sa confirmation et peut demander l'autorisation d'installer depuis Domolia. Le menu **Paramètres → Mises à jour** permet de désactiver cette vérification, choisir `dev-latest` ou un canal `preview-…` (le canal de la branche est sélectionné automatiquement au premier lancement d'un APK preview), consulter la version installée et vérifier manuellement. Les boutons « Mise à jour » utilisent désormais ce mécanisme.

### Signature Android et mises à jour sans perte de données

**Tous les APK publiés sont obligatoirement signés avec la clé Android persistante.** La CI échoue si les secrets correspondants sont absents ou partiels ; seuls les APK de test de PR non publiés sont compilés en mode debug.

Pour obtenir de vraies mises à jour installables par-dessus l'application existante, il faut une **signature Android persistante**. Créer une clé privée et la sauvegarder en lieu sûr :

```bash
keytool -genkeypair -v -keystore domolia-release.jks -alias domolia -keyalg RSA -keysize 3072 -validity 10000
base64 -w0 domolia-release.jks
```

Ne jamais mettre la clé privée dans Git. Renseigner ces quatre secrets dans **Settings → Secrets and variables → Actions** :

| Secret | Description |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | Contenu du keystore `.jks` encodé en base64 |
| `ANDROID_KEYSTORE_PASSWORD` | Mot de passe du keystore |
| `ANDROID_KEY_ALIAS` | Alias de la clé (`domolia` dans l'exemple) |
| `ANDROID_KEY_PASSWORD` | Mot de passe de la clé |

Les builds `main`, les préversions de branches et les tags `v*` exigent tous la même clé de signature. Un manifeste `Domolia-update.json`, généré à partir de chaque APK construit, accompagne désormais chaque release.

Les prochaines installations peuvent alors mettre l'application à jour sans effacer ses données, à condition de garder le même identifiant de package Android et d'augmenter le numéro de build. Le workflow utilise `github.run_number` comme numéro de build Android.

**Attention :** passer d'une ancienne installation debug à une installation release exige une désinstallation unique, faute de signature identique.

### Vérifier les quatre secrets et la signature

Sur Termux (avec GitHub CLI connecté), vérifier que les **noms** des quatre secrets sont présents :

```bash
gh secret list -R Hyarius/Domolia
```

GitHub ne permet pas de relire leurs valeurs. Un simple test de présence ne suffit donc pas à prouver que le keystore et ses mots de passe sont corrects.

Pour une vraie vérification, pousser un commit sur une branche de travail. Le workflow `Android APK` exécute alors `Configurer la signature release`, `Compiler l'APK release (branches et tags)` et, si les secrets sont présents, `Vérifier la signature Android permanente`.

La dernière étape lit le certificat public de l'APK avec `apksigner` et compare son empreinte SHA-256 au certificat de `domolia-release.jks` fourni via les secrets. Elle **échoue** si le certificat ne correspond pas, sans révéler les mots de passe ni la clé privée.

[Voir les exécutions Actions](https://github.com/Hyarius/Domolia/actions/workflows/android-apk.yml).

### Publier une version stable

Après configuration des secrets :

```bash
git tag v0.1.0
git push origin v0.1.0
```

L'APK signé est alors publié sur la page [GitHub Releases](https://github.com/Hyarius/Domolia/releases), sous le nom `Domolia.apk`.

## Développement local

Prérequis : Flutter stable, Android SDK et Java 21.

```bash
flutter create --platforms=android --org=fr.domolia --project-name=domolia .
python3 tool/configure_android_updates.py
flutter pub get
flutter analyze
flutter test
flutter run
```

Le dossier Android est toujours généré par Flutter. La commande `python3 tool/configure_android_updates.py` **après** `flutter create` restaure Kotlin, le manifeste et FileProvider. La CI exécute cette étape automatiquement. Voir [la PR02](docs/rp/PR02.md) pour le fonctionnement exact et le test réel N → N+1.

## Suite du projet

Les prochaines étapes couvriront la connexion à OpenUncensored, le chat de jeu de rôle, la mémoire persistante, les PNJ et l'illustration des scènes.

## Fournisseur IA — PR03

Dans **Menu → Paramètres → Fournisseur IA**, renseigner votre clé OpenUncensored et choisir un modèle de chat.

- URL par défaut : `https://api.openuncensored.com/v1`
- Clé API : `ou-…`, saisie masquée et enregistrée dans le **stockage sécurisé Android**, jamais dans des préférences en texte clair.
- **Modèle de chat** : choix uniquement dans le menu déroulant, qui affiche aussi le modèle déjà enregistré. **Charger les modèles** récupère la liste disponible.
- **Tester la connexion** : envoie une courte requête de chat en français, **susceptible de consommer des crédits**.
- Les paramètres sont conservés entre les démarrages. Une clé enregistrée ne s'affiche jamais ; le champ vide la conserve, le bouton « Supprimer la clé API » l'efface.

Le client est compatible OpenAI via un contrat `AiChatProvider` réutilisable par PR04, sans dépendance du domaine RP au transport HTTP. Seules les URL HTTPS sont acceptées ; les redirections sont désactivées ; erreurs et délais sont présentés sans divulguer les requêtes ou la clé.

Pour éviter la restauration de secrets chiffrés sans leur clé Android Keystore, la sauvegarde automatique Android et le transfert de données de l'application sont désactivés ; l'export volontaire des aventures est prévu en PR17.

Voir [PR03](docs/rp/PR03.md) et la [documentation OpenUncensored](https://openuncensored.com/docs).

Les vérifications **manuelles** des mises à jour affichent une fenêtre avec un retour explicite : recherche, « déjà à jour », téléchargement, installation Android ou erreur. La vérification automatique au démarrage reste discrète si aucune nouvelle version n'est disponible.

### Plusieurs connexions IA

Dans « Fournisseur IA », le menu **Configuration API** en haut de page permet de conserver autant de comptes ou fournisseurs que nécessaire. **+** crée un profil nommé ; **⋮** le renomme ou le supprime. Le statut à droite concerne exclusivement le profil sélectionné : « Non testé », « En cours », « Connecté » ou « Invalide ». En cas d'échec, le chevron ouvre la raison détaillée, sans afficher la clé API. La liste des configurations et leurs secrets sont stockés de manière chiffrée et migrés automatiquement depuis l'ancien réglage unique, sans perdre sa clé.

## Chat narratif en groupe — PR04

L'écran **Conversation** s'ouvre depuis l'accueil ou le menu. Il ressemble à une discussion de groupe : chaque message est précédé de son **nom** et de son **avatar**, et possède sa bulle distincte. « Vous », « Narrateur » et chaque personnage peuvent s'exprimer dans leur propre bulle. Le narrateur n'est pas une sortie de texte spéciale : c'est un participant de la scène.

Le moteur de dialogue demande aux modèles un format **une ligne JSON par prise de parole** et affiche progressivement le texte dans les bulles. Le joueur conserve l'exclusivité de ses actions et de ses paroles. L'utilisateur peut arrêter la génération, réessayer une erreur et régénérer la dernière réponse. Les conversations restent temporaires avant la PR05.

**Important :** dans l'application, « Envoyer » contacte l'API configurée par l'utilisateur, y compris lorsqu'elle est payante. Les tests automatisés de la PR04 utilisent **uniquement des modèles et flux mockés localement**, jamais les API réelles (gratuites ou payantes). Aucun crédit externe n'est consommé pendant la CI.


### Configurations IA nommées, indépendantes du fournisseur

Domolia présente **une seule liste de configurations IA nommées**. Dans chaque configuration, « Type de fournisseur » propose `ChatGPT` ou `CustomAI`. Le choix change seulement les champs du profil : connexion OAuth de votre compte ChatGPT et modèles autorisés, ou configuration HTTPS + clé API personnalisée. Toutes les autres fonctions peuvent cibler la configuration par son nom et son identifiant stable, sans connaître son fournisseur.

L'option ChatGPT demande séparément l'autorisation d'utiliser le forfait et ses limites ; l'application utilise alors l'API publique Responses avec un jeton OAuth chiffré sur l'appareil. Elle ne récupère ni l'historique ni la mémoire des conversations ChatGPT. Le retour du navigateur OAuth sur Android doit être validé sur téléphone avec un compte autorisé. Les tests automatisés sont **entièrement mockés**, sans aucun appel à des API payantes ni gratuites.

### Configuration du narrateur (PR04)

Le menu **Narrateur** (également accessible depuis **Paramètres**) permet de personnaliser :

1. Le **style narratif** du jeu de rôle : instructions de narration transmises à l'IA.
2. Les **premiers messages possibles**, à raison d'un message par ligne. Une ouverture est choisie automatiquement lorsque vous démarrez une nouvelle conversation, et s'affiche comme une bulle du narrateur.

Les réglages sont sauvegardés localement et réutilisés au prochain lancement de l'application. Les instructions du protocole JSON demeurent fixes et non éditables ; elles sont combinées au style à chaque requête. Le premier message est inséré localement, **sans appel réseau ni consommation de crédits**. Les tests et la CI utilisent uniquement des fournisseurs simulés.


## Bibliothèque de Livres (refonte)

Chaque Livre possède un titre, une couverture, un narrateur, un niveau de détail et des tags. Les parties sont enregistrées localement et les configurations IA restent séparées dans le stockage sécurisé. Un Livre peut être exporté/importé comme JSON portable, sans clés, compte, lien de profil ou historique de Partie. Format et limites : [docs/books/format.md](docs/books/format.md).
