import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:presence_app/auth/apple_sign_in.dart';
import 'package:presence_app/auth/auth_service.dart';
import 'package:presence_app/auth/auth_session.dart';
import 'package:presence_app/auth/google_auth_service.dart';
import 'package:presence_app/auth/saved_session.dart';
import 'package:presence_app/auth/session_store.dart';
import 'package:presence_app/auth/silent_sign_in.dart';

String _part(Map<String, Object?> m) =>
    base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');

/// An unsigned JWT with the given `exp` (a provider's ID token, enough for
/// the tests).
String token(DateTime expiry) =>
    '${_part({'alg': 'none'})}.'
    '${_part({'exp': expiry.millisecondsSinceEpoch ~/ 1000, 'email': 'ana@example.com'})}.sig';

/// An unsigned Presence session token, with the claims the app reads.
String presenceToken(
  DateTime expiry, {
  int serial = 0,
  String sub = '7',
  String email = 'ana@example.com',
  String? name = 'Ana',
  String idp = 'https://accounts.google.com',
}) =>
    '${_part({'alg': 'RS256'})}.'
    '${_part({'iss': 'https://presence.nu01.com', 'aud': 'presence', 'sub': 'presence-subject', 'exp': expiry.millisecondsSinceEpoch ~/ 1000, 'email': email, 'email_verified': true, 'name': ?name, 'idp': idp, 'idp_sub': sub, 'jti': serial})}.sig';

/// The auth API's session routes, in memory.
class FakeSessionApi implements SessionApi {
  FakeSessionApi(this.now, {this.name = 'Ana', this.idp = 'google'});

  final DateTime Function() now;
  final String? name;
  final String idp;

  /// Every exchange's arguments, in order.
  final exchanges = <Map<String, Object?>>[];

  /// The refresh tokens refreshed, in order.
  final refreshes = <String>[];

  /// The refresh tokens revoked.
  final revoked = <String>[];

  /// What each exchange or refresh gives, in turn: a [SessionGrant] or an
  /// exception to throw. When empty, a fresh grant.
  final exchangeResults = <Object>[];
  final refreshResults = <Object>[];

  int _serial = 0;

