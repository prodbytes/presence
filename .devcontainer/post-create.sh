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
devbox install
