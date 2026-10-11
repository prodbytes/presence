#!/usr/bin/env bash
# Copies a folder of raw photos and videos into the test data, cleaned for a
# public repo, then rewrites labels.csv from the whole tree. See README.md.
#
#   test/data/import.sh <source-folder> <species> <subject>
#   test/data/import.sh ../test.local/images/cats/suerte cats suerte
#   test/data/import.sh "../test.local/images/cats/not suerte" cats other
#
# <subject> is who's in every file of the folder, or "other" for animals
# or people who aren't a subject (strangers). Files land in
# <species>/<subject>/{photos,stills,clips}/:
#   - photos: *.jpg, *.jpeg, *.png, and *.heic without a .jpg twin;
#   - stills: photos named *_still_<n>.* (frames taken from a video);
#   - clips:  *.mp4, *.mov.
# Cleaning (needs ffmpeg 7.1 or later, for HEIC and EXIF rotation):
#   - all metadata dropped (EXIF, GPS, camera, dates), rotation applied;
#   - at most 1280 px on the long side, as the app's frames;
#   - clips as the app records them: H.264, 30 fps, a keyframe every
#     second exactly, no audio.
# Re-running overwrites what it made; nothing else is touched.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

if [ "$#" -ne 3 ]; then
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi
src=$1 species=$2 subject=$3
[ -d "$src" ] || { echo "no such folder: $src" >&2; exit 1; }
case "$species$subject" in
  *[!a-z0-9-]*) echo "species and subject: lowercase, digits, dashes" >&2; exit 1 ;;
esac
command -v ffmpeg >/dev/null || { echo "needs ffmpeg" >&2; exit 1; }

dest="$here/$species/$subject"
long_side="scale='if(gte(iw,ih),min(1280,iw),-2)':'if(gte(iw,ih),-2,min(1280,ih))'"

# "photo (2).JPG" -> "photo_2.jpg"
clean_name() {
  local base=$1 ext=$2
  base=$(printf '%s' "$base" | sed -E 's/ *\(([0-9]+)\)/_\1/g; s/[^A-Za-z0-9._-]+/_/g')
  printf '%s.%s' "$base" "$ext"
}

photo() { # <in> <out>
  ffmpeg -nostdin -loglevel error -y -i "$1" -vf "$long_side" \
    -map_metadata -1 -frames:v 1 -update 1 -q:v 3 "$2"
}

clip() { # <in> <out>
  ffmpeg -nostdin -loglevel error -y -i "$1" -an -sn -dn \
    -map_metadata -1 -map_chapters -1 -vf "$long_side,fps=30" \
    -c:v libx264 -preset slow -crf 26 -pix_fmt yuv420p \
    -g 30 -keyint_min 30 -sc_threshold 0 -movflags +faststart "$2"
}

count=0
while IFS= read -r -d '' f; do
  name=$(basename "$f")
  base=${name%.*}
  ext=$(printf '%s' "${name##*.}" | tr '[:upper:]' '[:lower:]')
  case "$ext" in
    jpg | jpeg | png | heic)
      if [ "$ext" = heic ] && compgen -G "$(dirname "$f")/$base.[jJ][pP]*[gG]" >/dev/null; then
        continue # The .jpg twin is the same picture.
      fi
      kind=photos
      case "$base" in *_still_[0-9]*) kind=stills ;; esac
      mkdir -p "$dest/$kind"
      photo "$f" "$dest/$kind/$(clean_name "$base" jpg)"
      ;;
    mp4 | mov)
      mkdir -p "$dest/clips"
      clip "$f" "$dest/clips/$(clean_name "$base" mp4)"
      ;;
    *) continue ;;
  esac
  count=$((count + 1))
done < <(find "$src" -maxdepth 1 -type f -print0 | sort -z)
echo "$species/$subject: $count files"

# labels.csv: one row per file, from where it sits in the tree.
{
  echo "path,species,subject,kind"
  cd "$here"
  find . -mindepth 4 -maxdepth 4 -type f \
    \( -path './*/*/photos/*' -o -path './*/*/stills/*' -o -path './*/*/clips/*' \) \
    | sed 's|^\./||' | LC_ALL=C sort \
    | awk -F/ '{ k = $3; sub(/s$/, "", k); print $0 "," $1 "," $2 "," k }'
} > "$here/labels.csv.tmp"
mv "$here/labels.csv.tmp" "$here/labels.csv"
echo "labels.csv: $(($(wc -l < "$here/labels.csv") - 1)) files"
