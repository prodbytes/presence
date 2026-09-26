#!/usr/bin/env bash
# Serves the Flutter app in web mode on http://localhost:${FLUTTER_WEB_PORT}/app/.
# The /app/ base href matches the path the CloudFront distribution routes to
# the app (see presence_floci/).
# Runs via `devbox services up` (see process-compose.yaml) or `devbox run web`.
# Uses the web-server device, so no Chrome is needed; open the URL in any browser.
# Settings such as the Google client IDs come from the repo's .env (see
# .env.example).
set -euo pipefail

PORT="${FLUTTER_WEB_PORT:-8080}"
# 127.0.0.1, not localhost: Dart binds "localhost" to IPv6 [::1] only, which
# Docker Desktop's host gateway (how Floci's CloudFront reaches this origin)
# can't reach.
# Browsers still reach it at http://localhost:$PORT/app/.

cd "$(dirname "$0")/../presence_app"
source ../scripts/dart-defines.sh
flutter pub get
exec flutter run -d web-server --web-hostname 127.0.0.1 --web-port "$PORT" \
  --base-href /app/ \
  "${DART_DEFINES[@]}"
