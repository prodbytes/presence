import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';

/// Where the app stands for the signed-in user.
enum AccessState {
  /// Nobody is signed in.
  signedOut,

  /// Signed in; asking the auth API for the user's roles.
  checking,

  /// The user has at least one role: every feature is available.
  granted,

  /// Signed in without a role (or the check failed): only their account and
  /// the sign-up icon show.
  denied,
}

/// Asks the auth API (`GET /api/auth`) for a user's roles.
abstract class RolesClient {
  /// The roles for the user whose Google ID token is [idToken].
  Future<List<String>> fetch(String idToken);
}

/// Why the auth API didn't answer with roles.
class RolesException implements Exception {
  RolesException(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'Auth API HTTP $statusCode';
}

/// The real client: `GET <base>/api/auth` with `Authorization: Bearer`.
class HttpRolesClient implements RolesClient {
  HttpRolesClient(this.base, {http.Client? client})
    : _client = client ?? http.Client();

  /// The site the API is under: the page's own origin on web, or
  /// `ApiConfig.baseUrl` on Android and iOS.
  final Uri base;
  final http.Client _client;

  @override
  Future<List<String>> fetch(String idToken) async {
    final response = await _client.get(
      base.resolve('/api/auth'),
      headers: {'authorization': 'Bearer $idToken'},
    );
    if (response.statusCode != 200) throw RolesException(response.statusCode);
    final body = (jsonDecode(response.body) as Map).cast<String, Object?>();
    final roles = body['roles'];
    return roles is List ? [for (final r in roles) '$r'] : const [];
  }
}

/// The signed-in user's roles, fetched whenever the user changes. Having
/// any role grants access to the app's events and features; no role, or a
/// failed check, doesn't (deny by default).
class RolesService extends ChangeNotifier {
  RolesService({required this.auth, required this._client}) {
    auth.addListener(_onAuthChanged);
    _onAuthChanged();
  }

  final AuthService auth;
  final RolesClient _client;

  AccessState _state = AccessState.signedOut;
  List<String> _roles = const [];
  String? _error;
  String? _user;
  int _generation = 0;
  bool _disposed = false;

  AccessState get state => _state;
  List<String> get roles => _roles;

  /// Why the last check failed, if it did.
  String? get error => _error;

  bool get hasAccess => _state == AccessState.granted;

  /// Checks the roles again (e.g. after asking for access).
  Future<void> refresh() => _check();

  void _onAuthChanged() {
    final user = auth.user?.id;
    if (user == _user) return;
    _user = user;
    _check();
  }

  Future<void> _check() async {
    final generation = ++_generation;
    final token = auth.idToken;
    if (auth.user == null) {
      _set(AccessState.signedOut, const []);
      return;
    }
    if (token == null) {
      _set(AccessState.denied, const [], 'No ID token to check roles with');
      return;
    }
    _set(AccessState.checking, const []);
    try {
      final roles = await _client.fetch(token);
      // A newer sign-in (or sign-out) wins over this answer.
      if (generation != _generation) return;
      _set(roles.isEmpty ? AccessState.denied : AccessState.granted, roles);
    } catch (e) {
      if (generation != _generation) return;
      debugPrint('Presence: could not check roles: $e');
      _set(AccessState.denied, const [], '$e');
    }
  }

  void _set(AccessState state, List<String> roles, [String? error]) {
    if (_disposed) return;
    _state = state;
    _roles = List.unmodifiable(roles);
    _error = error;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    auth.removeListener(_onAuthChanged);
    super.dispose();
  }
}
