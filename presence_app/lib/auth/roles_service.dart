import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';
import 'google_config.dart';
import 'rbacr_client.dart';

/// Uses the app: the camera's buttons, the tabs and cloud sync.
const userRole = 'presence_user';

/// Also answers feedback (the Admin screen). From rbacr's `admin` in its
/// presence system, never shared with a linked account.
const adminRole = 'presence_admin';

/// An rbacr root (rbacr's root list, `root: true` in `GET /api/me`):
/// comes with every other role.
const rootRole = 'presence_root';

/// Also syncs with the cloud (S3): events, clips, recordings and settings
/// go up and come down, so a new device gets the history. Given by rbacr
/// (premium or admin in its presence system), never by this app; the auth
/// API tags the profile's credentials with it, and the bucket requires
/// that. Without it, a member's devices tell each other about events over
/// live sync only.
const premiumRole = 'presence_premium';

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
  /// signed-in users get their roles from rbacr.
  rbac,
}

/// Which of the settings the system expects the auth API has
/// (`presence.auth.Settings`): an OIDC client, AWS cloud sync (the
/// identity pool and bucket), and rbacr (who is premium). Null where it
/// didn't say (an older API, for rbacr).
typedef ApiSettings = ({bool? oidc, bool? aws, bool? rbacr});

/// The execution mode, the anonymous user's roles and the API's settings.
typedef AnonymousAccess = ({
  ExecutionMode mode,
  List<String> roles,
  ApiSettings settings,
});

/// The signed-in user's roles and their profile's ID
/// (`automatic_paranoid_axolotl`), the same at every sign-in with the same
/// account, on every device. Null if the API didn't say.
typedef UserAccess = ({List<String> roles, String? profile});

/// Where the app stands for the signed-in user.
enum AccessState {
  /// Asking the auth API for the execution mode, before anything shows.
  starting,

  /// Nobody is signed in.
  signedOut,

  /// Signed in; asking rbacr and the auth API for the user's roles.
  checking,

  /// The user has the [userRole]: every feature is available.
  granted,

  /// Signed in without the [userRole] (or the check failed): only their
  /// account and the sign-up icon show.
  denied,
}

/// Asks for a user's roles and profile, the execution mode, and whether
/// the system is in maintenance.
abstract class RolesClient {
  /// The roles and profile of the user whose Google ID token is [idToken]:
  /// the profile the account is linked to, made at its first sign-in.
  Future<UserAccess> fetch(String idToken);

  /// The execution mode and the anonymous user's roles, without a token.
  Future<AnonymousAccess> anonymous();

  /// Whether rbacr has Presence's system in maintenance, asked with the
  /// user's [idToken] (rbacr answers no one without a token).
  Future<bool> maintenance(String idToken);
}

/// Why the auth API or rbacr didn't answer.
class RolesException implements Exception {
  RolesException(this.statusCode, [this.source = 'Auth API']);

  final int statusCode;

  /// Who answered it: the auth API, or rbacr.
  final String source;

  @override
  String toString() => '$source HTTP $statusCode';
}

/// The real client. The user's own roles come from rbacr (`GET /api/me`,
/// [presenceRoles]); their profile, and the membership it shares with a
/// linked account (`shared`: [userRole] and [premiumRole] when the
/// profile's owner has them), from the auth API's
/// `GET <base>/api/auth/profile`, which makes the profile at the account's
/// first sign-in. Both must answer: either failing fails the check (deny).
class HttpRolesClient implements RolesClient {
  HttpRolesClient(
    this.base, {
    required this.rbacr,
    String? system,
    http.Client? client,
  }) : system = system ?? RbacrConfig.system,
       _client = client ?? http.Client();

  /// The site the API is under: the page's own origin on web, or
  /// `ApiConfig.baseUrl` on Android and iOS.
  final Uri base;

  /// rbacr's self-service routes, as the user.
  final RbacrClient rbacr;

  /// The rbacr system of Presence's roles.
  final String system;
  final http.Client _client;

  @override
  Future<UserAccess> fetch(String idToken) async {
    // Both at once; either failing fails the check.
    final answers = await Future.wait<Object>([
      rbacr.me(idToken),
      _profile(idToken),
    ]);
    final me = answers[0] as RbacrMe;
    final profile = answers[1] as Map<String, Object?>;
    final shared = profile['shared'];
    final answered = profile['profile'];
    final roles = <String>{
      ...presenceRoles(me, system),
      // A linked account shares its owner's membership, never more.
      if (shared is List)
        for (final r in shared)
          if (r == userRole || r == premiumRole) '$r',
    };
    return (
      roles: roles.toList()..sort(),
      profile: answered is String && answered.isNotEmpty ? answered : null,
    );
  }

  Future<Map<String, Object?>> _profile(String idToken) async {
    final response = await _client.get(
      base.resolve('/api/auth/profile'),
      headers: {'authorization': 'Bearer $idToken'},
    );
    if (response.statusCode != 200) throw RolesException(response.statusCode);
    return (jsonDecode(response.body) as Map).cast<String, Object?>();
  }

