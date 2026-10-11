#!/usr/bin/env bash
# Runs the app on a device with the settings from the repo's .env, e.g.
# `bash scripts/flutter-run.sh -d <device-id>`. Extra arguments go to
# `flutter run`.
set -euo pipefail

cd "$(dirname "$0")/../presence_app"
# The build calls production's auth API (ApiConfig), whose roles are GA
# rbacr's: so does the app's own rbacr client, unless RBACR_URL says.
export RBACR_URL="${RBACR_URL:-https://rbacr.nu01.com}"
source ../scripts/dart-defines.sh
source ../scripts/version.sh
# The Settings screen shows X.Y.Z, Z being when this run started.
exec flutter run "${DART_DEFINES[@]}" --dart-define="PRESENCE_VERSION=$VERSION" "$@"
