# Development environment

- [devbox.json](../devbox.json) manages the toolchain: GraalVM CE
  (`graalvmPackages.graalvm-ce`, 25.2.4 / JDK 25; locked for aarch64-darwin,
  aarch64-linux and x86_64-linux),
  Python, Node.js, Go, PostgreSQL, Flutter, the AWS SAM CLI (1.165.0),
  Maven (3.9.16, running on the GraalVM JDK), the AWS CDK CLI (`cdk`,
  2.1138.0), the AWS CLI (2.35.11), GNU Make, curl, mkcert (1.4.4, for the
  local HTTPS certificate) and OpenSSL. Everything the
  services, the Makefile and the SAM and CDK modules run comes from devbox,
  except Docker: the daemon (Docker Desktop, or docker-in-docker in the dev
  container) and its CLI with the `compose` plugin come from the host.
- The dev container ([.devcontainer/](../.devcontainer)) installs devbox and
  includes the Dart and Flutter VS Code extensions. It forwards ports 8080
  (Flutter web), 3000 (SAM API), 4566 (Floci), 8081 (index) and 8443
  (Floci HTTPS).
- Flutter web runs on the `web-server` device, so the container doesn't need
  Chrome.
- `devbox services up` ([process-compose.yaml](../process-compose.yaml)) starts:
  - the Flutter web server (`2-flutter-web`, via
    [scripts/flutter-web.sh](../scripts/flutter-web.sh)), with an HTTP
    readiness probe
  - the events API (`3-sam-api`, via
    [scripts/sam-api.sh](../scripts/sam-api.sh)): `sam build`, then
    `sam local start-api` on http://localhost:3000 (`SAM_API_PORT`), with a
    readiness probe on `GET /api/events`
  - Floci as the local CloudFront (`4-floci`; see
    [Local CDN](local-cdn.md)), over HTTP and HTTPS, after
    [scripts/local-certs.sh](../scripts/local-certs.sh) makes sure the
    mkcert certificate exists
  - the site index (`5-index`: `python3 -m http.server` on
    http://localhost:8081, `INDEX_PORT`; see [Site index](site-index.md))
  - the health monitor, which logs the status of the index, the web app,
    the API, the CDN and the CDN over HTTPS.

  The API process stops with SIGINT, so SAM removes its warm Lambda
  containers. The script exits with a clear message if `sam`, `mvn` or
  `docker` is missing. It points SAM at the active Docker context's socket
  when `DOCKER_HOST` isn't set.

  The health monitor waits until the web server, the API, Floci and the
  index all pass
  their readiness probes (`depends_on: process_healthy`), so its first line
  is already green. The probes start after 1–2 s and poll every 2 s, with
  about 5 minutes of allowance for a first build. Measured on an Apple
  Silicon Mac: the first all-green health line came 9 s after
  `devbox services up`, and 10 s with the Flutter and SAM build caches
  cleared. No database runs as a service: the app keeps its data on the device
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

- **AWS SAM:** building and deploying `presence_api_events` needs the SAM
  CLI, JDK 25 and Maven, all from devbox, plus Docker. `3-sam-api` finds
  them in the devbox environment, so nothing needs installing on the host.

- **AWS CDK:** `presence_infra_tenant` needs JDK 25, Maven 3.9+ and the CDK
  CLI, all from devbox (`cdk`). jsii warns that Node 26 is untested (it supports 22 and 24);
  set `JSII_SILENCE_WARNING_UNTESTED_NODE_VERSION=1` to hide the warning.

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
that reads `.env` (the run scripts, `make`) follows the link. The local
HTTPS certificates in `presence_floci/certs/` stay here: `local-certs.sh`
generates them per machine from its own mkcert CA.

## Known limitations

- The GraalVM package is the glibc/macOS build, not the musl one, so
  `native-image --static --libc=musl` isn't available. `devbox install` and
  `devbox shell` work on Apple Silicon Macs as well as Linux.
- The Nix Flutter package has no `x86_64-darwin` (Intel Mac) build.
