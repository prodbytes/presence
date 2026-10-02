#!/usr/bin/env bash
# Makes the recognition test's clips (ffmpeg) and copies them, with the
# portraits in test/chrome/fixtures, into the debug app's files on the
# connected Android device: files/fixtures/. The app must be installed.
#
#   integration_test/push_fixtures.sh
#   flutter test integration_test/recognition_android_test.dart
set -euo pipefail
cd "$(dirname "$0")/.."
app=com.nu01.presence
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 3 s: red, green, then blue, a second each.
ffmpeg -loglevel error -f lavfi -i "color=red:s=640x480:d=1:r=30" \
  -f lavfi -i "color=green:s=640x480:d=1:r=30" \
  -f lavfi -i "color=blue:s=640x480:d=1:r=30" \
  -filter_complex "[0][1][2]concat=n=3:v=1:a=0" -pix_fmt yuv420p \
  -c:v libx264 "$work/colours.mp4"
# 3 s on grey, Grace Hopper there from 1 s.
ffmpeg -loglevel error -f lavfi -i "color=gray:s=1280x720:d=3:r=30" \
  -i test/chrome/fixtures/hopper_1.jpg \
  -filter_complex "[0][1]overlay=100:200:enable='gte(t,1)'" \
  -pix_fmt yuv420p -c:v libx264 "$work/hopper.mp4"
cp test/chrome/fixtures/*.jpg "$work/"

adb shell run-as "$app" mkdir -p files/fixtures
for f in "$work"/*; do
  name=$(basename "$f")
  adb shell "run-as $app sh -c 'cat > files/fixtures/$name'" < "$f"
done
adb shell run-as "$app" ls -l files/fixtures
