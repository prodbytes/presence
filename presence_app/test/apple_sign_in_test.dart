import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presence_app/auth/account_sheet.dart';
import 'package:presence_app/auth/auth_service.dart';
import 'package:presence_app/auth/brand_buttons.dart';
import 'package:presence_app/auth/google_auth_service.dart';
import 'package:presence_app/auth/session_store.dart';
import 'package:presence_app/l10n/gen/app_localizations.dart';

import 'fakes.dart';
import 'session_test.dart' show FakeSessionApi;

Widget _app(Widget child, {ThemeData? theme}) => MaterialApp(
  theme: theme,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

/// The fill of the button under [key].
Color? _fill(WidgetTester tester, Key key) => tester
    .widget<Material>(
      find.descendant(of: find.byKey(key), matching: find.byType(Material)),
    )
    .color;

void main() {
  const apple = Key('apple-sign-in');
  const google = Key('google-sign-in');

  test('the service offers Apple on iOS only', () {
    GoogleAuthService service() => GoogleAuthService(
      store: MemorySessionStore(),
      api: FakeSessionApi(DateTime.now),
    );
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(service().appleAvailable, isTrue);
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(service().appleAvailable, isFalse, reason: '$platform');
    }
  });

  testWidgets('signed out on Android and web: Google alone', (tester) async {
    final auth = FakeAuthService();
    await tester.pumpWidget(_app(AccountSheet(auth: auth)));
    expect(find.byKey(google), findsOneWidget);
    expect(find.byKey(apple), findsNothing);
  });

  testWidgets('signed out on iOS: Apple and Google, the same size', (
    tester,
  ) async {
    final auth = FakeAuthService()..apple = true;
    await tester.pumpWidget(_app(AccountSheet(auth: auth)));
    expect(find.byKey(apple), findsOneWidget);
    expect(find.byKey(google), findsOneWidget);
    expect(find.text('Sign in with Apple'), findsOneWidget);
    final a = tester.getSize(find.byKey(apple));
    final g = tester.getSize(find.byKey(google));
    expect(a, g);
    expect(a.height, brandButtonHeight);
    // Apple's black and Google's white in light mode, each with its logo.
    expect(_fill(tester, apple), Colors.black);
    expect(_fill(tester, google), Colors.white);
    expect(
      find.descendant(
        of: find.byKey(apple),
        matching: find.byIcon(Icons.apple),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(google),
        matching: find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is GoogleLogoPainter,
        ),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(apple));
    await tester.pump();
    expect(auth.appleSignIns, 1);
    expect(auth.user, isNotNull);
  });

  testWidgets('Apple\'s button is white in dark mode, and translated', (
    tester,
  ) async {
    final auth = FakeAuthService()..apple = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: AccountSheet(auth: auth)),
      ),
    );
    await tester.pumpAndSettle();
    expect(_fill(tester, apple), Colors.white);
    expect(_fill(tester, google), const Color(0xFF131314));
    expect(find.text('Iniciar sesión con Apple'), findsOneWidget);
  });

  Widget appBar(AuthService auth) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      appBar: AppBar(
        title: const Text('Camera'),
        actions: [SignInAction(auth: auth)],
      ),
    ),
  );

  testWidgets('the app bar on Android and web: Sign in with Google', (
    tester,
  ) async {
    await tester.pumpWidget(appBar(FakeAuthService()));
    expect(find.byKey(google), findsOneWidget);
    expect(find.byKey(const Key('sign-in')), findsNothing);
  });

  testWidgets('the app bar on iOS: one Sign in, at 320 dp, opening both; '
      'the sheet closes once signed in', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final auth = FakeAuthService()..apple = true;
    await tester.pumpWidget(appBar(auth));
    expect(find.byKey(const Key('sign-in')), findsOneWidget);
    expect(find.byKey(google), findsNothing);
    expect(find.byKey(apple), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('sign-in')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sign-in-sheet')), findsOneWidget);
    expect(find.byKey(apple), findsOneWidget);
    expect(find.byKey(google), findsOneWidget);
    expect(
      tester.getSize(find.byKey(apple)),
      tester.getSize(find.byKey(google)),
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(apple));
    await tester.pumpAndSettle();
    expect(auth.appleSignIns, 1);
    expect(find.byKey(const Key('sign-in-sheet')), findsNothing);
  });

  test('the problems are shown translated', () {
    final en = lookupAppLocalizations(const Locale('en'));
    final auth = _ProblemAuth();
    expect(authErrorText(auth, en), isNull);
    auth.error = 'Google said no';
    expect(authErrorText(auth, en), 'Google said no');
    auth.problem = AuthProblem.sessionEnded;
    expect(authErrorText(auth, en), 'Your session ended. Sign in again.');
    auth.problem = AuthProblem.noVerifiedEmail;
    expect(
      authErrorText(auth, lookupAppLocalizations(const Locale('pt'))),
      'Esta conta não tem um e-mail verificado.',
    );
  });
}

class _ProblemAuth extends FakeAuthService {
  @override
  String? error;

  @override
  AuthProblem? problem;
}
