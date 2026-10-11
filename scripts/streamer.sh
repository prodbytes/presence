#!/usr/bin/env bash
# Builds presence-streamer (presence_streamer/) for the Raspberry Pi, 32-
# and 64-bit, as tarballs and .debs, into presence_streamer/build/:
#
#   presence-streamer_<version>_armhf.tar.gz / _arm64.tar.gz
#   presence-streamer_<version>_armhf.deb    / _arm64.deb   (with dpkg-deb)
#
#   bash scripts/streamer.sh            (or: make streamer)
#
# - armhf is GOARM=6: Raspberry Pi OS 32-bit is ARMv6 hard-float, so one
#   binary runs on every Pi (Zero, 1 to 5); arm64 is Raspberry Pi OS 64-bit.
#   Pure Go (CGO_ENABLED=0), static: no libraries to match.
# - The detector's model (YOLOv4-tiny, COCO) is downloaded once into
#   presence_streamer/build/models/ and checked against its pinned SHA-256.
# - The Google OAuth client for the device sign-in comes from
#   GOOGLE_DEVICE_CLIENT_ID and GOOGLE_DEVICE_CLIENT_SECRET (the environment,
#   else .env); without them the streamer asks for them at run time.
# - The version is scripts/version.sh's (VERSION_Z overrides Z).
set -euo pipefail

cd "$(dirname "$0")/.."
root=$PWD
src=presence_streamer
out=$src/build

# shellcheck source=scripts/version.sh
source scripts/version.sh

# One setting from .env, without running it.
dotenv() {
  [[ -f .env ]] || return 0
  sed -n "s/^$1=//p" .env | tail -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}
client_id=${GOOGLE_DEVICE_CLIENT_ID:-$(dotenv GOOGLE_DEVICE_CLIENT_ID)}
client_secret=${GOOGLE_DEVICE_CLIENT_SECRET:-$(dotenv GOOGLE_DEVICE_CLIENT_SECRET)}
for value in "$client_id" "$client_secret"; do
  if [[ ! "$value" =~ ^[A-Za-z0-9._-]*$ ]]; then
    echo "error: GOOGLE_DEVICE_CLIENT_ID/SECRET may hold only letters, digits, '.', '_' and '-'" >&2
    exit 1
  fi
done
[[ -n "$client_id" ]] || echo "warning: no GOOGLE_DEVICE_CLIENT_ID: the streamer will need one at run time" >&2

# The model: darknet's YOLOv4-tiny (COCO), pinned by commit and checksum.
DARKNET_COMMIT=59596d7880f6504768df41d6daa586f5cb2b932f
models=(
  "yolov4-tiny.cfg https://raw.githubusercontent.com/AlexeyAB/darknet/$DARKNET_COMMIT/cfg/yolov4-tiny.cfg f858e3724962eedf3ac44e3b6cb3f0c3d9ed067c306bb831f539c578b924c90e"
  "yolov4-tiny.weights https://github.com/AlexeyAB/darknet/releases/download/darknet_yolo_v4_pre/yolov4-tiny.weights cf9fbfd0f6d4869b35762f56100f50ed05268084078805f0e7989efe5bb8ca87"
)
sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}
mkdir -p "$out/models"
for entry in "${models[@]}"; do
  read -r name url sum <<<"$entry"
  file=$out/models/$name
  if [[ ! -f "$file" || "$(sha256 "$file")" != "$sum" ]]; then
    echo "==> downloading $name"
    curl -fsSL --retry 3 -o "$file.part" "$url"
    got=$(sha256 "$file.part")
    if [[ "$got" != "$sum" ]]; then
      rm -f "$file.part"
      echo "error: $name's SHA-256 is $got, not $sum" >&2
      exit 1
    fi
    mv "$file.part" "$file"
  fi
done

ldflags="-s -w -X main.version=$VERSION -X main.googleClientID=$client_id -X main.googleClientSecret=$client_secret"

for arch in armhf arm64; do
  case "$arch" in
    armhf) goarch=arm goarm=6 ;;
    arm64) goarch=arm64 goarm= ;;
  esac
  echo "==> presence-streamer $VERSION for $arch"
  stage=$out/stage-$arch
  rm -rf "$stage"
  dir=$stage/presence-streamer
  mkdir -p "$dir/models"
  (cd "$src" && GOOS=linux GOARCH=$goarch GOARM=$goarm CGO_ENABLED=0 \
    go build -trimpath -buildvcs=false -ldflags "$ldflags" -o "$root/$dir/presence-streamer" .)
  install -m 755 "$src/detector/presence-detect.py" "$dir/presence-detect.py"
  install -m 644 "$out"/models/yolov4-tiny.* "$dir/models/"
  install -m 644 "$src/README.md" "$dir/README.md"
  tar -czf "$out/presence-streamer_${VERSION}_$arch.tar.gz" -C "$stage" presence-streamer

  if command -v dpkg-deb >/dev/null; then
    pkg=$stage/deb
    install -d "$pkg/DEBIAN" "$pkg/usr/bin" "$pkg/usr/lib/presence-streamer" \
      "$pkg/usr/share/presence-streamer/models" "$pkg/lib/systemd/system" "$pkg/etc/default" \
      "$pkg/usr/share/doc/presence-streamer"
    install -m 755 "$dir/presence-streamer" "$pkg/usr/bin/presence-streamer"
    install -m 755 "$dir/presence-detect.py" "$pkg/usr/lib/presence-streamer/presence-detect.py"
    install -m 644 "$dir"/models/* "$pkg/usr/share/presence-streamer/models/"
    install -m 644 packaging/streamer/presence-streamer.service "$pkg/lib/systemd/system/"
    install -m 644 packaging/streamer/default "$pkg/etc/default/presence-streamer"
    install -m 644 "$src/README.md" "$pkg/usr/share/doc/presence-streamer/README.md"
    for script in postinst prerm postrm; do
      install -m 755 "packaging/streamer/$script" "$pkg/DEBIAN/$script"
    done
    echo /etc/default/presence-streamer >"$pkg/DEBIAN/conffiles"
    size=$(du -sk --exclude=DEBIAN "$pkg" 2>/dev/null | cut -f1 || du -sk "$pkg" | cut -f1)
    sed -e "s/@VERSION@/$VERSION/" -e "s/@ARCH@/$arch/" -e "s/@SIZE@/$size/" \
      packaging/streamer/control >"$pkg/DEBIAN/control"
    dpkg-deb --root-owner-group --build "$pkg" "$out/presence-streamer_${VERSION}_$arch.deb" >/dev/null
  fi
  rm -rf "$stage"
done
ls -l "$out"/presence-streamer_"$VERSION"_*