  /// A new session, lasting [lifetime] from [now].
  SessionGrant grant([Duration lifetime = const Duration(hours: 1)]) {
    final serial = ++_serial;
    final expiry = now().add(lifetime);
    return SessionGrant(
      token: presenceToken(
        expiry,
        serial: serial,
        name: name,
        idp: idp == 'apple'
            ? 'https://appleid.apple.com'
            : 'https://accounts.google.com',
      ),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        expiry.millisecondsSinceEpoch ~/ 1000 * 1000,
        isUtc: true,
      ),
      refreshToken: 'rt-$serial',
    );
  }

  Future<SessionGrant> _next(List<Object> results) async {
    await Future<void>.delayed(Duration.zero);
    final result = results.isEmpty ? grant() : results.removeAt(0);
    if (result is SessionGrant) return result;
    throw result;
  }

  @override
  Future<SessionGrant> exchange({
    required SessionProvider provider,
    required String idToken,
    String? nonce,
    String? authorizationCode,
    String? name,
  }) {
    exchanges.add({
      'provider': provider.name,
      'idToken': idToken,
      'nonce': nonce,
      'authorizationCode': authorizationCode,
      'name': name,
    });
    return _next(exchangeResults);
  }

  @override
  Future<SessionGrant> refresh(String refreshToken) {
    refreshes.add(refreshToken);
    return _next(refreshResults);
  }

  @override
  Future<void> revoke(String refreshToken) async => revoked.add(refreshToken);
}

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  final now = DateTime.utc(2026, 9, 27, 12);
  const ana = AuthUser(id: '7', email: 'ana@example.com', name: 'Ana');

  SavedSession saved({
    Duration left = const Duration(minutes: 30),
    SessionProvider provider = SessionProvider.google,
    String refreshToken = 'rt-0',
  }) => SavedSession(
    provider: provider,
    user: ana,
    token: presenceToken(now.add(left)),
    expiresAt: now.add(left),
    refreshToken: refreshToken,
  );

  group('SavedSession', () {
    test('round-trips', () {
      final back = SavedSession.decode(saved().encode())!;
      expect(back.provider, SessionProvider.google);
      expect(back.user.email, 'ana@example.com');
      expect(back.user.name, 'Ana');
      expect(back.refreshToken, 'rt-0');
      expect(back.expiresAt, now.add(const Duration(minutes: 30)));
      expect(
        SavedSession.decode(saved(provider: SessionProvider.apple).encode())!
            .provider,
        SessionProvider.apple,
      );
    });

    test('valid while more than a minute is left', () {
      expect(saved().validAt(now), isTrue);
      expect(saved(left: const Duration(seconds: 30)).validAt(now), isFalse);
      expect(saved(left: const Duration(minutes: -5)).validAt(now), isFalse);
    });

    test('refreshed five minutes before it expires', () {
      expect(saved().refreshIn(now), const Duration(minutes: 25));
      expect(
        saved(left: const Duration(minutes: 2)).refreshIn(now),
        Duration.zero,
      );
    });

    test('malformed sessions, and the old Google-token format, are '
        'ignored', () {
      for (final bad in [
        null,
        '',
        'garbage',
        '{}',
        // Kept by the version before Presence sessions.
        '{"id":"7","email":"a","idToken":"x.y.z"}',
        '{"provider":"github","token":"a.b.c","expiresAt":1,'
            '"refreshToken":"r","user":{"id":"7","email":"a"}}',
        '{"provider":"google","token":"a.b.c","expiresAt":1,'
            '"refreshToken":"","user":{"id":"7","email":"a"}}',
      ]) {
        expect(SavedSession.decode(bad), isNull, reason: '$bad');
      }
    });

    test('the user is read from the Presence token\'s claims', () {
      final user = SavedSession.userOf(
        presenceToken(now, sub: 'apple-sub', email: 'b@example.com'),
      )!;
      expect(user.id, 'apple-sub');
      expect(user.email, 'b@example.com');
      expect(user.name, 'Ana');
      expect(SavedSession.userOf('x.y'), isNull);
      expect(SavedSession.userOf(token(now)), isNull, reason: 'no idp_sub');
      expect(SavedSession.tokenExpiry(token(now)), now);
    });
  });

  group('HttpSessionApi', () {
    final base = Uri.parse('https://api.example.com/');

    String grantBody(String refresh) => jsonEncode({
      'token': presenceToken(now),
      'expiresAt': now.millisecondsSinceEpoch ~/ 1000,
      'refreshToken': refresh,
    });

    test('exchanges an Apple token with its nonce, code and name', () async {
      late http.Request sent;
      final api = HttpSessionApi(
        base,
        client: MockClient((request) async {
          sent = request;
          return http.Response(grantBody('r1'), 200);
        }),
      );
      final grant = await api.exchange(
        provider: SessionProvider.apple,
        idToken: 'apple.id.token',
        nonce: 'raw-nonce',
        authorizationCode: 'code',
        name: ' Ana Silva ',
      );
      expect(sent.method, 'POST');
      expect(sent.url.toString(), 'https://api.example.com/api/auth/session');
      expect(sent.headers['content-type'], startsWith('application/json'));
      expect(jsonDecode(sent.body), {
        'provider': 'apple',
        'idToken': 'apple.id.token',
        'nonce': 'raw-nonce',
        'authorizationCode': 'code',
        'name': 'Ana Silva',
      });
      expect(grant.refreshToken, 'r1');
      expect(grant.expiresAt, now);
    });

    test('a Google exchange sends only the provider and token', () async {
      late http.Request sent;
      final api = HttpSessionApi(
        base,
        client: MockClient((request) async {
          sent = request;
          return http.Response(grantBody('r1'), 200);
        }),
      );
      await api.exchange(provider: SessionProvider.google, idToken: 'g.t.k');
      expect(jsonDecode(sent.body), {'provider': 'google', 'idToken': 'g.t.k'});
    });

    test('refresh and revoke post the refresh token', () async {
      final sent = <http.Request>[];
      final api = HttpSessionApi(
        base,
        client: MockClient((request) async {
          sent.add(request);
          return request.url.path.endsWith('revoke')
              ? http.Response('', 204)
              : http.Response(grantBody('r2'), 200);
        }),
      );
      expect((await api.refresh('r1')).refreshToken, 'r2');
      await api.revoke('r2');
      expect(sent.map((r) => r.url.path), [
        '/api/auth/session/refresh',
        '/api/auth/session/revoke',
      ]);
      expect(jsonDecode(sent[0].body), {'refreshToken': 'r1'});
      expect(jsonDecode(sent[1].body), {'refreshToken': 'r2'});
    });

    test('400, 401 and 403 are refused; 429, 5xx, no answer and a '
        'malformed reply are worth retrying', () async {
      for (final status in [400, 401, 403]) {
        final api = HttpSessionApi(
          base,
          client: MockClient(
            (_) async => http.Response('{"error":"nope"}', status),
          ),
        );
        await expectLater(
          api.refresh('r'),
          throwsA(
            isA<SessionRefused>()
                .having((e) => e.status, 'status', status)
                .having((e) => e.reason, 'reason', 'nope'),
          ),
        );
      }
      for (final reply in [
        http.Response('{"error":"slow down"}', 429),
        http.Response('', 500),
        http.Response('{"error":"apple not configured"}', 503),
        http.Response('{"token":"x"}', 200),
      ]) {
        final api = HttpSessionApi(
          base,
          client: MockClient((_) async => reply),
        );
        await expectLater(api.refresh('r'), throwsA(isA<SessionUnavailable>()));
      }
      final offline = HttpSessionApi(
        base,
        client: MockClient((_) async => throw http.ClientException('down')),
      );
      await expectLater(
        offline.exchange(provider: SessionProvider.google, idToken: 't'),
        throwsA(isA<SessionUnavailable>()),
      );
      // Revoking never throws.
      await offline.revoke('r');
    });

    test('quick retries only while the API can\'t be reached', () async {
      var calls = 0;
      expect(
        await withSessionRetries(() async {
          if (++calls < 3) throw const SessionUnavailable(status: 502);
          return 'ok';
        }, delays: const [Duration.zero, Duration.zero]),
        'ok',
      );
      expect(calls, 3);
      calls = 0;
      await expectLater(
        withSessionRetries(() async {
          calls++;
          throw const SessionRefused(401);
        }, delays: const [Duration.zero, Duration.zero]),
        throwsA(isA<SessionRefused>()),
      );
      expect(calls, 1);
      calls = 0;
      await expectLater(
        withSessionRetries(() async {
          calls++;
          throw const SessionUnavailable();
        }, delays: const [Duration.zero, Duration.zero]),
        throwsA(isA<SessionUnavailable>()),
      );
      expect(calls, 3);
    });
  });

  group('Sign in with Apple helpers', () {
    test('offered on iOS only', () {
      for (final platform in TargetPlatform.values) {
        expect(
          appleSignInSupported(isWeb: false, platform: platform),
          platform == TargetPlatform.iOS,
        );
        expect(appleSignInSupported(isWeb: true, platform: platform), isFalse);
      }
    });

    test('the nonce is 32 random bytes, base64url; Apple gets its '
        'SHA-256', () {
      final nonce = newNonce();
      expect(nonce, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      expect(newNonce(), isNot(nonce));
      expect(
        sha256Hex('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('the full name', () {
      expect(appleFullName(' Ana ', 'Silva'), 'Ana Silva');
      expect(appleFullName('Ana', null), 'Ana');
      expect(appleFullName(null, ' '), isNull);
    });
  });

  group('GoogleAuthService sessions', () {
    // No Google client ID in tests: Google's library isn't started, so
    // only the kept session and Apple sign in.
    const noGoogle = (clientId: null, serverClientId: null);
    late FakeSessionApi api;
    late MemorySessionStore store;

    setUp(() {
      api = FakeSessionApi(() => now);
      store = MemorySessionStore();
    });

    GoogleAuthService service({
      DateTime Function()? clock,
      AppleSignIn? apple,
      bool appleAvailable = false,
    }) => GoogleAuthService(
      store: store,
      api: api,
      now: clock ?? () => now,
      ids: noGoogle,
      silent: _NoSilentSignIn(),
      apple: apple,
      appleAvailable: appleAvailable,
      retryUnit: const Duration(milliseconds: 5),
      exchangeDelays: const [Duration.zero, Duration.zero],
    );

    test('a kept session is signed in at launch, without asking the '
        'API; signing out revokes and forgets it', () async {
      final kept = saved();
      store.value = kept.encode();
      final auth = service();
      await auth.init();
      expect(auth.user?.email, 'ana@example.com');
      expect(auth.idToken, kept.token);
      expect(api.refreshes, isEmpty);

      await auth.signOut();
      await auth.stored;
      expect(auth.user, isNull);
      expect(auth.idToken, isNull);
      expect(store.value, isNull);
      expect(api.revoked, ['rt-0']);
      auth.dispose();
    });

    test('an expired kept token is refreshed at launch; the new refresh '
        'token replaces the old one', () async {
      store.value = saved(left: const Duration(minutes: -10)).encode();
      final auth = service();
      await auth.init();
      await auth.stored;
      expect(api.refreshes, ['rt-0']);
      expect(auth.user?.email, 'ana@example.com');
      expect(auth.idToken, isNotNull);
      expect(SavedSession.decode(store.value)!.refreshToken, 'rt-1');
      expect(SavedSession.decode(store.value)!.token, auth.idToken);
      auth.dispose();
    });

    test(
      'an expired kept session whose refresh is refused is dropped',
      () async {
        store.value = saved(left: const Duration(minutes: -10)).encode();
        api.refreshResults.add(const SessionRefused(401));
        final auth = service();
        await auth.init();
        await auth.stored;
        expect(auth.user, isNull);
        expect(auth.idToken, isNull);
        expect(store.value, isNull);
        expect(auth.problem, isNull, reason: 'Google: just signed out');
        auth.dispose();
      },
    );

    test('a malformed or old-format kept session is dropped', () async {
      store.value = '{"id":"7","email":"a","idToken":"x.y.z"}';
      final auth = service();
      await auth.init();
      await auth.stored;
      expect(auth.user, isNull);
      expect(store.value, isNull);
      expect(api.refreshes, isEmpty);
      auth.dispose();
    });

    test('a refresh at launch that fails this time keeps the user without '
        'a token, and retries with the backoff', () async {
      store.value = saved(left: const Duration(minutes: -10)).encode();
      api.refreshResults.addAll([
        const SessionUnavailable(),
        const SessionUnavailable(status: 503),
      ]);
      final auth = service();
      await auth.init();
      expect(auth.user?.email, 'ana@example.com');
      expect(auth.idToken, isNull);
      expect(auth.refreshFailures, 1);
      // 5 ms, then 10 ms later.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await settle();
      expect(api.refreshes, ['rt-0', 'rt-0', 'rt-0']);
      expect(auth.idToken, isNotNull);
      expect(auth.refreshFailures, 0);
      expect(auth.user?.email, 'ana@example.com');
      auth.dispose();
    });

    test('refreshed before it expires, rotating the refresh token: an old '
        'one is never sent again', () async {
      // Expires in two minutes: refreshed at once. Each new session also
      // expires within the lead, until the last.
      store.value = saved(left: const Duration(minutes: 2)).encode();
      api.refreshResults.addAll([
        api.grant(const Duration(minutes: 2)),
        api.grant(const Duration(minutes: 2)),
        api.grant(),
      ]);
      final auth = service();
      await auth.init();
      await settle();
      await auth.stored;
      expect(api.refreshes, ['rt-0', 'rt-1', 'rt-2']);
      expect(api.refreshes.toSet(), hasLength(api.refreshes.length));
      expect(SavedSession.decode(store.value)!.refreshToken, 'rt-3');
      expect(auth.idToken, SavedSession.decode(store.value)!.token);
      auth.dispose();
    });

    test('a refresh that fails this time keeps the session and retries '
        'quietly', () async {
      final kept = saved(left: const Duration(minutes: 2));
      store.value = kept.encode();
      api.refreshResults.addAll([
        const SessionUnavailable(status: 429),
        const SessionUnavailable(),
      ]);
      final auth = service();
      final tokens = <String?>[];
      auth.addListener(() => tokens.add(auth.idToken));
      await auth.init();
      await settle();
      expect(auth.user?.email, 'ana@example.com', reason: 'still signed in');
      expect(auth.idToken, kept.token);
      expect(auth.error, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await settle();
      expect(api.refreshes, hasLength(3));
      expect(auth.idToken, isNot(kept.token));
      expect(tokens, isNot(contains(null)), reason: 'never signed out');
      auth.dispose();
    });

    test('an Apple session whose refresh is refused signs out and says the '
        'session ended', () async {
      store.value = saved(
        left: const Duration(minutes: 2),
        provider: SessionProvider.apple,
      ).encode();
      api.refreshResults.add(const SessionRefused(401));
      final auth = service();
      await auth.init();
      await settle();
      await auth.stored;
      expect(auth.user, isNull);
      expect(auth.idToken, isNull);
      expect(auth.problem, AuthProblem.sessionEnded);
      expect(store.value, isNull);
      auth.dispose();
    });

    test('an expired Apple session refused at launch says so too', () async {
      store.value = saved(
        left: const Duration(minutes: -2),
        provider: SessionProvider.apple,
      ).encode();
      api.refreshResults.add(const SessionRefused(401));
      final auth = service();
      await auth.init();
      expect(auth.user, isNull);
      expect(auth.problem, AuthProblem.sessionEnded);
      auth.dispose();
    });

    test('Sign in with Apple: the raw nonce, the code and the name go to '
        'the exchange; Apple gets the nonce\'s SHA-256', () async {
      api = FakeSessionApi(() => now, idp: 'apple');
      final hashed = <String>[];
      final auth = service(
        appleAvailable: true,
        apple: ({required nonce}) async {
          hashed.add(nonce);
          return (
            identityToken: 'apple.id.token',
            authorizationCode: 'auth-code',
            givenName: 'Ana',
            familyName: 'Silva',
          );
        },
      );
      await auth.init();
      expect(auth.appleAvailable, isTrue);
      await auth.signInWithApple();
      await auth.stored;
      expect(api.exchanges, hasLength(1));
      final sent = api.exchanges.single;
      expect(sent['provider'], 'apple');
      expect(sent['idToken'], 'apple.id.token');
      expect(sent['authorizationCode'], 'auth-code');
      expect(sent['name'], 'Ana Silva');
      expect(sha256Hex(sent['nonce']! as String), hashed.single);
      expect(auth.user?.id, '7');
      expect(auth.user?.email, 'ana@example.com');
      expect(auth.idToken, isNotNull);
      final kept = SavedSession.decode(store.value)!;
      expect(kept.provider, SessionProvider.apple);
      expect(kept.refreshToken, 'rt-1');
      auth.dispose();
    });

    test('canceling Sign in with Apple is not an error; off iOS it does '
        'nothing', () async {
      var asked = 0;
      Future<AppleCredential?> cancel({required String nonce}) async {
        asked++;
        return null;
      }

      final auth = service(appleAvailable: true, apple: cancel);
      await auth.init();
      await auth.signInWithApple();
      expect(auth.error, isNull);
      expect(auth.user, isNull);
      expect(api.exchanges, isEmpty);
      auth.dispose();

      final android = service(apple: cancel);
      expect(android.appleAvailable, isFalse);
      await android.signInWithApple();
      expect(asked, 1);
      android.dispose();
    });

    test('a refused exchange shows the error and signs nobody in', () async {
      Future<AppleCredential?> apple({required String nonce}) async => (
        identityToken: 'apple.id.token',
        authorizationCode: 'c',
        givenName: null,
        familyName: null,
      );
      final auth = service(appleAvailable: true, apple: apple);
      await auth.init();
      api.exchangeResults.add(const SessionRefused(403, 'no verified email'));
      await auth.signInWithApple();
      expect(auth.user, isNull);
      expect(auth.idToken, isNull);
      expect(auth.problem, AuthProblem.noVerifiedEmail);
      expect(auth.error, contains('403'));
      expect(api.exchanges.single['name'], isNull);

      api.exchangeResults.add(const SessionRefused(401));
      await auth.signInWithApple();
      expect(auth.problem, AuthProblem.refused);
      expect(api.exchanges, hasLength(2), reason: 'refused: not retried');
      auth.dispose();
    });

    test('an exchange that can\'t reach the API is retried quickly', () async {
      Future<AppleCredential?> apple({required String nonce}) async => (
        identityToken: 'apple.id.token',
        authorizationCode: 'c',
        givenName: null,
        familyName: null,
      );
      final auth = service(appleAvailable: true, apple: apple);
      await auth.init();
      api.exchangeResults.addAll([
        const SessionUnavailable(status: 502),
        const SessionUnavailable(),
      ]);
      await auth.signInWithApple();
      expect(api.exchanges, hasLength(3));
      expect(auth.user, isNotNull);
      expect(auth.error, isNull);

      // Three failures: shown.
      await auth.signOut();
      api.exchangeResults.addAll([
        const SessionUnavailable(status: 503),
        const SessionUnavailable(status: 503),
        const SessionUnavailable(status: 503),
      ]);
      await auth.signInWithApple();
      expect(auth.user, isNull);
      expect(auth.problem, AuthProblem.notConfigured);
      auth.dispose();
    });

    test(
      'a refresh that answers after sign-out is revoked, not adopted',
      () async {
        store.value = saved(left: const Duration(minutes: 2)).encode();
        final auth = service();
        await auth.init();
        // The refresh (at once) is under way: sign out before it answers.
        await Future<void>.delayed(Duration.zero);
        expect(api.refreshes, ['rt-0']);
        await auth.signOut();
        await settle();
        await auth.stored;
        expect(auth.user, isNull);
        expect(store.value, isNull);
        expect(api.refreshes, ['rt-0']);
        expect(api.revoked, containsAll(['rt-0', 'rt-1']));
        auth.dispose();
      },
    );

    test('the log has no tokens', () async {
      final printed = <String>[];
      final print = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add('$message');
      addTearDown(() => debugPrint = print);
      final kept = saved(left: const Duration(minutes: 2));
      store.value = kept.encode();
      api.refreshResults.addAll([
        const SessionUnavailable(status: 500),
        const SessionRefused(401, 'reused'),
      ]);
      final auth = service();
      await auth.init();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await settle();
      final log = printed.join('\n');
      expect(log, isNotEmpty);
      expect(log, isNot(contains(kept.token)));
      expect(log, isNot(contains('rt-0')));
      expect(log, isNot(contains('ana@example.com')));
      auth.dispose();
    });
  });
}

/// No remembered Android account (and no platform channel in tests).
class _NoSilentSignIn implements SilentSignIn {
  @override
  Future<String?> remembered() async => null;

  @override
  Future<void> remember(String email) async {}

  @override
  Future<void> forget() async {}

  @override
  Future<SilentAccount?> signIn({
    required String email,
    required String serverClientId,
  }) async => null;
}
