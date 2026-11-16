"""Adapt the generated Android project for the optional local GGUF runtime.

Flutter generates android/ in CI; nothing under android/ is committed.
llama_flutter_android requires API 26 and NDK 27 for 16 KiB pages.
"""
from pathlib import Path

gradle = Path("android/app/build.gradle.kts")
if not gradle.is_file():
    raise SystemExit("Run flutter create --platforms=android first.")
text = gradle.read_text(encoding="utf-8")
old = "minSdk = flutter.minSdkVersion"
if old not in text:
    raise SystemExit("Android minSdk pattern changed; fail instead of silently using the wrong SDK.")
text = text.replace(old, "minSdk = maxOf(flutter.minSdkVersion, 26)")
# This controls the app NDK; the plugin may set its own compatible version.
text = text.replace("ndkVersion = flutter.ndkVersion", 'ndkVersion = "27.0.12077973"')
gradle.write_text(text, encoding="utf-8")
print("Domolia local GGUF: Android minSdk 26 and NDK r27 configured.")
