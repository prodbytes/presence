#!/bin/sh
# Downloads, extracts and runs the latest Presence release for this machine:
#
#   curl -fsSL https://raw.githubusercontent.com/prodbytes/presence/main/scripts/install.sh | sh
#
# On Linux x64 or arm64 it runs the native bundle, kept in
# ${XDG_DATA_HOME:-~/.local/share}/presence/<tag>/ so later runs of the same
# release skip the download. Anywhere else, or if the native app can't be
# downloaded or run, it opens the web app instead.
#
# Environment:
#   PRESENCE_TAG  release tag to run (default: the latest GA release)
#   PRESENCE_WEB  set to 1 to skip the native app and open the web app
set -eu

REPO=prodbytes/presence
WEB_URL=https://presence.nu01.com
# Debian/Ubuntu packages the native app needs.
DEPS="libgtk-3-0 libegl1 libgles2"

say() { printf 'presence: %s\n' "$*" >&2; }

open_web() {
  say "opening the web app: $WEB_URL"
  if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$WEB_URL" >/dev/null 2>&1 && return 0
  elif [ "$(uname -s)" = Darwin ]; then
    open "$WEB_URL" && return 0
  fi
  say "no browser to open here; visit $WEB_URL"
}

# x64 or arm64, the names Flutter gives Linux bundles; empty if unsupported.
linux_arch() {
  [ "$(uname -s)" = Linux ] || return 0
  case "$(uname -m)" in
    x86_64 | amd64) echo x64 ;;
    aarch64 | arm64) echo arm64 ;;
  esac
}

# The latest GA tag, from the releases/latest redirect (not rate limited
# like the API).
latest_tag() {
  curl -fsSI "https://github.com/$REPO/releases/latest" |
    tr -d '\r' | sed -n 's|^[Ll]ocation: .*/releases/tag/\([A-Za-z0-9._-]*\)$|\1|p'
}

# The asset's sha256 from the release API, or nothing if the API is
# unreachable or rate limited.
asset_sha256() {
  curl -fsS "https://api.github.com/repos/$REPO/releases/tags/$1" 2>/dev/null |
    tr ',' '\n' |
    awk -v name="\"name\":\"$2\"" '
      index($0, name) { found = 1 }
      found && /"digest":"sha256:/ { sub(/.*sha256:/, ""); sub(/".*/, ""); print; exit }
    ' || true
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Downloads and extracts the bundle into $1 unless it's already there.
install_native() {
  dir=$1 tag=$2 arch=$3
  [ -x "$dir/bundle/presence_app" ] && return 0
  asset="presence-$tag-linux-$arch.tar.gz"
  mkdir -p "$(dirname "$dir")"
  tmp=$(mktemp -d "$dir.XXXXXX")
  say "downloading $asset"
  if ! curl -fL --progress-bar -o "$tmp/$asset" \
    "https://github.com/$REPO/releases/download/$tag/$asset"; then
    rm -rf "$tmp"
    say "release $tag has no $asset"
    return 1
  fi
  want=$(asset_sha256 "$tag" "$asset")
  if [ -z "$want" ]; then
    say "couldn't get the checksum from GitHub; not verified"
  elif [ "$(sha256_of "$tmp/$asset")" != "$want" ]; then
    rm -rf "$tmp"
    say "checksum mismatch for $asset"
    return 1
  fi
  tar -xzf "$tmp/$asset" -C "$tmp" && rm -f "$tmp/$asset" || {
    rm -rf "$tmp"
    return 1
  }
  rm -rf "$dir"
  mv "$tmp" "$dir"
}

run_native() {
  app="$1/bundle/presence_app"
  if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    say "no display (DISPLAY or WAYLAND_DISPLAY) to show the app on"
    return 1
  fi
  # Linked libraries (ldd), plus the EGL and GLES ones Flutter loads at run
  # time (ldconfig).
  missing=
  if command -v ldd >/dev/null 2>&1; then
    missing=$(ldd "$app" 2>/dev/null | awk '/not found/ { print $1 }')
  fi
  if command -v ldconfig >/dev/null 2>&1; then
    for lib in libEGL.so.1 libGLESv2.so.2; do
      ldconfig -p 2>/dev/null | grep -q "$lib" || missing="$missing $lib"
    done
  fi
  if [ -n "$missing" ]; then
    say "missing libraries:" $missing
    say "install them (e.g. apt install $DEPS) for the native app"
    return 1
  fi
  say "running $app"
  "$app" </dev/null || {
    say "the native app exited with status $? (it needs e.g. $DEPS)"
    return 1
  }
}

main() {
  arch=$(linux_arch)
  if [ "${PRESENCE_WEB:-}" = 1 ]; then
    open_web
    return
  fi
  if [ -z "$arch" ]; then
    say "no native build for $(uname -s) $(uname -m)"
    open_web
    return
  fi
  tag=${PRESENCE_TAG:-$(latest_tag)}
  case "$tag" in
    "" | *[!A-Za-z0-9._-]*)
      say "couldn't find the latest release"
      open_web
      return
      ;;
  esac
  dir="${XDG_DATA_HOME:-$HOME/.local/share}/presence/$tag"
  if install_native "$dir" "$tag" "$arch" && run_native "$dir"; then
    return
  fi
  open_web
}

# Everything runs from here, so a truncated download runs nothing.
main "$@"
