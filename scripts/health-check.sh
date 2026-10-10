#!/usr/bin/env bash
# Continuous health monitor: every HEALTH_CHECK_INTERVAL seconds (15 by
# default), one line per run: the time, then each check as its emoji, a
# short label and ✅ (ok) / ❌ (failed) / ⚪ (not set), separated by " · ":
#   🏠 Index · 🌐 Web · 🚚 CDN · 🔒 HTTPS · 🔌 API · 🔑 OIDC · ☁️ AWS ·
#   👮 RBACR (the API's rbacr setting) · 💎 RBACR svc (rbacr's /health)
# Runs via `devbox services up` (see process-compose.yaml) or standalone.
set -uo pipefail

INTERVAL="${HEALTH_CHECK_INTERVAL:-15}"
FLOCI="http://localhost:${FLOCI_PORT:-4566}"
CDN_ALIAS="${PRESENCE_CDN_ALIAS:-presence.localhost}"

# This run's results, one "<emoji> <label> <status emoji>" each.
RESULTS=()

# report "<emoji> <label>" <status emoji>: adds a check's result to this run's line.
report() {
    RESULTS+=("$1 $2")
}

# ok_if "<emoji> <label>" <command...>: ✅ when the command succeeds.
ok_if() {
    local emoji=$1
    shift
    if "$@"; then report "$emoji" ✅; else report "$emoji" ❌; fi
}

# get <timeout> <curl args...>: succeeds on a 2xx answer.
get() {
    local timeout=$1
    shift
    curl -fs -o /dev/null --max-time "$timeout" "$@"
}

check_index() { ok_if "🏠 Index" get 5 "http://localhost:${INDEX_PORT:-8081}/"; }

check_web() { ok_if "🌐 Web" get 5 "http://localhost:${FLUTTER_WEB_PORT:-8080}/app/"; }

# The CloudFront distribution in Floci, addressed by its alias in the Host
# header (so it works where *.localhost doesn't resolve).
check_cdn() { ok_if "🚚 CDN" get 10 -H "Host: $CDN_ALIAS" "$FLOCI/app/"; }

# HTTPS through the CDN on the public local name (the Google sign-in origin),
# validating the certificate against mkcert's CA (not the system trust store,
# so it passes before `mkcert -install` too). --resolve pins the name to
# loopback, so it doesn't depend on DNS either.
MKCERT_CA="$(mkcert -CAROOT 2>/dev/null)/rootCA.pem"
check_https() {
    local host="${PRESENCE_PUBLIC_HOST:-local.presence.nu01.com}" port="${FLOCI_HTTPS_PORT:-8443}"
    ok_if "🔒 HTTPS" get 10 --cacert "$MKCERT_CA" \
        --resolve "$host:$port:127.0.0.1" "https://$host:$port/app/"
}

# setting <body> "<emoji> <label>" <json key>: ✅ set, ⚪ not set, ❌ not reported.
setting() {
    if [[ "$1" == *"\"$3\":true"* ]]; then
        report "$2" ✅
    elif [[ "$1" == *"\"$3\":false"* ]]; then
        report "$2" ⚪
    else
        report "$2" ❌
    fi
}

# Whether Floci implements Cognito Identity, which the local auth API calls
# for cloud-sync credentials (POST /api/auth/credentials: GetId). It asks
# Floci itself (an unsigned GetId for a made-up pool): an emulator without
# the service answers UnknownOperationException; anything else (a real
# error about the pool) means it's there.
floci_has_cognito_identity() {
    local answer
    answer="$(curl -s --max-time 5 -X POST "$FLOCI/" \
        -H 'Content-Type: application/x-amz-json-1.1' \
        -H 'X-Amz-Target: AWSCognitoIdentityService.GetId' \
        -d '{"IdentityPoolId":"us-east-1:00000000-0000-0000-0000-000000000000"}')"
    [[ "$answer" != *UnknownOperationException* ]]
}

# The auth API through the CDN (GET /api/auth/anonymous, no token): it
# answers with its execution mode, and whether the OIDC client (🔑
# GOOGLE_WEB_CLIENT_ID), the AWS cloud-sync settings (☁️
# COGNITO_IDENTITY_POOL_ID and USER_DATA_BUCKET) and rbacr (👮 RBACR_TOKEN)
# are set (presence.auth.Settings). Those are only known when the API
# answers, so they're ❌ when it doesn't.
check_api() {
    local body mode
    body="$(curl -fs --max-time 10 -H "Host: $CDN_ALIAS" "$FLOCI/api/auth/anonymous")"
    mode="$(sed -n 's/.*"mode":"\([A-Z]*\)".*/\1/p' <<<"$body")"
    if [[ -z "$mode" ]]; then
        report "🔌 API" ❌
        report "🔑 OIDC" ❌
        report "☁️ AWS" ❌
        report "👮 RBACR" ❌
        return
    fi
    report "🔌 API" ✅
    setting "$body" "🔑 OIDC" oidc
    # Set, but Floci has no Cognito Identity (GetId): the local auth API
    # can't issue credentials, so the app's cloud sync fails here.
    if [[ "$body" == *'"aws":true'* ]] && ! floci_has_cognito_identity; then
        report "☁️ AWS" ❌
    else
        setting "$body" "☁️ AWS" aws
    fi
    setting "$body" "👮 RBACR" rbacr
}

# rbacr itself (which gives every role): its public /health, at RBACR_URL (the
# environment, else .env, else https://rbacr.nu01.com). No token is sent.
RBACR_URL="${RBACR_URL:-$( [[ -f .env ]] && sed -n 's/^RBACR_URL=//p' .env | tail -1)}"
RBACR_URL="${RBACR_URL:-https://rbacr.nu01.com}"
check_rbacr() { ok_if "💎 RBACR svc" get 5 "$RBACR_URL/health"; }

# run_checks: one pass over every check, printed as one line.
run_checks() {
    RESULTS=()
    # Add more services here, one check_* function each.
    check_index
    check_web
    check_cdn
    check_https
    check_api
    check_rbacr
    local line
    printf -v line ' · %s' "${RESULTS[@]}"
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${line# · }"
}

# Sourced (e.g. to call run_checks once): define the functions only.
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

while true; do
    run_checks
    sleep "$INTERVAL"
done