  @override
  Future<bool> maintenance(String idToken) => rbacr.maintenance(idToken);

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
      settings: (oidc: flag('oidc'), aws: flag('aws'), rbacr: flag('rbacr')),
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
    this.maintenanceCheckInterval,
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

  /// How often rbacr is asked whether Presence's system is in maintenance
  /// ([checkMaintenance]), so a running app (an unattended phone) follows
  /// a root switching it in rbacr, and the auth API whether it answers
  /// ([checkApi]) (the app: every minute); null never asks after the
  /// start check.
  final Duration? maintenanceCheckInterval;

  Timer? _retry;
  Timer? _maintenanceCheck;

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

  ApiSettings _apiSettings = (oidc: null, aws: null, rbacr: null);

  /// Which expected settings the auth API reported at start; unknown
  /// (null) until then, or if it didn't answer.
  ApiSettings get apiSettings => _apiSettings;

  bool _maintenance = false;

  /// Shows only the sorry message: rbacr has Presence's system in
  /// maintenance (`GET /api/systems/presence/status`), as it last answered
  /// the signed-in user; kept when it doesn't answer. While it's on, rbacr
  /// gives nobody a role in the system, admins and roots included, so
  /// everyone signed in sees the sorry message, never "no access". Off
  /// while nobody is signed in (rbacr answers no one without a token) and
  /// in DEV.
  bool get inMaintenance => _maintenance;

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

  /// Has access and may use the Admin screen.
  bool get isAdmin => hasAccess && _roles.contains(adminRole);

  /// An admin who is an rbacr root.
  bool get isRoot => isAdmin && _roles.contains(rootRole);

  /// Has access and syncs with the cloud ([premiumRole]); a member without
  /// it is free: live sync only.
  bool get isPremium => hasAccess && _roles.contains(premiumRole);

  /// Checks the roles again (e.g. after asking for access).
  Future<void> refresh() async {
    if (_mode == ExecutionMode.rbac) await _check();
  }

  /// Asks the auth API again (`GET /api/auth/anonymous`) whether it
  /// answers and which settings it has: every [maintenanceCheckInterval],
  /// and the Log tab's health panel. Updates [apiError], [apiSettings] and
  /// [apiCheckedAt]; the
  /// [mode] stays the one the start check decided. Does nothing until
  /// then, and joins a check already running.
  Future<void> checkApi() {
    if (_mode == null || _disposed) return Future.value();
    return _apiCheck ??= _checkApi().whenComplete(() => _apiCheck = null);
  }

  Future<void> _checkApi() async {
    String? error;
    AnonymousAccess? access;
    final watch = Stopwatch()..start();
    try {
      access = await _client.anonymous().timeout(checkTimeout);
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
    if (access != null) _apiSettings = access.settings;
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
      const unknown = (oidc: null, aws: null, rbacr: null);
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
    if (maintenanceCheckInterval case final every?) {
      _maintenanceCheck = Timer.periodic(every, (_) {
        checkApi();
        checkMaintenance();
      });
    }
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
      // rbacr can't be asked without a token.
      _setMaintenance(false);
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
    // Asked with the roles, so the sorry message shows rather than "no
    // access" while rbacr gives nobody roles.
    final maintenance = _askMaintenance(token);
    try {
      final user = auth.user!.id;
      final access = await _client.fetch(token);
      final on = await maintenance;
      // A newer sign-in (or sign-out) wins over this answer.
      if (generation != _generation) return;
      if (on != null) _setMaintenance(on);
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
      final on = await maintenance;
      if (generation != _generation) return;
      if (on != null) _setMaintenance(on);
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

  /// Asks rbacr whether Presence's system is in maintenance; null if it
  /// didn't answer (the last answer stands).
  Future<bool?> _askMaintenance(String token) => _client
      .maintenance(token)
      .then<bool?>(
        (on) => on,
        onError: (Object e) {
          debugPrint('Presence: could not ask rbacr about maintenance: $e');
          return null;
        },
      );

  /// Asks rbacr again whether Presence's system is in maintenance (every
  /// [maintenanceCheckInterval]), for the signed-in user; nothing while
  /// nobody is (or in DEV). When it's over, the roles are checked again:
  /// the checks during it got none.
  Future<void> checkMaintenance() async {
    final token = auth.idToken;
    if (_mode != ExecutionMode.rbac || _disposed) return;
    if (auth.user == null || token == null) return;
    final generation = _generation;
    final on = await _askMaintenance(token);
    if (on == null || _disposed || generation != _generation) return;
    final was = _maintenance;
    if (on == was) return;
    _setMaintenance(on);
    notifyListeners();
    if (was && !on) _check(retry: true);
  }

  void _setMaintenance(bool on) {
    if (on != _maintenance) {
      debugPrint('Presence: maintenance mode ${on ? 'on' : 'off'} (rbacr)');
    }
    _maintenance = on;
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
    _maintenanceCheck?.cancel();
    auth.removeListener(_onAuthChanged);
    super.dispose();
  }
}
