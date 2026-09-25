#!/usr/bin/env bash
# Serves the Flutter app in web mode on http://localhost:${FLUTTER_WEB_PORT}.
# Runs via `devbox services up` (see process-compose.yaml) or `devbox run web`.
# Uses the web-server device, so no Chrome is needed; open the URL in any browser.
# Settings such as the Google client IDs come from the repo's .env (see
# .env.example).
set -euo pipefail

PORT="${FLUTTER_WEB_PORT:-8080}"

cd "$(dirname "$0")/../presence_app"
source ../scripts/dart-defines.sh
flutter pub get
exec flutter run -d web-server --web-hostname localhost --web-port "$PORT" \
  "${DART_DEFINES[@]}"
