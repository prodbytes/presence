#!/usr/bin/env bash
# Downloads the detector's model (presence_streamer/detector/models.txt)
# into <dir>, checking each file's SHA-256; files already there and right
# aren't downloaded again. Used by scripts/streamer.sh (the Pi packages) and
# scripts/deploy.sh (presence_ingest, the cloud detector).
#
#   bash scripts/models.sh <dir>
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <dir>" >&2
  exit 2
fi
dir=$1
list="$(cd "$(dirname "$0")/.." && pwd)/presence_streamer/detector/models.txt"

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}

mkdir -p "$dir"
while read -r name url sum; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ || ! "$url" =~ ^https:// || ! "$sum" =~ ^[0-9a-f]{64}$ ]]; then
    echo "error: bad line in $list: $name" >&2
    exit 1
  fi
  file=$dir/$name
  if [[ -f "$file" && "$(sha256 "$file")" == "$sum" ]]; then
    continue
  fi
  echo "==> downloading $name"
  curl -fsSL --retry 3 -o "$file.part" "$url"
  got=$(sha256 "$file.part")
  if [[ "$got" != "$sum" ]]; then
    rm -f "$file.part"
    echo "error: $name's SHA-256 is $got, not $sum" >&2
    exit 1
  fi
  mv "$file.part" "$file"
done <"$list"
