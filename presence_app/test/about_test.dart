import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/about.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/main.dart';

import 'fakes.dart';

void main() {
  Future<void> pumpApp(
    WidgetTester tester, {
    required FakeAuthService auth,
    FakeRolesClient? roles,
    Size size = const Size(400, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      PresenceApp(
        consentGiven: true,
        cameras: noCameras,
        mediaIo: fakeMediaIo,
        auth: auth,
        rolesClient: roles ?? FakeRolesClient(),
        membershipClient: FakeMembershipClient(),
        mapTiles: const SizedBox(),
        locator: NoLocation(),
      ),
    );
    await tester.pumpAndSettle();
    await settleStorage(tester);
  }

  Future<void> openAbout(WidgetTester tester) async {
    await tester.tap(find.byTooltip('About'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('about-page')), findsOneWidget);
  }

  Finder support = find.byKey(const Key('about-support'));

  testWidgets('signed out: About is there; it asks to sign in, then join', (
    tester,
  ) async {
    await pumpApp(tester, auth: FakeAuthService());
    await openAbout(tester);
    expect(
      find.textContaining('turns a phone, tablet or laptop'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('about-made-by')), findsOneWidget);
    expect(find.text('Support Presence'), findsOneWidget);
    expect(
      find.descendant(of: support, matching: find.text('Sign in with Google')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('about-become-member')), findsNothing);
    expect(find.text('Source code'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('signed in without access: Become a member opens the request', (
    tester,
  ) async {
    await pumpApp(
      tester,
      auth: FakeAuthService.signedIn(),
      roles: FakeRolesClient.none(),
    );
    await openAbout(tester);
    await tester.ensureVisible(find.byKey(const Key('about-become-member')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('about-become-member')));
    await tester.pumpAndSettle();
    expect(find.text('Request access'), findsOneWidget);
  });

  for (final size in [const Size(320, 640), const Size(1280, 800)]) {
    testWidgets('a member: About beside the tabs at ${size.width.toInt()} '
        'wide, and thanks', (tester) async {
      await pumpApp(tester, auth: FakeAuthService.signedIn(), size: size);
      expect(find.byTooltip('Settings'), findsOneWidget);
      await openAbout(tester);
      expect(find.text('Thank you for being a member'), findsOneWidget);
      expect(find.byKey(const Key('about-become-member')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a link opens outside the app; one that can\'t is copied', (
    tester,
  ) async {
    final opened = <Uri>[];
    var opens = true;
    final roles = RolesService(
      auth: FakeAuthService(),
      client: FakeRolesClient(),
    );
    addTearDown(roles.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AboutScreen(
          auth: FakeAuthService(),
          roles: roles,
          membership: FakeMembershipClient(),
          openLink: (url) async {
            opened.add(url);
            return opens;
          },
        ),
      ),
    );
    await tester.ensureVisible(find.text('Source code'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Source code'));
    await tester.pumpAndSettle();
    expect(opened, [AboutScreen.source]);
    expect(find.text('Link copied'), findsNothing);

    opens = false;
    await tester.tap(find.text('Source code'));
    await tester.pumpAndSettle();
    expect(find.text('Link copied'), findsOneWidget);
  });
}
