import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../app_log.dart';
import 'api_config.dart';
import 'apple_sign_in.dart';
import 'auth_service.dart';
import 'auth_session.dart';
import 'google_button.dart';
import 'google_config.dart';
import 'saved_session.dart';
import 'session_store.dart';
import 'silent_sign_in.dart';

/// Signing in, with Google (`google_sign_in`) everywhere and Sign in with
/// Apple on iOS, for a **Presence session**: the provider's ID token is
/// exchanged with the auth API ([SessionApi]) for a one-hour Presence
/// session token ([idToken], the bearer for every API and rbacr) and a
/// refresh token, which renews it five minutes before it expires. The
/// session is kept between launches ([SessionStore]).
///
/// Google follows Google's current guidance on each platform:
///
/// - **Web:** Google Identity Services with **FedCM** (the browser's native
///   identity prompt): a silent, auto-select prompt at launch, plus Google's
///   own rendered button.
/// - **Android:** **Credential Manager**: a silent check against
///   previously authorized accounts at launch, and the "Sign in with Google"
///   flow for the button. Once an account has signed in, the app remembers
///   it ([SilentSignIn]) and, when there's no Presence session to renew,
///   signs that account back in with no UI: Credential Manager's check
///   shows an account chooser when several accounts on the phone have
///   signed in to the app, and the unattended phone has nobody to answer
///   it.
/// - **iOS:** the Google Sign-In SDK.
///
/// When the refresh token is refused (the session ended), a Google session
/// falls back to Google's quiet sign-in, whose new token is exchanged
/// again; an Apple session has no quiet path, so it signs out and says so.
class GoogleAuthService extends AuthService {
  GoogleAuthService({
    SessionStore? store,
    SessionApi? api,
    DateTime Function()? now,
    SilentSignIn? silent,
    AppleSignIn? apple,
    bool? appleAvailable,
    @visibleForTesting ({String? clientId, String? serverClientId})? ids,
    @visibleForTesting this.retryUnit = const Duration(minutes: 1),
    @visibleForTesting
    this.exchangeDelays = const [Duration(seconds: 1), Duration(seconds: 3)],
  }) : _store = store ?? SessionStore.platform(),
       _api = api ?? HttpSessionApi(ApiConfig.baseUrl),
       _now = now ?? DateTime.now,
       _ids = ids ?? _platformIds,
       _apple = apple ?? nativeAppleSignIn,
       _appleAvailable =
           appleAvailable ??
           appleSignInSupported(isWeb: kIsWeb, platform: defaultTargetPlatform),
       _silent =
           silent ??
           NativeSilentSignIn.forPlatform(
             serverClientId: (ids ?? _platformIds).serverClientId,
           );

  /// Keeps the Presence session between launches.
  final SessionStore _store;
  final SessionApi _api;
  final DateTime Function() _now;
  final ({String? clientId, String? serverClientId}) _ids;
  final AppleSignIn _apple;
  final bool _appleAvailable;

  /// Signs the remembered account back in with no UI (Android; null
  /// elsewhere).
  final SilentSignIn? _silent;

  /// The waits between quick retries of an exchange that couldn't reach
  /// the auth API.
  final List<Duration> exchangeDelays;

  /// The live session, with its refresh token; null when signed out, or
  /// when its refresh token was refused and Google's quiet sign-in is
  /// replacing it.
  SavedSession? _session;
  AuthUser? _user;
  String? _idToken;
  bool _checking = true;
  String? _error;
  AuthProblem? _problem;
  String? _unavailable;
  bool _googleReady = false;
  StreamSubscription<GoogleSignInAuthenticationEvent>? _events;
  Timer? _refresh;

  /// Bumped whenever the session is replaced or ends, so a result that
  /// arrives after that (an exchange, a refresh) is dropped.
  int _epoch = 0;

  /// The refresh under way, shared: two at once would send the same
  /// refresh token twice, which ends the session.
  Future<_Refreshed>? _refreshing;

  /// Store writes, in order.
  Future<void> _storeQueue = Future.value();

  @override
  AuthUser? get user => _user;

  @override
  String? get idToken => _idToken;

