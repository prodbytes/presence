import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';
import 'google_config.dart';

/// Uses the app: the camera's buttons, the tabs and cloud sync.
const userRole = 'presence_user';

/// Also approves other users' membership requests (the Admin screen).
const adminRole = 'presence_admin';

/// Nobody signed in: may only sign in (or, in [ExecutionMode.dev], has
/// every role).
const anonymousRole = 'presence_anonymous';

/// How the system runs, as the auth API reports it at start
/// (`GET /api/auth/anonymous`; `presence.auth.ExecutionMode`).
enum ExecutionMode {
  /// No OIDC client is configured, so nobody can sign in: the anonymous
  /// user has every role. Local development only.
  dev,

  /// Sign-in is configured: the anonymous user may only sign in, and
  /// signed-in users get their roles from the auth API.
  rbac,
}

/// Which of the settings the system expects the auth API has
/// (`presence.auth.Settings`): an OIDC client, and AWS cloud sync (the
/// identity pool and bucket). Null where it didn't say.
typedef ApiSettings = ({bool? oidc, bool? aws});

/// The execution mode, the anonymous user's roles and the API's settings.
typedef AnonymousAccess = ({
  ExecutionMode mode,
  List<String> roles,
  ApiSettings settings,
});

/// What `GET /api/auth` says about the signed-in user: their roles and
/// their profile's ID (`automatic-paranoid-axolotl`), the same at every
/// sign-in with the same account. Null if the API didn't say.
typedef UserAccess = ({List<String> roles, String? profile});

/// Where the app stands for the signed-in user.
enum AccessState {
  /// Asking the auth API for the execution mode, before anything shows.
  starting,

  /// Nobody is signed in.
  signedOut,

  /// Signed in; asking the auth API for the user's roles.
  checking,

  /// The user has the [userRole]: every feature is available.
  granted,

  /// Signed in without the [userRole] (or the check failed): only their
  /// account and the sign-up icon show.
  denied,
}

/// Asks the auth API (`GET /api/auth`) for a user's roles and profile.
abstract class RolesClient {
  /// The roles and profile of the user whose Google ID token is [idToken].
  Future<UserAccess> fetch(String idToken);

  /// The execution mode and the anonymous user's roles, without a token.
  Future<AnonymousAccess> anonymous();
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
  Future<UserAccess> fetch(String idToken) async {
    final response = await _client.get(
      base.resolve('/api/auth'),
      headers: {'authorization': 'Bearer $idToken'},
    );
    if (response.statusCode != 200) throw RolesException(response.statusCode);
    final body = (jsonDecode(response.body) as Map).cast<String, Object?>();
    final roles = body['roles'];
    final profile = body['profile'];
    return (
      roles: roles is List ? [for (final r in roles) '$r'] : const <String>[],
      profile: profile is String && profile.isNotEmpty ? profile : null,
    );
  }

  @override
  Future<AnonymousAccess> anonymous() async {
    final response = await _client.get(base.resolve('/api/auth/anonymous'));
    if (response.statusCode != 200) throw RolesException(response.statusCode);
    final body = (jsonDecode(response.body) as Map).cast<String, Object?>();
    final mode = switch (body['mode']) {
      'DEV' => ExecutionMode.dev,
      'RBAC' => ExecutionMode.rbac,
      final other => throw FormatException('Unknown execution mode: $other'),
    };
    final roles = body['roles'];
    final settings = body['settings'];
    bool? flag(String name) => settings is Map && settings[name] is bool
        ? settings[name] as bool
        : null;
    return (
      mode: mode,
      roles: roles is List ? [for (final r in roles) '$r'] : const <String>[],
      settings: (oidc: flag('oidc'), aws: flag('aws')),
    );
  }
}

/// Whether this build has a Google client ID to sign in with.
bool get hasOidcClient =>
    GoogleConfig.webClientId.isNotEmpty || GoogleConfig.iosClientId.isNotEmpty;

/// The signed-in user's roles, fetched whenever the user changes. The
/// [userRole] grants access to the app's events and features; without it,
/// or after a failed check, there's none (deny by default). The
/// [adminRole] adds the Admin screen.
///
/// It starts by asking the auth API for the [ExecutionMode] and the
/// anonymous user's roles. In [ExecutionMode.dev] access is granted to the
/// anonymous user, and sign-in is ignored. If the API can't answer, the
/// mode follows [oidcClient]: [ExecutionMode.dev] only without one.
class RolesService extends ChangeNotifier {
  RolesService({
    required this.auth,
    required this._client,
    bool? oidcClient,
    this.startTimeout = const Duration(seconds: 5),
  }) : oidcClient = oidcClient ?? hasOidcClient {
    _start();
  }

