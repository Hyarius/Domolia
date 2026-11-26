#!/usr/bin/env bash
set -euo pipefail
package=fr.domolia.domolia
candidate=files/updates/update-2.apk
signer=$(find "$ANDROID_HOME/build-tools" -name apksigner | sort -V | tail -1)
keytool -genkeypair -keystore "$RUNNER_TEMP/other.jks" -storepass android -keypass android \
  -alias other -keyalg RSA -validity 365 -dname CN=Other >/dev/null
"$signer" sign --ks "$RUNNER_TEMP/other.jks" --ks-pass pass:android \
  --out "$RUNNER_TEMP/wrong.apk" "$RUNNER_TEMP/domolia-2.apk"

adb install "$RUNNER_TEMP/domolia-1.apk"
adb shell appops set "$package" REQUEST_INSTALL_PACKAGES allow
adb shell run-as "$package" mkdir -p files/updates
upload() {
  adb shell -T run-as "$package" sh -c "'cat > $candidate'" < "$1"
  test "$(sha256sum "$1" | cut -d' ' -f1)" = "$(adb shell run-as "$package" sha256sum "$candidate" | cut -d' ' -f1)"
}
version_is() {
  adb shell dumpsys package "$package" | grep "versionCode=$1 " >/dev/null
}
diagnostics() {
  adb shell run-as "$package" cat files/update-error || true
  adb logcat -d -s PackageInstaller PackageInstallerSession PackageManager AndroidRuntime flutter | tail -80
}
trap 'diagnostics' ERR

upload "$RUNNER_TEMP/wrong.apk"
adb shell am start -n "$package/.MainActivity"
for _ in {1..90}; do
  if adb shell run-as "$package" test -s files/update-error; then break; fi
  sleep 1
done
adb shell run-as "$package" cat files/update-error | grep -Ei 'signature|certificat|UPDATE_INCOMPATIBLE'
version_is 1
adb shell am force-stop "$package"
adb shell run-as "$package" rm files/update-error

upload "$RUNNER_TEMP/domolia-2.apk"
adb shell am start -n "$package/.MainActivity"
for _ in {1..90}; do
  if version_is 2; then
    test "$(adb shell run-as "$package" cat files/before-update | tr -d '\r')" = 'still here'
    echo 'Android upgraded Domolia unattended and preserved private data.'
    exit 0
  fi
  if adb shell run-as "$package" test -s files/update-error; then break; fi
  sleep 1
done
diagnostics
exit 1
