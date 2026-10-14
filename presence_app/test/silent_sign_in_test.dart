import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:presence_app/auth/auth_service.dart';
import 'package:presence_app/auth/auth_session.dart';
import 'package:presence_app/auth/google_auth_service.dart';
import 'package:presence_app/auth/saved_session.dart';
import 'package:presence_app/auth/session_store.dart';
import 'package:presence_app/auth/silent_sign_in.dart';

import 'session_test.dart' show FakeSessionApi, presenceToken, settle, token;

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
  late FakeSessionApi api;
  late MemorySessionStore store;

  setUp(() {
    GoogleSignInPlatform.instance = google = FakeGooglePlatform();
    api = FakeSessionApi(() => now);
    store = MemorySessionStore();
  });

  GoogleAuthService service(
    SilentSignIn? silent, {
    Duration retryUnit = const Duration(minutes: 1),
  }) => GoogleAuthService(
    silent: silent,
    ids: ids,
    now: () => now,
    api: api,
    store: store,
    appleAvailable: false,
    retryUnit: retryUnit,
    exchangeDelays: const [Duration.zero, Duration.zero],
  );

  /// A Google session kept from before, whose token has [left].
  void keep(Duration left) => store.value = SavedSession(
    provider: SessionProvider.google,
    user: ana,
    token: presenceToken(now.add(left)),
    expiresAt: now.add(left),
    refreshToken: 'rt-0',
  ).encode();

  test('a remembered account signs back in silently, without the quiet '
      'check; its Google token is exchanged for a Presence session', () async {
    final fresh = token(now.add(const Duration(hours: 1)));
    final silent = FakeSilentSignIn(
      email: 'ana@example.com',
      results: [(user: ana, idToken: fresh)],
    );
    final auth = service(silent);
    await auth.init();
    await auth.stored;
    expect(silent.asked, ['ana@example.com']);
    expect(google.lightweight, 0);
    expect(api.exchanges.single['provider'], 'google');
    expect(api.exchanges.single['idToken'], fresh);
    expect(auth.user?.id, '7');
    expect(auth.user?.email, 'ana@example.com');
    expect(auth.idToken, isNot(fresh), reason: 'the Presence token');
    expect(SavedSession.decode(store.value)!.token, auth.idToken);
    expect(auth.checking, isFalse);
    expect(auth.error, isNull);
    auth.dispose();
  });

  test('a kept session needs no silent sign-in and no quiet check', () async {
    keep(const Duration(minutes: 30));
    final silent = FakeSilentSignIn(email: 'ana@example.com');
    final auth = service(silent);
    await auth.init();
    expect(auth.user?.email, 'ana@example.com');
    expect(silent.asked, isEmpty);
    expect(google.lightweight, 0);
    expect(api.exchanges, isEmpty);
    auth.dispose();
  });

  test('no remembered account: Google\'s quiet check, as before', () async {
    final silent = FakeSilentSignIn();
    final googleToken = token(now.add(const Duration(hours: 1)));
    google.lightweightResult = AuthenticationResults(
      user: const GoogleSignInUserData(email: 'ana@example.com', id: '7'),
      authenticationTokens: AuthenticationTokenData(idToken: googleToken),
    );
    final auth = service(silent);
    await auth.init();
    await settle();
    expect(silent.asked, isEmpty);
    expect(google.lightweight, 1);
    expect(api.exchanges.single['idToken'], googleToken);
    expect(auth.user?.email, 'ana@example.com');
    expect(auth.idToken, isNotNull);
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
    final auth = service(silent, retryUnit: const Duration(milliseconds: 5));
    await auth.init();
    expect(silent.asked, ['ana@example.com']);
    expect(auth.user, isNull);
    // 5 ms, then 10 ms later.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await settle();
    expect(silent.asked, hasLength(3));
    expect(api.exchanges.single['idToken'], fresh);
    expect(auth.idToken, isNotNull);
    expect(google.lightweight, 0);
    auth.dispose();
  });

  test('a silent sign-in whose exchange can\'t reach the API is retried '
      'quietly', () async {
    final silent = FakeSilentSignIn(
      email: 'ana@example.com',
      results: [
        (user: ana, idToken: token(now.add(const Duration(hours: 1)))),
        (user: ana, idToken: token(now.add(const Duration(hours: 1)))),
      ],
    );
    api.exchangeResults.addAll([
      const SessionUnavailable(),
      const SessionUnavailable(),
      const SessionUnavailable(),
    ]);
    final auth = service(silent, retryUnit: const Duration(milliseconds: 5));
    await auth.init();
    expect(auth.user, isNull);
    expect(auth.error, isNull, reason: 'quiet');
    expect(auth.silentFailures, 1);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await settle();
    expect(silent.asked, hasLength(2));
    expect(api.exchanges, hasLength(4));
    expect(auth.user?.email, 'ana@example.com');
    expect(auth.silentFailures, 0);
    expect(google.lightweight, 0);
    auth.dispose();
  });

  test('a silent sign-in whose token the API refuses shows the error and '
      'isn\'t retried', () async {
    final silent = FakeSilentSignIn(
      email: 'ana@example.com',
      results: [(user: ana, idToken: token(now.add(const Duration(hours: 1))))],
    );
    api.exchangeResults.add(const SessionRefused(401));
    final auth = service(silent, retryUnit: const Duration(milliseconds: 5));
    await auth.init();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(auth.user, isNull);
    expect(auth.problem, AuthProblem.refused);
    expect(silent.asked, hasLength(1));
    expect(api.exchanges, hasLength(1));
    expect(google.lightweight, 0);
    auth.dispose();
  });

  test('an account that must sign in again gets Google\'s check', () async {
    final silent = FakeSilentSignIn(
      email: 'ana@example.com',
      results: [const SilentSignInRequired('ana@example.com')],
    );
    final auth = service(silent);
    await auth.init();
    expect(silent.asked, ['ana@example.com']);
    expect(google.lightweight, 1);
    expect(auth.user, isNull);
    auth.dispose();
  });

  test('a dead refresh token falls back to the silent sign-in of the same '
      'account', () async {
    keep(const Duration(minutes: 2));
    api.refreshResults.add(const SessionRefused(401));
    final fresh = token(now.add(const Duration(hours: 1)));
    final silent = FakeSilentSignIn(
      email: 'ana@example.com',
      results: [(user: ana, idToken: fresh)],
    );
    final auth = service(silent);
    await auth.init();
    await settle();
    await auth.stored;
    expect(api.refreshes, ['rt-0']);
    expect(silent.asked, ['ana@example.com']);
    expect(api.exchanges.single['idToken'], fresh);
    expect(auth.user?.email, 'ana@example.com');
    expect(SavedSession.decode(store.value)!.refreshToken, 'rt-1');
    expect(google.lightweight, 0);
    auth.dispose();
  });

  test('a failed fallback keeps the session and retries quietly', () async {
    keep(const Duration(minutes: 2));
    api.refreshResults.add(const SessionRefused(401));
    final silent = FakeSilentSignIn(
      email: 'ana@example.com',
      // The silent sign-in fails twice (status 8), then works.
      results: [
        null,
        null,
        (user: ana, idToken: token(now.add(const Duration(hours: 1)))),
      ],
    );
    final auth = service(silent, retryUnit: const Duration(milliseconds: 5));
    await auth.init();
    await settle();
    expect(auth.user?.email, 'ana@example.com', reason: 'still signed in');
    expect(auth.idToken, isNotNull);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await settle();
    expect(silent.asked, hasLength(3));
    expect(api.exchanges, hasLength(1));
    expect(auth.user?.email, 'ana@example.com');
    expect(google.lightweight, 0);
    auth.dispose();
  });

  test('off Android, a dead refresh token gets Google\'s quiet check, whose '
      'token is exchanged', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    keep(const Duration(minutes: 2));
    api.refreshResults.add(const SessionRefused(401));
    final googleToken = token(now.add(const Duration(hours: 1)));
    google.lightweightResult = AuthenticationResults(
      user: const GoogleSignInUserData(email: 'ana@example.com', id: '7'),
      authenticationTokens: AuthenticationTokenData(idToken: googleToken),
    );
    final auth = service(null);
    await auth.init();
    await settle();
    expect(google.lightweight, 1);
    expect(api.exchanges.single['idToken'], googleToken);
    expect(auth.user?.email, 'ana@example.com');
    auth.dispose();
  });

  test('signing out starts the silent backoff over, and the log masks '
      'the email', () async {
    final printed = <String>[];
    final print = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add('$message');
    addTearDown(() => debugPrint = print);
    final silent = FakeSilentSignIn(email: 'ana@example.com');
    final auth = service(silent, retryUnit: const Duration(milliseconds: 5));
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

  test('signing out forgets the account and revokes the session', () async {
    final silent = FakeSilentSignIn(
      email: 'ana@example.com',
      results: [(user: ana, idToken: token(now.add(const Duration(hours: 1))))],
    );
    final auth = service(silent);
    await auth.init();
    expect(auth.user, isNotNull);
    await auth.signOut();
    await auth.stored;
    expect(auth.user, isNull);
    expect(silent.email, isNull);
    expect(store.value, isNull);
    expect(api.revoked, ['rt-1']);
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
