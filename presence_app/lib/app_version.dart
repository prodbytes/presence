/// The build's version, compiled in by the build scripts: the release tag
/// (X.Y.Z-RC or X.Y.Z-GA) for tagged builds, X.Y.Z for other `make` builds,
/// and X.Y-dev for dev servers (scripts/flutter-web.sh, flutter-run.sh).
/// Only a plain `flutter run` or test has none.
abstract final class AppVersion {
  static const String _tag = String.fromEnvironment('PRESENCE_TAG');
  static const String _version = String.fromEnvironment('PRESENCE_VERSION');

  /// What the Settings screen shows, e.g. "0.3.202609271300-GA" or "0.3-dev".
  static String get label => _tag.isNotEmpty
      ? _tag
      : _version.isNotEmpty
      ? _version
      : 'development build';
}
