import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../app_log.dart';
import 'auth_service.dart';

/// A silent sign-in's result: who, and their fresh Google ID token.
typedef SilentAccount = ({AuthUser user, String idToken});

/// The remembered account can't sign in without UI (Play services'
/// SIGN_IN_REQUIRED: removed from the phone, or no longer granting the
/// app). Any other failure may pass on a retry, and is a null instead.
class SilentSignInRequired implements Exception {
  const SilentSignInRequired(this.email);

  final String email;

  @override
  String toString() => 'SilentSignInRequired(${maskEmail(email)})';
}

/// Signs the account that signed in last back in, with no UI: on Android,
/// after a restart and to refresh the ID token. Credential Manager's quiet
/// check shows Google's account chooser when more than one account on the
/// phone has signed in to the app, and the unattended phone has nobody to
/// tap it.
abstract class SilentSignIn {
  /// The email of the account remembered at the last sign-in, or null.
  Future<String?> remembered();

  /// Remembers [email] as the signed-in account.
  Future<void> remember(String email);

  /// Forgets the remembered account (on sign-out).
  Future<void> forget();

  /// Signs [email] in quietly, with an ID token for [serverClientId]; null
  /// when it failed this time (offline, Play services busy), and throws
  /// [SilentSignInRequired] when it can't without UI.
  Future<SilentAccount?> signIn({
    required String email,
    required String serverClientId,
  });
}

/// [SilentSignIn] through the app's Android channel (`presence/device`,
/// `GoogleSilentSignIn.kt`): the account is kept in the app's preferences,
/// and Play services' sign-in, asked for that account only, returns its ID
/// token. Every failure (no channel, Play services' error) is a null or a
/// no-op: the caller falls back to Google's library.
class NativeSilentSignIn implements SilentSignIn {
  const NativeSilentSignIn({this.serverClientId});

  /// For signing Play services' sign-in out too, on [forget].
  final String? serverClientId;

  static const _channel = MethodChannel('presence/device');

  /// On Android only; null elsewhere (web and iOS keep their own sign-in).
  static SilentSignIn? forPlatform({String? serverClientId}) =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android
      ? NativeSilentSignIn(serverClientId: serverClientId)
      : null;

  @override
  Future<String?> remembered() async {
    try {
      return await _channel.invokeMethod<String>('googleAccount');
    } catch (e) {
      debugPrint('Presence: no remembered Google account: $e');
      return null;
    }
  }

  @override
  Future<void> remember(String email) async {
    try {
      await _channel.invokeMethod<void>('rememberGoogleAccount', {
        'email': email,
      });
    } catch (e) {
      debugPrint('Presence: could not remember the Google account: $e');
    }
  }

  @override
  Future<void> forget() async {
    try {
      await _channel.invokeMethod<void>('forgetGoogleAccount', {
        'serverClientId': serverClientId,
      });
    } catch (e) {
      debugPrint('Presence: could not forget the Google account: $e');
    }
  }

  @override
  Future<SilentAccount?> signIn({
    required String email,
    required String serverClientId,
  }) async {
    try {
      final m = await _channel.invokeMapMethod<String, Object?>(
        'silentGoogleSignIn',
        {'email': email, 'serverClientId': serverClientId},
      );
      if (m != null && failureOf(m) == signInRequired) {
        throw SilentSignInRequired(email);
      }
      return m == null ? null : parse(m);
    } on SilentSignInRequired {
      rethrow;
    } catch (e) {
      debugPrint(
        'Presence: silent Google sign-in of ${maskEmail(email)} failed: $e',
      );
      return null;
    }
  }

  /// Play services' SIGN_IN_REQUIRED status code.
  static const signInRequired = 4;

  /// The failure's status code in the channel's reply, or null when it has
  /// none (an account).
  @visibleForTesting
  static int? failureOf(Map<String, Object?> m) =>
      int.tryParse('${m['failure'] ?? ''}');

  /// The account in the channel's reply, or null if it's incomplete.
  @visibleForTesting
  static SilentAccount? parse(Map<String, Object?> m) {
    final id = m['id'];
    final email = m['email'];
    final token = m['idToken'];
    if (id is! String || email is! String || token is! String) return null;
    if (token.isEmpty) return null;
    return (
      user: AuthUser(
        id: id,
        email: email,
        name: m['displayName'] as String?,
        photoUrl: m['photoUrl'] as String?,
      ),
      idToken: token,
    );
  }
}
