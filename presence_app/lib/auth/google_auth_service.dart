import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'auth_service.dart';
import 'google_button.dart';
import 'google_config.dart';
import 'saved_session.dart';
import 'session_store.dart';

/// Sign in with Google (`google_sign_in`), following Google's current
/// guidance on each platform:
///
/// - **Web:** Google Identity Services with **FedCM** (the browser's native
///   identity prompt): a silent, auto-select prompt at launch, plus Google's
///   own rendered button.
/// - **Android:** **Credential Manager**: a silent check against
///   previously authorized accounts at launch, and the "Sign in with Google"
///   flow for the button.
/// - **iOS:** the Google Sign-In SDK, restoring the previous sign-in.
class GoogleAuthService extends AuthService {
  GoogleAuthService({
    this._store = const SessionStore(),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Remembers the session across reloads (web; a no-op elsewhere).
  final SessionStore _store;
  final DateTime Function() _now;

  AuthUser? _user;
  String? _idToken;
  bool _checking = true;
  String? _error;
  String? _unavailable;
  StreamSubscription<GoogleSignInAuthenticationEvent>? _events;

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
  static ({String? clientId, String? serverClientId}) get _ids {
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
      // Refresh the session quietly, if Google allows it. On web this starts
      // the FedCM prompt and returns at once; a sign-in then arrives as an
      // event. Finding nothing leaves a restored session as it is.
      await google.attemptLightweightAuthentication();
    } catch (e) {
      debugPrint('Presence: Google sign-in is unavailable: ${_details(e)}');
      _unavailable = 'Google sign-in is unavailable: ${_describe(e)}';
    }
    _checking = false;
    notifyListeners();
  }

  void _onEvent(GoogleSignInAuthenticationEvent event) {
    _error = null;
    switch (event) {
      case GoogleSignInAuthenticationEventSignIn(:final user):
        _user = AuthUser(
          id: user.id,
          email: user.email,
          name: user.displayName,
          photoUrl: user.photoUrl,
        );
        _idToken = user.authentication.idToken;
        _remember();
      case GoogleSignInAuthenticationEventSignOut():
        _user = null;
        _idToken = null;
        _store.clear();
    }
    notifyListeners();
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
    // library knows about, so it might not send a sign-out event.
    _store.clear();
    _user = null;
    _idToken = null;
    notifyListeners();
    try {
      await GoogleSignIn.instance.signOut();
    } catch (e) {
      debugPrint('Presence: Google sign-out failed: $e');
    }
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
    super.dispose();
  }
}
