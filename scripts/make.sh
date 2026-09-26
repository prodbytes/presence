#!/usr/bin/env bash
# Builds the app binaries. Run through the Makefile (`make`, `make web`, ...)
# or directly: `bash scripts/make.sh <target>...`.
#
# Targets: web, android, ios, linux, all (every platform this host can
# build), clean. Settings, from the environment or `make VAR=value`:
#   MODE          release (default), profile or debug
#   IOS_CODESIGN  1 to sign the iOS build (needs a signing team in Xcode);
#                 unsigned by default
# Settings such as the Google client IDs come from the repo's .env (see
# .env.example), through the same allowlist as the run scripts.
#
# The version is X.Y.Z: X and Y from version.X.txt and version.Y.txt, Z the
# build time as YYYYMMDDHHMM (UTC); the build number is the same time in
# Unix seconds. Set VERSION_Z and BUILD_NUMBER to override them (see
# scripts/version.sh).
set -euo pipefail

MODE="${MODE:-release}"
case "$MODE" in
  release | profile | debug) ;;
  *) echo "error: MODE must be release, profile or debug (got '$MODE')" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/../presence_app"
source ../scripts/dart-defines.sh
source ../scripts/version.sh
BUILD_ARGS=(--build-name "$VERSION" --build-number "$BUILD_NUMBER" "${DART_DEFINES[@]}")

# can_build <target>: whether this host's OS can build the target.
can_build() {
  case "$1" in
    ios) [[ "$(uname -s)" == Darwin ]] ;;
    linux) [[ "$(uname -s)" == Linux ]] ;;
    *) return 0 ;;
  esac
}

build() {
  local target="$1"
  if ! can_build "$target"; then
    echo "error: $target can't be built on $(uname -s)" >&2
    return 1
  fi
  echo "==> $target ($MODE, version $VERSION, build $BUILD_NUMBER)"
  case "$target" in
    web)
      flutter build web "--$MODE" "${BUILD_ARGS[@]}"
      echo "==> web: presence_app/build/web/"
      ;;
    android)
      flutter build apk "--$MODE" "${BUILD_ARGS[@]}"
      echo "==> android: presence_app/build/app/outputs/flutter-apk/app-$MODE.apk"
      ;;
    ios)
      local sign=--no-codesign
      [[ "${IOS_CODESIGN:-}" == 1 ]] && sign=--codesign
      flutter build ios "--$MODE" "$sign" "${BUILD_ARGS[@]}"
      echo "==> ios: presence_app/build/ios/iphoneos/Runner.app"
      ;;
    linux)
      flutter build linux "--$MODE" "${BUILD_ARGS[@]}"
      echo "==> linux: presence_app/build/linux/*/$MODE/bundle/"
      ;;
  esac
}

[[ $# -gt 0 ]] || set -- all
for arg in "$@"; do
  case "$arg" in
    web | android | ios | linux) build "$arg" ;;
    all)
      for target in web android ios linux; do
        if can_build "$target"; then
          build "$target"
        else
          echo "==> skipping $target: can't be built on $(uname -s)"
        fi
      done
      ;;
    clean) flutter clean ;;
    *) echo "error: unknown target '$arg' (web, android, ios, linux, all, clean)" >&2; exit 2 ;;
  esac
done
