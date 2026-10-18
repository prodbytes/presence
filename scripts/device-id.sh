#!/usr/bin/env bash
# Prints new device IDs, made by the app's own generator
# (presence_app/lib/identity/device_id.dart): two different adjectives and a
# thing, joined by underscores, such as automatic_paranoid_gadget.
#
# Usage: scripts/device-id.sh [count]   (count defaults to 1)
# Needs `dart` on PATH (the host Flutter SDK's, or devbox's).
set -euo pipefail

count="${1:-1}"
if [[ ! "$count" =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: $0 [count]  (count: a whole number, 1 or more)" >&2
  exit 2
fi

lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../presence_app/lib/identity" && pwd)/device_id.dart"
# The path goes into a Dart string literal: refuse characters that would end it.
if [[ "$lib" == *[\'\\\$]* ]]; then
  echo "error: unsupported characters in path: $lib" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/device_id_main.dart" <<EOF
import '$lib';

void main(List<String> args) {
  for (var i = 0; i < int.parse(args.first); i++) {
    print(DeviceId.generate());
  }
}
EOF
dart run "$tmp/device_id_main.dart" "$count"