  final AuthService auth;
  final RolesClient _client;

  /// Whether this build can sign in; decides the mode when the API can't.
  final bool oidcClient;

  /// How long to wait for the auth API at start.
  final Duration startTimeout;

  ExecutionMode? _mode;
  List<String> _anonymousRoles = const [anonymousRole];

  /// Null until the start check is done.
  ExecutionMode? get mode => _mode;

  String? _apiError;

  /// Why the auth API didn't answer the start check, if it didn't.
  String? get apiError => _apiError;

  ApiSettings _apiSettings = (oidc: null, aws: null);

  /// Which expected settings the auth API reported at start; unknown
  /// (null) until then, or if it didn't answer.
  ApiSettings get apiSettings => _apiSettings;

  AccessState _state = AccessState.starting;
  List<String> _roles = const [];
  String? _profile;
  String? _error;
  String? _user;
  String? _token;
  int _generation = 0;
  bool _disposed = false;

  AccessState get state => _state;
  List<String> get roles => _roles;

  /// The signed-in user's profile ID, from the auth API: whose data it is.
  /// Null while signed out, checking, in [ExecutionMode.dev], or if the
  /// check failed.
  String? get profile => _profile;

  /// Why the last check failed, if it did.
  String? get error => _error;

  bool get hasAccess => _state == AccessState.granted;

  /// Has access and may approve membership requests.
  bool get isAdmin => hasAccess && _roles.contains(adminRole);

  /// Checks the roles again (e.g. after asking for access).
  Future<void> refresh() async {
    if (_mode == ExecutionMode.rbac) await _check();
  }

  Future<void> _start() async {
    AnonymousAccess access;
    try {
      access = await _client.anonymous().timeout(startTimeout);
    } catch (e) {
      debugPrint('Presence: could not ask the execution mode: $e');
      _apiError = '$e';
      const unknown = (oidc: null, aws: null);
      access = oidcClient
          ? (
              mode: ExecutionMode.rbac,
              roles: const [anonymousRole],
              settings: unknown,
            )
          : (
              mode: ExecutionMode.dev,
              roles: const [anonymousRole, userRole, adminRole],
              settings: unknown,
            );
    }
    if (_disposed) return;
    _mode = access.mode;
    _anonymousRoles = access.roles;
    _apiSettings = access.settings;
    if (access.mode == ExecutionMode.dev) {
      _set(AccessState.granted, access.roles);
      return;
    }
    auth.addListener(_onAuthChanged);
    _user = auth.user?.id;
    await _check();
  }

  /// Checks again when the user changes, or when a check that failed (e.g.
  /// with a stale token restored at launch, or the API still starting) gets
  /// a new token from a silent sign-in.
  void _onAuthChanged() {
    final user = auth.user?.id;
    final token = auth.idToken;
    final retry = _error != null && token != null && token != _token;
    if (user == _user && !retry) return;
    _user = user;
    _check();
  }

  Future<void> _check() async {
    final generation = ++_generation;
    final token = _token = auth.idToken;
    if (auth.user == null) {
      _set(AccessState.signedOut, _anonymousRoles);
      return;
    }
    if (token == null) {
      _set(
        AccessState.denied,
        const [],
        error: 'No ID token to check roles with',
      );
      return;
    }
    _set(AccessState.checking, const []);
    try {
      final access = await _client.fetch(token);
      // A newer sign-in (or sign-out) wins over this answer.
      if (generation != _generation) return;
      _set(
        access.roles.contains(userRole)
            ? AccessState.granted
            : AccessState.denied,
        access.roles,
        profile: access.profile,
      );
    } catch (e) {
      if (generation != _generation) return;
      debugPrint('Presence: could not check roles: $e');
      _set(AccessState.denied, const [], error: '$e');
    }
  }

  void _set(
    AccessState state,
    List<String> roles, {
    String? error,
    String? profile,
  }) {
    if (_disposed) return;
    _state = state;
    _roles = List.unmodifiable(roles);
    _profile = profile;
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
