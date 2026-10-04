import 'dart:convert';

import 'package:http/http.dart' as http;

import 'sigv4.dart';

/// A Cognito identity (its ID is the user's prefix in the bucket) with its
/// temporary AWS credentials.
class CognitoSession {
  const CognitoSession({required this.identityId, required this.credentials});

  final String identityId;
  final AwsCredentials credentials;
}

/// Why Cognito, or the auth API on its behalf, refused (for example, an
/// expired Google ID token).
class CognitoException implements Exception {
  CognitoException(this.type, this.message);

  final String type;
  final String message;

  /// The Google token was rejected: signing in again gets a fresh one.
  bool get needsSignIn => type.endsWith('NotAuthorizedException');

  @override
  String toString() => 'Cognito $type: $message';
}

/// Temporary AWS credentials for the signed-in user's profile: the auth API
/// (`POST /api/auth/credentials`, with the Google ID token) answers with the
/// profile's Cognito identity and a developer-identity token for it, which
/// `GetCredentialsForIdentity` (unsigned: the token is the proof) trades for
/// credentials. Every Google account linked to the profile gets the same
/// identity, so the same folder.
class CognitoCredentials {
  CognitoCredentials({
    required this.region,
    required this.api,
    http.Client? client,
    DateTime Function()? now,
  }) : _client = client ?? http.Client(),
       _now = now ?? DateTime.now;

  /// The `Logins` key for tokens Cognito issued itself (developer identities).
  static const String cognitoProvider = 'cognito-identity.amazonaws.com';

  final String region;

  /// The site the auth API is under (`ApiConfig.baseUrl`).
  final Uri api;
  final http.Client _client;
  final DateTime Function() _now;

  CognitoSession? _session;
  String? _sessionToken;

  /// A session for [idToken], reused until its credentials expire soon or
  /// the token changes.
  Future<CognitoSession> session(String idToken) async {
    final current = _session;
    if (current != null &&
        _sessionToken == idToken &&
        !current.credentials.expiresSoon(_now())) {
      return current;
    }
    final profile = await _profileToken(idToken);
    final identityId = profile.identityId;
    final result = await _call('GetCredentialsForIdentity', {
      'IdentityId': identityId,
      'Logins': {cognitoProvider: profile.token},
    });
    final c = (result['Credentials'] as Map).cast<String, Object?>();
    final expiration = c['Expiration'];
    final session = CognitoSession(
      identityId: result['IdentityId'] as String? ?? identityId,
      credentials: AwsCredentials(
        accessKeyId: c['AccessKeyId']! as String,
        secretAccessKey: c['SecretKey']! as String,
        sessionToken: c['SessionToken'] as String?,
        expiration: expiration is num
            ? DateTime.fromMillisecondsSinceEpoch(
                (expiration * 1000).round(),
                isUtc: true,
              )
            : null,
      ),
    );
    _session = session;
    _sessionToken = idToken;
    return session;
  }

  /// The profile's identity and a token for it, from the auth API. A
  /// rejected Google token (401) needs a new sign-in, as Cognito's own
  /// `NotAuthorizedException` would.
  Future<({String identityId, String token})> _profileToken(
    String idToken,
  ) async {
    final response = await _client.post(
      api.resolve('/api/auth/credentials'),
      headers: {'authorization': 'Bearer $idToken'},
    );
    Map<String, Object?> body;
    try {
      body = (jsonDecode(response.body) as Map).cast<String, Object?>();
    } catch (_) {
      body = const {};
    }
    if (response.statusCode != 200) {
      throw CognitoException(
        response.statusCode == 401
            ? 'NotAuthorizedException'
            : 'HTTP ${response.statusCode}',
        '${body['error'] ?? 'the auth API refused credentials'}',
      );
    }
    return (
      identityId: body['identityId']! as String,
      token: body['token']! as String,
    );
  }

  /// Forgets the session (on sign-out).
  void clear() {
    _session = null;
    _sessionToken = null;
  }

  Future<Map<String, Object?>> _call(
    String action,
    Map<String, Object?> body,
  ) async {
    final response = await _client.post(
      Uri.https('cognito-identity.$region.amazonaws.com', '/'),
      headers: {
        'content-type': 'application/x-amz-json-1.1',
        'x-amz-target': 'AWSCognitoIdentityService.$action',
      },
      body: jsonEncode(body),
    );
    final decoded = response.body.isEmpty
        ? <String, Object?>{}
        : (jsonDecode(response.body) as Map).cast<String, Object?>();
    if (response.statusCode != 200) {
      throw CognitoException(
        (decoded['__type'] as String?) ?? 'HTTP ${response.statusCode}',
        (decoded['message'] ?? decoded['Message'] ?? response.body).toString(),
      );
    }
    return decoded;
  }
}
