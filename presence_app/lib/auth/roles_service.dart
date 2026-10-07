import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

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
/// sign-in with the same account, on every device. Null if the API didn't
/// say.
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
  /// The roles and profile of the user whose Google ID token is [idToken]:
  /// the profile the account is linked to, made at its first sign-in.
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
/// The [profile] is the signed-in account's, as the auth API answers: the
/// one the account is linked to, the same on every device, or a new one it
/// made at the account's first sign-in. Nobody signed in (and DEV), no
/// profile.
class RolesService extends ChangeNotifier {
  RolesService({
    required this.auth,
    required this._client,
    bool? oidcClient,
    this.startTimeout = const Duration(seconds: 5),
    this.checkTimeout = const Duration(seconds: 15),
    this.retryDelays = const [
      Duration(seconds: 5),
      Duration(seconds: 15),
      Duration(seconds: 30),
      Duration(minutes: 1),
    ],
  }) : oidcClient = oidcClient ?? hasOidcClient {
    _start();
  }

  final AuthService auth;
  final RolesClient _client;

  /// Whether this build can sign in; decides the mode when the API can't.
  final bool oidcClient;

  /// How long to wait for the auth API at start, which holds up the mode.
  final Duration startTimeout;

  /// How long a later check ([checkApi]) waits: longer, since nothing waits
  /// on it. A phone's first HTTPS request can take ~10 s while the app
  /// starts (a debug build, with the camera and recognition starting).
  final Duration checkTimeout;

  /// When the start check (or a roles check) failed: how long to wait
  /// before each check that follows it, until one answers; the last delay
  /// repeats.
  final List<Duration> retryDelays;

  Timer? _retry;

  /// Checks the roles again after a failed roles check, so an unattended
  /// device that started offline gets its access back without anyone
  /// pressing "Check again".
  Timer? _rolesRetry;
  int _rolesAttempt = 0;

  ExecutionMode? _mode;
  List<String> _anonymousRoles = const [anonymousRole];

  /// Null until the start check is done.
  ExecutionMode? get mode => _mode;

  String? _apiError;

  /// Why the auth API didn't answer the last check (the start check, then
  /// [checkApi]), if it didn't.
  String? get apiError => _apiError;

  ApiSettings _apiSettings = (oidc: null, aws: null);

  /// Which expected settings the auth API reported at start; unknown
  /// (null) until then, or if it didn't answer.
  ApiSettings get apiSettings => _apiSettings;

  DateTime? _apiCheckedAt;

  /// When the auth API was last asked ([checkApi], or the start check);
  /// null until the start check is done.
  DateTime? get apiCheckedAt => _apiCheckedAt;

  Future<void>? _apiCheck;

  AccessState _state = AccessState.starting;
  List<String> _roles = const [];
  String? _profile;

  /// Whose [_profile] it is.
  String? _profileUser;
  String? _error;
  String? _user;
  String? _token;
  int _generation = 0;
  bool _disposed = false;

  AccessState get state => _state;
  List<String> get roles => _roles;

  /// The signed-in account's profile ID: whose data it is. Null while
  /// nobody is signed in, until the auth API answers a sign-in, and in
  /// DEV. A failed check of the same account keeps it.
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

  /// Asks the auth API again (`GET /api/auth/anonymous`) whether it
  /// answers and which settings it has: the Log tab's health panel, every
  /// 30 s. Updates [apiError], [apiSettings] and [apiCheckedAt]; the
  /// [mode] stays the one the start check decided. Does nothing until
  /// then, and joins a check already running.
  Future<void> checkApi() {
    if (_mode == null || _disposed) return Future.value();
    return _apiCheck ??= _checkApi().whenComplete(() => _apiCheck = null);
  }

