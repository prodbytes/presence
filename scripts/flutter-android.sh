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

# adb: on the PATH, or in the Android SDK (ANDROID_HOME, Flutter's
# configured SDK, or Homebrew's android-commandlinetools).
find_adb() {
  if command -v adb >/dev/null 2>&1; then
    command -v adb
    return
  fi
  local sdk
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
    "$(flutter config --list 2>/dev/null | sed -n 's/^ *android-sdk: //p')" \
    /opt/homebrew/share/android-commandlinetools "$HOME/Library/Android/sdk" \
    "$HOME/Android/Sdk"; do
    if [[ -n "$sdk" && -x "$sdk/platform-tools/adb" ]]; then
      echo "$sdk/platform-tools/adb"
      return
    fi
  done
  return 1
}

adb="$(find_adb)" || {
  echo "error: adb not found; install the Android SDK platform-tools" \
    "(see specs/dev-environment.md)" >&2
  exit 1
}
"$adb" start-server >/dev/null

# USB devices only: wireless ones are listed as <ip>:<port>, emulators as
# emulator-<port>.
usb=()
unauthorized=()
while read -r serial state _; do
  [[ -z "$serial" || "$serial" == emulator-* || "$serial" == *:* ]] && continue
  case "$state" in
    device) usb+=("$serial") ;;
    unauthorized) unauthorized+=("$serial") ;;
  esac
done < <("$adb" devices | tail -n +2)

if [[ -n "${ANDROID_SERIAL:-}" ]]; then
  serial="$ANDROID_SERIAL"
elif ((${#usb[@]} == 1)); then
  serial="${usb[0]}"
elif ((${#usb[@]} > 1)); then
  echo "error: several phones attached (${usb[*]}); pick one with" \
    "ANDROID_SERIAL=<serial>" >&2
  exit 1
elif ((${#unauthorized[@]} > 0)); then
  echo "error: ${unauthorized[*]} hasn't allowed this computer; unlock the" \
    "phone and accept the USB debugging prompt" >&2
  exit 1
else
  echo "error: no Android phone attached by USB. Plug it in with a data" \
    "cable, unlock it, and turn on USB debugging (Settings > Developer" \
    "options)" >&2
  exit 1
fi

echo "Running on $serial ($("$adb" -s "$serial" shell getprop ro.product.model | tr -d '\r'))"
exec bash "$(dirname "$0")/flutter-run.sh" -d "$serial" "$@"
