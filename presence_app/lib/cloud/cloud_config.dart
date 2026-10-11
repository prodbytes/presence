/// Where signed-in users' data is synced: the Cognito identity pool and
/// the S3 bucket from `presence_infra/` (stacks `presence-identity` and
/// `presence-user-data`).
///
/// Public identifiers, not secrets, set at build time like the Google
/// client IDs (`.env` locally, `scripts/deploy.sh` for production). Empty
/// means cloud sync is off.
abstract final class CloudConfig {
  static const String region = String.fromEnvironment(
    'AWS_REGION',
    defaultValue: 'us-east-1',
  );

  /// Whether there's a pool at all: the app doesn't call it by ID, since the
  /// auth API hands it the profile's identity (`POST /api/auth/credentials`).
  static const String identityPoolId = String.fromEnvironment(
    'COGNITO_IDENTITY_POOL_ID',
  );

  static const String userDataBucket = String.fromEnvironment(
    'USER_DATA_BUCKET',
  );

  /// The Feedback and Help table (`FeedbackTable` of presence-user-data),
  /// which the app reads and writes with the profile's credentials. Empty:
  /// Feedback and Help is off.
  static const String feedbackTable = String.fromEnvironment('FEEDBACK_TABLE');

  static bool get enabled =>
      identityPoolId.isNotEmpty && userDataBucket.isNotEmpty;

  /// The account's AWS IoT Core data endpoint (`aws iot describe-endpoint
  /// --endpoint-type iot:Data-ATS`, set by `scripts/deploy.sh`), for live
  /// sync. Public, like the rest. Empty means live sync is off: events
  /// still reach the profile's other devices through the bucket.
  static const String iotEndpoint = String.fromEnvironment('IOT_ENDPOINT');

  /// Another AWS than Amazon's for S3 (`AWS_ENDPOINT`): the local stack's
  /// Floci, `https://localhost:8443`, set by `scripts/flutter-web.sh`
  /// (`PRESENCE_LOCAL_CLOUD`, see `scripts/dart-defines.sh`). Empty: AWS. Only
  /// HTTPS, or HTTP to this machine, is taken.
  static Uri? get awsEndpoint {
    const value = String.fromEnvironment('AWS_ENDPOINT');
    final url = Uri.tryParse(value.trim());
    if (url == null || url.host.isEmpty) return null;
    final local = url.host == 'localhost' || url.host == '127.0.0.1';
    return url.scheme == 'https' || (url.scheme == 'http' && local)
        ? url
        : null;
  }

  /// The stage in live sync's topics (`presence/<stage>/...`): `rc` for
  /// the release candidate's build, `prod` for every other build (local
  /// builds sync with production's bucket and pool).
  static const String liveStage =
      String.fromEnvironment('PRESENCE_STAGE') == 'rc' ? 'rc' : 'prod';
}
