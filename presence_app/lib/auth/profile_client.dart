import 'dart:convert';

import 'package:http/http.dart' as http;

import 'roles_service.dart';

/// One Google account of the signed-in user's profile.
class ProfileAccount {
  const ProfileAccount({
    required this.email,
    required this.owner,
    required this.current,
  });

  factory ProfileAccount.fromJson(Map<String, Object?> json) => ProfileAccount(
    email: '${json['email'] ?? ''}',
    owner: json['owner'] == true,
    current: json['current'] == true,
  );

  final String email;

  /// Made the profile: its roles are the profile's, and it can't be unlinked.
  final bool owner;

  /// The account signed in now.
  final bool current;
}

/// A one-time code that links another account to this profile.
class LinkCode {
  const LinkCode({required this.code, required this.expiresAt});

  /// As shown and typed: `ABCD-EFGH`.
  final String code;
  final DateTime expiresAt;
}

/// The auth API's profile routes: a profile is one person's cloud folder,
/// whichever of their Google accounts signs in. Failures throw
/// [RolesException] with the HTTP status (404: a wrong, used or expired
/// code; 409: the account can't be linked or unlinked; 429: throttled).
abstract class ProfileClient {
  /// The profile's accounts, the owner first.
  Future<List<ProfileAccount>> accounts(String idToken);

  /// A new code another account can use, for 10 minutes.
  Future<LinkCode> linkCode(String idToken);

  /// Moves the signed-in account into the profile of [code]; its accounts.
  Future<List<ProfileAccount>> link(String idToken, String code);

  /// Removes [email] from the profile; the accounts left.
  Future<List<ProfileAccount>> unlink(String idToken, String email);
}

/// The real client, next to `GET /api/auth` (see [HttpRolesClient]).
class HttpProfileClient implements ProfileClient {
  HttpProfileClient(this.base, {http.Client? client})
    : _client = client ?? http.Client();

  final Uri base;
  final http.Client _client;

  Future<Map<String, Object?>> _send(
    String method,
    String path,
    String idToken, [
    String body = '',
  ]) async {
    final request = http.Request(method, base.resolve(path))
      ..headers['authorization'] = 'Bearer $idToken';
    if (method == 'POST') {
      request.headers['content-type'] = 'text/plain; charset=utf-8';
      request.bodyBytes = utf8.encode(body);
    }
    final response = await http.Response.fromStream(
      await _client.send(request),
    );
    if (response.statusCode ~/ 100 != 2) {
      throw RolesException(response.statusCode);
    }
    return (jsonDecode(response.body) as Map).cast<String, Object?>();
  }

  static List<ProfileAccount> _accounts(Map<String, Object?> body) {
    final accounts = body['accounts'];
    return accounts is List
        ? [
            for (final a in accounts)
              if (a is Map) ProfileAccount.fromJson(a.cast<String, Object?>()),
          ]
        : const [];
  }

  @override
  Future<List<ProfileAccount>> accounts(String idToken) async =>
      _accounts(await _send('GET', '/api/auth/profile', idToken));

  @override
  Future<LinkCode> linkCode(String idToken) async {
    final body = await _send('POST', '/api/auth/profile/link-code', idToken);
    return LinkCode(
      code: '${body['code']}',
      expiresAt:
          DateTime.tryParse('${body['expiresAt']}') ??
          DateTime.now().add(const Duration(minutes: 10)),
    );
  }

  @override
  Future<List<ProfileAccount>> link(String idToken, String code) async =>
      _accounts(await _send('POST', '/api/auth/profile/link', idToken, code));

  @override
  Future<List<ProfileAccount>> unlink(String idToken, String email) async =>
      _accounts(
        await _send('POST', '/api/auth/profile/unlink', idToken, email),
      );
}
