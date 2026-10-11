#!/bin/sh
# Installs the Presence streamer on a Raspberry Pi (Raspberry Pi OS 32- or
# 64-bit) and sets it up for a profile, so it streams from every boot:
#
#   curl -fsSL https://sh.presence.nu01.com/streamer | sh -s -- <profile ID>
#   curl -fsSL https://sh.presence.nu01.com/streamer | PRESENCE_PROFILE=<profile ID> sh
#
# (https://sh.presence.nu01.com/streamer serves this file: presence_sh/,
# deployed on *GA tags. The raw GitHub URL of this file on main works too.)
# The app's account sheet shows the first command, with the profile filled
# in, for a premium profile.
#
# It downloads the release's presence-streamer .deb for this Pi's
# architecture (armhf or arm64), checks its sha256, installs it with apt
# (with sudo; apt brings ffmpeg, rclone and OpenCV), and runs `sudo
# presence-streamer setup --profile <ID>`: that asks for a Google sign-in
# (a code to enter on a phone), checks the profile is Premium, and starts
# presence-streamer.service, which starts at every boot.
#
# Environment:
#   PRESENCE_PROFILE  the profile ID, when not given as the argument
#   PRESENCE_TAG      release tag to install (default: the latest GA release)
set -eu

REPO=prodbytes/presence

say() { printf 'presence-streamer: %s\n' "$*" >&2; }

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

main() {
  profile=${1:-${PRESENCE_PROFILE:-}}
  case "$profile" in
    "")
      say "give the profile ID: curl -fsSL https://sh.presence.nu01.com/streamer | sh -s -- <profile ID>"
      say "(the Presence app shows it, and this command, in the account sheet)"
      return 2
      ;;
  esac
  if ! printf '%s' "$profile" | grep -Eq '^[a-z]+_[a-z]+_[a-z]+$' || [ "${#profile}" -gt 64 ]; then
    say "'$profile' isn't a profile ID (they look like automatic_paranoid_axolotl)"
    return 2
  fi

  if [ "$(uname -s)" != Linux ] || ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg >/dev/null 2>&1; then
    say "the streamer is for Raspberry Pi OS (Debian, with apt)"
    return 1
  fi
  arch=$(dpkg --print-architecture)
  case "$arch" in
    armhf | arm64) ;;
    *)
      say "the streamer is for 32-bit (armhf) or 64-bit (arm64) Raspberry Pi OS, not $arch"
      return 1
      ;;
  esac

  tag=${PRESENCE_TAG:-$(latest_tag)}
  case "$tag" in
    "" | *[!A-Za-z0-9._-]*)
      say "couldn't find the latest release"
      return 1
      ;;
  esac

  sudo=
  [ "$(id -u)" = 0 ] || sudo=sudo

  asset="presence-streamer-$tag-raspberrypi-$arch.deb"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  # apt reads the file as its _apt user.
  chmod 755 "$tmp"
  say "downloading $asset"
  if ! curl -fL --progress-bar -o "$tmp/$asset" \
    "https://github.com/$REPO/releases/download/$tag/$asset"; then
    say "release $tag has no $asset"
    return 1
  fi
  # It installs as root: the checksum is required.
  want=$(asset_sha256 "$tag" "$asset")
  if [ -z "$want" ]; then
    say "couldn't get the checksum from GitHub to verify $asset; try again later"
    return 1
  fi
  if [ "$(sha256_of "$tmp/$asset")" != "$want" ]; then
    say "checksum mismatch for $asset"
    return 1
  fi
  chmod 644 "$tmp/$asset"

  # With 2 GB of memory or more the streamer searches its chunks itself,
  # with OpenCV (the package suggests it); with less, the cloud does.
  opencv=
  mem_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || true)
  if [ -n "$mem_kb" ] && [ "$mem_kb" -lt 1572864 ]; then
    say "$((mem_kb / 1024)) MB of memory: chunks are searched in the cloud"
  else
    opencv="python3 python3-opencv python3-numpy"
  fi
  say "installing $asset (apt-get install, with ffmpeg and rclone${opencv:+ and OpenCV})"
  $sudo apt-get update -qq || say "apt-get update failed; installing with the package lists there are"
  # shellcheck disable=SC2086 # the package names, or none
  $sudo apt-get install -y "$tmp/$asset" $opencv

  # The sign-in asks on the terminal: this script's own stdin is the pipe
  # from curl.
  say "setting up profile $profile"
  if [ -r /dev/tty ]; then
    $sudo presence-streamer setup --profile "$profile" </dev/tty
  else
    say "no terminal for the sign-in: run  sudo presence-streamer setup --profile $profile"
    return 1
  fi
}

# Everything runs from here, so a truncated download runs nothing.
main "$@"
