#!/usr/bin/env bash
# Builds the auth API (presence_api_auth: sam build) for the local stack,
# only when its sources changed since the last build. Runs before Floci
# starts (4-floci in process-compose.yaml), whose ready hook deploys the
# build into Floci (presence_floci/init/ready.d/05-auth-api.sh).
set -euo pipefail

cd "$(dirname "$0")/../presence_api_auth"
built=.aws-sam/build/template.yaml

if [[ -f "$built" ]] && [[ -z "$(find template.yaml AuthFunction/pom.xml AuthFunction/src/main -newer "$built" -print -quit)" ]]; then
    echo "build-auth-api: up to date"
    exit 0
fi
for tool in sam mvn java; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "build-auth-api: '$tool' is not on PATH; run inside devbox (devbox services up)" >&2
        exit 1
    fi
done
echo "build-auth-api: sam build"
sam build
