#!/usr/bin/env bash
# Takes the App Store screenshots: runs
# presence_app/integration_test/store_screenshots_test.dart on an iOS
# Simulator (the 6.9" iPhone, 1320x2868) and screenshots it at each
# "SHOT <name>" it prints, into store/app-store/en-US/screenshots/ (PNG
# without alpha, as the App Store wants). The Premium screen is also
# store/app-store/subscription-review.png, the subscriptions' review
# screenshot. Upload them with scripts/app-store-listing.mjs.
#
#   bash scripts/app-store-screenshots.sh ["iPhone 18 Pro Max"]
#
# Uses the host Flutter (not devbox's) and Xcode's simulators.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="$repo/presence_app"
out="$repo/store/app-store/en-US/screenshots"
review="$repo/store/app-store/subscription-review.png"
name="${1:-}"

# The simulator: the one named, else the newest "Pro Max" iPhone.
if [[ -z "$name" ]]; then
  name="$(xcrun simctl list devices available | sed -n 's/^ *\(iPhone [0-9]* Pro Max\) (.*/\1/p' | sort -V | tail -1)"
fi
udid="$(xcrun simctl list devices available | grep -F "    $name (" | head -1 | sed -n 's/.*(\([0-9A-F-]\{36\}\)).*/\1/p')"
if [[ -z "$udid" ]]; then
  echo "error: no available simulator named '$name'" >&2
  exit 1
fi
echo "simulator: $name ($udid)"
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
# Apple's marketing status bar: 9:41, full signal and battery.
xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi \
  --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 \
  --batteryState charged --batteryLevel 100
xcrun simctl ui "$udid" appearance light

# Drops the alpha channel the simulator's PNGs have.
flatten() { # flatten <in.png> <out.png>
  if command -v ffmpeg >/dev/null; then
    ffmpeg -loglevel error -y -i "$1" -pix_fmt rgb24 "$2"
  else
    local jpg
    jpg="$(mktemp -t shot).jpg"
    sips -s format jpeg -s formatOptions best "$1" --out "$jpg" >/dev/null
    sips -s format png "$jpg" --out "$2" >/dev/null
    rm -f "$jpg"
  fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$out"
rm -f "$out"/*.png
cd "$app"
flutter test integration_test/store_screenshots_test.dart -d "$udid" \
  --dart-define=SHOTS_DATA="$app/test/data" 2>&1 |
  while IFS= read -r line; do
    printf '%s\n' "$line"
    if [[ "$line" =~ SHOT\ ([a-z0-9-]+) ]]; then
      shot="${BASH_REMATCH[1]}"
      xcrun simctl io "$udid" screenshot "$tmp/$shot.png" >/dev/null 2>&1
      flatten "$tmp/$shot.png" "$out/$shot.png"
      echo "saved $out/$shot.png"
    fi
  done
status="${PIPESTATUS[0]}"
xcrun simctl status_bar "$udid" clear
[[ "$status" == 0 ]] || { echo "error: the screenshot test failed" >&2; exit "$status"; }
cp "$out/4-premium.png" "$review"
sips -g pixelWidth -g pixelHeight -g hasAlpha "$out"/*.png "$review"
