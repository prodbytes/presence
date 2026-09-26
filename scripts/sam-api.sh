#!/usr/bin/env bash
# Serves the presence_api_events SAM API on http://localhost:${SAM_API_PORT}.
# Runs via `devbox services up` (see process-compose.yaml) or standalone.
# Needs the SAM CLI, Maven, JDK 25 and a running Docker daemon.
set -euo pipefail

PORT="${SAM_API_PORT:-3000}"

for tool in sam mvn docker; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "sam-api: '$tool' is not on PATH; see presence_api_events/README.md" >&2
        exit 1
    fi
done

# SAM doesn't read Docker contexts, so point it at the active context's
# socket (Docker Desktop's isn't /var/run/docker.sock).
if [[ -z "${DOCKER_HOST:-}" ]]; then
    host="$(docker context inspect -f '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"
    if [[ "$host" == unix://* ]]; then
        export DOCKER_HOST="$host"
    fi
fi

cd "$(dirname "$0")/../presence_api_events"
sam build
exec sam local start-api --host localhost --port "$PORT"
