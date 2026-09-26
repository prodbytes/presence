# Development environment

- [devbox.json](../devbox.json) manages the toolchain: GraalVM CE
  (`graalvmPackages.graalvm-ce`, 25.2.4 / JDK 25; locked for aarch64-darwin,
  aarch64-linux and x86_64-linux),
  Python, Node.js, Go, PostgreSQL and Flutter.
- The dev container ([.devcontainer/](../.devcontainer)) installs devbox and
  includes the Dart and Flutter VS Code extensions. It forwards ports 8080
  (Flutter web) and 3000 (SAM API).
- Flutter web runs on the `web-server` device, so the container doesn't need
  Chrome.
- `devbox services up` ([process-compose.yaml](../process-compose.yaml)) starts:
  - the Flutter web server (`2-flutter-web`, via
    [scripts/flutter-web.sh](../scripts/flutter-web.sh)), with an HTTP
    readiness probe
  - the events API (`3-sam-api`, via
    [scripts/sam-api.sh](../scripts/sam-api.sh)): `sam build`, then
    `sam local start-api` on http://localhost:3000 (`SAM_API_PORT`), with a
    readiness probe on `GET /events`
  - the health monitor, which logs the status of the web app and the API.

  The API process stops with SIGINT, so SAM removes its warm Lambda
  containers. The script exits with a clear message if `sam`, `mvn` or
  `docker` is missing. It points SAM at the active Docker context's socket
  when `DOCKER_HOST` isn't set. No database runs as a service: the app keeps its data on the device
  (see [Storage](storage.md)). The `postgresql` devbox package stays in the
  toolchain (for `psql` and `pg_isready`).
- The app requires Dart SDK `^3.13.0`, which covers the Nix Flutter 3.47.0
  (Dart 3.13.0).
- **Google Cloud CLI:** Homebrew's `gcloud-cli` cask, logged in with
  `gcloud auth login` (a browser sign-in) as julio@nu01.com, with project
  `presence-492410` set as the default. It can manage the project, but
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
  (default), `profile` or `debug`. Plain `make` (`all`) builds every
  platform the host can build and skips the rest: iOS needs macOS and Linux
  needs a Linux host, and asking for either elsewhere fails. Verified: on
  the development Mac, web (with the web client ID compiled in and no
  secret), a release APK (`com.nu01.presence`, arm64/armv7/x86_64, signed
  with the debug key because no release key exists yet) and an arm64
  `Runner.app`; and `make linux` in a Linux arm64 container with Flutter
  3.47.5, which built the GTK bundle. The iOS build has no client ID until
  `GOOGLE_IOS_CLIENT_ID` is filled in `.env`.

- **AWS SAM:** building and deploying `presence_api_events` needs the SAM
  CLI, JDK 25 (from devbox's GraalVM), Maven 3.9+ and Docker. The SAM CLI
  and Maven aren't in devbox yet, so `3-sam-api` fails unless they're
  installed on the host.

- **AWS CDK:** `presence_infra_tenant` needs JDK 25, Maven 3.9+ and the CDK
  CLI (`npx aws-cdk`, 2.1143.0 at the time of writing). Maven isn't in
  devbox yet. jsii warns that Node 26 is untested (it supports 22 and 24);
  set `JSII_SILENCE_WARNING_UNTESTED_NODE_VERSION=1` to hide the warning.

## Known limitations

- The GraalVM package is the glibc/macOS build, not the musl one, so
  `native-image --static --libc=musl` isn't available. `devbox install` and
  `devbox shell` work on Apple Silicon Macs as well as Linux.
- The Nix Flutter package has no `x86_64-darwin` (Intel Mac) build.
