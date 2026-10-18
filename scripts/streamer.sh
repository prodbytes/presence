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
# - The detector's model (YOLOv4-tiny, COCO; presence_streamer/detector/
#   models.txt) is downloaded once into presence_streamer/build/models/ and
#   checked against its pinned SHA-256 (scripts/models.sh).
# - The Google OAuth client for the device sign-in comes from
#   GOOGLE_DEVICE_CLIENT_ID and GOOGLE_DEVICE_CLIENT_SECRET (the environment,
#   else .env); without them the streamer asks for them at run time.
# - Live sync's AWS IoT endpoint comes from IOT_ENDPOINT (the environment,
#   else .env), as the app's builds: the account's iot:Data-ATS endpoint,
#   the same for prod and the RC. Without it the streamer's live sync is
#   off unless PRESENCE_STREAMER_IOT_ENDPOINT sets one at run time.
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
iot_endpoint=${IOT_ENDPOINT:-$(dotenv IOT_ENDPOINT)}
# Only AWS IoT's form is built in: a local .env's ws://localhost (the local
# stack's broker) isn't for a Pi.
if [[ -n "$iot_endpoint" && ! "$iot_endpoint" =~ ^[a-z0-9]+-ats\.iot\.[a-z0-9-]+\.amazonaws\.com$ ]]; then
  echo "warning: IOT_ENDPOINT '$iot_endpoint' isn't <id>-ats.iot.<region>.amazonaws.com: not built in" >&2
  iot_endpoint=
fi
[[ -n "$iot_endpoint" ]] || echo "warning: no IOT_ENDPOINT: the streamer's live sync is off unless set at run time" >&2

# The model (presence_streamer/detector/models.txt), checked against its
# SHA-256.
bash scripts/models.sh "$out/models"

ldflags="-s -w -X main.version=$VERSION -X main.googleClientID=$client_id -X main.googleClientSecret=$client_secret -X main.iotEndpoint=$iot_endpoint"

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
  install -m 755 "$src/detector/presence-blink.py" "$dir/presence-blink.py"
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
    install -m 755 "$dir/presence-blink.py" "$pkg/usr/lib/presence-streamer/presence-blink.py"
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
