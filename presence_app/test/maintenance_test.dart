import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/home/home_navigation_bar.dart';
import 'package:presence_app/main.dart';

import 'fakes.dart';

void main() {
  final sorry = find.byKey(const Key('maintenance'));

  Future<void> open(
    WidgetTester tester,
    FakeRolesClient roles, {
    FakeAuthService? auth,
  }) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      PresenceApp(
        consentGiven: true,
        cameras: openFakes([FakeCameraSource('Main')]),
        auth: auth ?? FakeAuthService.signedIn(),
        rolesClient: roles,
        rbacrClient: FakeRbacrClient(),
        mapTiles: const SizedBox(),
        locator: NoLocation(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a member sees only the sorry message, not "no access"', (
    tester,
  ) async {
    // rbacr gives nobody roles in maintenance: the sorry message wins.
    final roles = FakeRolesClient()..inMaintenance = true;
    await open(tester, roles);
    expect(sorry, findsOneWidget);
    expect(find.text('Sorry, Presence is down for maintenance.'), findsOne);
    expect(find.byType(HomeNavigationBar), findsNothing);
    expect(find.byType(HomeScreen), findsNothing);
    expect(find.byKey(const Key('sign-up')), findsNothing);
    expect(roles.maintenanceTokens.first, startsWith('id-token-'));
  });

  testWidgets('admins and roots don\'t get past it either', (tester) async {
    await open(
      tester,
      FakeRolesClient([userRole, premiumRole, adminRole, rootRole])
        ..inMaintenance = true,
    );
    expect(sorry, findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });

  testWidgets('signed out, rbacr can\'t be asked: the app shows', (
    tester,
  ) async {
    final roles = FakeRolesClient()..inMaintenance = true;
    await open(tester, roles, auth: FakeAuthService());
    expect(sorry, findsNothing);
    expect(roles.maintenanceTokens, isEmpty);
  });

  testWidgets('rbacr not answering keeps the app (deny by roles only)', (
    tester,
  ) async {
    final roles = FakeRolesClient()..maintenanceError = Exception('down');
    await open(tester, roles);
    expect(sorry, findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('a running app follows rbacr within a minute, and gets its '
      'roles back after', (tester) async {
    final roles = FakeRolesClient();
    await open(tester, roles);
    expect(sorry, findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);

    roles.inMaintenance = true;
    await tester.pump(const Duration(minutes: 1));
    await tester.pump();
    expect(sorry, findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);

    // A check of the roles meanwhile gets none from rbacr.
    final checks = roles.tokens.length;
    roles.inMaintenance = false;
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(sorry, findsNothing);
    expect(roles.tokens.length, greaterThan(checks), reason: 'roles again');
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byKey(const Key('sign-up')), findsNothing);
  });
}
