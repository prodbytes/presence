import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'auth_service.dart';
import 'google_button.dart';
import 'google_config.dart';
import 'saved_session.dart';
import 'session_store.dart';
import 'silent_sign_in.dart';

/// Sign in with Google (`google_sign_in`), following Google's current
/// guidance on each platform:
///
/// - **Web:** Google Identity Services with **FedCM** (the browser's native
///   identity prompt): a silent, auto-select prompt at launch, plus Google's
///   own rendered button.
/// - **Android:** **Credential Manager**: a silent check against
///   previously authorized accounts at launch, and the "Sign in with Google"
///   flow for the button. Once an account has signed in, the app remembers
///   it ([SilentSignIn]) and signs that account back in after a restart,
///   and refreshes its token, with no UI: Credential Manager's check shows
///   an account chooser when several accounts on the phone have signed in
///   to the app, and the unattended phone has nobody to answer it.
/// - **iOS:** the Google Sign-In SDK, restoring the previous sign-in.
class GoogleAuthService extends AuthService {
  GoogleAuthService({
    this._store = const SessionStore(),
    DateTime Function()? now,
    SilentSignIn? silent,
    @visibleForTesting ({String? clientId, String? serverClientId})? ids,
  }) : _now = now ?? DateTime.now,
       _ids = ids ?? _platformIds,
       _silent =
           silent ??
           NativeSilentSignIn.forPlatform(
             serverClientId: (ids ?? _platformIds).serverClientId,
           );

  /// Remembers the session across reloads (web; a no-op elsewhere).
  final SessionStore _store;
  final DateTime Function() _now;
  final ({String? clientId, String? serverClientId}) _ids;

  /// Signs the remembered account back in with no UI (Android; null
  /// elsewhere).
  final SilentSignIn? _silent;

  AuthUser? _user;
  String? _idToken;
  bool _checking = true;
  String? _error;
  String? _unavailable;
  StreamSubscription<GoogleSignInAuthenticationEvent>? _events;
  Timer? _refresh;

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

  /// The client ID this platform needs, and the server client ID: the web
  /// client, so every platform's ID token is issued for it (the one client
  /// Cognito trusts). Android has no client ID of its own in the app.
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
    // Signed in before this reload, with a token still valid: signed in
    // now, before Google's library has even loaded.
    final saved = SavedSession.decode(_store.load(), now: _now());
    if (saved != null) {
      _user = saved.user;
      _idToken = saved.idToken;
      notifyListeners();
    } else {
      _store.clear();
    }
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
    } catch (e) {
      // Only a library that can't start makes sign-in unavailable.
      debugPrint('Presence: Google sign-in is unavailable: ${_details(e)}');
      _unavailable = 'Google sign-in is unavailable: ${_describe(e)}';
      _checking = false;
      notifyListeners();
      return;
    }
    try {
      // Already signed in (a session restored after a reload): don't start
      // Google's prompt now, only shortly before the token expires.
      // Otherwise check quietly for a session, if Google allows it. On web
      // this starts the FedCM prompt and returns at once; a sign-in then
      // arrives as an event. A failure (e.g. Android's "[28473] Caller
      // could not be verified", when the prompt is answered long after it
      // opened) is a failed sign-in, not an unavailable one: the sign-in
      // button stays. On Android, the account that signed in last is first
      // signed back in with no UI; Google's check only if that fails.
      if (_idToken case final token?) {
        _scheduleRefresh(token);
      } else if (!await _signInSilently(await _silent?.remembered())) {
        await GoogleSignIn.instance.attemptLightweightAuthentication();
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

  void _onEvent(GoogleSignInAuthenticationEvent event) {
    _error = null;
    switch (event) {
      case GoogleSignInAuthenticationEventSignIn(:final user):
        _signedIn(
          AuthUser(
            id: user.id,
            email: user.email,
            name: user.displayName,
            photoUrl: user.photoUrl,
          ),
          user.authentication.idToken,
        );
        _silent?.remember(user.email).ignore();
      case GoogleSignInAuthenticationEventSignOut():
        _user = null;
        _idToken = null;
        _refresh?.cancel();
        _store.clear();
        _silent?.forget().ignore();
    }
    notifyListeners();
  }

  /// Signed in as [user], with [token]: remembered, and refreshed before it
  /// expires (not before [atLeast]).
  void _signedIn(
    AuthUser user,
    String? token, {
    Duration atLeast = Duration.zero,
  }) {
    _error = null;
    _user = user;
    _idToken = token;
    _remember();
    if (token != null) _scheduleRefresh(token, atLeast: atLeast);
  }

  /// Signs [email] back in with no UI ([SilentSignIn], Android), as a
  /// Google sign-in would. False when there's no such path, no [email], or
  /// it failed (the caller then asks Google's library); also when the
  /// session changed meanwhile (signed out, or someone else signed in).
  Future<bool> _signInSilently(String? email) async {
    final silent = _silent;
    final server = _ids.serverClientId;
    if (silent == null || server == null || email == null) return false;
    final before = _user?.email;
    final previous = _idToken;
    final account = await silent.signIn(email: email, serverClientId: server);
    if (account == null || _user?.email != before) return false;
    // Play services hands back a cached token until shortly before it
    // expires: if it's the same one, try again in a minute rather than at
    // once.
    final same = account.idToken == previous;
    _signedIn(
      account.user,
      account.idToken,
      atLeast: same ? const Duration(minutes: 1) : Duration.zero,
    );
    if (!same) debugPrint('Presence: signed in again as $email, silently');
    notifyListeners();
    return true;
  }

  @override
  Future<void> signIn() async {
    _error = null;
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
  Future<void> signOut() async {
    // Forget the session here too: a restored session may not be one the
    // library knows about, so it might not send a sign-out event. The
    // account is forgotten, so a restart doesn't sign it back in.
    _store.clear();
    await _silent?.forget();
    _refresh?.cancel();
    _user = null;
    _idToken = null;
    notifyListeners();
    try {
      await GoogleSignIn.instance.signOut();
    } catch (e) {
      debugPrint('Presence: Google sign-out failed: $e');
    }
  }

  /// Refreshes [token] quietly shortly before it expires, so a signed-in
  /// user isn't asked to sign in while their token is still good, not
  /// before [atLeast]. On Android the same account is first signed in
  /// again with no UI. Finding nothing leaves the session as it is.
  void _scheduleRefresh(String token, {Duration atLeast = Duration.zero}) {
    _refresh?.cancel();
    final delay = SavedSession.refreshIn(token, now: _now());
    if (delay == null) return;
    _refresh = Timer(delay < atLeast ? atLeast : delay, () async {
      final email = _user?.email;
      if (email == null) return;
      if (await _signInSilently(email)) return;
      if (_user?.email != email) return;
      GoogleSignIn.instance.attemptLightweightAuthentication()?.ignore();
    });
  }

  void _remember() {
    final user = _user;
    final token = _idToken;
    if (user == null || token == null) {
      _store.clear();
      return;
    }
    _store.save(SavedSession(user: user, idToken: token).encode());
  }

  @override
  Widget? buildSignInButton() => GoogleSignIn.instance.supportsAuthenticate()
      ? null
      : googleSignInButton();

  /// Shows [e] as the sign-in error, and logs all of it ([_details]): the
  /// message is short, the log is what explains it.
  void _fail(String what, Object e) {
    debugPrint('Presence: $what: ${_details(e)}');
    _error = _describe(e);
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
    super.dispose();
  }
}
