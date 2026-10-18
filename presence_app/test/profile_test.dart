import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:idb_shim/idb_shim.dart';
import 'package:presence_app/auth/profile_client.dart';
import 'package:presence_app/home/home_navigation_bar.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/cloud/cloud_sync.dart';
import 'package:presence_app/cloud/cognito.dart';
import 'package:presence_app/main.dart';
import 'package:presence_app/storage/event_store.dart';
import 'package:presence_app/storage/media_store.dart';

import 'fakes.dart';

void main() {
  group('CognitoCredentials', () {
    final api = Uri.parse('https://presence.example/');

    test('takes the credentials the local auth API answers, without '
        'Cognito', () async {
      final calls = <http.Request>[];
      final cognito = CognitoCredentials(
        region: 'us-east-1',
        api: api,
        now: () => DateTime.utc(2026, 10, 11),
        client: MockClient((request) async {
          calls.add(request);
          return http.Response(
            jsonEncode({
              'identityId': 'us-east-1:local',
              'token': 'local',
              'credentials': {
                'AccessKeyId': 'ASIALOCALX',
                'SecretKey': 'secret',
                'SessionToken': 'session',
                'Expiration': 4102444800,
              },
            }),
            200,
          );
        }),
      );
      final session = await cognito.session('google-token');
      expect(session.identityId, 'us-east-1:local');
      expect(session.credentials.accessKeyId, 'ASIALOCALX');
      expect(session.credentials.sessionToken, 'session');
      expect(session.credentials.expiration, DateTime.utc(2100));
      // Only the auth API: Floci has no Cognito Identity.
      expect(calls.map((r) => r.url.host), ['presence.example']);
    });

    test(
      'trades the profile token from the auth API for credentials',
      () async {
        final calls = <http.Request>[];
        final client = MockClient((request) async {
          calls.add(request);
          if (request.url.host == 'presence.example') {
            return http.Response(
              jsonEncode({'identityId': 'us-east-1:profile', 'token': 'oidc'}),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'IdentityId': 'us-east-1:profile',
              'Credentials': {
                'AccessKeyId': 'AKIA',
                'SecretKey': 'secret',
                'SessionToken': 'session',
                'Expiration': 4102444800,
              },
            }),
            200,
          );
        });
        final cognito = CognitoCredentials(
          region: 'us-east-1',
          api: api,
          client: client,
          now: () => DateTime.utc(2026, 10, 4),
        );

        final session = await cognito.session('google-token');
        expect(session.identityId, 'us-east-1:profile');
        expect(session.credentials.accessKeyId, 'AKIA');
        expect(
          calls.first.url.toString(),
          'https://presence.example/api/auth/credentials',
        );
        expect(calls.first.method, 'POST');
        expect(calls.first.headers['authorization'], 'Bearer google-token');
        expect(calls[1].url.host, 'cognito-identity.us-east-1.amazonaws.com');
        expect(
          calls[1].headers['x-amz-target'],
          'AWSCognitoIdentityService.GetCredentialsForIdentity',
        );
        expect(jsonDecode(calls[1].body), {
          'IdentityId': 'us-east-1:profile',
          'Logins': {'cognito-identity.amazonaws.com': 'oidc'},
        });

        // Reused until it expires or the token changes.
        await cognito.session('google-token');
        expect(calls, hasLength(2));
      },
    );

    group('kept per account', () {
      /// A session token as the auth API issues it (unsigned here: the
      /// cache only reads it).
      String tokenOf(String sub, {int iat = 1, String iss = 'https://p.x'}) {
        String part(Object json) =>
            base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
        return '${part({'alg': 'RS256'})}.'
            '${part({'iss': iss, 'sub': sub, 'iat': iat})}.c2ln';
      }

      late List<String> bearers;
      late DateTime clock;
      var expiration = 4102444800;

      CognitoCredentials make() {
        bearers = [];
        clock = DateTime.utc(2026, 10, 18, 12);
        return CognitoCredentials(
          region: 'us-east-1',
          api: api,
          now: () => clock,
          client: MockClient((request) async {
            bearers.add(request.headers['authorization']!);
            final n = bearers.length;
            return http.Response(
              jsonEncode({
                'identityId': 'us-east-1:p',
                'token': 'local',
                'credentials': {
                  'AccessKeyId': 'AKIA$n',
                  'SecretKey': 'secret',
                  'Expiration': expiration,
                },
              }),
              200,
            );
          }),
        );
      }

      setUp(() => expiration = 4102444800);

      test('a refreshed session token of the same account reuses the '
          'credentials', () async {
        final cognito = make();
        final a = await cognito.session(tokenOf('p_a', iat: 1));
        final b = await cognito.session(tokenOf('p_a', iat: 3600));
        expect(identical(a, b), isTrue);
        expect(bearers, hasLength(1));
      });

      test('another account, or another issuer, never gets them', () async {
        final cognito = make();
        await cognito.session(tokenOf('p_a'));
        final other = await cognito.session(tokenOf('p_b'));
        expect(other.credentials.accessKeyId, 'AKIA2');
        expect(bearers.last, 'Bearer ${tokenOf('p_b')}');
        final rc = await cognito.session(tokenOf('p_b', iss: 'https://rc.x'));
        expect(rc.credentials.accessKeyId, 'AKIA3');
        // Not JWTs: per token, as before.
        await cognito.session('opaque-1');
        await cognito.session('opaque-1');
        await cognito.session('opaque-2');
        expect(bearers, hasLength(5));
      });

      test('credentials expiring soon are fetched again, with the token '
          'given', () async {
        final cognito = make();
        expiration =
            clock.add(const Duration(minutes: 30)).millisecondsSinceEpoch ~/
            1000;
        await cognito.session(tokenOf('p_a', iat: 1));
        clock = clock.add(const Duration(minutes: 20));
        await cognito.session(tokenOf('p_a', iat: 2));
        expect(bearers, hasLength(1));
        clock = clock.add(const Duration(minutes: 6));
        final renewed = await cognito.session(tokenOf('p_a', iat: 3));
        expect(renewed.credentials.accessKeyId, 'AKIA2');
        expect(bearers.last, 'Bearer ${tokenOf('p_a', iat: 3)}');
      });

      test('clear (sign-out, another profile, a change of plan: a new tier '
          'tag) fetches again', () async {
        final cognito = make();
        await cognito.session(tokenOf('p_a'));
        cognito.clear();
        final again = await cognito.session(tokenOf('p_a', iat: 2));
        expect(again.credentials.accessKeyId, 'AKIA2');
        expect(bearers, hasLength(2));
      });

      test('credentials without an expiry are kept for their own token '
          'only', () async {
        bearers = [];
        final noExpiry = CognitoCredentials(
          region: 'us-east-1',
          api: api,
          client: MockClient((request) async {
            bearers.add(request.headers['authorization']!);
            return http.Response(
              jsonEncode({
                'identityId': 'us-east-1:p',
                'token': 'local',
                'credentials': {'AccessKeyId': 'AKIA', 'SecretKey': 's'},
              }),
              200,
            );
          }),
        );
        await noExpiry.session(tokenOf('p_a', iat: 1));
        await noExpiry.session(tokenOf('p_a', iat: 1));
        await noExpiry.session(tokenOf('p_a', iat: 2));
        expect(bearers, hasLength(2));
      });

      test('reads the account from the token\'s issuer and subject', () {
        expect(
          CognitoCredentials.accountOf(tokenOf('p_a', iat: 1)),
          CognitoCredentials.accountOf(tokenOf('p_a', iat: 2)),
        );
        expect(
          CognitoCredentials.accountOf(tokenOf('p_a')),
          isNot(CognitoCredentials.accountOf(tokenOf('p_b'))),
        );
        expect(CognitoCredentials.accountOf('a.b.c'), 'token:a.b.c');
        expect(CognitoCredentials.accountOf('x'), 'token:x');
      });
    });

    test('callers asking at once share one fetch; one cleared meanwhile '
        'isn\'t kept', () async {
      var authCalls = 0;
      final gate = Completer<void>();
      final cognito = CognitoCredentials(
        region: 'us-east-1',
        api: api,
        now: () => DateTime.utc(2026, 10, 4),
        client: MockClient((request) async {
          if (request.url.host == 'presence.example') {
            authCalls++;
            await gate.future;
            return http.Response(
              jsonEncode({'identityId': 'us-east-1:p', 'token': 'oidc'}),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'IdentityId': 'us-east-1:p',
              'Credentials': {
                'AccessKeyId': 'AKIA$authCalls',
                'SecretKey': 'secret',
                'Expiration': 4102444800,
              },
            }),
            200,
          );
        }),
      );
      final a = cognito.session('t');
      final b = cognito.session('t');
      await Future<void>.delayed(Duration.zero);
      expect(authCalls, 1);
      // Signed out meanwhile: what comes back isn't kept.
      cognito.clear();
      gate.complete();
      expect((await a).credentials.accessKeyId, 'AKIA1');
      expect(identical(await a, await b), isTrue);
      final c = await cognito.session('t');
      expect(authCalls, 2, reason: 'fetched again after the clear');
      expect(c.credentials.accessKeyId, 'AKIA2');
      await cognito.session('t');
      expect(authCalls, 2, reason: 'kept this time');
    });

    test(
      'a rejected Google token needs a new sign-in; no access does not',
      () async {
        var status = 401;
        final cognito = CognitoCredentials(
          region: 'us-east-1',
          api: api,
          client: MockClient(
            (_) async => http.Response('{"error":"nope"}', status),
          ),
        );
        await expectLater(
          cognito.session('t'),
          throwsA(
            isA<CognitoException>().having(
              (e) => e.needsSignIn,
              'sign in',
              true,
            ),
          ),
        );
        status = 403;
        await expectLater(
          cognito.session('t'),
          throwsA(
            isA<CognitoException>()
                .having((e) => e.needsSignIn, 'sign in', false)
                .having((e) => e.message, 'message', 'nope'),
          ),
        );
      },
    );

    test('a failed auth API says what failed and where to look', () async {
      final cognito = CognitoCredentials(
        region: 'us-east-1',
        api: api,
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': 'the profile service failed',
              'cause': 'CognitoIdentity AccessDeniedException (HTTP 400)',
              'requestId': 'req-1',
            }),
            502,
          ),
        ),
      );
      await expectLater(
        cognito.session('t'),
        throwsA(
          isA<CognitoException>().having(
            (e) => '$e',
            'log line',
            'Cognito HTTP 502 from /api/auth/credentials: the profile service '
                'failed (cause: CognitoIdentity AccessDeniedException '
                '(HTTP 400); request req-1)',
          ),
        ),
      );
    });

    test('a body that is not JSON is quoted', () async {
      final cognito = CognitoCredentials(
        region: 'us-east-1',
        api: api,
        client: MockClient(
          (_) async => http.Response('Internal Server Error', 502),
        ),
      );
      await expectLater(
        cognito.session('t'),
        throwsA(
          isA<CognitoException>().having(
            (e) => e.detail,
            'detail',
            'body: Internal Server Error',
          ),
        ),
      );
    });
  });

  test('reconnect uploads to the new folder after a link', () async {
    final store = await EventStore.open(newIdbFactoryMemory());
    final changes = StreamController<Set<String>?>.broadcast();
    final backend = FakeCloudBackend();
    final auth = FakeAuthService();
    await store.putEvent({
      'userId': '1',
      'profileId': '1',
      'id': 'e1',
      'type': 'appStarted',
      'title': 'Application started',
      'time': 1,
    });
    final sync = CloudSync(
      auth: auth,
      backend: backend,
      store: Future.value(store),
      media: Future.value(IdbMediaStore(store)),
      changes: changes.stream,
      debounce: Duration.zero,
    );
    addTearDown(() {
      sync.dispose();
      changes.close();
      store.close();
    });
    await auth.signIn();
    await sync.idle();
    expect(backend.uploads.keys, {
      'us-east-1:identity/events/year=1970/day=001/e1.json',
    });

    final resets = backend.resets;
    backend.prefix = 'us-east-1:profile';
    sync.reconnect();
    await sync.idle();
    expect(backend.resets, resets + 1);
    expect(
      backend.uploads.keys,
      contains('us-east-1:profile/events/year=1970/day=001/e1.json'),
    );
    expect(
      backend.listings.where((l) => l == 'events/'),
      hasLength(2),
      reason: 'the first pass for the new folder lists all events',
    );
  });

  group('linked accounts', () {
    Future<void> launch(
      WidgetTester tester,
      FakeRolesClient roles,
      FakeProfileClient profiles,
    ) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        PresenceApp(
          consentGiven: true,
          cameras: openFakes([FakeCameraSource('Main')]),
          auth: FakeAuthService.signedIn(),
          rolesClient: roles,
          rbacrClient: FakeRbacrClient(),
          profileClient: profiles,
          mapTiles: const SizedBox(),
          locator: NoLocation(),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('an account without access links to a member with a code', (
      tester,
    ) async {
      final roles = FakeRolesClient.none();
      final profiles = FakeProfileClient();
      await launch(tester, roles, profiles);
      expect(find.byType(HomeNavigationBar), findsNothing);

      await tester.tap(find.byKey(const Key('sign-up')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('linked-accounts')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('linked-ana@example.com')), findsOneWidget);
      // Without access there's no code to make, only one to enter.
      expect(find.byKey(const Key('make-link-code')), findsNothing);
      final use = find.byKey(const Key('use-link-code'));
      expect(tester.widget<OutlinedButton>(use).onPressed, isNull);

      await tester.enterText(
        find.byKey(const Key('link-code-field')),
        ' abcd-efgh ',
      );
      await tester.pump();
      // The member's roles come with the link.
      roles.roles = [userRole];
      await tester.tap(use);
      await tester.pumpAndSettle();
      expect(profiles.linked, ['abcd-efgh']);
      expect(find.text('Linked to ana@nu01.com.'), findsOneWidget);
      expect(find.byKey(const Key('linked-ana@nu01.com')), findsOneWidget);
      expect(find.byKey(const Key('unlink-ana@example.com')), findsOneWidget);
      expect(find.byKey(const Key('unlink-ana@nu01.com')), findsNothing);

      Navigator.of(
        tester.element(find.byKey(const Key('linked-accounts-sheet'))),
      ).pop();
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byKey(const Key('sign-up-sheet'))))
          .pop();
      await tester.pumpAndSettle();
      expect(find.byType(HomeNavigationBar), findsOneWidget);
    });

    testWidgets('a member makes a code and unlinks an account', (tester) async {
      final profiles = FakeProfileClient([
        const ProfileAccount(
          email: 'ana@example.com',
          owner: true,
          current: true,
        ),
        const ProfileAccount(
          email: 'ana@gmail.com',
          owner: false,
          current: false,
        ),
      ]);
      await launch(tester, FakeRolesClient([userRole]), profiles);

      await tester.tap(find.byKey(const Key('account-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('linked-accounts')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('make-link-code')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SelectableText>(find.byKey(const Key('link-code'))).data,
        'ABCD-EFGH',
      );
      expect(profiles.codes, hasLength(1));

      await tester.tap(find.byKey(const Key('unlink-ana@gmail.com')));
      await tester.pumpAndSettle();
      expect(profiles.unlinked, ['ana@gmail.com']);
      expect(find.byKey(const Key('linked-ana@gmail.com')), findsNothing);
      expect(find.text('ana@gmail.com was unlinked.'), findsOneWidget);
    });

    testWidgets('a refused link says why', (tester) async {
      final profiles = FakeProfileClient()..error = RolesException(409);
      await launch(tester, FakeRolesClient([userRole]), profiles);
      await tester.tap(find.byKey(const Key('account-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('linked-accounts')));
      await tester.pumpAndSettle();
      expect(find.textContaining('cloud data of its own'), findsOneWidget);
    });
  });
}
