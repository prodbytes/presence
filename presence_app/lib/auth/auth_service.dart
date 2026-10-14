import 'package:flutter/widgets.dart';

/// Who is signed in.
@immutable
class AuthUser {
  const AuthUser({
    required this.id,
    required this.email,
    this.name,
    this.photoUrl,
  });

  final String id;
  final String email;
  final String? name;
  final String? photoUrl;

  /// A name to show: the display name, or the email.
  String get label => (name?.trim().isNotEmpty ?? false) ? name! : email;

  /// Who is signed in, for tooltips: "Ana · ana@example.com".
  String get identity => label == email ? email : '$label · $email';
}

/// Signing in and out. The app owns one; the account sheet and the app bar
/// read it.
abstract class AuthService extends ChangeNotifier {
  /// The signed-in user, or null.
  AuthUser? get user;

  /// The signed-in user's **Presence session token** (a JWT the auth API
  /// issues for the provider's ID token, refreshed before it expires): the
  /// bearer for Presence's APIs and rbacr, e.g. exchanged for AWS
  /// credentials by `CloudSync`. Never a Google or Apple token. Null when
  /// signed out, or while a session restored at launch is being refreshed.
  String? get idToken;

  /// True while checking at launch whether a previous session can be
  /// restored silently (the app waits before choosing what to show).
  bool get checking;

  /// False when sign-in can't work here (e.g. no client ID configured);
  /// [unavailableReason] says why.
  bool get available;
  String? get unavailableReason;

  /// The last sign-in error, shown in the account sheet.
  String? get error;

  /// What [error] means, when the app knows it (shown translated); null
  /// for the provider's own errors, shown as they are.
  AuthProblem? get problem => null;

  /// Whether Sign in with Apple is offered here (iOS only).
  bool get appleAvailable;

  /// Sets up the provider and restores a previous session if possible.
  Future<void> init();

  /// Starts an interactive sign-in. Not used on web, where the provider's
  /// own button ([buildSignInButton]) signs in.
  Future<void> signIn();

  /// Starts Sign in with Apple ([appleAvailable] only).
  Future<void> signInWithApple();

  Future<void> signOut();

  /// The provider's own sign-in button, where the platform requires one
  /// (Google on web); null to use the app's button, which calls [signIn].
  Widget? buildSignInButton();
}

/// Sign-in problems the app explains itself, in the user's language.
enum AuthProblem {
  /// The auth API refused the provider's token.
  refused,

  /// The account has no verified email.
  noVerifiedEmail,

  /// The provider isn't set up on the server.
  notConfigured,

  /// The auth API couldn't be reached.
  unreachable,

  /// The session ended and can't be renewed quietly (Apple): sign in again.
  sessionEnded,
}
