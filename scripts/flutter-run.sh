#!/usr/bin/env bash
# Runs the app on a device with the settings from the repo's .env, e.g.
# `bash scripts/flutter-run.sh -d <device-id>`. Extra arguments go to
# `flutter run`.
set -euo pipefail

cd "$(dirname "$0")/../presence_app"
source ../scripts/dart-defines.sh
exec flutter run "${DART_DEFINES[@]}" "$@"
