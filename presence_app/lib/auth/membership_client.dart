import 'dart:convert';

import 'package:http/http.dart' as http;

import 'roles_service.dart';

/// A user's request for access, as the Admin screen lists it.
class MembershipRequest {
  const MembershipRequest({
    required this.email,
    required this.name,
    required this.message,
    required this.requestedAt,
  });

  factory MembershipRequest.fromJson(Map<String, Object?> json) =>
      MembershipRequest(
        email: '${json['email'] ?? ''}',
        name: '${json['name'] ?? ''}',
        message: '${json['message'] ?? ''}',
        requestedAt:
            DateTime.tryParse('${json['requestedAt']}') ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );

  final String email;
  final String name;
  final String message;
  final DateTime requestedAt;
}

/// The auth API's membership routes: users without access ask for it
/// (`POST /api/auth/membership`); admins list, grant and dismiss those
/// requests. Failures throw [RolesException] with the HTTP status (409: a
/// request was already sent this hour; 429: throttled).
abstract class MembershipClient {
  /// Sends [message] as the signed-in user's request for access.
  Future<void> request(String idToken, String message);

  /// The pending requests, oldest first (admins only).
  Future<List<MembershipRequest>> list(String idToken);

  /// Gives [email] the `presence_user` role and drops its request.
  Future<void> grant(String idToken, String email);

  /// Hides [email]'s request without granting anything.
  Future<void> dismiss(String idToken, String email);
}

/// The real client, next to `GET /api/auth` (see [HttpRolesClient]).
class HttpMembershipClient implements MembershipClient {
  HttpMembershipClient(this.base, {http.Client? client})
    : _client = client ?? http.Client();

  final Uri base;
  final http.Client _client;

  Map<String, String> _headers(String idToken) => {
    'authorization': 'Bearer $idToken',
    'content-type': 'text/plain; charset=utf-8',
  };

  Future<http.Response> _post(String path, String idToken, String body) async {
    final response = await _client.post(
      base.resolve(path),
      headers: _headers(idToken),
      body: utf8.encode(body),
    );
    if (response.statusCode ~/ 100 != 2) {
      throw RolesException(response.statusCode);
    }
    return response;
  }

  @override
  Future<void> request(String idToken, String message) =>
      _post('/api/auth/membership', idToken, message);

  @override
  Future<List<MembershipRequest>> list(String idToken) async {
    final response = await _client.get(
      base.resolve('/api/auth/membership'),
      headers: {'authorization': 'Bearer $idToken'},
    );
    if (response.statusCode != 200) throw RolesException(response.statusCode);
    final body = (jsonDecode(response.body) as Map).cast<String, Object?>();
    final requests = body['requests'];
    return [
      if (requests is List)
        for (final r in requests.whereType<Map>())
          MembershipRequest.fromJson(r.cast<String, Object?>()),
    ];
  }

  @override
  Future<void> grant(String idToken, String email) =>
      _post('/api/auth/membership/grant', idToken, email);

  @override
  Future<void> dismiss(String idToken, String email) =>
      _post('/api/auth/membership/dismiss', idToken, email);
}
