import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:idb_shim/idb_shim.dart';
import 'package:presence_app/auth/profile_client.dart';
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
    final changes = StreamController<void>.broadcast();
    final backend = FakeCloudBackend();
    final auth = FakeAuthService();
    await store.putEvent({
      'userId': '1',
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
          membershipClient: FakeMembershipClient(),
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
      expect(find.byType(TabBar), findsNothing);

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
      expect(find.byType(TabBar), findsOneWidget);
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
