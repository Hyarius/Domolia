"""Restore the committed Android integration after Flutter recreates android/ in CI."""
from pathlib import Path
from shutil import copyfile
import xml.etree.ElementTree as ET

root = Path("android/app/src/main")
manifest = root / "AndroidManifest.xml"
if not manifest.exists():
    raise SystemExit("Run flutter create --platforms=android first.")

android = "http://schemas.android.com/apk/res/android"
ET.register_namespace("android", android)
document = ET.parse(manifest)
manifest_root = document.getroot()
application = manifest_root.find("application")
if application is None:
    raise SystemExit("Missing Flutter <application>.")

for permission in (
    "android.permission.INTERNET",
    "android.permission.REQUEST_INSTALL_PACKAGES",
):
    existing = manifest_root.findall("uses-permission")
    if not any(item.get("{" + android + "}name") == permission for item in existing):
        ET.SubElement(manifest_root, "uses-permission", {
            "{" + android + "}name": permission
        })

provider = ET.SubElement(application, "provider", {
    "{" + android + "}name": "androidx.core.content.FileProvider",
    "{" + android + "}authorities": "${applicationId}.updates.fileprovider",
    "{" + android + "}exported": "false",
    "{" + android + "}grantUriPermissions": "true",
})
ET.SubElement(provider, "meta-data", {
    "{" + android + "}name": "android.support.FILE_PROVIDER_PATHS",
    "{" + android + "}resource": "@xml/domolia_update_paths",
})
document.write(manifest, encoding="utf-8", xml_declaration=True)

xml = root / "res/xml"
xml.mkdir(parents=True, exist_ok=True)
(xml / "domolia_update_paths.xml").write_text(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<paths xmlns:android="http://schemas.android.com/apk/res/android">\n'
    '  <files-path name="updates" path="updates/" />\n'
    '</paths>\n', encoding="utf-8"
)

activity = root / "kotlin/fr/domolia/domolia/MainActivity.kt"
activity.parent.mkdir(parents=True, exist_ok=True)
copyfile("tool/android/MainActivity.kt", activity)
print("Domolia Android updater: Kotlin, permissions and FileProvider restored.")

# FileProvider is not guaranteed to be a direct dependency of generated Gradle.
gradle = Path("android/app/build.gradle.kts")
with gradle.open("a", encoding="utf-8") as out:
    out.write('\ndependencies { implementation("androidx.core:core:1.15.0") }\n')
