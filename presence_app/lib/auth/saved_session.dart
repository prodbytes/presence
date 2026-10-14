import 'dart:convert';

import 'auth_service.dart';

/// Who issued the ID token a Presence session was made from.
enum SessionProvider {
  google,
  apple;

  /// As the auth API names it (`"google"`, `"apple"`).
  static SessionProvider? parse(Object? name) => switch (name) {
    'google' => google,
    'apple' => apple,
    _ => null,
  };
}

/// A Presence session, as kept between launches ([SessionStore]): the
/// provider it was made from, who, the Presence session token (a JWT, the
/// bearer for Presence's APIs and rbacr), when it expires, and the refresh
/// token that gets the next one. Never logged.
class SavedSession {
  const SavedSession({
    required this.provider,
    required this.user,
    required this.token,
    required this.expiresAt,
    required this.refreshToken,
  });

  final SessionProvider provider;
  final AuthUser user;
  final String token;
  final DateTime expiresAt;
  final String refreshToken;

  String encode() => jsonEncode({
    'provider': provider.name,
    'token': token,
    'expiresAt': expiresAt.millisecondsSinceEpoch ~/ 1000,
    'refreshToken': refreshToken,
    'user': {
      'id': user.id,
      'email': user.email,
      'name': user.name,
      'photoUrl': user.photoUrl,
    },
  });

  /// The session in [json], or null if it's missing or malformed (a
  /// session saved by an older version, which kept the Google ID token,
  /// is malformed: it's dropped). Expired sessions are returned: their
  /// refresh token may still work.
  static SavedSession? decode(String? json) {
    if (json == null) return null;
    try {
      final m = (jsonDecode(json) as Map).cast<String, Object?>();
      final provider = SessionProvider.parse(m['provider']);
      final token = m['token'];
      final expiresAt = m['expiresAt'];
      final refreshToken = m['refreshToken'];
      final u = m['user'];
      if (provider == null ||
          token is! String ||
          token.isEmpty ||
          expiresAt is! num ||
          refreshToken is! String ||
          refreshToken.isEmpty ||
          u is! Map) {
        return null;
      }
      final id = u['id'];
      final email = u['email'];
      if (id is! String || email is! String) return null;
      return SavedSession(
        provider: provider,
        user: AuthUser(
          id: id,
          email: email,
          name: u['name'] as String?,
          photoUrl: u['photoUrl'] as String?,
        ),
        token: token,
        expiresAt: _fromEpoch(expiresAt),
        refreshToken: refreshToken,
      );
    } catch (_) {
      return null;
    }
  }

  /// Whether the token has more than [margin] left at [now].
  bool validAt(DateTime now, {Duration margin = const Duration(minutes: 1)}) =>
      now.add(margin).isBefore(expiresAt);

  /// How long until the session should be refreshed: [lead] before it
  /// expires, or now if that's past.
  Duration refreshIn(
    DateTime now, {
    Duration lead = const Duration(minutes: 5),
  }) {
    final left = expiresAt.subtract(lead).difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// The signed-in user a Presence session token names: the provider's
  /// subject (`idp_sub`, as Google's `sub` was before), `email`, `name` and
  /// `picture`. Null when the claims are missing. The app doesn't verify
  /// the token (the servers do); it only reads who it's for.
  static AuthUser? userOf(String jwt) {
    final c = claims(jwt);
    if (c == null) return null;
    final id = c['idp_sub'];
    final email = c['email'];
    if (id is! String || id.isEmpty || email is! String || email.isEmpty) {
      return null;
    }
    final name = c['name'];
    final picture = c['picture'];
    return AuthUser(
      id: id,
      email: email,
      name: name is String && name.isNotEmpty ? name : null,
      photoUrl: picture is String && picture.isNotEmpty ? picture : null,
    );
  }

  /// When a JWT expires (its `exp` claim), or null if it can't be read.
  static DateTime? tokenExpiry(String jwt) {
    final exp = claims(jwt)?['exp'];
    return exp is num ? _fromEpoch(exp) : null;
  }

  /// A JWT's payload, unverified, or null if it can't be read.
  static Map<String, Object?>? claims(String jwt) {
    final parts = jwt.split('.');
    if (parts.length != 3) return null;
    try {
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      return (jsonDecode(payload) as Map).cast<String, Object?>();
    } catch (_) {
      return null;
    }
  }

  static DateTime _fromEpoch(num seconds) =>
      DateTime.fromMillisecondsSinceEpoch(
        (seconds * 1000).round(),
        isUtc: true,
      );
}
