# Domolia

Application Android de jeu de rôle narratif, en cours de développement.

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

Les Pull Requests produisent uniquement des artifacts de test et **ne publient pas** dev-latest. Les tags `v*` publient des releases stables indépendantes.

> Un canal à tag mobile nécessite que les **releases immuables** ne soient pas activées pour ce dépôt : GitHub interdit alors de modifier le tag et les assets d'une release existante.

### Installer sur Android

1. Ouvrir le [lien APK direct](https://github.com/Hyarius/Domolia/releases/download/dev-latest/Domolia-dev.apk) depuis le téléphone.
2. Autoriser l'installation depuis le navigateur/gestionnaire de fichiers si Android le demande.
3. Installer `Domolia-dev.apk` et lancer Domolia.

L'application dispose d'un bouton **Mise à jour** qui ouvre ce canal. Android demande toujours une confirmation d'installation.

### Signature Android et mises à jour sans perte de données

Sans configuration supplémentaire, `dev-latest` est compilé en **debug**, avec une clé temporaire liée au runner GitHub. Une version issue d'une autre compilation peut alors exiger une désinstallation — et donc supprimer les données locales.

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

Quand les quatre secrets existent, les builds `main` deviennent des APK **release signés avec la même clé**. Les tags stables `v*` **exigent** ces secrets, sinon le workflow échoue.

Les prochaines installations peuvent alors mettre l'application à jour sans effacer ses données, à condition de garder le même identifiant de package Android et d'augmenter le numéro de build. Le workflow utilise `github.run_number` comme numéro de build Android.

**Attention :** passer d'une ancienne installation debug à une installation release exige une désinstallation unique, faute de signature identique.

### Publier une version stable

Après configuration des secrets :

```bash
git tag v0.1.0
git push origin v0.1.0
```

L'APK signé est alors publié sur la page [GitHub Releases](https://github.com/Hyarius/Domolia/releases), sous le nom `Domolia.apk`.

## Développement local

Prérequis : Flutter stable, Android SDK et Java 17.

```bash
flutter create --platforms=android --org=fr.domolia --project-name=domolia .
flutter pub get
flutter analyze
flutter test
flutter run
```

Le dossier Android est généré par Flutter pour l'instant. Il sera versionné explicitement lors de l'ajout des intégrations Android natives.

## Suite du projet

Les prochaines étapes couvriront la connexion à OpenUncensored, le chat de jeu de rôle, la mémoire persistante, les PNJ et l'illustration des scènes.
