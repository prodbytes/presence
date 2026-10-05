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
#
# --pull [dir] instead copies what the app kept on the phone, to look into
# what happened while nobody watched (default dir: android-logs/<time>/,
# git-ignored): its log files (every message, a file per day, for 7 days),
# the logcat it saved at each start (the minutes before a crash or kill),
# and the system's records of its crashes, ANRs and kills, with the
# phone's uptime and whether the app, its service and wake lock are up.
set -euo pipefail

clear=false
all=false
pull=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clear) clear=true ;;
    --all) all=true ;;
    --pull)
      pull="$(cd "$(dirname "$0")/.." && pwd)/android-logs/$(date +%Y%m%d-%H%M%S)"
      if [[ $# -gt 1 && "$2" != --* ]]; then pull="$2"; shift; fi
      ;;
    *) echo "usage: $0 [--clear] [--all] | --pull [dir]" >&2; exit 2 ;;
  esac
  shift
done

source "$(dirname "$0")/android-device.sh"
package=com.nu01.presence
adb_s() { "$adb" -s "$serial" "$@"; }

if [[ -n "$pull" ]]; then
  mkdir -p "$pull"
  adb_s pull "/sdcard/Android/data/$package/files/logs/." "$pull" >/dev/null ||
    echo "note: no log files on the phone yet (the app writes them from this version on)" >&2
  {
    echo "== pulled $(date) from $serial"
    echo "== phone: $(adb_s shell date | tr -d '\r'); $(adb_s shell uptime | tr -d '\r')"
    echo "== app process: $(adb_s shell pidof "$package" | tr -d '\r' || true)"
    echo "== services"
    adb_s shell dumpsys activity services "$package" | grep -E 'ServiceRecord|isForeground' || true
    echo "== wake locks"
    adb_s shell dumpsys power | grep -E "presence:|mWakefulness=" || true
    echo "== battery"
    adb_s shell dumpsys battery | grep -E 'level|powered|status' || true
    echo "== the system's records (dropbox): crashes, ANRs, kills; details in dropbox.txt"
    adb_s shell dumpsys dropbox | grep -E 'crash|anr|wtf|lowmem|watchdog|tombstone' || true
  } >"$pull/status.txt" 2>&1
  adb_s shell dumpsys dropbox --print >"$pull/dropbox.txt" 2>&1 || true
  echo "Pulled to $pull:" >&2
  ls -1 "$pull" >&2
  exit 0
fi

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
