import 'dart:convert';

import 'package:http/http.dart' as http;

import 'roles_service.dart';

/// Where rbacr (github.com/prodbytes/rbacr), which keeps every role, lives
/// for this build, and the rbacr system Presence's roles are in.
///
/// Set at build time (`scripts/dart-defines.sh`): `RBACR_URL` is the same
/// rbacr the stage's auth API uses (`scripts/deploy.sh`); local web builds
/// use rbacr's RC (`.env`'s `RBACR_RC_URL`), like the local auth API, and
/// phone builds GA rbacr, like the production auth API they call. Unset:
/// GA rbacr, as `ApiConfig` defaults to production.
abstract final class RbacrConfig {
  static const String _url = String.fromEnvironment('RBACR_URL');
  static const String _system = String.fromEnvironment('RBACR_SYSTEM');

  /// rbacr's origin. Only HTTPS (or plain HTTP to localhost) is taken, as
  /// the user's Google ID token goes there.
  static Uri get baseUrl {
    final url = Uri.tryParse(_url.trim());
    return url != null && isSafe(url) ? url : Uri.parse(gaUrl);
  }

  /// GA rbacr.
  static const gaUrl = 'https://rbacr.nu01.com';

  /// The rbacr system of Presence's roles (`RBACR_SYSTEM`, default
  /// `presence`).
  static String get system => _system.trim().isEmpty ? 'presence' : _system;

  /// Whether the ID token may go to [url]: HTTPS, or HTTP to this machine.
  static bool isSafe(Uri url) =>
      url.host.isNotEmpty &&
      (url.scheme == 'https' ||
          (url.scheme == 'http' &&
              (url.host == 'localhost' || url.host == '127.0.0.1')));
}

/// rbacr's answer to `GET /api/me` about the signed-in user: whether they
/// are an rbacr [root], and their [roles] in each system.
typedef RbacrMe = ({String email, bool root, Map<String, List<String>> roles});

/// The app's roles for what rbacr gives the user in [system] (as the auth
/// API maps them, `presence.auth.Roles`): [userRole] for free, premium or
/// admin; [premiumRole] for premium or admin; [adminRole] for admin; and
/// every role, [rootRole] included, for an rbacr root. Sorted.
List<String> presenceRoles(RbacrMe me, String system) {
  final held = me.roles[system] ?? const [];
  final roles = <String>{
    if (me.root) ...[userRole, premiumRole, adminRole, rootRole],
    if (held.any(const {'free', 'premium', 'admin'}.contains)) userRole,
    if (held.any(const {'premium', 'admin'}.contains)) premiumRole,
    if (held.contains('admin')) adminRole,
  };
  return roles.toList()..sort();
}

/// A voucher rbacr would honor only with a payment, which isn't built yet
/// (HTTP 402): it gives [discount] percent off, when rbacr says.
class PaymentRequiredException extends RolesException {
  PaymentRequiredException(this.discount) : super(402, 'rbacr');

  /// The voucher's discount, in percent; null if rbacr didn't say.
  final int? discount;
}

/// rbacr's self-service routes, asked as the signed-in user with their
/// Google ID token (`Authorization: Bearer`; rbacr checks its audience is
/// one of Presence's Google clients). Failures throw [RolesException] with
/// the HTTP status.
abstract class RbacrClient {
  /// `GET /api/me`: the user's own roles. A system in maintenance lists no
  /// roles.
  Future<RbacrMe> me(String idToken);

  /// `GET /api/systems/<system>/status`: whether Presence's system is in
  /// maintenance.
  Future<bool> maintenance(String idToken);

  /// `POST /api/vouchers/redeem`: grants the voucher [code]'s roles to the
  /// user. 404: unknown code; 409: inactive (not started, expired, used
  /// up, disabled) or already redeemed by this user; 402
  /// ([PaymentRequiredException]): its discount is under 100%.
  Future<void> redeem(String idToken, String code);
}

/// The real client, over HTTPS to [base] (`RbacrConfig.baseUrl`).
class HttpRbacrClient implements RbacrClient {
  HttpRbacrClient(
    this.base, {
    String? system,
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
  }) : system = system ?? RbacrConfig.system,
       _client = client ?? http.Client() {
    if (!RbacrConfig.isSafe(base)) {
      throw ArgumentError.value(base, 'base', 'must be an https URL');
    }
  }

  final Uri base;
  final String system;
  final Duration timeout;
  final http.Client _client;

  Map<String, String> _headers(String idToken) => {
    'authorization': 'Bearer $idToken',
  };

  Future<Map<String, Object?>> _get(String path, String idToken) async {
    final response = await _client
        .get(base.resolve(path), headers: _headers(idToken))
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw RolesException(response.statusCode, 'rbacr');
    }
    return (jsonDecode(response.body) as Map).cast<String, Object?>();
  }

  @override
  Future<RbacrMe> me(String idToken) async {
    final body = await _get('/api/me', idToken);
    final roles = body['roles'];
    return (
      email: '${body['email'] ?? ''}',
      root: body['root'] == true,
      roles: <String, List<String>>{
        if (roles is Map)
          for (final MapEntry(:key, :value) in roles.entries)
            if (value is List) '$key': [for (final r in value) '$r'],
      },
    );
  }

  @override
  Future<bool> maintenance(String idToken) async {
    final body = await _get(
      '/api/systems/${Uri.encodeComponent(system)}/status',
      idToken,
    );
    return body['maintenance'] == true;
  }

  @override
  Future<void> redeem(String idToken, String code) async {
    final response = await _client
        .post(
          base.resolve('/api/vouchers/redeem'),
          headers: {..._headers(idToken), 'content-type': 'application/json'},
          body: jsonEncode({'code': code.trim()}),
        )
        .timeout(timeout);
    if (response.statusCode == 402) {
      int? discount;
      try {
        final body = jsonDecode(response.body);
        final percent = body is Map && body['payment'] is Map
            ? (body['payment'] as Map)['discountPercent']
            : null;
        if (percent is num) discount = percent.toInt();
      } on FormatException {
        // No body to read the discount from.
      }
      throw PaymentRequiredException(discount);
    }
    if (response.statusCode ~/ 100 != 2) {
      throw RolesException(response.statusCode, 'rbacr');
    }
  }
}
