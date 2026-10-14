import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

/// What Sign in with Apple gives: its identity token (for the auth API),
/// the authorization code, and the name, which Apple only gives at the
/// first sign-in.
typedef AppleCredential = ({
  String? identityToken,
  String authorizationCode,
  String? givenName,
  String? familyName,
});

/// Asks Apple for a credential whose identity token carries [nonce] (the
/// SHA-256 of the raw nonce); null when the user canceled.
typedef AppleSignIn = Future<AppleCredential?> Function({
  required String nonce,
});

/// Sign in with Apple is offered on iOS only: App Store guideline 4.8 asks
/// for it next to Google there; Android and web keep Google alone.
bool appleSignInSupported({
  required bool isWeb,
  required TargetPlatform platform,
}) => !isWeb && platform == TargetPlatform.iOS;

/// The native Sign in with Apple sheet (`sign_in_with_apple`), asking for
/// the email and the name.
Future<AppleCredential?> nativeAppleSignIn({required String nonce}) async {
  try {
    final c = await SignInWithApple.getAppleIDCredential(
      scopes: const [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
      nonce: nonce,
    );
    return (
      identityToken: c.identityToken,
      authorizationCode: c.authorizationCode,
      givenName: c.givenName,
      familyName: c.familyName,
    );
  } on SignInWithAppleAuthorizationException catch (e) {
    if (e.code == AuthorizationErrorCode.canceled) return null;
    rethrow;
  }
}

/// A fresh raw nonce: 32 random bytes, base64url.
String newNonce([Random? random]) {
  final r = random ?? Random.secure();
  return base64Url
      .encode(List<int>.generate(32, (_) => r.nextInt(256)))
      .replaceAll('=', '');
}

/// The hex SHA-256 of [raw], which Apple embeds in the identity token; the
/// auth API checks it against the raw nonce it's sent.
String sha256Hex(String raw) => sha256.convert(utf8.encode(raw)).toString();

/// "Given Family", or null when Apple gave neither.
String? appleFullName(String? givenName, String? familyName) {
  final name = [
    givenName?.trim(),
    familyName?.trim(),
  ].whereType<String>().where((s) => s.isNotEmpty).join(' ');
  return name.isEmpty ? null : name;
}
