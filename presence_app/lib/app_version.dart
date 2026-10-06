/// The build's version, X.Y.Z, compiled in by the build scripts
/// (scripts/make.sh, and the dev servers' scripts/flutter-web.sh and
/// flutter-run.sh). Empty for a bare `flutter run` or a test.
abstract final class AppVersion {
  static const String version = String.fromEnvironment('PRESENCE_VERSION');

  /// The site the build is deployed to, from scripts/deploy.sh: `rc` for
  /// rc.presence.nu01.com, `prod`, or empty (any other build).
  static const String stage = String.fromEnvironment('PRESENCE_STAGE');

  /// The app's title (the browser tab's): marked on the RC site, so its
  /// tabs never pass for production's.
  static const String title = stage == 'rc' ? '🧪 Presence RC' : 'Presence';
}
