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
# can't reach. The dev container sets PRESENCE_BIND_HOST=0.0.0.0, because
# there Docker's host gateway is the bridge address, not loopback.
# Browsers still reach it at http://localhost:$PORT/app/.
HOST="${PRESENCE_BIND_HOST:-127.0.0.1}"

cd "$(dirname "$0")/../presence_app"
# Cloud sync with the local stack's Floci, not AWS (scripts/dart-defines.sh);
# PRESENCE_LOCAL_CLOUD=0 builds against the .env's AWS settings instead.
export PRESENCE_LOCAL_CLOUD="${PRESENCE_LOCAL_CLOUD:-1}"
source ../scripts/dart-defines.sh
source ../scripts/version.sh
flutter pub get
# The Settings screen shows X.Y.Z, Z being when this server started.
exec flutter run -d web-server --web-hostname "$HOST" --web-port "$PORT" \
  --base-href /app/ \
  "${DART_DEFINES[@]}" --dart-define="PRESENCE_VERSION=$VERSION"
