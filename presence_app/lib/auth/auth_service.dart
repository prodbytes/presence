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

  /// Who is signed in, for tooltips: "Julio · julio@nu01.com".
  String get identity => label == email ? email : '$label · $email';
}

/// Signing in and out. The app owns one; the account sheet and the app bar
/// read it.
abstract class AuthService extends ChangeNotifier {
  /// The signed-in user, or null.
  AuthUser? get user;

  /// The signed-in user's OpenID Connect ID token (a JWT), exchanged with
  /// Cognito for AWS credentials by `CloudSync`. Null when signed out, or
  /// when the provider didn't return one.
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

  /// Sets up the provider and restores a previous session if possible.
  Future<void> init();

  /// Starts an interactive sign-in. Not used on web, where the provider's
  /// own button ([buildSignInButton]) signs in.
  Future<void> signIn();

  Future<void> signOut();

  /// The provider's own sign-in button, where the platform requires one
  /// (Google on web); null to use the app's button, which calls [signIn].
  Widget? buildSignInButton();
}
