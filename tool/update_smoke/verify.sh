#!/usr/bin/env bash
set -euo pipefail
package=fr.domolia.domolia
adb install "${RUNNER_TEMP}/domolia-1.apk"
adb shell appops set "$package" REQUEST_INSTALL_PACKAGES allow
adb shell run-as "$package" mkdir -p files/updates
adb shell -T run-as "$package" sh -c "'cat > files/updates/update-2.apk'" < "${RUNNER_TEMP}/domolia-2.apk"
adb shell am start -W -n "$package/.MainActivity"
for _ in {1..90}; do
  if adb shell dumpsys package "$package" | grep 'versionCode=2 ' >/dev/null; then
    test "$(adb shell run-as "$package" cat files/before-update | tr -d '\r')" = 'still here'
    exit 0
  fi
  sleep 1
done
adb shell run-as "$package" cat files/update-error || true
adb logcat -d -s PackageInstaller PackageInstallerSession AndroidRuntime flutter
exit 1
