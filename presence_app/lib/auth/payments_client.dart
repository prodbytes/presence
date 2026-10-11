import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';
import 'premium_checkout.dart';
import 'roles_service.dart';

/// The Premium plans' Stripe Payment Links, as the payments API
/// (presence_api_payments) answers them: each an HTTPS link on stripe.com,
/// or empty when that plan isn't offered.
@immutable
class PaymentLinks {
  const PaymentLinks({
    this.monthly = '',
    this.yearly = '',
    this.saved = false,
    this.updatedAt,
  });

  factory PaymentLinks.fromJson(Map<String, Object?> json) => PaymentLinks(
    monthly: _link(json['monthly']),
    yearly: _link(json['yearly']),
    saved: json['saved'] == true,
    updatedAt: switch (json['updatedAt']) {
      final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
      _ => null,
    },
  );

  /// A link the app may open: a Stripe HTTPS link, else empty.
  static String _link(Object? value) {
    final link = value is String ? value.trim() : '';
    final url = Uri.tryParse(link);
    return url != null && PremiumCheckout.isStripe(url) ? link : '';
  }

  final String monthly;
  final String yearly;

  /// Whether an admin saved them (else they're the deploy's defaults).
  final bool saved;

  /// When an admin saved them.
  final DateTime? updatedAt;

  /// Whether no plan is offered.
  bool get isEmpty => monthly.isEmpty && yearly.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is PaymentLinks &&
      other.monthly == monthly &&
      other.yearly == yearly &&
      other.saved == saved &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(monthly, yearly, saved, updatedAt);
}

/// The payments API's routes, with the user's Google ID token. Failures
/// throw [RolesException] with the HTTP status (403: not an admin; 400:
/// links that aren't Stripe's).
abstract class PaymentsClient {
  /// The plans' links (`GET /api/payments/links`).
  Future<PaymentLinks> links(String idToken);

  /// Saves the links, for admins (`PUT /api/payments/links`); what's saved.
  Future<PaymentLinks> save(
    String idToken, {
    required String monthly,
    required String yearly,
  });
}

/// The real client, under the site's `/api/payments/` (see [ApiConfig]).
class HttpPaymentsClient implements PaymentsClient {
  HttpPaymentsClient(this.base, {http.Client? client})
    : _client = client ?? http.Client();

  final Uri base;
  final http.Client _client;

  Future<PaymentLinks> _read(http.Response response) async {
    if (response.statusCode ~/ 100 != 2) {
      throw RolesException(response.statusCode, 'Payments API');
    }
    return PaymentLinks.fromJson(
      (jsonDecode(response.body) as Map).cast<String, Object?>(),
    );
  }

  @override
  Future<PaymentLinks> links(String idToken) async => _read(
    await _client.get(
      base.resolve('/api/payments/links'),
      headers: {'authorization': 'Bearer $idToken'},
    ),
  );

  @override
  Future<PaymentLinks> save(
    String idToken, {
    required String monthly,
    required String yearly,
  }) async => _read(
    await _client.put(
      base.resolve('/api/payments/links'),
      headers: {
        'authorization': 'Bearer $idToken',
        'content-type': 'application/json',
      },
      body: jsonEncode({'monthly': monthly.trim(), 'yearly': yearly.trim()}),
    ),
  );
}

/// The links for the signed-in user, loaded at each sign-in (and by
/// [load]); null while unknown: signed out, loading, or when the API
/// didn't answer (the app then offers nu01.com, as before payments).
class PaymentsService extends ChangeNotifier {
  PaymentsService({required this.auth, required this.client}) {
    auth.addListener(_onAuth);
    _onAuth();
  }

  final AuthService auth;
  final PaymentsClient client;

  PaymentLinks? get links => _links;
  PaymentLinks? _links;
  String? _for;

  void _onAuth() {
    final email = auth.user?.email;
    if (email == _for) return;
    _for = email;
    _links = null;
    notifyListeners();
    if (email != null) load();
  }

  /// Asks the API again.
  Future<void> load() async {
    final token = auth.idToken;
    final email = _for;
    if (token == null || email == null) return;
    try {
      final links = await client.links(token);
      if (_for != email || _disposed) return;
      _links = links;
      notifyListeners();
    } catch (e) {
      debugPrint('Presence: no payment links: $e');
    }
  }

  /// Saves the links (admins), and shows them from now on.
  Future<PaymentLinks> save({
    required String monthly,
    required String yearly,
  }) async {
    final token = auth.idToken;
    if (token == null) throw RolesException(401, 'Payments API');
    final links = await client.save(token, monthly: monthly, yearly: yearly);
    if (!_disposed) {
      _links = links;
      notifyListeners();
    }
    return links;
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    auth.removeListener(_onAuth);
    super.dispose();
  }
}
