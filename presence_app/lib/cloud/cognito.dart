import 'dart:convert';

import 'package:http/http.dart' as http;

import 'device_slots.dart';
import 'sigv4.dart';

/// A Cognito identity (its ID is the user's prefix in the bucket) with its
/// temporary AWS credentials.
class CognitoSession {
  const CognitoSession({
    required this.identityId,
    required this.credentials,
    this.deviceSlots,
  });

  final String identityId;
  final AwsCredentials credentials;

  /// The profile's devices, as the auth API listed them with the
  /// credentials; null when it didn't.
  final DeviceSlots? deviceSlots;
}

/// Why Cognito, or the auth API on its behalf, refused (for example, an
/// expired Google ID token).
class CognitoException implements Exception {
  CognitoException(this.type, this.message, {this.detail});

  final String type;
  final String message;

  /// What else the answer said, for the log: the auth API's `cause` (the
  /// AWS service and error code that failed) and `requestId` (which finds
  /// the full error in its log), or the start of a body that isn't JSON.
  final String? detail;

  /// The Google token was rejected: signing in again gets a fresh one.
  bool get needsSignIn => type.endsWith('NotAuthorizedException');

  @override
  String toString() =>
      'Cognito $type: $message${detail == null ? '' : ' ($detail)'}';
}

/// Temporary AWS credentials for the signed-in user's profile: the auth API
/// (`POST /api/auth/credentials`, with the Google ID token) answers with the
/// profile's Cognito identity and a developer-identity token for it, which
/// `GetCredentialsForIdentity` (unsigned: the token is the proof) trades for
/// credentials. Every Google account linked to the profile gets the same
/// identity, so the same folder. With [deviceId], the request names this
/// device, which joins the profile's [DeviceSlots].
class CognitoCredentials {
  CognitoCredentials({
    required this.region,
    required this.api,
    this.deviceId,
    http.Client? client,
    DateTime Function()? now,
  }) : _client = client ?? http.Client(),
       // AWS's time as best known: credentials expire by its clock.
       _now = now ?? AwsClock.shared.now;

  /// The `Logins` key for tokens Cognito issued itself (developer identities).
  static const String cognitoProvider = 'cognito-identity.amazonaws.com';

  final String region;

  /// The site the auth API is under (`ApiConfig.baseUrl`).
  final Uri api;

  /// This device's ID, sent with each request for credentials.
  final Future<String?> Function()? deviceId;
  final http.Client _client;
  final DateTime Function() _now;

  CognitoSession? _session;
  String? _sessionToken;

  /// The fetch of a session under way, and the token it's for: callers
  /// asking meanwhile share it (one auth API and Cognito call, not one
  /// each).
  Future<CognitoSession>? _inFlight;
  String? _inFlightToken;

  /// Bumped by [clear]: a fetch that started before isn't kept.
  int _epoch = 0;

  /// A session for [idToken], reused until its credentials expire soon or
  /// the token changes. Calls made while one is being fetched for the same
  /// token share it.
  Future<CognitoSession> session(String idToken) {
    final current = _session;
    if (current != null &&
        _sessionToken == idToken &&
        !current.credentials.expiresSoon(_now())) {
      return Future.value(current);
    }
    if (_inFlight case final fetching? when _inFlightToken == idToken) {
      return fetching;
    }
    final epoch = _epoch;
    final fetch = _fetch(idToken).then((session) {
      // Not after a clear() (a sign-out, or rejected credentials).
      if (epoch == _epoch) {
        _session = session;
        _sessionToken = idToken;
      }
      return session;
    });
    _inFlight = fetch;
    _inFlightToken = idToken;
    fetch.whenComplete(() {
      if (identical(_inFlight, fetch)) {
        _inFlight = null;
        _inFlightToken = null;
      }
    }).ignore();
    return fetch;
  }

  Future<CognitoSession> _fetch(String idToken) async {
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
      deviceSlots: profile.deviceSlots,
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
    return session;
  }

  /// The profile's identity and a token for it, from the auth API, with
  /// its devices. A rejected Google token (401) needs a new sign-in, as
  /// Cognito's own `NotAuthorizedException` would.
  Future<({String identityId, String token, DeviceSlots? deviceSlots})>
  _profileToken(String idToken) async {
    String? device;
    try {
      device = await deviceId?.call();
    } catch (_) {
      // Credentials all the same, without a place among the devices.
    }
    final response = await _client.post(
      api.resolve('/api/auth/credentials'),
      headers: {
        'authorization': 'Bearer $idToken',
        if (device != null) 'content-type': 'text/plain; charset=utf-8',
      },
      body: device,
    );
    final body = _json(response.body);
    if (response.statusCode != 200) {
      final detail = [
        if (body['cause'] case final String cause) 'cause: $cause',
        if (body['requestId'] case final String id) 'request $id',
        if (body.isEmpty && response.body.isNotEmpty)
          'body: ${_head(response.body)}',
      ];
      throw CognitoException(
        response.statusCode == 401
            ? 'NotAuthorizedException'
            : 'HTTP ${response.statusCode} from /api/auth/credentials',
        '${body['error'] ?? 'the auth API refused credentials'}',
        detail: detail.isEmpty ? null : detail.join('; '),
      );
    }
    return (
      identityId: body['identityId']! as String,
      token: body['token']! as String,
      deviceSlots: DeviceSlots.fromJson(body),
    );
  }

  /// Takes [device] out of the profile's devices
  /// (`POST /api/auth/profile/devices/remove`); the slots after, or null
  /// when the auth API refused or didn't say.
  Future<DeviceSlots?> removeDevice(String idToken, String device) async {
    final response = await _client.post(
      api.resolve('/api/auth/profile/devices/remove'),
      headers: {
        'authorization': 'Bearer $idToken',
        'content-type': 'text/plain; charset=utf-8',
      },
      body: device,
    );
    if (response.statusCode != 200) return null;
    return DeviceSlots.fromJson(_json(response.body));
  }

  static Map<String, Object?> _json(String text) {
    try {
      return (jsonDecode(text) as Map).cast<String, Object?>();
    } catch (_) {
      return const {};
    }
  }

  /// Forgets the session (on sign-out).
  void clear() {
    _epoch++;
    _session = null;
    _sessionToken = null;
    _inFlight = null;
    _inFlightToken = null;
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

/// The start of a response [body], for the log.
String _head(String body) =>
    body.length > 300 ? '${body.substring(0, 300)}…' : body;
