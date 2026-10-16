import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:presence_app/auth/account_sheet.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/auth/store_billing.dart';
import 'package:presence_app/l10n/gen/app_localizations.dart';

import 'fakes.dart';

/// The sign-up sheet of a signed-in user without access: Join free in the
/// iOS and Android apps (App Store 3.1.1, Play's payments policy), the
/// nu01.com link on the web and desktop.
void main() {
  late FakeAuthService auth;
  late FakeRolesClient client;
  late RolesService roles;

  setUp(() async {
    auth = FakeAuthService();
    client = FakeRolesClient.none();
    roles = RolesService(auth: auth, client: client);
    await auth.signIn();
  });

  tearDown(() => roles.dispose());

  Future<List<Uri>> show(
    WidgetTester tester, {
    Future<void> Function()? joinFree,
    Locale locale = const Locale('en'),
  }) async {
    final opened = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: SignUpSheet(
              auth: auth,
              roles: roles,
              rbacr: FakeRbacrClient(),
              joinFree: joinFree,
              openLink: (url) async {
                opened.add(url);
                return true;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return opened;
  }

  /// Every text on screen.
  String texts(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
      .join('\n');

  group('on iOS and Android', () {
    testWidgets('Join free, never nu01.com or Premium, in every language', (
      tester,
    ) async {
      for (final lang in ['en', 'es', 'pt']) {
        await show(tester, joinFree: () async {}, locale: Locale(lang));
        expect(find.byKey(const Key('join-free')), findsOneWidget);
        expect(find.byKey(const Key('subscribe')), findsNothing);
        final shown = texts(tester);
        expect(shown, isNot(contains('nu01.com')), reason: lang);
        expect(shown, isNot(contains('Premium')), reason: lang);
        expect(shown, contains('ana@example.com'), reason: lang);
        // The voucher code stays.
        expect(find.byKey(const Key('voucher-code')), findsOneWidget);
      }
    });

    testWidgets('joining checks the roles again: at once the user is in', (
      tester,
    ) async {
      var joined = 0;
      await show(
        tester,
        joinFree: () async {
          joined++;
          client.roles = [userRole];
        },
      );
      expect(find.text('Join free'), findsOneWidget);
      await tester.tap(find.byKey(const Key('join-free')));
      await tester.pumpAndSettle();
      expect(joined, 1);
      expect(roles.hasAccess, isTrue);
      expect(find.byKey(const Key('join-free-error')), findsNothing);
    });

    testWidgets('rbacr slow to see the grant: checked again 2 s later', (
      tester,
    ) async {
      var checks = 0;
      var joined = false;
      await show(tester, joinFree: () async => joined = true);
      roles.addListener(() {
        if (!joined) return;
        if (roles.state == AccessState.checking) checks++;
        // The first look after joining finds nothing; the grant shows on
        // the second.
        if (roles.state == AccessState.denied) client.roles = [userRole];
      });
      await tester.tap(find.byKey(const Key('join-free')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(roles.hasAccess, isFalse);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(checks, 2);
      expect(roles.hasAccess, isTrue);
    });

    testWidgets('a failure says so, and the button is back', (tester) async {
      await show(
        tester,
        joinFree: () async => throw const StoreVerifyException(502),
      );
      await tester.tap(find.byKey(const Key('join-free')));
      await tester.pumpAndSettle();
      expect(
        find.text("Couldn't join right now. Try again in a moment."),
        findsOneWidget,
      );
      expect(find.byKey(const Key('join-free')), findsOneWidget);
      expect(roles.hasAccess, isFalse);
    });
  });

  group('on the web and desktop', () {
    testWidgets('subscribe at nu01.com, as before', (tester) async {
      final opened = await show(tester);
      expect(find.byKey(const Key('join-free')), findsNothing);
      expect(find.text('Subscribe at nu01.com'), findsOneWidget);
      await tester.tap(find.byKey(const Key('subscribe')));
      await tester.pumpAndSettle();
      expect(opened.single.host, 'nu01.com');
    });
  });

  test('HttpStoreClient.joinFree posts with the session token', () async {
    final requests = <http.Request>[];
    var status = 200;
    final store = HttpStoreClient(
      Uri.parse('https://presence.example.com/app/'),
      client: MockClient((request) async {
        requests.add(request);
        return http.Response('{"member":true,"granted":true}', status);
      }),
    );
    await store.joinFree('session-token');
    expect(requests.single.method, 'POST');
    expect(
      requests.single.url.toString(),
      'https://presence.example.com/api/payments/free',
    );
    expect(requests.single.headers['authorization'], 'Bearer session-token');
    status = 503;
    expect(
      () => store.joinFree('session-token'),
      throwsA(isA<StoreVerifyException>()),
    );
  });
}
