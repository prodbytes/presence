#!/usr/bin/env bash
# Runs once when the dev container is created (postCreateCommand).
#
# Devbox has Nix resolve flakes through api.github.com: its own on
# `devbox install`, and nixpkgs when `devbox services up` first installs
# process-compose. Unauthenticated, that API allows 60 requests an hour per
# IP, and Codespaces share IPs, so it often answers 403. Codespaces provide
# a GITHUB_TOKEN; every shell hands it to Nix through NIX_CONFIG. The line
# added below reads the token from the environment, so it's never written
# to disk. Elsewhere, export GITHUB_TOKEN (e.g. `gh auth token`) if you hit
# the limit.
set -euo pipefail

line='[ -n "${GITHUB_TOKEN:-}" ] && export NIX_CONFIG="access-tokens = github.com=${GITHUB_TOKEN}"'
# ~/.profile for login shells; the top of ~/.bashrc, before its guard for
# non-interactive shells, for VS Code's terminals.
for rc in "$HOME/.profile" "$HOME/.bashrc"; do
  touch "$rc"
  if ! grep -qxF "$line" "$rc"; then
    printf '%s\n%s\n' "$line" "$(cat "$rc")" > "$rc"
  fi
done

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  export NIX_CONFIG="access-tokens = github.com=${GITHUB_TOKEN}"
fi
export PATH="$HOME/.nix-profile/bin:$PATH"

# A failure says which step failed and how much disk is left, the likeliest
# cause on a small machine.
fail() {
  echo "post-create: $1 failed" >&2
  df -h / /nix 2>/dev/null >&2 || true
  exit 1
}

# First the locked store paths, straight from cache.nixos.org (no GitHub
# API), quietly: listing and copying ~800 paths would push everything else
# out of the creation log. Then `devbox install` finds them cached.
paths=$(jq -r --arg sys "$(uname -m)-linux" \
  '.packages[].systems[$sys].outputs[]?.path // empty' devbox.lock)
echo "post-create: fetching $(wc -l <<<"$paths") locked Nix store paths..."
xargs -r nix-store --quiet --realise <<<"$paths" >/dev/null ||
  fail "fetching the Nix store"

echo "post-create: devbox install..."
devbox install || fail "devbox install"
echo "post-create: done"
df -h /
