"""Configure la signature Android release dans le Gradle généré par Flutter.

Appelé pour les APK signés (branches ou tags), après création de android/key.properties.
La clé privée reste dans les secrets GitHub Actions et n'est jamais commitée.
"""

from pathlib import Path

gradle_file = Path("android/app/build.gradle.kts")
if not gradle_file.exists():
    raise SystemExit("Gradle Kotlin DSL introuvable : android/app/build.gradle.kts")

source = gradle_file.read_text(encoding="utf-8")
debug_signing = 'signingConfig = signingConfigs.getByName("debug")'
if debug_signing not in source:
    raise SystemExit("Configuration de signature Flutter inconnue : mise à jour nécessaire")
if "android {" not in source:
    raise SystemExit("Bloc android introuvable dans build.gradle.kts")

signing = """val domoliaSigningProperties = Properties().apply {
    rootProject.file("key.properties").inputStream().use { load(it) }
}

android {
    signingConfigs {
        create("domoliaRelease") {
            keyAlias = domoliaSigningProperties.getProperty("keyAlias")
            keyPassword = domoliaSigningProperties.getProperty("keyPassword")
            storeFile = file(domoliaSigningProperties.getProperty("storeFile"))
            storePassword = domoliaSigningProperties.getProperty("storePassword")
        }
    }
"""

source = "import java.util.Properties\n\n" + source.replace("android {", signing, 1)
source = source.replace(
    debug_signing,
    'signingConfig = signingConfigs.getByName("domoliaRelease")',
    1,
)
gradle_file.write_text(source, encoding="utf-8")
print("Signature release Android configurée.")
