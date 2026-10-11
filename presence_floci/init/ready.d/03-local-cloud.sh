#!/bin/sh
# The local cloud: the user-data bucket the local stack's cloud sync uses
# instead of AWS's (scripts/dart-defines.sh, PRESENCE_LOCAL_CLOUD=1), with
# CORS for the local web app's origins, which reach it at
# https://localhost:8443/presence-local-user-data/... (path-style). The
# credentials come from the local auth API (LocalCloudBackend, 05-auth-api.sh),
# and live sync uses Floci's MQTT broker (ws://localhost:4566/mqtt). Floci
# keeps nothing between starts (FLOCI_STORAGE_MODE: memory), so neither does
# this bucket.
set -eu

BUCKET=presence-local-user-data
PUBLIC_HOST="${PRESENCE_PUBLIC_HOST:-local.presence.nu01.com}"
WEB_PORT="${FLUTTER_WEB_PORT:-8080}"

aws s3 mb "s3://$BUCKET" >/dev/null
aws s3api put-bucket-cors --bucket "$BUCKET" --cors-configuration "{
  \"CORSRules\": [{
    \"AllowedOrigins\": [\"https://$PUBLIC_HOST:8443\", \"https://${PRESENCE_CDN_ALIAS:-presence.localhost}:8443\",
                         \"http://${PRESENCE_CDN_ALIAS:-presence.localhost}:4566\", \"http://localhost:$WEB_PORT\"],
    \"AllowedMethods\": [\"GET\", \"PUT\", \"HEAD\", \"DELETE\"],
    \"AllowedHeaders\": [\"*\"],
    \"ExposeHeaders\": [\"ETag\"],
    \"MaxAgeSeconds\": 3000
  }]
}"
echo "presence: local cloud bucket $BUCKET ready"
