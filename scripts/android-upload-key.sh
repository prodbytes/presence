#!/usr/bin/env bash
# Creates the Android upload key: the key that signs the App Bundles uploaded
# to Google Play (Play App Signing re-signs them with Play's own app signing
# key). Run it once, by hand, then keep the keystore and its password backed
# up: losing them means asking Google for an upload key reset.
#
#   bash scripts/android-upload-key.sh [keystore path]
#
# The keystore defaults to ~/.config/presence/upload-keystore.jks, outside
# the repo (PKCS12, alias "upload", one password for the store and the key).
# It asks for the name on the certificate and the password, then prints the
# key's SHA-1 and SHA-256 fingerprints and the commands that hand it to the
# release workflow (`gh secret set`) and to local builds (key.properties).
# Given an existing keystore, it only prints those.
set -euo pipefail

alias_name=upload
keystore="${1:-$HOME/.config/presence/upload-keystore.jks}"

command -v keytool >/dev/null || { echo "error: keytool (a JDK) isn't on PATH" >&2; exit 1; }

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
keystore_dir="$(mkdir -p "$(dirname "$keystore")" && cd "$(dirname "$keystore")" && pwd)"
keystore="$keystore_dir/$(basename "$keystore")"
case "$keystore" in
  "$repo_root"/*)
    echo "error: keep the keystore outside the repo (got $keystore)" >&2
    exit 1
    ;;
esac

read_password() {
  local again
  read -rsp "Keystore password: " password; echo >&2
  if [[ "${1:-}" == new ]]; then
    read -rsp "Again: " again; echo >&2
    if [[ "$password" != "$again" ]]; then
      echo "error: the passwords don't match" >&2
      exit 1
    fi
    if (( ${#password} < 6 )) || [[ "$password" == *\\* || "$password" =~ ^[[:space:]] ]]; then
      echo "error: 6 or more characters, no backslash, not starting with a space" >&2
      exit 1
    fi
  fi
}

if [[ -e "$keystore" ]]; then
  echo "$keystore exists already; showing its fingerprints."
  read_password
else
  read -rp "Name on the certificate (e.g. your name or company): " name
  if [[ -z "$name" || "$name" =~ [,+=\<\>#\;\"\\] ]]; then
    echo "error: give a name without , + = < > # ; \" or \\" >&2
    exit 1
  fi
  read_password new
  chmod 700 "$keystore_dir"
  # RSA 4096, valid ~27 years (Play wants a key valid past 2033).
  KEYSTORE_PASSWORD="$password" keytool -genkeypair -keystore "$keystore" \
    -storetype PKCS12 -alias "$alias_name" -keyalg RSA -keysize 4096 \
    -validity 10000 -dname "CN=$name, O=Presence" -storepass:env KEYSTORE_PASSWORD
  chmod 600 "$keystore"
  echo "Created $keystore"
fi

echo
echo "Upload key fingerprints (SHA-1 for a Google Android OAuth client;"
echo "SHA-256 for /.well-known/assetlinks.json, next to Play's app signing key's):"
KEYSTORE_PASSWORD="$password" keytool -list -v -keystore "$keystore" \
  -alias "$alias_name" -storepass:env KEYSTORE_PASSWORD | grep -E '^[[:space:]]*SHA(1|256):'

cat <<EOF

Hand it to the release workflow (repository secrets; gh asks for the
password, so it stays out of your shell history):
  base64 < "$keystore" | gh secret set ANDROID_UPLOAD_KEYSTORE_BASE64
  gh secret set ANDROID_UPLOAD_KEYSTORE_PASSWORD
  gh secret set ANDROID_UPLOAD_KEY_ALIAS --body $alias_name

For local store builds (make appbundle), write presence_app/android/key.properties
(ignored by git; readable only by you):
  (umask 077; printf 'storeFile=%s\\nstorePassword=%s\\nkeyAlias=%s\\nkeyPassword=%s\\n' \\
    "$keystore" "<password>" $alias_name "<password>" > presence_app/android/key.properties)
or export ANDROID_KEYSTORE_PATH="$keystore" and ANDROID_KEYSTORE_PASSWORD.
EOF
