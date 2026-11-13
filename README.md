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

À partir de la première version contenant PR02, Domolia **vérifie automatiquement la présence de mises à jour après son lancement**, télécharge tout APK plus récent en affichant une progression discrète, vérifie SHA-256 et la compatibilité Android, puis ouvre l'installateur système. Android conserve sa confirmation et peut demander l'autorisation d'installer depuis Domolia. Le menu **Paramètres → Mises à jour** permet de désactiver cette vérification, choisir `dev-latest` ou un canal `preview-…`, consulter la version installée et vérifier manuellement. Les boutons « Mise à jour » utilisent désormais ce mécanisme.

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
