# Domolia

Domolia est une future application Android de jeu de rôle narratif. Cette première version contient un écran de bienvenue et une chaîne d'intégration continue qui construit un **APK installable**.

## Télécharger une version d'essai

1. Ouvrir l'onglet [Actions](https://github.com/Hyarius/Domolia/actions/workflows/android-apk.yml).
2. Ouvrir une exécution **Android APK** terminée avec succès.
3. Télécharger l'artifact **domolia-apk-…** en bas de la page.
4. Décompresser l'archive ZIP et installer `Domolia-debug.apk` sur Android, en autorisant l'installation depuis cette source si nécessaire.

**Attention :** les APK de test sont signés avec la clé de débogage temporaire du runner GitHub. Une version d'essai issue d'une autre exécution peut nécessiter de désinstaller la précédente (ce qui supprime ses données locales). Ne pas utiliser ces APK comme canal de mises à jour durables.

## Bouton « Mise à jour »

Le bouton de l'application ouvre les [versions publiées sur GitHub](https://github.com/Hyarius/Domolia/releases). Cette première version n'installe **pas** une mise à jour silencieusement. Sur Android, une installation hors Play Store demande l'accord explicite de l'utilisateur.

Le canal durable sera constitué d'APK **release**, signés avec **la même clé privée à chaque version**, puis publiés sur GitHub Releases.

## Publier une version APK signée

Créer une clé Android **privée et conservée en lieu sûr** :

```bash
keytool -genkeypair -v -keystore domolia-release.jks -alias domolia -keyalg RSA -keysize 3072 -validity 10000
base64 -w0 domolia-release.jks
```

Ne jamais ajouter la clé privée au dépôt. Configurer les secrets GitHub Actions suivants dans *Settings → Secrets and variables → Actions* :

| Secret | Valeur |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Contenu base64 du fichier `.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | Mot de passe du keystore |
| `ANDROID_KEY_ALIAS` | Alias créé (par exemple `domolia`) |
| `ANDROID_KEY_PASSWORD` | Mot de passe de la clé |

Ensuite, pousser un tag de version, par exemple :

```bash
git tag v0.1.0
git push origin v0.1.0
```

Le workflow échoue explicitement si les secrets sont absents sur les tags. Avec les secrets, il construit `Domolia.apk`, le conserve comme artifact et le publie dans [Releases](https://github.com/Hyarius/Domolia/releases).

**Pour que les mises à jour fonctionnent :** conserver le même identifiant de package, la même clé de signature et augmenter le numéro de version Android. Le workflow utilise `github.run_number` comme numéro de build.

## Développement local

Pré-requis : Flutter stable, Android SDK et Java 17.

```bash
flutter create --platforms=android --org=fr.domolia --project-name=domolia .
flutter pub get
flutter analyze
flutter test
flutter run
```

Le dossier `android/` est pour l'instant généré par Flutter. Il sera versionné explicitement dès que nous aurons besoin d'intégrations Android natives.

## Évolution envisagée

Le jeu de rôle, la mémoire, les PNJ et les illustrations viendront après validation de la base Android et du canal de distribution.
