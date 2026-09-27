import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:presence_app/auth/auth_service.dart';
import 'package:presence_app/auth/google_auth_service.dart';
import 'package:presence_app/auth/saved_session.dart';
import 'package:presence_app/auth/session_store.dart';

/// localStorage without a browser.
class MemorySessionStore extends SessionStore {
  MemorySessionStore([this.value]);

  String? value;

  @override
  String? load() => value;

  @override
  void save(String session) => value = session;

  @override
  void clear() => value = null;
}

/// An unsigned JWT with the given `exp` (enough for the expiry check).
String token(DateTime expiry) {
  String part(Map<String, Object?> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.'
      '${part({'exp': expiry.millisecondsSinceEpoch ~/ 1000, 'email': 'ana@example.com'})}.sig';
}

void main() {
  final now = DateTime.utc(2026, 9, 27, 12);
  const ana = AuthUser(id: '7', email: 'ana@example.com', name: 'Ana');

  group('SavedSession', () {
    test('round-trips while the token is valid', () {
      final json = SavedSession(
        user: ana,
        idToken: token(now.add(const Duration(minutes: 30))),
      ).encode();
      final back = SavedSession.decode(json, now: now)!;
      expect(back.user.email, 'ana@example.com');
      expect(back.user.name, 'Ana');
    });

    test('an expired or nearly expired token is not restored', () {
      for (final left in [
        const Duration(minutes: -5),
        const Duration(seconds: 30),
      ]) {
        final json = SavedSession(
          user: ana,
          idToken: token(now.add(left)),
        ).encode();
        expect(SavedSession.decode(json, now: now), isNull);
      }
    });

    test('malformed sessions are ignored', () {
      for (final bad in [
        null,
        '',
        'garbage',
        '{}',
        '{"id":"7","email":"a","idToken":"x.y"}',
      ]) {
        expect(SavedSession.decode(bad, now: now), isNull);
      }
    });
  });

  group('GoogleAuthService', () {
    // Without Google's plugin in tests, init() reports sign-in unavailable;
    // a remembered session is restored before that.
    test(
      'a remembered session is signed in at launch, after a reload',
      () async {
        final store = MemorySessionStore(
          SavedSession(
            user: ana,
            idToken: token(now.add(const Duration(minutes: 30))),
          ).encode(),
        );
        final auth = GoogleAuthService(store: store, now: () => now);
        await auth.init();
        expect(auth.user?.email, 'ana@example.com');
        expect(auth.idToken, isNotNull);
        expect(store.value, isNotNull);

        // Signing out forgets it, so the next reload starts signed out.
        await auth.signOut();
        expect(auth.user, isNull);
        expect(store.value, isNull);
      },
    );

    test('an expired remembered session is dropped', () async {
      final store = MemorySessionStore(
        SavedSession(
          user: ana,
          idToken: token(now.subtract(const Duration(minutes: 1))),
        ).encode(),
      );
      final auth = GoogleAuthService(store: store, now: () => now);
      await auth.init();
      expect(auth.user, isNull);
      expect(store.value, isNull);
    });
  });
}
