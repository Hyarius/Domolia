#!/usr/bin/env bash
set -euxo pipefail
package=fr.domolia.domolia
candidate=files/updates/update-2.apk
signer=$(find "$ANDROID_HOME/build-tools" -name apksigner | sort -V | tail -1)
# Use the same persistent signer across builds, just like the published releases.
# Flutter's generated debug signing configuration can use a per-build key.
keytool -genkeypair -keystore "$RUNNER_TEMP/publisher.jks" -storepass android -keypass android \
  -alias publisher -keyalg RSA -validity 365 -dname CN=Publisher >/dev/null
for version in 1 2; do
  "$signer" sign --ks "$RUNNER_TEMP/publisher.jks" --ks-pass pass:android \
    --out "$RUNNER_TEMP/published-$version.apk" "$RUNNER_TEMP/domolia-$version.apk"
done
signer_digest() {
  "$signer" verify --print-certs "$1" | awk '/certificate SHA-256 digest:/ && !seen++ { print $NF }'
}
publisher_digest=$(signer_digest "$RUNNER_TEMP/published-1.apk")
test -n "$publisher_digest"
test "$publisher_digest" = "$(signer_digest "$RUNNER_TEMP/published-2.apk")"
keytool -genkeypair -keystore "$RUNNER_TEMP/other.jks" -storepass android -keypass android \
  -alias other -keyalg RSA -validity 365 -dname CN=Other >/dev/null
"$signer" sign --ks "$RUNNER_TEMP/other.jks" --ks-pass pass:android \
  --out "$RUNNER_TEMP/wrong.apk" "$RUNNER_TEMP/domolia-2.apk"

test "$publisher_digest" != "$(signer_digest "$RUNNER_TEMP/wrong.apk")"
adb install "$RUNNER_TEMP/published-1.apk"
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
  adb shell dumpsys activity activities | grep -E 'mResumedActivity|topResumedActivity' || true
  adb shell dumpsys package "$package" | grep -E 'versionCode=|installerPackageName=' || true
  adb logcat -d | grep -Ei 'domolia|PackageInstallerSession|silent update|INSTALL_FAILED' | tail -90 || true
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

# Android counts the rejected silent attempt towards its 30-second per-installer
# throttle. Space these two artificial releases like independent updates.
sleep 35
upload "$RUNNER_TEMP/published-2.apk"
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
