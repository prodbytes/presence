#!/usr/bin/env bash
# Links this clone's private files, .env and env.local/, from a clone of
# the private prodbytes/setec-astronomy repository, where they're kept per
# tenant. Both names stay git-ignored here, and scripts read .env through
# the link.
#
# Settings, from the environment:
#   PRIVATE_DIR  the setec-astronomy clone (default ../setec-astronomy,
#                relative to this repo, which makes relative links)
#   TENANT       the tenant directory in it (default presence.nu01)
set -euo pipefail

cd "$(dirname "$0")/.."
PRIVATE_DIR="${PRIVATE_DIR:-../setec-astronomy}"
TENANT="${TENANT:-presence.nu01}"
src="$PRIVATE_DIR/$TENANT"

if [[ ! -d "$src" ]]; then
  echo "error: $src not found. Clone the private repository next to this one:" >&2
  echo "  git clone https://github.com/prodbytes/setec-astronomy.git $PRIVATE_DIR" >&2
  exit 1
fi

for name in .env env.local; do
  target="$src/$name"
  if [[ ! -e "$target" ]]; then
    echo "skipped $name: $target doesn't exist"
    continue
  fi
  if [[ -e "$name" && ! -L "$name" ]]; then
    echo "error: $name is a real file here; move it to $src first" >&2
    exit 1
  fi
  ln -sfn "$target" "$name"
  echo "$name -> $target"
done