  Future<void> _checkApi() async {
    String? error;
    ApiSettings? settings;
    final watch = Stopwatch()..start();
    try {
      settings = (await _client.anonymous().timeout(checkTimeout)).settings;
    } catch (e) {
      error = '$e';
    }
    if (_disposed) return;
    // Every failure, and the first answer after one, go to the log (and
    // logcat on Android), so a health brick's ❌ can be explained.
    if (error != null) {
      debugPrint(
        'Presence: auth API health check failed after '
        '${watch.elapsedMilliseconds} ms: $error',
      );
    } else if (_apiError != null) {
      debugPrint(
        'Presence: auth API health check answered in '
        '${watch.elapsedMilliseconds} ms, after failing: $_apiError',
      );
    }
    _apiError = error;
    if (settings != null) _apiSettings = settings;
    _apiCheckedAt = DateTime.now();
    notifyListeners();
  }

  Future<void> _start() async {
    AnonymousAccess access;
    final watch = Stopwatch()..start();
    try {
      access = await _client.anonymous().timeout(startTimeout);
      debugPrint(
        'Presence: auth API answered the start check in '
        '${watch.elapsedMilliseconds} ms (${access.mode.name} mode)',
      );
    } catch (e) {
      debugPrint(
        'Presence: could not ask the execution mode (after '
        '${watch.elapsedMilliseconds} ms; checking again): $e',
      );
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
    _apiCheckedAt = DateTime.now();
    _mode = access.mode;
    _anonymousRoles = access.roles;
    _apiSettings = access.settings;
    // Unanswered: check again, sooner then less often, until it answers.
    if (_apiError != null) _retryCheck(0);
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

  Future<void> _check({bool retry = false}) async {
    final generation = ++_generation;
    _rolesRetry?.cancel();
    if (!retry) _rolesAttempt = 0;
    final token = _token = auth.idToken;
    // Another account (or nobody): the profile was the last one's.
    if (auth.user?.id != _profileUser) {
      _profile = null;
      _profileUser = null;
    }
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
    // A background retry keeps the denied screen up while it asks, rather
    // than flashing "checking" every time.
    if (!retry) _set(AccessState.checking, const []);
    try {
      final user = auth.user!.id;
      final access = await _client.fetch(token);
      // A newer sign-in (or sign-out) wins over this answer.
      if (generation != _generation) return;
      _rolesAttempt = 0;
      if (access.profile case final id?) {
        _profile = id;
        _profileUser = user;
      }
      _set(
        access.roles.contains(userRole)
            ? AccessState.granted
            : AccessState.denied,
        access.roles,
      );
    } catch (e) {
      if (generation != _generation) return;
      debugPrint('Presence: could not check roles (checking again): $e');
      _set(AccessState.denied, const [], error: '$e');
      _retryRoles(generation);
    }
  }

  /// Checks the roles again after [retryDelays], sooner then less often,
  /// while the check that failed ([generation]) is still the last one.
  void _retryRoles(int generation) {
    if (retryDelays.isEmpty || _disposed) return;
    final delay = retryDelays[_rolesAttempt.clamp(0, retryDelays.length - 1)];
    _rolesAttempt++;
    _rolesRetry = Timer(delay, () {
      if (_disposed || generation != _generation || _error == null) return;
      if (auth.user == null) return;
      _check(retry: true);
    });
  }

  void _set(AccessState state, List<String> roles, {String? error}) {
    if (_disposed) return;
    _state = state;
    _roles = List.unmodifiable(roles);
    _error = error;
    notifyListeners();
  }

  /// Checks the auth API again after [retryDelays] (the [attempt]th, or the
  /// last), until a check answers.
  void _retryCheck(int attempt) {
    if (retryDelays.isEmpty || _disposed) return;
    final delay = retryDelays[attempt.clamp(0, retryDelays.length - 1)];
    _retry = Timer(delay, () async {
      await checkApi();
      if (_disposed) return;
      if (_apiError != null) {
        _retryCheck(attempt + 1);
      } else if (_mode == ExecutionMode.rbac &&
          _error != null &&
          auth.user != null &&
          auth.idToken != null) {
        // The API answers again: the roles check that failed with it
        // needn't wait for its own retry.
        _check(retry: true);
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _rolesRetry?.cancel();
    auth.removeListener(_onAuthChanged);
    super.dispose();
  }
}
