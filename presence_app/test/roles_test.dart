import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:presence_app/auth/membership_client.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/main.dart';

import 'fakes.dart';

void main() {
  group('RolesService', () {
    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('signed out, then checking, then granted with a role', () async {
      final auth = FakeAuthService();
      final client = FakeRolesClient([userRole]);
      final roles = RolesService(auth: auth, client: client);
      expect(roles.state, AccessState.starting);
      await settle();
      expect(roles.state, AccessState.signedOut);
      expect(roles.mode, ExecutionMode.rbac);
      expect(roles.roles, [anonymousRole], reason: 'may only sign in');
      expect(roles.hasAccess, isFalse);

      final states = <AccessState>[];
      roles.addListener(() => states.add(roles.state));
      await auth.signIn();
      await settle();
      expect(states, [AccessState.checking, AccessState.granted]);
      expect(roles.roles, [userRole]);
      expect(roles.isAdmin, isFalse);
      expect(roles.hasAccess, isTrue);
      expect(client.tokens, ['id-token-1']);

      await auth.signOut();
      expect(roles.state, AccessState.signedOut);
      expect(roles.hasAccess, isFalse);
    });

    test('the profile comes with the roles, whatever they are', () async {
      final auth = FakeAuthService();
      final client = FakeRolesClient.none();
      final roles = RolesService(auth: auth, client: client);
      await settle();
      expect(roles.profile, isNull, reason: 'signed out');

      await auth.signIn();
      await settle();
      expect(roles.state, AccessState.denied);
      expect(roles.profile, 'automatic-paranoid-axolotl');

      client.error = Exception('down');
      await roles.refresh();
      expect(roles.profile, isNull, reason: 'a failed check');

      client.error = null;
      await roles.refresh();
      expect(roles.profile, 'automatic-paranoid-axolotl');
      await auth.signOut();
      expect(roles.profile, isNull);
    });

    test('HttpRolesClient reads the profile', () async {
      Future<UserAccess> answer(String body) => HttpRolesClient(
        Uri.parse('https://presence.test/'),
        client: MockClient((request) async {
          expect(request.url.path, '/api/auth');
          expect(request.headers['authorization'], 'Bearer t');
          return http.Response(body, 200);
        }),
      ).fetch('t');

      final ana = await answer(
        '{"email":"ana@example.com","profile":"automatic-paranoid-axolotl",'
        '"roles":["presence_user"]}',
      );
      expect(ana.roles, [userRole]);
      expect(ana.profile, 'automatic-paranoid-axolotl');
      // No subject, or an API from before profiles.
      final none = await answer('{"email":null,"profile":null,"roles":[]}');
      expect(none.roles, isEmpty);
      expect(none.profile, isNull);
      expect((await answer('{"email":"a@b.c","roles":[]}')).profile, isNull);
    });

    test('no roles, or a failed check, denies access', () async {
      final auth = FakeAuthService.signedIn();
      final client = FakeRolesClient.none();
      final roles = RolesService(auth: auth, client: client);
      await settle();
      expect(roles.state, AccessState.denied);

      client
        ..roles = [userRole]
        ..error = RolesException(401);
      await roles.refresh();
      expect(roles.state, AccessState.denied);
      expect(roles.error, contains('401'));

      client.error = null;
      await roles.refresh();
      expect(roles.state, AccessState.granted);
    });

    test('a failed check retries when the token is refreshed', () async {
      final auth = FakeAuthService.signedIn();
      final client = FakeRolesClient()..error = RolesException(502);
      final roles = RolesService(auth: auth, client: client);
      await settle();
      expect(roles.state, AccessState.denied);

      // The same token again doesn't retry; a new one does.
      client.error = null;
      auth.notify();
      await settle();
      expect(roles.state, AccessState.denied);
      auth.refreshToken();
      await settle();
      expect(roles.state, AccessState.granted);
      expect(client.tokens, ['id-token-1', 'id-token-1-r1']);
    });

    test('dev mode: the anonymous user gets every role', () async {
      final auth = FakeAuthService();
      final client = FakeRolesClient()..mode = ExecutionMode.dev;
      final roles = RolesService(auth: auth, client: client);
      await settle();
      expect(roles.mode, ExecutionMode.dev);
      expect(roles.state, AccessState.granted);
      expect(roles.roles, containsAll([anonymousRole, userRole, adminRole]));
      // Sign-in doesn't matter in dev mode.
      await auth.signIn();
      await roles.refresh();
      await settle();
      expect(client.tokens, isEmpty);
      expect(roles.state, AccessState.granted);
    });

    test('an unreachable API: dev without an OIDC client, else RBAC', () async {
      for (final (oidc, mode) in [
        (false, ExecutionMode.dev),
        (true, ExecutionMode.rbac),
      ]) {
        final client = FakeRolesClient()..anonymousError = RolesException(404);
        final roles = RolesService(
          auth: FakeAuthService(),
          client: client,
          oidcClient: oidc,
        );
        await settle();
        expect(roles.mode, mode, reason: 'oidc: $oidc');
        expect(roles.hasAccess, mode == ExecutionMode.dev);
      }
    });

    test('roles decide the navigation: none, member, admin', () async {
      for (final (granted, access, admin) in [
        (<String>[], false, false),
        (['viewer'], false, false),
        ([adminRole], false, false),
        ([userRole], true, false),
        ([userRole, adminRole], true, true),
      ]) {
        final roles = RolesService(
          auth: FakeAuthService.signedIn(),
          client: FakeRolesClient(granted),
        );
        await settle();
        expect(roles.hasAccess, access, reason: '$granted');
        expect(roles.isAdmin, admin, reason: '$granted');
      }
    });
  });

  group('the app', () {
    Future<void> launch(
      WidgetTester tester,
      FakeRolesClient roles, [
      FakeMembershipClient? membership,
    ]) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final camera = FakeCameraSource('Main');
      await tester.pumpWidget(
        PresenceApp(
          consentGiven: true,
          cameras: openFakes([camera]),
          auth: FakeAuthService.signedIn(),
          rolesClient: roles,
          membershipClient: membership ?? FakeMembershipClient(),
          mapTiles: const SizedBox(),
          locator: NoLocation(),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('signed in without a role: only the account and sign-up', (
      tester,
    ) async {
      final roles = FakeRolesClient.none();
      final membership = FakeMembershipClient();
      await launch(tester, roles, membership);

      expect(find.byType(TabBar), findsNothing);
      expect(find.byTooltip('Clip'), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byKey(const Key('account-button')), findsOneWidget);
      expect(find.byKey(const Key('sign-up')), findsOneWidget);
      expect(find.byKey(const Key('camera-page')), findsOneWidget);

      await tester.tap(find.byKey(const Key('sign-up')));
      await tester.pumpAndSettle();
      expect(find.text('Request access'), findsOneWidget);
      expect(find.textContaining('ana@example.com'), findsOneWidget);

      // Sending needs a message.
      final send = find.byKey(const Key('send-membership'));
      expect(tester.widget<FilledButton>(send).onPressed, isNull);
      await tester.enterText(
        find.byKey(const Key('membership-message')),
        '  I run the front desk  ',
      );
      await tester.pump();
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(membership.sent, ['I run the front desk']);
      expect(find.byKey(const Key('membership-sent')), findsOneWidget);

      // Another role isn't enough.
      roles.roles = ['viewer'];
      await tester.tap(find.byKey(const Key('check-access')));
      await tester.pumpAndSettle();
      expect(find.byType(TabBar), findsNothing);

      // An administrator grants presence_user: checking again unlocks
      // everything.
      roles.roles = [userRole];
      await tester.tap(find.byKey(const Key('check-access')));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byKey(const Key('sign-up-sheet'))))
          .pop();
      await tester.pumpAndSettle();
      expect(find.byType(TabBar), findsOneWidget);
      expect(find.byTooltip('Clip'), findsOneWidget);
      expect(find.byKey(const Key('sign-up')), findsNothing);
    });

    testWidgets('a repeated request says to wait', (tester) async {
      final membership = FakeMembershipClient()..error = RolesException(409);
      await launch(tester, FakeRolesClient.none(), membership);
      await tester.tap(find.byKey(const Key('sign-up')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('membership-message')),
        'again',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('send-membership')));
      await tester.pumpAndSettle();
      expect(find.textContaining('already sent a request'), findsOneWidget);
      expect(find.byKey(const Key('membership-sent')), findsNothing);
    });

    testWidgets('a presence_user: everything but Admin', (tester) async {
      await launch(tester, FakeRolesClient([userRole]));
      expect(find.byType(TabBar), findsOneWidget);
      expect(find.byTooltip('Clip'), findsOneWidget);
      expect(find.byKey(const Key('sign-up')), findsNothing);
      expect(find.byKey(const Key('admin')), findsNothing);
    });

    testWidgets('an admin without presence_user gets nothing', (tester) async {
      await launch(tester, FakeRolesClient([adminRole]));
      expect(find.byType(TabBar), findsNothing);
      expect(find.byKey(const Key('admin')), findsNothing);
      expect(find.byKey(const Key('sign-up')), findsOneWidget);
    });

    testWidgets('a presence_admin grants and dismisses requests', (
      tester,
    ) async {
      final membership = FakeMembershipClient()
        ..requests.addAll([
          MembershipRequest(
            email: 'bob@example.com',
            name: 'Bob',
            message: 'Night shift',
            requestedAt: DateTime.utc(2026, 9, 27),
          ),
          MembershipRequest(
            email: 'eve@example.com',
            name: '',
            message: 'hi',
            requestedAt: DateTime.utc(2026, 9, 27),
          ),
        ]);
      await launch(tester, FakeRolesClient([userRole, adminRole]), membership);
      expect(find.byType(TabBar), findsOneWidget);

      await tester.tap(find.byKey(const Key('admin')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('admin-screen')), findsOneWidget);
      expect(find.text('Night shift'), findsOneWidget);

      await tester.tap(find.byKey(const Key('grant-bob@example.com')));
      await tester.pumpAndSettle();
      expect(membership.granted, ['bob@example.com']);
      expect(find.text('Night shift'), findsNothing);
      expect(find.text('bob@example.com can now use Presence'), findsOneWidget);

      await tester.tap(find.byKey(const Key('dismiss-eve@example.com')));
      await tester.pumpAndSettle();
      expect(membership.granted, ['bob@example.com']);
      expect(membership.requests, isEmpty);
      expect(find.text('No pending requests.'), findsOneWidget);
    });

    testWidgets('a failed roles check shows only the account and sign-up', (
      tester,
    ) async {
      await launch(tester, FakeRolesClient()..error = RolesException(503));
      expect(find.byType(TabBar), findsNothing);
      expect(find.byKey(const Key('sign-up')), findsOneWidget);
    });
  });
}
