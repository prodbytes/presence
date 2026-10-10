#!/usr/bin/env bash
# Continuous health monitor: every HEALTH_CHECK_INTERVAL seconds (15 by
# default), one line per check, each with the time, an emoji, ✅/❌/⚪ and a
# short reason. Runs via `devbox services up` (see process-compose.yaml) or
# standalone.
set -uo pipefail

INTERVAL="${HEALTH_CHECK_INTERVAL:-15}"
FLOCI="http://localhost:${FLOCI_PORT:-4566}"
CDN_ALIAS="${PRESENCE_CDN_ALIAS:-presence.localhost}"

# report <emoji> <name> <status emoji> [detail]
report() {
    printf '%s %s %-5s %s%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" "$3" "${4:+ $4}"
}

# ok_if <emoji> <name> <detail> <command...>: ✅ when the command succeeds.
ok_if() {
    local emoji=$1 name=$2 detail=$3
    shift 3
    if "$@"; then report "$emoji" "$name" ✅ "$detail"; else report "$emoji" "$name" ❌ "$detail"; fi
}

# get <timeout> <curl args...>: succeeds on a 2xx answer.
get() {
    local timeout=$1
    shift
    curl -fs -o /dev/null --max-time "$timeout" "$@"
}

check_index() { ok_if 🏠 index "localhost:${INDEX_PORT:-8081}/" get 5 "http://localhost:${INDEX_PORT:-8081}/"; }

check_web() { ok_if 🌐 web "localhost:${FLUTTER_WEB_PORT:-8080}/app/" get 5 "http://localhost:${FLUTTER_WEB_PORT:-8080}/app/"; }

# The CloudFront distribution in Floci, addressed by its alias in the Host
# header (so it works where *.localhost doesn't resolve).
check_cdn() { ok_if ☁️ cdn "$CDN_ALIAS/app/ in Floci" get 10 -H "Host: $CDN_ALIAS" "$FLOCI/app/"; }

# HTTPS through the CDN on the public local name (the Google sign-in origin),
# validating the certificate against mkcert's CA (not the system trust store,
# so it passes before `mkcert -install` too). --resolve pins the name to
# loopback, so it doesn't depend on DNS either.
MKCERT_CA="$(mkcert -CAROOT 2>/dev/null)/rootCA.pem"
check_https() {
    local host="${PRESENCE_PUBLIC_HOST:-local.presence.nu01.com}" port="${FLOCI_HTTPS_PORT:-8443}"
    ok_if 🔒 https "$host:$port/app/" get 10 --cacert "$MKCERT_CA" \
        --resolve "$host:$port:127.0.0.1" "https://$host:$port/app/"
}

# setting <body> <emoji> <name> <json key> <when set> <when not set>
setting() {
    if [[ "$1" == *"\"$4\":true"* ]]; then
        report "$2" "$3" ✅ "$5"
    elif [[ "$1" == *"\"$4\":false"* ]]; then
        report "$2" "$3" ⚪ "$6"
    else
        report "$2" "$3" ❌ "the API doesn't report it"
    fi
}

# The auth API through the CDN (GET /api/auth/anonymous, no token): its
# execution mode, and whether the OIDC client and the AWS cloud-sync
# settings are set (presence.auth.Settings). OIDC and AWS are only known
# when the API answers.
check_api() {
    local body mode
    body="$(curl -fs --max-time 10 -H "Host: $CDN_ALIAS" "$FLOCI/api/auth/anonymous")"
    mode="$(sed -n 's/.*"mode":"\([A-Z]*\)".*/\1/p' <<<"$body")"
    if [[ -z "$mode" ]]; then
        report 🔌 api ❌ "/api/auth/anonymous didn't answer"
        report 🔑 oidc ❌ "unknown: the API didn't answer"
        report 🪣 aws ❌ "unknown: the API didn't answer"
        report 🛂 rbacr-api ❌ "unknown: the API didn't answer"
        return
    fi
    report 🔌 api ✅ "$mode mode"
    setting "$body" 🔑 oidc oidc "GOOGLE_WEB_CLIENT_ID set: sign-in on" \
        "GOOGLE_WEB_CLIENT_ID not set: authentication off, anonymous has every role"
    setting "$body" 🪣 aws aws "COGNITO_IDENTITY_POOL_ID and USER_DATA_BUCKET set: events sync to S3" \
        "COGNITO_IDENTITY_POOL_ID or USER_DATA_BUCKET not set: nothing is shipped to S3"
    setting "$body" 🛂 rbacr-api rbacr "RBACR_TOKEN set: rbacr gives the roles" \
        "RBACR_TOKEN not set: nobody who signs in has a role"
}

# rbacr itself (which gives every role): its public /health, at RBACR_URL (the
# environment, else .env, else https://rbacr.nu01.com). No token is sent.
RBACR_URL="${RBACR_URL:-$( [[ -f .env ]] && sed -n 's/^RBACR_URL=//p' .env | tail -1)}"
RBACR_URL="${RBACR_URL:-https://rbacr.nu01.com}"
check_rbacr() { ok_if 🛂 rbacr "$RBACR_URL/health" get 5 "$RBACR_URL/health"; }

while true; do
    # Add more services here, one check_* function each.
    check_index
    check_web
    check_cdn
    check_https
    check_api
    check_rbacr
    sleep "$INTERVAL"
done
