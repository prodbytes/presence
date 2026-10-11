# Development environment

- [devbox.json](../devbox.json) manages the toolchain: GraalVM CE
  (`graalvmPackages.graalvm-ce`, 25.2.4 / JDK 25; locked for aarch64-darwin,
  aarch64-linux and x86_64-linux),
  Python, Node.js, Go, PostgreSQL, Flutter, Maven (3.9.16, running on the
  GraalVM JDK, for the auth API), the AWS SAM CLI, the AWS CLI (2.35.11),
  GNU Make, curl, mkcert (1.4.4, for the local HTTPS certificate) and
  OpenSSL. Everything the services, the Makefile and the deploy script run
  comes from devbox,
  except Docker: the daemon (Docker Desktop, or docker-in-docker in the dev
  container) and its CLI with the `compose` plugin come from the host.
- The dev container ([.devcontainer/](../.devcontainer)) installs devbox and
  includes the Dart and Flutter VS Code extensions. It forwards ports 8080
  (Flutter web), 4566 (Floci), 8081 (index) and 8443 (Floci HTTPS).
  - It pins devbox (0.18.1: the release's `linux_amd64` or `linux_arm64`
    binary from GitHub, checked against the release's published SHA-256,
    instead of piping `get.jetify.com/devbox` into bash) and Nix (2.35.0,
    its installer checked against the published SHA-256), and the
    docker-in-docker feature (`devcontainer-lock.json`).
  - It asks for a 4-core, 16 GB machine (`hostRequirements`).
  - It sets `PRESENCE_BIND_HOST=0.0.0.0`, so Floci in docker-in-docker
    reaches the dev servers (see [Local CDN](local-cdn.md)).
  - The image only installs devbox and Nix. It doesn't fill the Nix store:
    that made a 9.8 GiB layer, Codespaces rebuild the image for each
    codespace anyway, and a failed build leaves only recovery mode.
  - [post-create.sh](../.devcontainer/post-create.sh) fills the store
    with the locked paths from cache.nixos.org (`nix-store --quiet
    --realise`, output dropped: listing and copying ~800 paths pushed the
    error out of the creation log), then runs `devbox install`. On failure
    it prints which step failed and `df -h` of `/` and `/nix`, and exits
    non-zero; the codespace still opens, and the script can be run again.
    It also makes every shell pass `GITHUB_TOKEN` (which Codespaces provide)
    to Nix as `NIX_CONFIG` access-tokens. Devbox has Nix resolve flakes
    through api.github.com (on install, and when `devbox services up`
    first installs process-compose), which answers 403 to unauthenticated
    callers past 60 requests an hour per IP. The token stays in the
    environment; the line in `~/.profile` and `~/.bashrc` only reads it.
  - Verified with the Dev Containers CLI on an arm64 Mac: the image built,
    post-create installed everything, and `devbox services up` came up
    with every health check ✅. It wasn't run on an x86_64 Codespace.
    After the Nix step moved to post-create, the image built and
    post-create, run in a fresh container, fetched the 39 locked paths and
    finished `devbox install` in 15 lines of output (arm64 Mac).
- Flutter web runs on the `web-server` device, so the container doesn't need
  Chrome.
