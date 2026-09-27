import 'dart:convert';

import 'auth_service.dart';

/// A signed-in session as remembered across reloads: who, and their Google
/// ID token. Only restored while the token is still valid.
class SavedSession {
  const SavedSession({required this.user, required this.idToken});

  final AuthUser user;
  final String idToken;

  String encode() => jsonEncode({
    'id': user.id,
    'email': user.email,
    'name': user.name,
    'photoUrl': user.photoUrl,
    'idToken': idToken,
  });

  /// The session in [json], or null if it's missing, malformed, or its token
  /// expires within [margin] of [now].
  static SavedSession? decode(
    String? json, {
    required DateTime now,
    Duration margin = const Duration(minutes: 1),
  }) {
    if (json == null) return null;
    try {
      final m = (jsonDecode(json) as Map).cast<String, Object?>();
      final token = m['idToken'];
      final id = m['id'];
      final email = m['email'];
      if (token is! String || id is! String || email is! String) return null;
      final expiry = tokenExpiry(token);
      if (expiry == null || !now.add(margin).isBefore(expiry)) return null;
      return SavedSession(
        user: AuthUser(
          id: id,
          email: email,
          name: m['name'] as String?,
          photoUrl: m['photoUrl'] as String?,
        ),
        idToken: token,
      );
    } catch (_) {
      return null;
    }
  }

  /// When a JWT expires (its `exp` claim), or null if it can't be read. Only
  /// used to decide whether a saved session is still worth restoring: the
  /// auth API and Cognito verify the token itself.
  static DateTime? tokenExpiry(String jwt) {
    final parts = jwt.split('.');
    if (parts.length != 3) return null;
    try {
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final exp = (jsonDecode(payload) as Map)['exp'];
      return exp is num
          ? DateTime.fromMillisecondsSinceEpoch(
              (exp * 1000).round(),
              isUtc: true,
            )
          : null;
    } catch (_) {
      return null;
    }
  }
}
