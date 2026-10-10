#!/usr/bin/env bash
# Tags the current commit with the current version and a release kind, and
# pushes the tag, which starts the Release workflow
# (.github/workflows/release.yml). Used by scripts/release-rc.sh and
# scripts/release-ga.sh: `bash scripts/tag-release.sh RC|GA`.
#
# The tag is X.Y.Z-<kind>: X and Y from version.X.txt and version.Y.txt, Z
# the current time (see scripts/version.sh). The workflow builds with that
# same version. The commit must be on main (the Deploy, Deploy RC and
# Release workflows refuse others), and the tag is signed (git tag -s, with
# your configured GPG or SSH signing key; see specs/release.md). DRY_RUN=1
# checks and prints the tag without creating it.
set -euo pipefail

kind="${1:-}"
case "$kind" in
  RC | GA) ;;
  *) echo "usage: $0 RC|GA" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."
source scripts/version.sh
tag="$VERSION-$kind"

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "error: uncommitted changes; commit and push them first" >&2
  exit 1
fi
git fetch --quiet origin
if [[ -z "$(git branch --remotes --contains HEAD)" ]]; then
  echo "error: $(git rev-parse --short HEAD) isn't pushed; push it first" >&2
  exit 1
fi
if ! git merge-base --is-ancestor HEAD origin/main; then
  echo "error: a release must be a commit on main (check out main and pull)" >&2
  exit 1
fi
if git rev-parse --quiet --verify "refs/tags/$tag" >/dev/null ||
  git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null; then
  echo "error: tag $tag already exists; try again in a minute" >&2
  exit 1
fi

echo "Tagging $(git rev-parse --short HEAD) as $tag"
if [[ "${DRY_RUN:-}" == 1 ]]; then
  echo "Dry run: not tagged."
  exit 0
fi
if ! git tag --sign "$tag" --message "presence $tag"; then
  echo "error: couldn't sign the tag; set up a signing key (git config user.signingkey," >&2
  echo "  and gpg.format ssh for an SSH key) and add it to GitHub, then try again" >&2
  exit 1
fi
git push --quiet origin "refs/tags/$tag"
echo "Pushed $tag. The Release workflow publishes it as presence-$tag:"
echo "  $(git remote get-url origin | sed -e 's#^git@github.com:#https://github.com/#' -e 's#\.git$##')/actions/workflows/release.yml"
