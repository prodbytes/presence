import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/main.dart';

import 'fakes.dart';

void main() {
  group('RolesService', () {
    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('signed out, then checking, then granted with a role', () async {
      final auth = FakeAuthService();
      final client = FakeRolesClient(['admin']);
      final roles = RolesService(auth: auth, client: client);
      expect(roles.state, AccessState.signedOut);

      final states = <AccessState>[];
      roles.addListener(() => states.add(roles.state));
      await auth.signIn();
      await settle();
      expect(states, [AccessState.checking, AccessState.granted]);
      expect(roles.roles, ['admin']);
      expect(roles.hasAccess, isTrue);
      expect(client.tokens, ['id-token-1']);

      await auth.signOut();
      expect(roles.state, AccessState.signedOut);
      expect(roles.hasAccess, isFalse);
    });

    test('no roles, or a failed check, denies access', () async {
      final auth = FakeAuthService.signedIn();
      final client = FakeRolesClient.none();
      final roles = RolesService(auth: auth, client: client);
      await settle();
      expect(roles.state, AccessState.denied);

      client
        ..roles = ['admin']
        ..error = RolesException(401);
      await roles.refresh();
      expect(roles.state, AccessState.denied);
      expect(roles.error, contains('401'));

      client.error = null;
      await roles.refresh();
      expect(roles.state, AccessState.granted);
    });
  });

  group('the app', () {
    Future<void> launch(WidgetTester tester, FakeRolesClient roles) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final camera = FakeCameraSource('Main');
      await tester.pumpWidget(
        PresenceApp(
          cameras: openFakes([camera]),
          auth: FakeAuthService.signedIn(),
          rolesClient: roles,
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('signed in without a role: only the account and sign-up', (
      tester,
    ) async {
      final roles = FakeRolesClient.none();
      await launch(tester, roles);

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

      // An administrator grants a role: checking again unlocks everything.
      roles.roles = ['viewer'];
      await tester.tap(find.byKey(const Key('check-access')));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byKey(const Key('sign-up-sheet'))))
          .pop();
      await tester.pumpAndSettle();
      expect(find.byType(TabBar), findsOneWidget);
      expect(find.byTooltip('Clip'), findsOneWidget);
      expect(find.byKey(const Key('sign-up')), findsNothing);
    });

    testWidgets('signed in with a role: everything', (tester) async {
      await launch(tester, FakeRolesClient(['admin']));
      expect(find.byType(TabBar), findsOneWidget);
      expect(find.byTooltip('Clip'), findsOneWidget);
      expect(find.byKey(const Key('sign-up')), findsNothing);
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
