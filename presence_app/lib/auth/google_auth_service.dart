import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'auth_service.dart';
import 'google_button.dart';
import 'google_config.dart';

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
  AuthUser? _user;
  bool _checking = true;
  String? _error;
  String? _unavailable;
  StreamSubscription<GoogleSignInAuthenticationEvent>? _events;

  @override
  AuthUser? get user => _user;

  @override
  bool get checking => _checking;

  @override
  bool get available => _unavailable == null;

  @override
  String? get unavailableReason => _unavailable;

  @override
  String? get error => _error;

  /// The client ID this platform needs, and the server client ID for
  /// Android (which identifies the app to Google via the web client).
  static ({String? clientId, String? serverClientId}) get _ids {
    const web = GoogleConfig.webClientId;
    const ios = GoogleConfig.iosClientId;
    String? orNull(String s) => s.isEmpty ? null : s;
    if (kIsWeb) return (clientId: orNull(web), serverClientId: null);
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS ||
      TargetPlatform.macOS => (clientId: orNull(ios), serverClientId: null),
      _ => (clientId: null, serverClientId: orNull(web)),
    };
  }

  @override
  Future<void> init() async {
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
          _error = _describe(e);
          notifyListeners();
        },
      );
      // Restore the previous session quietly, if there is one. On web this
      // starts the FedCM prompt and returns at once; a sign-in then arrives
      // as an event while the sign-in screen is already showing.
      await google.attemptLightweightAuthentication();
    } catch (e) {
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
      case GoogleSignInAuthenticationEventSignOut():
        _user = null;
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
        _error = _describe(e);
        notifyListeners();
      }
    } catch (e) {
      _error = _describe(e);
      notifyListeners();
    }
  }

  @override
  Future<void> signOut() => GoogleSignIn.instance.signOut();

  @override
  Widget? buildSignInButton() => GoogleSignIn.instance.supportsAuthenticate()
      ? null
      : googleSignInButton();

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
