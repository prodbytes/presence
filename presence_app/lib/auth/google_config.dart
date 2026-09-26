/// Google OAuth client IDs, from the project's Google Cloud project (named
/// in the private settings repo).
///
/// These are public identifiers, not secrets: they name the app to Google.
/// They're set at build time from the repo's `.env` (gitignored; see
/// `.env.example`): `scripts/flutter-web.sh` and `scripts/flutter-run.sh`
/// pass them as `--dart-define`s. Empty means sign-in isn't set up.
abstract final class GoogleConfig {
  /// The "Web application" client. Used on web, and on Android as the
  /// server client ID (Android's own client is matched by package name and
  /// signing-key fingerprint, so it has no ID in the app).
  static const String webClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
  );

  /// The "iOS" client (bundle ID `com.nu01.presence`).
  static const String iosClientId = String.fromEnvironment(
    'GOOGLE_IOS_CLIENT_ID',
  );
}
