# Sourced by scripts/make.sh and the release scripts. Sets the app version,
# X.Y.Z:
#   VERSION_X, VERSION_Y  from version.X.txt and version.Y.txt at the repo root
#   VERSION_Z             the build time as a UTC timestamp, YYYYMMDDHHMM,
#                         unless VERSION_Z is already set
#   BUILD_NUMBER          the build time in Unix seconds (Android's
#                         versionCode, iOS's CFBundleVersion), unless set
#   VERSION               "$VERSION_X.$VERSION_Y.$VERSION_Z"
# Returns non-zero if a version file or a preset value isn't a plain number.

# _whole <name>...: fails, naming the first variable that isn't a whole number.
_whole() {
  local name
  for name in "$@"; do
    if [[ ! "${!name}" =~ ^(0|[1-9][0-9]*)$ ]]; then
      echo "error: $name must be a whole number (got '${!name}')" >&2
      return 1
    fi
  done
}

_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_X="$(tr -d '[:space:]' < "$_root/version.X.txt")"
VERSION_Y="$(tr -d '[:space:]' < "$_root/version.Y.txt")"
unset _root
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%s)}"
_whole VERSION_X VERSION_Y BUILD_NUMBER || { unset -f _whole; return 1; }
if [[ -z "${VERSION_Z:-}" ]]; then
  # BSD date (macOS) takes -r <seconds>; GNU date (Linux) takes -d @<seconds>.
  VERSION_Z="$(date -u -r "$BUILD_NUMBER" +%Y%m%d%H%M 2>/dev/null ||
    date -u -d "@$BUILD_NUMBER" +%Y%m%d%H%M)"
fi
_whole VERSION_Z || { unset -f _whole; return 1; }
unset -f _whole
VERSION="$VERSION_X.$VERSION_Y.$VERSION_Z"
