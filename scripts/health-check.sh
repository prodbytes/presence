#!/usr/bin/env bash
# Continuous health monitor: one line per check, one emoji per service.
# Runs via `devbox services up` (see process-compose.yaml) or standalone.
# Check interval in seconds is configurable via HEALTH_CHECK_INTERVAL.
set -uo pipefail

INTERVAL="${HEALTH_CHECK_INTERVAL:-15}"

check_web() {
    if curl -fs -o /dev/null --max-time 5 "http://localhost:${FLUTTER_WEB_PORT:-8080}/"; then
        echo "🌐 web ✅"
    else
        echo "🌐 web ❌"
    fi
}

check_api() {
    if curl -fs -o /dev/null --max-time 10 "http://localhost:${SAM_API_PORT:-3000}/events"; then
        echo "⚡ api ✅"
    else
        echo "⚡ api ❌"
    fi
}

# The CloudFront distribution in Floci, addressed by its alias in the Host
# header (so it works where *.localhost doesn't resolve).
check_cdn() {
    if curl -fs -o /dev/null --max-time 10 -H "Host: ${PRESENCE_CDN_ALIAS:-presence.localhost}" \
            "http://localhost:${FLOCI_PORT:-4566}/"; then
        echo "☁️ cdn ✅"
    else
        echo "☁️ cdn ❌"
    fi
}

while true; do
    # Add more services here, one check_* call per service, joined on one line
    printf '%s %s %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(check_web)" "$(check_api)" "$(check_cdn)"
    sleep "$INTERVAL"
done
