import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'auth_service.dart';
import 'google_button.dart';
import 'google_config.dart';

/// Sign in with Google (`google_sign_in`): Google Identity Services on web,
/// Credential Manager on Android, the Google Sign-In SDK on iOS.
class GoogleAuthService extends AuthService {
  AuthUser? _user;
  String? _error;
  String? _unavailable;
  StreamSubscription<GoogleSignInAuthenticationEvent>? _events;

  @override
  AuthUser? get user => _user;

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
          _error = _describe(e);
          notifyListeners();
        },
      );
      // Restore the previous session quietly, if there is one.
      await google.attemptLightweightAuthentication();
    } catch (e) {
      _unavailable = 'Google sign-in is unavailable: ${_describe(e)}';
      notifyListeners();
    }
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
