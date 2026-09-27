/// The build's version, X.Y.Z, compiled in by the build scripts
/// (scripts/make.sh, and the dev servers' scripts/flutter-web.sh and
/// flutter-run.sh). Empty for a bare `flutter run` or a test.
abstract final class AppVersion {
  static const String version = String.fromEnvironment('PRESENCE_VERSION');
}
