import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'saved_session.dart';

/// A Presence session as the auth API hands it out: the session token (a
/// one-hour JWT, the bearer for Presence's APIs and rbacr), when it
/// expires, and a refresh token for the next one.
class SessionGrant {
  const SessionGrant({
    required this.token,
    required this.expiresAt,
    required this.refreshToken,
  });

  final String token;
  final DateTime expiresAt;
  final String refreshToken;

  @override
  String toString() => 'SessionGrant(expiresAt: $expiresAt)';
}

/// The auth API said no, for good (400, 401, 403): asking again won't
/// help. For a refresh, the session is over (unknown, expired, revoked or
/// reused refresh token).
class SessionRefused implements Exception {
  const SessionRefused(this.status, [this.reason]);

  final int status;

  /// The API's `error`, for the log.
  final String? reason;

  @override
  String toString() =>
      'Presence refused the session (HTTP $status${reason == null ? '' : ': $reason'})';
}

/// The auth API couldn't answer this time (offline, a timeout, 429, 5xx,
/// a malformed reply): worth trying again.
class SessionUnavailable implements Exception {
  const SessionUnavailable({this.status, this.reason});

  /// The HTTP status, or null when there was no answer.
  final int? status;
  final String? reason;

  @override
  String toString() =>
      'Presence sign-in is unavailable'
      '${status == null ? '' : ' (HTTP $status)'}'
      '${reason == null ? '' : ': $reason'}';
}

/// The auth API's session routes: a provider's ID token (Google or Apple)
/// for a Presence session, its refresh, and its revocation. Exchange and
/// refresh throw [SessionRefused] or [SessionUnavailable].
abstract class SessionApi {
  /// `POST /api/auth/session`. For Apple, [nonce] is the raw nonce whose
  /// SHA-256 went to Apple; [authorizationCode] and [name] (only given at
  /// the first sign-in) when Apple gave them.
  Future<SessionGrant> exchange({
    required SessionProvider provider,
    required String idToken,
    String? nonce,
    String? authorizationCode,
    String? name,
  });

  /// `POST /api/auth/session/refresh`: a new session, with a new refresh
  /// token; [refreshToken] is used up.
  Future<SessionGrant> refresh(String refreshToken);

  /// `POST /api/auth/session/revoke`: ends the session. Never throws.
  Future<void> revoke(String refreshToken);
}

/// [SessionApi] over HTTP, at [base] (`ApiConfig.baseUrl`).
class HttpSessionApi implements SessionApi {
  HttpSessionApi(
    this.base, {
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  final Uri base;
  final Duration timeout;
  final http.Client _client;

  Future<http.Response> _post(String path, Map<String, Object?> body) async {
    try {
      return await _client
          .post(
            base.resolve(path),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const SessionUnavailable(reason: 'timed out');
    } catch (e) {
      // Offline, DNS, TLS: no answer. The type only: messages may quote the
      // request.
      throw SessionUnavailable(reason: '${e.runtimeType}');
    }
  }

  Future<SessionGrant> _grant(String path, Map<String, Object?> body) async {
    final response = await _post(path, body);
    final status = response.statusCode;
    if (status == 200) {
      final grant = parseGrant(response.body);
      if (grant == null) {
        throw const SessionUnavailable(status: 200, reason: 'malformed reply');
      }
      return grant;
    }
    final reason = errorOf(response.body);
    if (status == 400 || status == 401 || status == 403) {
      throw SessionRefused(status, reason);
    }
    throw SessionUnavailable(status: status, reason: reason);
  }

  @override
  Future<SessionGrant> exchange({
    required SessionProvider provider,
    required String idToken,
    String? nonce,
    String? authorizationCode,
    String? name,
  }) => _grant('/api/auth/session', {
    'provider': provider.name,
    'idToken': idToken,
    'nonce': ?nonce,
    'authorizationCode': ?authorizationCode,
    if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
  });

  @override
  Future<SessionGrant> refresh(String refreshToken) =>
      _grant('/api/auth/session/refresh', {'refreshToken': refreshToken});

  @override
  Future<void> revoke(String refreshToken) async {
    try {
      await _post('/api/auth/session/revoke', {'refreshToken': refreshToken});
    } catch (_) {
      // Best effort: the session expires on its own.
    }
  }

  /// The grant in a 200's [body], or null if it's incomplete.
  static SessionGrant? parseGrant(String body) {
    try {
      final m = (jsonDecode(body) as Map).cast<String, Object?>();
      final token = m['token'];
      final expiresAt = m['expiresAt'];
      final refreshToken = m['refreshToken'];
      if (token is! String ||
          token.isEmpty ||
          expiresAt is! num ||
          refreshToken is! String ||
          refreshToken.isEmpty) {
        return null;
      }
      return SessionGrant(
        token: token,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          (expiresAt * 1000).round(),
          isUtc: true,
        ),
        refreshToken: refreshToken,
      );
    } catch (_) {
      return null;
    }
  }

  /// The `error` of an error reply, shortened, or null.
  static String? errorOf(String body) {
    try {
      final error = (jsonDecode(body) as Map)['error'];
      if (error is! String || error.isEmpty) return null;
      return error.length > 200 ? '${error.substring(0, 200)}…' : error;
    } catch (_) {
      return null;
    }
  }
}

/// Runs [attempt], trying again after each of [delays] while it fails with
/// [SessionUnavailable]; [SessionRefused] and the last failure go to the
/// caller.
Future<T> withSessionRetries<T>(
  Future<T> Function() attempt, {
  required List<Duration> delays,
}) async {
  for (var i = 0; ; i++) {
    try {
      return await attempt();
    } on SessionUnavailable {
      if (i >= delays.length) rethrow;
      await Future<void>.delayed(delays[i]);
    }
  }
}
