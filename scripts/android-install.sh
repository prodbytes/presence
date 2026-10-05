#!/usr/bin/env bash
# Installs a release build on the Android phone attached by USB and starts
# it, for a phone that runs unattended: `bash scripts/android-install.sh` or
# `devbox run android-release`. Unlike `flutter run`, nothing stays attached:
# the app runs on its own, compiled (half the memory of a debug build).
#
# It builds with the settings from the repo's .env (scripts/dart-defines.sh)
# and the version (scripts/version.sh), installs over the current app
# (keeping its data), then starts it with its task cleared: a screen left
# on top of the app's task (Google's account chooser) otherwise keeps
# Android from starting the app at all. Finally it checks the app runs.
# ANDROID_SERIAL=<serial> picks a phone when several are attached.
set -euo pipefail

source "$(dirname "$0")/android-device.sh"
package=com.nu01.presence
adb_s() { "$adb" -s "$serial" "$@"; }

cd "$(dirname "$0")/../presence_app"
source ../scripts/dart-defines.sh
source ../scripts/version.sh
# The version code stays the pubspec's, as `flutter run` builds it, so
# either can install over the other without uninstalling (losing data).
flutter build apk --release "${DART_DEFINES[@]}" \
  --dart-define="PRESENCE_VERSION=$VERSION"

echo "Installing $VERSION on $serial" >&2
adb_s install -r build/app/outputs/flutter-apk/app-release.apk
# NEW_TASK | CLEAR_TASK (0x10008000): a fresh task with only the app. No
# -W: it waits for the screen to be drawn, which never happens while the
# phone is locked (the app still starts, and is checked below).
adb_s shell am start -f 0x10008000 -n "$package/.MainActivity" >/dev/null

for _ in $(seq 1 20); do
  pid="$(adb_s shell pidof "$package" | tr -d '\r' || true)"
  if [[ -n "$pid" ]]; then
    echo "Presence $VERSION is running on $serial (process $pid)" >&2
    exit 0
  fi
  sleep 1
done
echo "error: the app didn't start on $serial; see devbox run android-log" >&2
exit 1
