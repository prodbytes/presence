/// The build's version, compiled in by scripts/make.sh: the release tag
/// (X.Y.Z-RC or X.Y.Z-GA) for tagged builds, else X.Y.Z. Dev servers
/// (flutter run) have neither.
abstract final class AppVersion {
  static const String _tag = String.fromEnvironment('PRESENCE_TAG');
  static const String _version = String.fromEnvironment('PRESENCE_VERSION');

  /// What the Settings screen shows, e.g. "0.3.202609271300-GA".
  static String get label => _tag.isNotEmpty
      ? _tag
      : _version.isNotEmpty
      ? _version
      : 'development build';
}
