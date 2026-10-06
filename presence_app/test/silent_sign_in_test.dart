import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:presence_app/auth/auth_service.dart';
import 'package:presence_app/auth/google_auth_service.dart';
import 'package:presence_app/auth/silent_sign_in.dart';

import 'session_test.dart' show token;

/// Google's library, without Google: counts the quiet checks.
class FakeGooglePlatform extends GoogleSignInPlatform {
  int lightweight = 0;
  AuthenticationResults? lightweightResult;

  @override
  Future<void> init(InitParameters params) async {}

  @override
  Future<AuthenticationResults?> attemptLightweightAuthentication(
    AttemptLightweightAuthenticationParameters params,
  ) async {
    lightweight++;
    return lightweightResult;
  }

  @override
  bool supportsAuthenticate() => true;

  @override
  Future<AuthenticationResults> authenticate(AuthenticateParameters params) =>
      throw UnimplementedError();

  @override
  bool authorizationRequiresUserInteraction() => false;

  @override
  Future<ClientAuthorizationTokenData?> clientAuthorizationTokensForScopes(
    ClientAuthorizationTokensForScopesParameters params,
  ) async => null;

  @override
  Future<ServerAuthorizationTokenData?> serverAuthorizationTokensForScopes(
    ServerAuthorizationTokensForScopesParameters params,
  ) async => null;

  @override
  Future<void> signOut(SignOutParams params) async {}

  @override
  Future<void> disconnect(DisconnectParams params) async {}
}

/// The native silent sign-in, in memory.
class FakeSilentSignIn implements SilentSignIn {
  FakeSilentSignIn({this.email, List<Object?>? results})
    : results = results ?? [];

  String? email;

  /// What each sign-in gives, in turn: an account, null (a failure worth
  /// retrying) or a [SilentSignInRequired] to throw.
  final List<Object?> results;
  final List<String> asked = [];

  @override
  Future<String?> remembered() async => email;

  @override
  Future<void> remember(String email) async => this.email = email;

  @override
  Future<void> forget() async => email = null;

  @override
  Future<SilentAccount?> signIn({
    required String email,
    required String serverClientId,
  }) async {
    asked.add(email);
    final result = results.isEmpty ? null : results.removeAt(0);
    if (result is SilentSignInRequired) throw result;
    return result as SilentAccount?;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 6, 12);
  const ana = AuthUser(id: '7', email: 'ana@example.com', name: 'Ana');
  const ids = (clientId: null, serverClientId: 'web-client');
  late FakeGooglePlatform google;

  setUp(() => GoogleSignInPlatform.instance = google = FakeGooglePlatform());

