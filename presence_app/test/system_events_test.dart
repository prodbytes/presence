import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/cameras/cameras.dart';
import 'package:presence_app/main.dart';

import 'fakes.dart';

void main() {
  Future<void> pumpApp(
    WidgetTester tester, {
    CameraBackend? cameras,
    bool dev = false,
  }) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      PresenceApp(
        consentGiven: true,
        cameras: cameras ?? noCameras,
        mediaIo: fakeMediaIo,
        auth: dev ? FakeAuthService() : FakeAuthService.signedIn(),
        rolesClient: dev
            ? (FakeRolesClient()..mode = ExecutionMode.dev)
            : FakeRolesClient(),
        mapTiles: const SizedBox(),
        locator: NoLocation(),
      ),
    );
    await tester.pumpAndSettle();
    await settleStorage(tester);
  }

  Finder chip() => find.byKey(const Key('show-system-events'));
  bool checked(WidgetTester tester) =>
      tester.widget<FilterChip>(chip()).selected;
  Finder inEvents(Finder f) =>
      find.descendant(of: find.byKey(const Key('events-page')), matching: f);

  testWidgets('signed in (RBAC): only grabs, until system events are shown', (
    tester,
  ) async {
    await pumpApp(tester, cameras: openFakes([FakeCameraSource('Front door')]));
    await clipAndShowEvents(tester);

    expect(find.text('Show system events'), findsOneWidget);
    expect(checked(tester), isFalse);
    expect(inEvents(find.text('Clip requested')), findsOneWidget);
    expect(inEvents(find.text('Application started')), findsNothing);
    expect(inEvents(find.text('Signed in')), findsNothing);

    await tester.tap(chip());
    await tester.pumpAndSettle();
    expect(checked(tester), isTrue);
    expect(inEvents(find.text('Clip requested')), findsOneWidget);
    expect(inEvents(find.text('Application started')), findsOneWidget);

    // The choice stays while switching tabs.
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await showEvents(tester);
    expect(checked(tester), isTrue);
    expect(inEvents(find.text('Application started')), findsOneWidget);
  });

  testWidgets('with only system events hidden, it says so', (tester) async {
    await pumpApp(tester);
    await showEvents(tester);
    expect(checked(tester), isFalse);
    expect(find.text('No grabs yet: system events are hidden'), findsOneWidget);
  });

  testWidgets('in DEV, system events show by default', (tester) async {
    await pumpApp(tester, dev: true);
    await showEvents(tester);
    expect(checked(tester), isTrue);
    expect(inEvents(find.text('Application started')), findsOneWidget);

    await tester.tap(chip());
    await tester.pumpAndSettle();
    expect(inEvents(find.text('Application started')), findsNothing);
  });
}
