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

/// A voucher code that grants [role] to whoever redeems it, as the Admin
/// screen lists it.
class Voucher {
  const Voucher({
    required this.code,
    required this.role,
    required this.expiresAt,
    required this.maxUses,
    required this.uses,
    this.redeemedBy = const [],
    this.createdBy = '',
    required this.createdAt,
  });

  factory Voucher.fromJson(Map<String, Object?> json) => Voucher(
    code: '${json['code'] ?? ''}',
    role: '${json['role'] ?? ''}',
    expiresAt: _instant(json['expiresAt']),
    maxUses: (json['maxUses'] as num?)?.toInt() ?? 0,
    uses: (json['uses'] as num?)?.toInt() ?? 0,
    redeemedBy: [
      if (json['redeemedBy'] case final List list) ...list.map((e) => '$e'),
    ],
    createdBy: '${json['createdBy'] ?? ''}',
    createdAt: _instant(json['createdAt']),
  );

  /// `XXXX-XXXX-XXXX`.
  final String code;

  /// [userRole] or [adminRole] (which also grants [userRole]).
  final String role;
  final DateTime expiresAt;
  final int maxUses;
  final int uses;

  /// The emails that redeemed it.
  final List<String> redeemedBy;
  final String createdBy;
  final DateTime createdAt;

  bool isExpired(DateTime now) => !expiresAt.isAfter(now);
  bool get isUsedUp => uses >= maxUses;
}

DateTime _instant(Object? value) =>
    DateTime.tryParse('$value') ??
    DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

/// The auth API's membership routes: users without access ask for it
/// (`POST /api/auth/membership`) or redeem a voucher code
/// (`POST /api/auth/voucher`); admins list, grant and dismiss those
/// requests, and create, list and delete vouchers. Failures throw
/// [RolesException] with the HTTP status (409: a request was already sent
/// this hour; 404 from [redeem]: the code is invalid, expired or used up;
/// 429: throttled).
abstract class MembershipClient {
  /// Sends [message] as the signed-in user's request for access.
  Future<void> request(String idToken, String message);

  /// The pending requests, oldest first (admins only).
  Future<List<MembershipRequest>> list(String idToken);

  /// Gives [email] the `presence_user` role and drops its request.
  Future<void> grant(String idToken, String email);

  /// Hides [email]'s request without granting anything.
  Future<void> dismiss(String idToken, String email);

  /// Redeems [code] for the signed-in user; returns the voucher's role.
  Future<String> redeem(String idToken, String code);

  /// Every voucher, newest first (admins only).
  Future<List<Voucher>> vouchers(String idToken);

  /// Creates a voucher with a random code (admins only).
  Future<Voucher> createVoucher(
    String idToken, {
    required String role,
    required DateTime expiresAt,
    required int maxUses,
  });

  /// Deletes the voucher [code] (admins only).
  Future<void> deleteVoucher(String idToken, String code);
}

/// The real client, next to `GET /api/auth` (see [HttpRolesClient]).
class HttpMembershipClient implements MembershipClient {
  HttpMembershipClient(this.base, {http.Client? client})
    : _client = client ?? http.Client();

  final Uri base;
  final http.Client _client;

  Future<http.Response> _post(
    String path,
    String idToken,
    String body, {
    String contentType = 'text/plain; charset=utf-8',
  }) async {
    final response = await _client.post(
      base.resolve(path),
      headers: {
        'authorization': 'Bearer $idToken',
        'content-type': contentType,
      },
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

  Future<List<Map<String, Object?>>> _getList(
    String path,
    String idToken,
    String field,
  ) async {
    final response = await _client.get(
      base.resolve(path),
      headers: {'authorization': 'Bearer $idToken'},
    );
    if (response.statusCode != 200) throw RolesException(response.statusCode);
    final body = (jsonDecode(response.body) as Map).cast<String, Object?>();
    return [
      if (body[field] case final List items)
        for (final item in items.whereType<Map>()) item.cast<String, Object?>(),
    ];
  }

  @override
  Future<List<MembershipRequest>> list(String idToken) async => [
    for (final r in await _getList('/api/auth/membership', idToken, 'requests'))
      MembershipRequest.fromJson(r),
  ];

  @override
  Future<void> grant(String idToken, String email) =>
      _post('/api/auth/membership/grant', idToken, email);

  @override
  Future<void> dismiss(String idToken, String email) =>
      _post('/api/auth/membership/dismiss', idToken, email);

  @override
  Future<String> redeem(String idToken, String code) async {
    final response = await _post('/api/auth/voucher', idToken, code);
    final body = (jsonDecode(response.body) as Map).cast<String, Object?>();
    return '${body['role'] ?? ''}';
  }

  @override
  Future<List<Voucher>> vouchers(String idToken) async => [
    for (final v in await _getList('/api/auth/vouchers', idToken, 'vouchers'))
      Voucher.fromJson(v),
  ];

  @override
  Future<Voucher> createVoucher(
    String idToken, {
    required String role,
    required DateTime expiresAt,
    required int maxUses,
  }) async {
    final response = await _post(
      '/api/auth/vouchers',
      idToken,
      Uri(
        queryParameters: {
          'role': role,
          'expiresAt': expiresAt.toUtc().toIso8601String(),
          'maxUses': '$maxUses',
        },
      ).query,
      contentType: 'application/x-www-form-urlencoded',
    );
    return Voucher.fromJson(
      (jsonDecode(response.body) as Map).cast<String, Object?>(),
    );
  }

  @override
  Future<void> deleteVoucher(String idToken, String code) =>
      _post('/api/auth/vouchers/delete', idToken, code);
}
