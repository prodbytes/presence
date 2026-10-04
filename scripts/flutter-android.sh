#!/usr/bin/env bash
# Runs the app on the Android phone attached by USB, with the settings from
# the repo's .env (through scripts/flutter-run.sh), e.g.
# `bash scripts/flutter-android.sh` or `devbox run android`. Extra arguments
# go to `flutter run` (e.g. `--release`).
#
# With several phones attached, pick one with ANDROID_SERIAL=<serial> (from
# `adb devices`). The phone needs USB debugging on (Settings > Developer
# options), and to have allowed this computer.
set -euo pipefail

# adb and the phone: $adb and $serial.
source "$(dirname "$0")/android-device.sh"

echo "Running on $serial ($("$adb" -s "$serial" shell getprop ro.product.model | tr -d '\r'))"
exec bash "$(dirname "$0")/flutter-run.sh" -d "$serial" "$@"
