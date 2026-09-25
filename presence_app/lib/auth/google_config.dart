/// Google OAuth client IDs, from the `presence-492410` Google Cloud project.
///
/// These are public identifiers, not secrets: they name the app to Google.
/// Each can also be set at build time, e.g.
/// `flutter run --dart-define=GOOGLE_WEB_CLIENT_ID=…`.
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
