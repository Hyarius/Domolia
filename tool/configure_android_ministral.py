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
# Flutter release APKs can enable R8. The plugin calls JNI methods that
# require stable names. Without keep rules the app may terminate in inference.
release = "        release {"
if release not in data:
    raise SystemExit("Expected release buildType missing: cannot protect native API.")
data = data.replace(release, release + """
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )""", 1)
path.write_text(data, encoding="utf-8")

proguard = path.parent / "proguard-rules.pro"
proguard.write_text("""# llama_flutter_android invokes these classes from native code (JNI).
-keep class com.write4me.llama_flutter_android.** { *; }
-keep class kotlin.jvm.functions.Function1
-keepclassmembers class * implements kotlin.jvm.functions.Function1 {
    public java.lang.Object invoke(java.lang.Object);
}
-keepclasseswithmembernames class * {
    native <methods>;
}
""", encoding="utf-8")
print("Configured API 26 / NDK r27 and protected JNI methods in release APK")
