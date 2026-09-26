#!/usr/bin/env bash
# Continuous health monitor: one line per check, one emoji per service.
# Runs via `devbox services up` (see process-compose.yaml) or standalone.
# Check interval in seconds is configurable via HEALTH_CHECK_INTERVAL.
set -uo pipefail

INTERVAL="${HEALTH_CHECK_INTERVAL:-15}"

check_web() {
    if curl -fs -o /dev/null --max-time 5 "http://localhost:${FLUTTER_WEB_PORT:-8080}/app/"; then
        echo "🌐 web ✅"
    else
        echo "🌐 web ❌"
    fi
}

check_api() {
    if curl -fs -o /dev/null --max-time 10 "http://localhost:${SAM_API_PORT:-3000}/api/events"; then
        echo "⚡ api ✅"
    else
        echo "⚡ api ❌"
    fi
}

# The CloudFront distribution in Floci, addressed by its alias in the Host
# header (so it works where *.localhost doesn't resolve).
check_cdn() {
    if curl -fs -o /dev/null --max-time 10 -H "Host: ${PRESENCE_CDN_ALIAS:-presence.localhost}" \
            "http://localhost:${FLOCI_PORT:-4566}/app/"; then
        echo "☁️ cdn ✅"
    else
        echo "☁️ cdn ❌"
    fi
}

check_index() {
    if curl -fs -o /dev/null --max-time 5 "http://localhost:${INDEX_PORT:-8081}/"; then
        echo "🏠 index ✅"
    else
        echo "🏠 index ❌"
    fi
}

# HTTPS through the CDN on the public local name (the Google sign-in origin),
# validating the certificate against mkcert's CA (not the system trust store,
# so it passes before `mkcert -install` too). --resolve pins the name to
# loopback, so it doesn't depend on DNS either.
MKCERT_CA="$(mkcert -CAROOT 2>/dev/null)/rootCA.pem"
check_https() {
    local host="${PRESENCE_PUBLIC_HOST:-local.presence.nu01.com}" port="${FLOCI_HTTPS_PORT:-8443}"
    if curl -fs -o /dev/null --max-time 10 --cacert "$MKCERT_CA" \
            --resolve "$host:$port:127.0.0.1" "https://$host:$port/app/"; then
        echo "🔒 https ✅"
    else
        echo "🔒 https ❌"
    fi
}

while true; do
    # Add more services here, one check_* call per service, joined on one line
    printf '%s %s %s %s %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(check_index)" "$(check_web)" "$(check_api)" "$(check_cdn)" "$(check_https)"
    sleep "$INTERVAL"
done
