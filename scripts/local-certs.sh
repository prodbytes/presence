#!/usr/bin/env bash
# Generates the local HTTPS certificate for Floci's CloudFront with mkcert,
# only when it's missing, expires within 30 days, or doesn't cover every
# name below. Runs before Floci starts (4-floci in process-compose.yaml) or
# standalone.
#
# The certificate is signed by mkcert's local CA (`mkcert -CAROOT`). mkcert
# creates the CA on first use; browsers trust it only after a one-time
# `mkcert -install` (see presence_floci/README.md). The files live in
# presence_floci/certs/, which git ignores: never commit the key.
set -euo pipefail

CERT_DIR="$(cd "$(dirname "$0")/.." && pwd)/presence_floci/certs"
CERT="$CERT_DIR/presence.pem"
KEY="$CERT_DIR/presence-key.pem"
# local.presence.nu01.com is a public name that resolves to 127.0.0.1 (Route 53,
# zone nu01.com), for OAuth origins that must end in a public TLD.
NAMES=("${PRESENCE_PUBLIC_HOST:-local.presence.nu01.com}" presence.localhost '*.presence.localhost' localhost 127.0.0.1 ::1)

if ! command -v mkcert >/dev/null 2>&1; then
    echo "local-certs: 'mkcert' is not on PATH; run inside devbox (devbox shell / devbox services up)" >&2
    exit 1
fi

covers_all_names() {
    local sans
    sans="$(openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null)" || return 1
    for name in "${NAMES[@]}"; do
        case "$name" in
            # openssl prints ::1 in full
            ::1) grep -q -F "IP Address:0:0:0:0:0:0:0:1" <<<"$sans" || return 1 ;;
            [0-9]*) grep -q -F "IP Address:$name" <<<"$sans" || return 1 ;;
            *) grep -q -F "DNS:$name" <<<"$sans" || return 1 ;;
        esac
    done
}

if [[ -s "$CERT" && -s "$KEY" ]] \
        && openssl x509 -in "$CERT" -noout -checkend $((30 * 24 * 3600)) >/dev/null 2>&1 \
        && covers_all_names; then
    echo "local-certs: $CERT is valid; nothing to do"
    exit 0
fi

mkdir -p "$CERT_DIR"
mkcert -cert-file "$CERT" -key-file "$KEY" "${NAMES[@]}"
# Floci reads the key through a read-only bind mount as its own user, which
# on Linux isn't the file's owner. It's a local-only certificate (localhost
# names, signed by this machine's mkcert CA), and git ignores the folder.
chmod 755 "$CERT_DIR"
chmod 644 "$KEY"
echo "local-certs: wrote $CERT (CA: $(mkcert -CAROOT)/rootCA.pem)"
