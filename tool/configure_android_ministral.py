"""Adapt generated Flutter Android project for the GGUF local runtime.

Flutter creates android/ on CI, so the project needs these settings after
flutter create and before flutter pub get. Refuse unexpected templates.
"""
from pathlib import Path

path = Path("android/app/build.gradle.kts")
if not path.is_file():
    raise SystemExit("Android Gradle file missing; generate Android first.")
data = path.read_text(encoding="utf-8")
if "minSdk = flutter.minSdkVersion" not in data:
    raise SystemExit("Expected minSdk assignment missing.")
data = data.replace("minSdk = flutter.minSdkVersion",
                    "minSdk = maxOf(flutter.minSdkVersion, 26)")
if "ndkVersion = flutter.ndkVersion" not in data:
    raise SystemExit("Expected NDK assignment missing.")
data = data.replace("ndkVersion = flutter.ndkVersion",
                    'ndkVersion = "27.0.12077973"')
path.write_text(data, encoding="utf-8")
print("Configured API 26 / Android NDK r27 for Ministral local runtime")