- `devbox services up` ([process-compose.yaml](../process-compose.yaml)) starts:
  - the Flutter web server (`2-flutter-web`, via
    [scripts/flutter-web.sh](../scripts/flutter-web.sh)), with an HTTP
    readiness probe. On stop, its shutdown command kills whatever listens
    on `FLUTTER_WEB_PORT`: stopping only the script used to leave
    Flutter's `dart` process serving the old build, so every later start
    failed to bind the port and the app never updated.
  - Floci as the local CloudFront (`4-floci`; see
    [Local CDN](local-cdn.md)), over HTTP and HTTPS, after
    [scripts/local-certs.sh](../scripts/local-certs.sh) makes sure the
    mkcert certificate exists. It restarts whenever it ends (`restart:
    always`), because a container stopped from outside, for example by
    another checkout's `devbox services stop` (the compose project is
    shared), ends `compose up` with exit code 0
  - the site index (`5-index`: `python3 -m http.server` on
    http://localhost:8081, `INDEX_PORT`; see [Site index](site-index.md))
  - the health monitor
    ([scripts/health-check.sh](../scripts/health-check.sh)): every 15 s
    (`HEALTH_CHECK_INTERVAL`), **one line per run**: the time, then each
    check as its emoji, a short label and ✅ (ok) / ❌ (failed) / ⚪ (not
    set), separated by ` · `, with no reasons. In order: 🏠 Index (the
    site index), 🌐 Web (the web app), 🚚 CDN, 🔒 HTTPS (the CDN over
    HTTPS), 🔌 API (the auth API through the CDN, `/api/auth/anonymous`),
    then from the API's answer 🔑 OIDC
    (`GOOGLE_WEB_CLIENT_ID` set, or ⚪ authentication off), ☁️ AWS
    (`COGNITO_IDENTITY_POOL_ID` and `USER_DATA_BUCKET` set, or ⚪ nothing
    shipped to S3) and 👮 RBACR (`.env`'s `RBACR_RC_TOKEN` set, or ⚪ the local auth API can't tell a linked account's shared membership or a profile's tier),
    all three ❌ when the API doesn't answer. With AWS set, it also asks
    Floci whether it implements Cognito Identity (an unsigned `GetId` for
    a made-up pool): Floci answers `UnknownOperationException`, so ☁️ AWS
    is ❌, since the local auth API can't issue credentials and the app's
    cloud sync fails here (test it on the RC, or remove the settings from
    `.env` to turn it off); if Floci ever implements it, it goes back to
    ✅ by itself; last 💎 RBACR svc, the /health of
    rbacr's RC (`RBACR_RC_URL`, default https://rc.rbacr.nu01.com), which
    the local web build asks for the user's roles and the local auth API
    for shared membership. For example: `🏠 Index ✅ · … · 🔑 OIDC ⚪ · …`.
    Sourcing the script defines `run_checks` (one pass) without starting
    the loop.

  The health monitor waits until the web server, Floci and the index all
  pass
  their readiness probes (`depends_on: process_healthy`), so its first line
  is already green. The probes start after 1–2 s and poll every 2 s, with
  about 5 minutes of allowance for a first build. Measured on an Apple
  Silicon Mac: the first all-green health line came 9 s after
  `devbox services up`, and 10 s with the Flutter build cache cleared. No database runs as a service: the app keeps its data on the device
  (see [Storage](storage.md)). The `postgresql` devbox package stays in the
  toolchain (for `psql` and `pg_isready`).
- The app requires Dart SDK `^3.13.0`, which covers the Nix Flutter 3.47.0
  (Dart 3.13.0).
- **Google Cloud CLI:** Homebrew's `gcloud-cli` cask, logged in with
  `gcloud auth login` (a browser sign-in) as the project owner, with the
  project's Google Cloud project (named in the private repo) set as the
  default. It can manage the project, but
  Google offers no CLI for creating Android or iOS OAuth clients, so those
  are made in the Cloud Console.
- **Android builds on macOS:** Homebrew's `android-commandlinetools` cask
  (SDK at `/opt/homebrew/share/android-commandlinetools`, with
  platform-tools, platform 36 and build-tools 36), and JDK 21
  (`openjdk@21`), configured with `flutter config --android-sdk` and
  `--jdk-dir`. Gradle fetches the NDK and extra platforms on the first
  build. The dev container doesn't include the Android SDK.

- **iOS and macOS builds on macOS:** full **Xcode** from the Mac App Store.
  The Command Line Tools alone are not enough: Flutter needs `xcodebuild` and
  the iOS SDK, which only the full Xcode ships. After installing it, point the
  toolchain at it and finish its setup:
  `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`,
  then `sudo xcodebuild -license accept` and `sudo xcodebuild -runFirstLaunch`
  — in that order, because `-runFirstLaunch` refuses to run until the license
  is accepted. Finally `xcodebuild -downloadPlatform iOS` (no `sudo`) for the
  iOS simulator runtime, which the base Xcode no longer bundles: it's an
  ~8 GB download of its own.
  **CocoaPods** comes from Homebrew (`brew install cocoapods`); Flutter needs
  it to resolve plugin pods. The dev container has none of this, because Xcode
  is macOS-only.
- Xcode 27 ships no `Simulator.app`, so simulators are driven from the command
  line with `xcrun simctl` (`list devices`, `boot <udid>`, `io <udid>
  screenshot`). `flutter run -d <udid>` picks up a booted simulator.
- **Building binaries:** the [Makefile](../Makefile) delegates every target
  to [scripts/make.sh](../scripts/make.sh), which runs `flutter build` with
  the `.env` settings from [scripts/dart-defines.sh](../scripts/dart-defines.sh)
  (same allowlist as the run scripts). `make web` builds
  `presence_app/build/web/`, `make android` a release APK, `make ios` an
  unsigned `Runner.app` (signed with `IOS_CODESIGN=1`) and `make linux` the
  Linux bundle; `make clean` runs `flutter clean`. `MODE` picks `release`
  (default), `profile` or `debug`. Every build is versioned `X.Y.Z` (see
  [Versioning](release.md#versioning)). Plain `make` (`all`) builds every
  platform the host can build and skips the rest: iOS needs macOS and Linux
  needs a Linux host, and asking for either elsewhere fails. Verified: on
  the development Mac, web (with the web client ID compiled in and no
  secret), a release APK (`com.nu01.presence`, arm64/armv7/x86_64, signed
  with the debug key because no release key exists yet) and an arm64
  `Runner.app`; and `make linux` in a Linux arm64 container with Flutter
  3.47.5, which built the GTK bundle. CI builds the same targets for
  releases; see [Release builds](release.md).

## README

The [README](../README.md) is the project's front page. It covers:

- what Presence is: tracking what happens in a private place you're
  responsible for;
- a notice that users must make sure local law allows them to record
  (video and audio) where they set it up;
- the technology and main libraries;
- **Before you start**, ahead of every run and deploy section, in order:
  getting the code and tools (Devbox, Docker, clone, `.env`,
  `devbox shell`); creating the Google OAuth consent screen and the web,
  iOS and Android clients; setting up AWS access (`aws configure sso`,
  deploying the `presence-user-data` and `presence-identity` stacks,
  reading `COGNITO_IDENTITY_POOL_ID` and `USER_DATA_BUCKET`, and
  `HOSTED_ZONE_ID` for deploys); and a table of every `.env` variable
  (purpose and source). It doesn't mention the private settings repo;
- running it locally with devbox and on GitHub Codespaces, both pointing
  back to Before you start. The Open in GitHub Codespaces badge links to
  `codespaces.new/prodbytes/presence?machine=standardLinux32gb`, so it
  defaults to a 4-core, 16 GB machine;
- deploying to Floci: what `devbox services up` deploys into it (the
  `presence-local-auth-api` stack and the CloudFront distribution), that
  it needs `GOOGLE_WEB_CLIENT_ID`, redeploying with
  `devbox services restart 4-floci`, and inspecting it with the AWS CLI
  (`--endpoint-url http://localhost:4566`, dummy credentials). Cloud sync
  isn't emulated;
- deploying to AWS (it first sends readers to Before you start): `*RC*` tags deploy to https://rc.presence.nu01.com,
  and `*GA` tags to production, https://presence.nu01.com;
- contributing: contributions are welcome, and merged changes are deployed
  automatically with the next tag.

## Private settings

`.env` and `env.local/` (the OAuth client files downloaded from the Cloud
Console) are kept in the **private** repository
[prodbytes/setec-astronomy](https://github.com/prodbytes/setec-astronomy),
one directory per tenant: this tenant's is `presence.nu01/`. The clone sits
next to this one (`../setec-astronomy`), and this repo holds only relative
symlinks, `.env` → `../setec-astronomy/presence.nu01/.env` and `env.local`
→ `../setec-astronomy/presence.nu01/env.local`, both git-ignored.
[scripts/link-private.sh](../scripts/link-private.sh) makes the links
(`PRIVATE_DIR` and `TENANT` override the clone and the tenant); it
refuses to replace a real file, and re-running it is harmless. Everything
that reads `.env` (the run scripts, `make`) follows the link. Variants such
as `.env.ga` (`.env.*`) are git-ignored too, except the committed
`.env.example`. The local
HTTPS certificates in `presence_floci/certs/` stay here: `local-certs.sh`
generates them per machine from its own mkcert CA.

## Known limitations

- The GraalVM package is the glibc/macOS build, not the musl one, so
  `native-image --static --libc=musl` isn't available. `devbox install` and
  `devbox shell` work on Apple Silicon Macs as well as Linux.
- The Nix Flutter package has no `x86_64-darwin` (Intel Mac) build.

## Claude Code settings

The whole `.claude/` folder is git-ignored: each checkout keeps its own
`.claude/settings.json` (the command allowlist agents grow as you approve
commands) and `.claude/worktrees/` (the worktrees agents work in). Neither
is shared through git, so approving a command never leaves a change to
commit.

[.vscode/settings.json](../.vscode/settings.json) keeps the agent worktrees
out of VS Code. It turns off worktree detection, and it skips `.claude` when
scanning for repositories, so Source Control lists only this repo. It also
hides `.claude/worktrees` from the Explorer, search and the file watcher.