  Future<void> settle() async {
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test(
    'a remembered account signs back in silently, without the quiet check',
    () async {
      final fresh = token(now.add(const Duration(hours: 1)));
      final silent = FakeSilentSignIn(
        email: 'ana@example.com',
        results: [(user: ana, idToken: fresh)],
      );
      final auth = GoogleAuthService(silent: silent, ids: ids, now: () => now);
      await auth.init();
      expect(silent.asked, ['ana@example.com']);
      expect(google.lightweight, 0);
      expect(auth.user?.id, '7');
      expect(auth.user?.email, 'ana@example.com');
      expect(auth.idToken, fresh);
      expect(auth.checking, isFalse);
      expect(auth.error, isNull);
      auth.dispose();
    },
  );

  test('no remembered account: Google\'s quiet check, as before', () async {
    final silent = FakeSilentSignIn();
    google.lightweightResult = AuthenticationResults(
      user: const GoogleSignInUserData(email: 'ana@example.com', id: '7'),
      authenticationTokens: AuthenticationTokenData(
        idToken: token(now.add(const Duration(hours: 1))),
      ),
    );
    final auth = GoogleAuthService(silent: silent, ids: ids, now: () => now);
    await auth.init();
    await settle();
    expect(silent.asked, isEmpty);
    expect(google.lightweight, 1);
    expect(auth.user?.email, 'ana@example.com');
    // Signed in: remembered for the next restart.
    expect(silent.email, 'ana@example.com');
    auth.dispose();
  });

  test('a failed silent sign-in at launch is retried quietly, never with '
      'the chooser', () async {
    final fresh = token(now.add(const Duration(hours: 1)));
    final silent = FakeSilentSignIn(
      email: 'ana@example.com',
      results: [null, null, (user: ana, idToken: fresh)],
    );
    final auth = GoogleAuthService(
      silent: silent,
      ids: ids,
      now: () => now,
      retryUnit: const Duration(milliseconds: 5),
    );
    await auth.init();
    expect(silent.asked, ['ana@example.com']);
    expect(auth.user, isNull);
    // 5 ms, then 10 ms later.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await settle();
    expect(silent.asked, hasLength(3));
    expect(auth.idToken, fresh);
    expect(google.lightweight, 0);
    auth.dispose();
  });

  test('an account that must sign in again gets Google\'s check', () async {
    final silent = FakeSilentSignIn(
      email: 'ana@example.com',
      results: [const SilentSignInRequired('ana@example.com')],
    );
    final auth = GoogleAuthService(silent: silent, ids: ids, now: () => now);
    await auth.init();
    expect(silent.asked, ['ana@example.com']);
    expect(google.lightweight, 1);
    expect(auth.user, isNull);
    auth.dispose();
  });

  test('a failed refresh keeps the session and retries quietly', () async {
    final old = token(now.add(const Duration(minutes: 2)));
    final fresh = token(now.add(const Duration(hours: 1)));
    final silent = FakeSilentSignIn(
      email: 'ana@example.com',
      // Launch, then the refresh fails twice (status 8), then works.
      results: [
        (user: ana, idToken: old),
        null,
        null,
        (user: ana, idToken: fresh),
      ],
    );
    final auth = GoogleAuthService(
      silent: silent,
      ids: ids,
      now: () => now,
      retryUnit: const Duration(milliseconds: 5),
    );
    await auth.init();
    await settle();
    expect(auth.user?.email, 'ana@example.com', reason: 'still signed in');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await settle();
    expect(silent.asked, hasLength(4));
    expect(auth.idToken, fresh);
    expect(google.lightweight, 0);
    auth.dispose();
  });

  test('signing out starts the silent backoff over, and the log masks '
      'the email', () async {
    final printed = <String>[];
    final print = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add('$message');
    addTearDown(() => debugPrint = print);
    final silent = FakeSilentSignIn(email: 'ana@example.com');
    final auth = GoogleAuthService(
      silent: silent,
      ids: ids,
      now: () => now,
      retryUnit: const Duration(milliseconds: 5),
    );
    await auth.init();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await settle();
    expect(auth.silentFailures, greaterThanOrEqualTo(2));
    await auth.signOut();
    expect(auth.silentFailures, 0);
    expect(printed, isNotEmpty);
    expect(printed.join('\n'), isNot(contains('ana@example.com')));
    expect(printed.join('\n'), contains('a***@example.com'));
    auth.dispose();
  });

  test('signing out forgets the account', () async {
    final silent = FakeSilentSignIn(
      email: 'ana@example.com',
      results: [(user: ana, idToken: token(now.add(const Duration(hours: 1))))],
    );
    final auth = GoogleAuthService(silent: silent, ids: ids, now: () => now);
    await auth.init();
    expect(auth.user, isNotNull);
    await auth.signOut();
    expect(auth.user, isNull);
    expect(silent.email, isNull);
    auth.dispose();
  });

  test('the token is refreshed silently, for the same account', () async {
    // Expires in two minutes: refreshed at once.
    final old = token(now.add(const Duration(minutes: 2)));
    final fresh = token(now.add(const Duration(hours: 1)));
    final silent = FakeSilentSignIn(
      email: 'ana@example.com',
      results: [(user: ana, idToken: old), (user: ana, idToken: fresh)],
    );
    final auth = GoogleAuthService(silent: silent, ids: ids, now: () => now);
    await auth.init();
    await settle();
    expect(silent.asked, ['ana@example.com', 'ana@example.com']);
    expect(auth.idToken, fresh);
    expect(google.lightweight, 0);
    auth.dispose();
  });

  test('the same cached token back is retried later, not at once', () async {
    final old = token(now.add(const Duration(minutes: 2)));
    final silent = FakeSilentSignIn(
      email: 'ana@example.com',
      results: [
        (user: ana, idToken: old),
        (user: ana, idToken: old),
        (user: ana, idToken: old),
      ],
    );
    final auth = GoogleAuthService(silent: silent, ids: ids, now: () => now);
    await auth.init();
    await settle();
    expect(silent.asked, hasLength(2));
    expect(google.lightweight, 0);
    auth.dispose();
  });

  group('NativeSilentSignIn', () {
    const channel = MethodChannel('presence/device');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('signs in through the app\'s channel', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'silentGoogleSignIn' => {
            'id': '7',
            'email': 'ana@example.com',
            'displayName': 'Ana',
            'photoUrl': null,
            'idToken': 'a.b.c',
          },
          'googleAccount' => 'ana@example.com',
          _ => null,
        };
      });
      const native = NativeSilentSignIn(serverClientId: 'web-client');
      expect(await native.remembered(), 'ana@example.com');
      final account = await native.signIn(
        email: 'ana@example.com',
        serverClientId: 'web-client',
      );
      expect(account?.user.id, '7');
      expect(account?.user.name, 'Ana');
      expect(account?.idToken, 'a.b.c');
      await native.forget();
      expect(calls.last.method, 'forgetGoogleAccount');
      expect(calls.last.arguments, {'serverClientId': 'web-client'});
    });

    test('a failure or a missing channel is no account', () async {
      const native = NativeSilentSignIn();
      expect(await native.remembered(), isNull);
      expect(await native.signIn(email: 'a@b.c', serverClientId: 'x'), isNull);
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => throw PlatformException(code: 'x'),
      );
      expect(await native.signIn(email: 'a@b.c', serverClientId: 'x'), isNull);
    });

    test('SIGN_IN_REQUIRED from the channel throws; other failures are '
        'null', () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => {'failure': '4'},
      );
      const native = NativeSilentSignIn();
      await expectLater(
        native.signIn(email: 'a@b.c', serverClientId: 'x'),
        throwsA(isA<SilentSignInRequired>()),
      );
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => {'failure': '8'},
      );
      expect(await native.signIn(email: 'a@b.c', serverClientId: 'x'), isNull);
    });

    test('an incomplete reply is no account', () {
      expect(NativeSilentSignIn.parse({'id': '7', 'email': 'a'}), isNull);
      expect(
        NativeSilentSignIn.parse({'id': '7', 'email': 'a', 'idToken': ''}),
        isNull,
      );
    });
  });
}
