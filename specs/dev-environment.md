# Development environment

- [devbox.json](../devbox.json) manages the toolchain: GraalVM CE
  (`graalvmPackages.graalvm-ce`, 25.2.4 / JDK 25; locked for aarch64-darwin,
  aarch64-linux and x86_64-linux),
  Python, Node.js, Go, PostgreSQL and Flutter.
- The dev container ([.devcontainer/](../.devcontainer)) installs devbox and
  includes the Dart and Flutter VS Code extensions. It forwards port 8080 for
  Flutter web.
- Flutter web runs on the `web-server` device, so the container doesn't need
  Chrome.
- `devbox services up` ([process-compose.yaml](../process-compose.yaml)) starts
  the Flutter web server (`2-flutter-web`, via
  [scripts/flutter-web.sh](../scripts/flutter-web.sh), with an HTTP readiness
  probe) and the health monitor, which logs the web app's status. No
  database runs as a service: the app keeps its data on the device
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

## Known limitations

- The GraalVM package is the glibc/macOS build, not the musl one, so
  `native-image --static --libc=musl` isn't available. `devbox install` and
  `devbox shell` work on Apple Silicon Macs as well as Linux.
- The Nix Flutter package has no `x86_64-darwin` (Intel Mac) build.
