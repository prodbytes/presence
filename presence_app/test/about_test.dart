import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/about.dart';
import 'package:presence_app/auth/account_sheet.dart';
import 'package:presence_app/consent/consent_screen.dart';
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
        rbacrClient: FakeRbacrClient(),
        mapTiles: const SizedBox(),
        locator: NoLocation(),
      ),
    );
    await tester.pumpAndSettle();
    await settleStorage(tester);
  }

  final about = find.byKey(const Key('about'));

  for (final size in [const Size(320, 640)]) {
    testWidgets('no About button; the account sheet ends with what Presence '
        'is at ${size.width.toInt()} wide', (tester) async {
      await pumpApp(tester, auth: FakeAuthService.signedIn(), size: size);
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
      expect(
        find.descendant(
          of: about,
          matching: find.textContaining('Raspberry Pi'),
        ),
        findsOneWidget,
      );
      expect(find.text('Presence is open source:'), findsOneWidget);
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

  group('Privacy Policy and Terms of Service', () {
    test('are the API site\'s /privacy and /tos', () {
      expect(LegalPages.privacy.path, '/privacy');
      expect(LegalPages.terms.path, '/tos');
      // Android and iOS tests: production, unless API_BASE_URL says.
      expect(LegalPages.privacy.origin, LegalPages.terms.origin);
      expect(LegalPages.privacy.scheme, anyOf('https', 'http'));
    });

    Future<void> tapOpens(WidgetTester tester, List<Uri> opened) async {
      for (final (key, url) in [
        ('legal-privacy', LegalPages.privacy),
        ('legal-terms', LegalPages.terms),
      ]) {
        final link = find.byKey(Key(key));
        if (find.byType(Scrollable).evaluate().isNotEmpty) {
          await tester.scrollUntilVisible(
            link,
            100,
            scrollable: find.byType(Scrollable).first,
          );
        }
        await tester.pumpAndSettle();
        await tester.tap(link);
        await tester.pumpAndSettle();
        expect(opened.last, url);
      }
      expect(opened, hasLength(2));
    }

    testWidgets('signed in: the account sheet\'s About links to both', (
      tester,
    ) async {
      final opened = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccountSheet(
              auth: FakeAuthService.signedIn(),
              openLink: (url) async {
                opened.add(url);
                return true;
              },
            ),
          ),
        ),
      );
      expect(
        find.descendant(of: about, matching: find.text('Privacy Policy')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: about, matching: find.text('Terms of Service')),
        findsOneWidget,
      );
      await tapOpens(tester, opened);
    });

    testWidgets('on the consent screen, under I agree', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final opened = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          home: ConsentScreen(
            onAgree: () async {},
            openLink: (url) async {
              opened.add(url);
              return true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tapOpens(tester, opened);
      expect(
        tester.getTopLeft(find.byKey(const Key('legal-links'))).dy,
        greaterThan(
          tester.getTopLeft(find.byKey(const Key('consent-agree'))).dy,
        ),
      );
    });

    testWidgets('signed out: at the bottom of the camera, at 360 wide', (
      tester,
    ) async {
      await pumpApp(
        tester,
        auth: FakeAuthService(),
        size: const Size(360, 640),
      );
      expect(find.byKey(const Key('google-sign-in')), findsOneWidget);
      final links = find.byKey(const Key('legal-links'));
      expect(links, findsOneWidget);
      expect(find.text('Privacy Policy'), findsOneWidget);
      expect(find.text('Terms of Service'), findsOneWidget);
      expect(tester.getBottomLeft(links).dy, greaterThan(560));
    });

    testWidgets('signed in with access: not over the camera (the Profile '
        'tab has them)', (tester) async {
      await pumpApp(tester, auth: FakeAuthService.signedIn());
      expect(find.byKey(const Key('legal-links')), findsNothing);
    });

    testWidgets('signed out, the links open outside the app', (tester) async {
      final opened = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            children: [
              SignedOutLegalLinks(
                openLink: (url) async {
                  opened.add(url);
                  return true;
                },
              ),
            ],
          ),
        ),
      );
      await tapOpens(tester, opened);
    });
  });
}