  @override
  bool get checking => _checking;

  @override
  bool get available => _unavailable == null;

  @override
  String? get unavailableReason => _unavailable;

  @override
  String? get error => _error;

  @override
  AuthProblem? get problem => _problem;

  @override
  bool get appleAvailable => _appleAvailable;

  /// The client ID this platform needs, and the server client ID: the web
  /// client, so every platform's ID token is issued for it (the one client
  /// the auth API trusts). Android has no client ID of its own in the app.
  static ({String? clientId, String? serverClientId}) get _platformIds {
    const web = GoogleConfig.webClientId;
    const ios = GoogleConfig.iosClientId;
    String? orNull(String s) => s.isEmpty ? null : s;
    if (kIsWeb) return (clientId: orNull(web), serverClientId: null);
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS || TargetPlatform.macOS => (
        clientId: orNull(ios),
        serverClientId: orNull(web),
      ),
      _ => (clientId: null, serverClientId: orNull(web)),
    };
  }

  @override
  Future<void> init() async {
    // A session kept from before: signed in now, before Google's library
    // has even loaded. An expired one is refreshed first.
    await _restore();
    final ids = _ids;
    if (ids.clientId == null && ids.serverClientId == null) {
      _unavailable =
          "Google sign-in isn't set up yet: no client ID configured.";
      _checking = false;
      notifyListeners();
      return;
    }
    try {
      final google = GoogleSignIn.instance;
      await google.initialize(
        clientId: ids.clientId,
        serverClientId: ids.serverClientId,
      );
      _events = google.authenticationEvents.listen(
        _onEvent,
        onError: (Object e) {
          // "Canceled" is the quiet check finding no session (or the user
          // closing Google's prompt): not an error worth showing.
          if (e is GoogleSignInException &&
              e.code == GoogleSignInExceptionCode.canceled) {
            return;
          }
          _fail('Google sign-in failed', e);
        },
      );
      _googleReady = true;
    } catch (e) {
      // Only a library that can't start makes sign-in unavailable.
      debugPrint('Presence: Google sign-in is unavailable: ${_details(e)}');
      _unavailable = 'Google sign-in is unavailable: ${_describe(e)}';
      _checking = false;
      notifyListeners();
      return;
    }
    try {
      // Signed in already (a kept session, or one whose refresh is being
      // retried): no Google prompt. Otherwise check quietly for a session,
      // if Google allows it. On web this starts the FedCM prompt and
      // returns at once; a sign-in then arrives as an event. A failure
      // (e.g. Android's "[28473] Caller could not be verified", when the
      // prompt is answered long after it opened) is a failed sign-in, not
      // an unavailable one: the sign-in button stays. On Android, the
      // account that signed in last is first signed back in with no UI;
      // Google's check only if that fails.
      if (_user == null) {
        final email = await _silent?.remembered();
        switch (await _signInSilently(email)) {
          case _Silent.signedIn || _Silent.refused:
            break;
          // Offline or Play services busy at launch: tried again quietly,
          // never with Google's account chooser, which nobody may be there
          // to tap.
          case _Silent.failed when email != null:
            _retrySilently(email);
          case _Silent.failed || _Silent.needsUi:
            await GoogleSignIn.instance.attemptLightweightAuthentication();
        }
      }
    } on GoogleSignInException catch (e) {
      // Usually also reported as an authentication event: logged once.
      if (e.code != GoogleSignInExceptionCode.canceled && _error == null) {
        _fail('Google sign-in failed', e);
      }
    } catch (e) {
      if (_error == null) _fail('Google sign-in failed', e);
    }
    _checking = false;
    notifyListeners();
  }

  /// Restores the kept session: signed in at once while its token has
  /// more than a minute left; otherwise refreshed now. A refresh that
  /// fails this time keeps the user, without a token, and tries again
  /// ([_retryRefresh]); a refused one drops the session (the launch then
  /// goes on as without one).
  Future<void> _restore() async {
    final raw = await _store.load();
    final saved = SavedSession.decode(raw);
    if (saved == null) {
      if (raw != null) _clearStore();
      return;
    }
    if (saved.validAt(_now())) {
      _adopt(saved, save: false);
      return;
    }
    _session = saved;
    _user = saved.user;
    _idToken = null;
    notifyListeners();
    if (await _refreshSession() == _Refreshed.refused) {
      _user = null;
      if (saved.provider == SessionProvider.apple) {
        _problem = AuthProblem.sessionEnded;
        _error = 'The Apple session ended';
      }
      notifyListeners();
    }
  }

  void _onEvent(GoogleSignInAuthenticationEvent event) {
    switch (event) {
      case GoogleSignInAuthenticationEventSignIn(:final user):
        _onGoogleSignIn(user).ignore();
      case GoogleSignInAuthenticationEventSignOut():
        // Our own sign-out has already ended the session; this only acts
        // when Google signs out on its own. An Apple session isn't
        // Google's.
        if (_session?.provider == SessionProvider.apple) return;
        if (_user == null && _session == null) return;
        _endLocally();
        _silent?.forget().ignore();
        notifyListeners();
    }
  }

  /// A Google sign-in (the button, Google's quiet check): its ID token is
  /// exchanged for a Presence session; signed in once that succeeds.
  Future<void> _onGoogleSignIn(GoogleSignInAccount account) async {
    final token = account.authentication.idToken;
    if (token == null) {
      _fail('Google sign-in failed', 'Google returned no ID token');
      return;
    }
    final result = await _startSession(
      SessionProvider.google,
      token,
      fallback: AuthUser(
        id: account.id,
        email: account.email,
        name: account.displayName,
        photoUrl: account.photoUrl,
      ),
    );
    if (result != _Outcome.signedIn) return;
    _silent?.remember(account.email).ignore();
    // A sign-in with UI starts the silent backoff over.
    _silentFailures = 0;
  }

  /// Exchanges the [provider]'s [idToken] for a Presence session (a few
  /// quick tries while the auth API can't be reached) and signs in with
  /// it. [quiet] (the silent sign-in) shows no error when the API can't be
  /// reached: the caller tries again later.
  Future<_Outcome> _startSession(
    SessionProvider provider,
    String idToken, {
    AuthUser? fallback,
    String? nonce,
    String? authorizationCode,
    String? name,
    bool quiet = false,
  }) async {
    final epoch = _epoch;
    final SessionGrant grant;
    try {
      grant = await withSessionRetries(
        () => _api.exchange(
          provider: provider,
          idToken: idToken,
          nonce: nonce,
          authorizationCode: authorizationCode,
          name: name,
        ),
        delays: exchangeDelays,
      );
    } on SessionRefused catch (e) {
      if (epoch != _epoch) return _Outcome.stale;
      _failSession(e);
      return _Outcome.refused;
    } catch (e) {
      if (epoch != _epoch) return _Outcome.stale;
      if (quiet) {
        debugPrint('Presence: Presence session failed: $e');
      } else {
        _failSession(e);
      }
      return _Outcome.failed;
    }
    if (epoch != _epoch) {
      // Signed out (or in again) meanwhile: this session isn't wanted.
      _api.revoke(grant.refreshToken).ignore();
      return _Outcome.stale;
    }
    final user = SavedSession.userOf(grant.token) ?? fallback;
    if (user == null) {
      _api.revoke(grant.refreshToken).ignore();
      _failSession(const SessionUnavailable(reason: 'no user in the session'));
      return _Outcome.failed;
    }
    // A new sign-in replaces the session there was (if any): that one ends.
    if (_session case final old?) _api.revoke(old.refreshToken).ignore();
    _adopt(
      SavedSession(
        provider: provider,
        user: user,
        token: grant.token,
        expiresAt: grant.expiresAt,
        refreshToken: grant.refreshToken,
      ),
    );
    return _Outcome.signedIn;
  }

  /// Signed in with [session]: kept (unless [save] is false: it came from
  /// the store), and refreshed before it expires.
  void _adopt(SavedSession session, {bool save = true}) {
    _epoch++;
    _session = session;
    _user = session.user;
    _idToken = session.token;
    _error = null;
    _problem = null;
    _refreshFailures = 0;
    if (save) _saveStore(session);
    _scheduleRefresh();
    notifyListeners();
  }

  /// Refreshes the session five minutes before its token expires.
  void _scheduleRefresh() {
    _refresh?.cancel();
    final session = _session;
    if (session == null) return;
    _refresh = Timer(session.refreshIn(_now()), _refreshOnTimer);
  }

  Future<void> _refreshOnTimer() async {
    final session = _session;
    if (session == null) return;
    if (await _refreshSession() != _Refreshed.refused) return;
    // The refresh token is dead. Google: its quiet sign-in, whose token is
    // exchanged again; the user stays signed in meanwhile (the token may
    // have minutes left). Apple has no quiet path: signed out.
    switch (session.provider) {
      case SessionProvider.google:
        final email = session.user.email;
        if (_user?.email == email) _googleFallback(email).ignore();
      case SessionProvider.apple:
        _endLocally();
        _problem = AuthProblem.sessionEnded;
        _error = 'The Apple session ended';
        notifyListeners();
    }
  }

  /// Renews the session with its refresh token: one at a time (callers
  /// share the refresh under way). A failure worth retrying keeps the
  /// session and tries again with the backoff ([_retryRefresh]); a refused
  /// one drops the session and its store, for the caller to fall back.
  Future<_Refreshed> _refreshSession() =>
      _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);

  Future<_Refreshed> _doRefresh() async {
    final session = _session;
    if (session == null) return _Refreshed.stale;
    final epoch = _epoch;
    try {
      final grant = await _api.refresh(session.refreshToken);
      if (epoch != _epoch) {
        _api.revoke(grant.refreshToken).ignore();
        return _Refreshed.stale;
      }
      // The old refresh token is used up: replaced here, and in the store.
      _adopt(
        SavedSession(
          provider: session.provider,
          user: SavedSession.userOf(grant.token) ?? session.user,
          token: grant.token,
          expiresAt: grant.expiresAt,
          refreshToken: grant.refreshToken,
        ),
      );
      return _Refreshed.done;
    } on SessionRefused catch (e) {
      if (epoch != _epoch) return _Refreshed.stale;
      debugPrint(
        'Presence: the session of ${maskEmail(session.user.email)} '
        'ended: $e',
      );
      _refresh?.cancel();
      _session = null;
      _refreshFailures = 0;
      _clearStore();
      return _Refreshed.refused;
    } catch (e) {
      if (epoch != _epoch) return _Refreshed.stale;
      _retryRefresh(e);
      return _Refreshed.failed;
    }
  }

  /// Refreshes that failed in a row, for [_retryRefresh]'s backoff.
  int _refreshFailures = 0;

  /// [_refreshFailures], for tests: back to 0 when a session is adopted.
  @visibleForTesting
  int get refreshFailures => _refreshFailures;

  /// After a refresh that failed this time ([e]): tries again in 1, 2, 4, 8
  /// and then every 15 [retryUnit]s, keeping the session.
  void _retryRefresh(Object e) {
    _refresh?.cancel();
    final wait = retryUnit * min(1 << min(_refreshFailures, 4), 15);
    _refreshFailures++;
    debugPrint(
      'Presence: session refresh failed ($_refreshFailures in a row): $e; '
      'trying again in ${wait.inSeconds} s',
    );
    _refresh = Timer(wait, _refreshOnTimer);
  }

  /// A Google session whose refresh token is gone: Google's quiet sign-in
  /// for [email] (on Android the remembered account, with no UI, retried
  /// quietly when it fails; elsewhere, or when it must sign in with UI,
  /// Google's quiet check). Finding nothing leaves the user signed in until
  /// the token expires.
  Future<void> _googleFallback(String email) async {
    switch (await _signInSilently(email)) {
      case _Silent.signedIn:
        return;
      case _Silent.refused:
        // The auth API won't take this account's token (the error shows):
        // the session can't go on.
        if (_user?.email != email) return;
        _endLocally();
        notifyListeners();
      case _Silent.failed when _silent != null:
        if (_user?.email == email) _retrySilently(email);
        return;
      case _Silent.failed || _Silent.needsUi:
        if (_user?.email != email) return;
        _lightweight();
    }
  }

  /// Google's quiet check; a sign-in arrives as an event.
  void _lightweight() {
    if (!_googleReady) return;
    try {
      GoogleSignIn.instance.attemptLightweightAuthentication()?.ignore();
    } catch (e) {
      debugPrint('Presence: Google quiet sign-in failed: ${_details(e)}');
    }
  }

  /// Signs [email] back in with no UI ([SilentSignIn], Android), and
  /// exchanges its Google ID token for a Presence session.
  /// [_Silent.needsUi] when there's no such path, no [email], or the
  /// account must sign in with UI (the caller then asks Google's library);
  /// [_Silent.failed] when it failed this time (worth retrying quietly) or
  /// the session changed meanwhile (signed out, or someone else signed
  /// in); [_Silent.refused] when the auth API refused the token (shown).
  Future<_Silent> _signInSilently(String? email) async {
    final silent = _silent;
    final server = _ids.serverClientId;
    if (silent == null || server == null || email == null) {
      return _Silent.needsUi;
    }
    final before = _user?.email;
    final SilentAccount? account;
    try {
      account = await silent.signIn(email: email, serverClientId: server);
    } on SilentSignInRequired {
      debugPrint('Presence: ${maskEmail(email)} must sign in again');
      return _Silent.needsUi;
    }
    if (account == null || _user?.email != before) return _Silent.failed;
    switch (await _startSession(
      SessionProvider.google,
      account.idToken,
      fallback: account.user,
      quiet: true,
    )) {
      case _Outcome.signedIn:
        _silentFailures = 0;
        debugPrint(
          'Presence: signed in again as ${maskEmail(email)}, silently',
        );
        return _Silent.signedIn;
      case _Outcome.refused:
        return _Silent.refused;
      case _Outcome.failed || _Outcome.stale:
        return _Silent.failed;
    }
  }

  /// Silent sign-ins that failed in a row, for [_retrySilently]'s backoff.
  int _silentFailures = 0;

  /// [_silentFailures], for tests: back to 0 at a sign-in or sign-out.
  @visibleForTesting
  int get silentFailures => _silentFailures;

  /// The first wait before a quiet retry (a silent sign-in, a session
  /// refresh); then 2, 4, 8 and 15 times it.
  final Duration retryUnit;

  /// After a failed silent sign-in of [email]: tries again quietly in 1, 2,
  /// 4, 8 and then every 15 minutes ([retryUnit]s), until it signs in, the account must
  /// sign in with UI, or the session changes (signed out, someone else).
  void _retrySilently(String email) {
    _refresh?.cancel();
    final wait = retryUnit * min(1 << min(_silentFailures, 4), 15);
    _silentFailures++;
    debugPrint(
      'Presence: silent sign-in of ${maskEmail(email)} failed '
      '($_silentFailures in a row); trying again in ${wait.inSeconds} s',
    );
    final user = _user?.email;
    _refresh = Timer(wait, () async {
      if (_user?.email != user) return;
      switch (await _signInSilently(email)) {
        case _Silent.signedIn:
          break;
        case _Silent.refused:
          if (_user != null && _user?.email == user) {
            _endLocally();
            notifyListeners();
          }
        case _Silent.failed:
          if (_user?.email == user) _retrySilently(email);
        case _Silent.needsUi:
          _lightweight();
      }
    });
  }

  @override
  Future<void> signIn() async {
    _error = null;
    _problem = null;
    notifyListeners();
    try {
      await GoogleSignIn.instance.authenticate();
    } on GoogleSignInException catch (e) {
      if (e.code != GoogleSignInExceptionCode.canceled) {
        _fail('Google sign-in failed', e);
      }
    } catch (e) {
      _fail('Google sign-in failed', e);
    }
  }

  @override
  Future<void> signInWithApple() async {
    if (!_appleAvailable) return;
    _error = null;
    _problem = null;
    notifyListeners();
    // Apple puts the nonce's SHA-256 in its token; the auth API gets the
    // raw nonce and checks it, so a token can't be replayed.
    final nonce = newNonce();
    final AppleCredential? credential;
    try {
      credential = await _apple(nonce: sha256Hex(nonce));
    } catch (e) {
      _fail('Apple sign-in failed', e);
      return;
    }
    if (credential == null) return; // canceled
    final token = credential.identityToken;
    if (token == null) {
      _fail('Apple sign-in failed', 'Apple returned no identity token');
      return;
    }
    await _startSession(
      SessionProvider.apple,
      token,
      nonce: nonce,
      authorizationCode: credential.authorizationCode,
      name: appleFullName(credential.givenName, credential.familyName),
    );
  }

  @override
  Future<void> signOut() async {
    // The session is revoked (best effort, not waited for) and forgotten,
    // and so is the Android account, so a restart doesn't sign it back in.
    final session = _session;
    if (session != null) _api.revoke(session.refreshToken).ignore();
    _endLocally();
    await _silent?.forget();
    _silentFailures = 0;
    notifyListeners();
    if (!_googleReady) return;
    try {
      await GoogleSignIn.instance.signOut();
    } catch (e) {
      debugPrint('Presence: Google sign-out failed: $e');
    }
  }

  /// Signed out here: no session, no user, nothing kept.
  void _endLocally() {
    _epoch++;
    _refresh?.cancel();
    _session = null;
    _user = null;
    _idToken = null;
    _refreshFailures = 0;
    _silentFailures = 0;
    _clearStore();
  }

  void _saveStore(SavedSession session) {
    final encoded = session.encode();
    _storeQueue = _storeQueue
        .then((_) => _store.save(encoded))
        .catchError(
          (Object e) => debugPrint('Presence: could not save the session'),
        );
  }

  void _clearStore() {
    _storeQueue = _storeQueue
        .then((_) => _store.clear())
        .catchError(
          (Object e) => debugPrint('Presence: could not forget the session'),
        );
  }

  /// The store's pending writes, for tests.
  @visibleForTesting
  Future<void> get stored => _storeQueue;

  @override
  Widget? buildSignInButton() =>
      _googleReady && !GoogleSignIn.instance.supportsAuthenticate()
      ? googleSignInButton()
      : null;

  /// Shows a failed exchange with the auth API: its meaning ([problem])
  /// is shown translated.
  void _failSession(Object e) {
    _problem = switch (e) {
      SessionRefused(status: 403) => AuthProblem.noVerifiedEmail,
      SessionRefused() => AuthProblem.refused,
      SessionUnavailable(status: 503) => AuthProblem.notConfigured,
      _ => AuthProblem.unreachable,
    };
    _fail('Presence session failed', e, problem: _problem);
  }

  /// Shows [e] as the sign-in error, and logs all of it ([_details]): the
  /// message is short, the log is what explains it.
  void _fail(String what, Object e, {AuthProblem? problem}) {
    debugPrint('Presence: $what: ${_details(e)}');
    _error = _describe(e);
    _problem = problem;
    notifyListeners();
  }

  /// Everything a sign-in error says, for the log: its code, description
  /// and the platform's details (on Android, Credential Manager's error
  /// type and message).
  @visibleForTesting
  static String details(Object e) => _details(e);

  static String _details(Object e) => switch (e) {
    GoogleSignInException(:final code, :final description, :final details) => [
      code.name,
      ?description,
      if (details != null) 'details: $details',
    ].join('; '),
    _ => e.toString(),
  };

  static String _describe(Object e) => switch (e) {
    GoogleSignInException(:final description?) => description,
    GoogleSignInException(:final code) => code.name,
    _ => e.toString(),
  };

  @override
  void dispose() {
    _events?.cancel();
    _refresh?.cancel();
    _epoch++;
    super.dispose();
  }
}

/// How a silent sign-in went ([GoogleAuthService._signInSilently]).
enum _Silent { signedIn, failed, needsUi, refused }

/// How an exchange went ([GoogleAuthService._startSession]).
enum _Outcome { signedIn, failed, refused, stale }

/// How a refresh went ([GoogleAuthService._refreshSession]).
enum _Refreshed { done, failed, refused, stale }
