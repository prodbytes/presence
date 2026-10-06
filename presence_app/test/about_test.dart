import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/about.dart';
import 'package:presence_app/auth/account_sheet.dart';
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

  final about = find.byKey(const Key('about'));

  for (final size in [const Size(320, 640), const Size(1280, 800)]) {
    testWidgets('no About button; the account sheet ends with what Presence '
        'is at ${size.width.toInt()} wide', (tester) async {
      await pumpApp(tester, auth: FakeAuthService.signedIn(), size: size);
      expect(find.byTooltip('About'), findsNothing);
      await tester.tap(find.byKey(const Key('account-button')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(about);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: about,
          matching: find.textContaining('always-on camera'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('is open source'), findsOneWidget);
      expect(find.text('github.com/prodbytes/presence'), findsOneWidget);
      // Nothing asks to become a member.
      expect(find.textContaining('member'), findsNothing);
      // It comes after Sign out.
      expect(
        tester.getTopLeft(about).dy,
        greaterThan(tester.getTopLeft(find.byKey(const Key('sign-out'))).dy),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('signed out: no About button', (tester) async {
    await pumpApp(tester, auth: FakeAuthService());
    expect(find.byTooltip('About'), findsNothing);
    expect(find.text('Presence'), findsNothing);
  });

  testWidgets('the link opens outside the app; one that can\'t is copied', (
    tester,
  ) async {
    final opened = <Uri>[];
    var opens = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountSheet(
            auth: FakeAuthService.signedIn(),
            openLink: (url) async {
              opened.add(url);
              return opens;
            },
          ),
        ),
      ),
    );
    final link = find.byKey(const Key('about-source'));
    await tester.ensureVisible(link);
    await tester.pumpAndSettle();
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(opened, [AboutParagraph.source]);
    expect(find.text('Link copied'), findsNothing);

    opens = false;
    await tester.tap(link);
    await tester.pumpAndSettle();
    expect(find.text('Link copied'), findsOneWidget);
  });
}
