import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../identity/profile_id.dart';
import 'auth_service.dart';
import 'google_config.dart';

/// Uses the app: the camera's buttons, the tabs and cloud sync.
const userRole = 'presence_user';

/// Also approves other users' membership requests and creates Member
/// vouchers (the Admin screen).
const adminRole = 'presence_admin';

/// On the auth API's root allowlist: also creates Admin vouchers, so only
/// roots make admins. Comes with [adminRole] and [userRole].
const rootRole = 'presence_root';

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
/// their profile's ID (`automatic_paranoid_axolotl`), the same at every
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

/// Where this device's profile ID is kept. There's always one: made at the
/// first start ([ProfileId.generate]), owned by nobody, until a sign-in
/// claims it or answers with the account's own.
abstract class ProfileStore {
  /// This device's profile ID, made and kept the first time it's asked.
  Future<String> get profileId;

  /// Keeps [id] as this device's profile from now on.
  Future<void> keepProfileId(String id);
}

/// A [ProfileStore] in memory, for a run without storage.
class MemoryProfileStore implements ProfileStore {
  MemoryProfileStore([String? id]) : _id = id ?? ProfileId.generate();

  String _id;

  @override
  Future<String> get profileId async => _id;

  @override
  Future<void> keepProfileId(String id) async => _id = id;
}

/// Asks the auth API (`GET /api/auth`) for a user's roles and profile.
abstract class RolesClient {
  /// The roles and profile of the user whose Google ID token is [idToken].
  /// [profile] is this device's profile, which a first sign-in claims.
  Future<UserAccess> fetch(String idToken, {String? profile});

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
  Future<UserAccess> fetch(String idToken, {String? profile}) async {
    final response = await _client.get(
      base
          .resolve('/api/auth')
          .replace(
            queryParameters: profile == null ? null : {'profile': profile},
          ),
      headers: {'authorization': 'Bearer $idToken'},
    );
    if (response.statusCode != 200) throw RolesException(response.statusCode);
    final body = (jsonDecode(response.body) as Map).cast<String, Object?>();
    final roles = body['roles'];
    final answered = body['profile'];
    return (
      roles: roles is List ? [for (final r in roles) '$r'] : const <String>[],
      profile: answered is String && answered.isNotEmpty ? answered : null,
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
///
/// There's always a [profile]: this device's, from [profiles], made at the
/// first start. A sign-in sends it to the auth API, which links it to the
/// account if the account has none yet; the profile the API answers with
/// is kept as this device's from then on.
class RolesService extends ChangeNotifier {
  RolesService({
    required this.auth,
    required this._client,
    ProfileStore? profiles,
    bool? oidcClient,
    this.startTimeout = const Duration(seconds: 5),
  }) : _profiles = profiles ?? MemoryProfileStore(),
       oidcClient = oidcClient ?? hasOidcClient {
    _start();
  }

  final AuthService auth;
  final RolesClient _client;
  final ProfileStore _profiles;

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

  /// This device's profile ID: whose data it is. The one made at the first
  /// start until a sign-in answers with the account's, which is kept from
  /// then on. Null only until storage has it, just after the start.
  String? get profile => _profile;

  /// Why the last check failed, if it did.
  String? get error => _error;

  bool get hasAccess => _state == AccessState.granted;

  /// Has access and may approve membership requests.
  bool get isAdmin => hasAccess && _roles.contains(adminRole);

  /// An admin who may also create Admin vouchers.
  bool get isRoot => isAdmin && _roles.contains(rootRole);

  /// Checks the roles again (e.g. after asking for access).
  Future<void> refresh() async {
    if (_mode == ExecutionMode.rbac) await _check();
  }

  /// Reads this device's profile, made the first time.
  Future<void> _loadProfile() async {
    try {
      final id = await _profiles.profileId;
      // A sign-in's answer, which came first, wins.
      if (!_disposed && _profile == null) {
        _profile = id;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Presence: no profile ID: $e');
    }
  }

  /// Keeps the profile a sign-in answered with as this device's.
  void _keepProfile(String id) {
    if (id == _profile) return;
    _profile = id;
    _profiles
        .keepProfileId(id)
        .catchError(
          (Object e) => debugPrint('Presence: could not keep the profile: $e'),
        );
  }

  Future<void> _start() async {
    _loadProfile().ignore();
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
              roles: const [anonymousRole, userRole, adminRole, rootRole],
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
      // A first sign-in claims this device's profile. It's loaded long
      // before: a session restored at launch isn't a first start, and the
      // account is linked by then anyway.
      final access = await _client.fetch(token, profile: _profile);
      // A newer sign-in (or sign-out) wins over this answer.
      if (generation != _generation) return;
      if (access.profile case final id?) _keepProfile(id);
      _set(
        access.roles.contains(userRole)
            ? AccessState.granted
            : AccessState.denied,
        access.roles,
      );
    } catch (e) {
      if (generation != _generation) return;
      debugPrint('Presence: could not check roles: $e');
      _set(AccessState.denied, const [], error: '$e');
    }
  }

  void _set(AccessState state, List<String> roles, {String? error}) {
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
