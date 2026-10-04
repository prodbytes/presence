#!/usr/bin/env bash
# Streams the app's log from the Android phone attached by USB, readable:
# the app's own lines (its process, tag flutter) and the system's errors
# that explain them (Google sign-in in Play services, crashes), without
# the rest of the system's noise. `bash scripts/android-log.sh` or
# `devbox run android-log`; ANDROID_SERIAL=<serial> with several phones.
#
# The phone's log buffer is raised to 16 MB first (Android's default,
# 256 KB, holds only minutes), and what's already in it is shown too.
# Options: --clear starts from now; --all shows every line of the app's
# process instead (native and plugin logs too, until it restarts).
set -euo pipefail

clear=false
all=false
for arg in "$@"; do
  case "$arg" in
    --clear) clear=true ;;
    --all) all=true ;;
    *) echo "usage: $0 [--clear] [--all]" >&2; exit 2 ;;
  esac
done

source "$(dirname "$0")/android-device.sh"
package=com.nu01.presence
adb_s() { "$adb" -s "$serial" "$@"; }

adb_s logcat -G 16M
if $clear; then adb_s logcat -c; fi

if $all; then
  pid="$(adb_s shell pidof "$package" | tr -d '\r')" || {
    echo "error: $package isn't running" >&2
    exit 1
  }
  echo "Logging $package (process $pid) on $serial; Ctrl-C to stop" >&2
  exec "$adb" -s "$serial" logcat -v time --pid="$pid"
fi

echo "Logging $package on $serial; Ctrl-C to stop" >&2
# The app's own lines (tag flutter: print and debugPrint), and the system
# lines that explain them: Google sign-in (Credential Manager and Play
# services' Auth.Api), crashes, and the app being started or killed.
tags='flutter|Auth\.Api[.A-Za-z]*|CredentialManager[A-Za-z]*|GoogleSignIn[A-Za-z]*|AndroidRuntime'
adb_s logcat -v time |
  grep --line-buffered -E " [VDIWEF]/($tags) *\(|FATAL|ActivityManager.*(Start proc|Killing|died|ANR).*$package"
