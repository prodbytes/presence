# blank-devbox

Your new project canvas: a blank, batteries-included dev environment powered by
[Devbox](https://www.jetify.com/devbox) inside a [Dev Container](https://containers.dev/).

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/prodbytes/blank-devbox)
[![Open in Dev Containers](https://img.shields.io/static/v1?label=Dev%20Containers&message=Open&color=007ACC&logo=visualstudiocode)](https://vscode.dev/redirect?url=vscode://ms-vscode-remote.remote-containers/cloneInVolume?url=https://github.com/prodbytes/blank-devbox)

## What's inside

Toolchain pinned by [devbox.json](devbox.json) and locked in [devbox.lock](devbox.lock):

| Tool | Version |
|------|---------|
| GraalVM CE | 25.2.4 (JDK 25) |
| Node.js | 26.x |
| Python | 3.14.x |
| PostgreSQL | 17.x |
| Flutter | 3.47.x |

The container also ships the
[docker-in-docker feature](https://github.com/devcontainers/features/tree/main/src/docker-in-docker),
so `docker ps` works out of the box.

## Getting started

Click a badge above, or locally:

```bash
git clone git@github.com:prodbytes/blank-devbox.git
code blank-devbox   # then "Reopen in Container" when prompted
```

Once inside the container:

```bash
devbox shell        # enter the environment
devbox run node --version
devbox add go@1.24  # add more tools (updates devbox.json + devbox.lock)
```

## Services

```bash
devbox services up
```

starts the Flutter app in web mode on http://localhost:8080/app/
([scripts/flutter-web.sh](scripts/flutter-web.sh)), the events API on
http://localhost:3000/api/events ([scripts/sam-api.sh](scripts/sam-api.sh)),
Floci as a local CloudFront that routes http://presence.localhost:4566/app/
and `/api/` to them ([presence_floci/](presence_floci)), and a `health-check`
monitor, wired up in [process-compose.yaml](process-compose.yaml). The
monitor logs one status line per check (every 15 s, configurable via
`HEALTH_CHECK_INTERVAL`):

```
2026-07-09 20:02:10 🌐 web ✅ ⚡ api ✅ ☁️ cdn ✅
```

Stop everything with `devbox services stop`. The monitor also runs standalone:
`bash scripts/health-check.sh`.

## Flutter app

The Flutter app lives in [presence_app/](presence_app). Run it in web mode with:

```bash
devbox run web      # or: devbox services up, to start it with the health monitor
```

It serves on http://localhost:8080/app/ (override the port with
`FLUTTER_WEB_PORT`); the dev
container forwards that port automatically. It uses Flutter's `web-server`
device, so no Chrome is needed inside the container. Open the URL in any
browser. Press `r` in the terminal to hot reload.

### Building the binaries

The [Makefile](Makefile) builds release binaries through
[scripts/make.sh](scripts/make.sh), with the settings from `.env`:

```bash
make            # every platform this host can build
make web        # presence_app/build/web/
make android    # presence_app/build/app/outputs/flutter-apk/app-release.apk
make ios        # presence_app/build/ios/iphoneos/Runner.app (macOS, unsigned)
make linux      # presence_app/build/linux/<arch>/release/bundle/ (Linux only)
make clean
```

Pass `MODE=profile` or `MODE=debug` for other build modes, and
`IOS_CODESIGN=1` to sign the iOS build (needs a signing team in Xcode).

## How the container is built

The [Containerfile](.devcontainer/Containerfile) keeps the Microsoft
`ubuntu-24.04` devcontainer base image and layers Devbox on top:

1. Devbox is installed as root, then everything else runs as the `vscode` user
   so the Nix store ownership matches the container's `remoteUser`.
2. Nix is installed in single-user mode (`--no-daemon`) — containers have no
   systemd, so the multi-user Nix daemon can't run.
3. At build time the locked store paths are fetched straight from
   `cache.nixos.org` to warm `/nix/store` (no GitHub API calls, so builds
   don't hit unauthenticated rate limits).
4. On container start, `postCreateCommand` runs `devbox install`, which finds
   the heavy downloads already cached. The first install still evaluates
   nixpkgs, which takes a few minutes; after that the environment is instant.
