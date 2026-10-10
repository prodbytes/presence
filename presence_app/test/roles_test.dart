import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:presence_app/app_log.dart';
import 'package:presence_app/auth/admin_screen.dart';
import 'package:presence_app/home/home_navigation_bar.dart';
import 'package:presence_app/auth/rbacr_client.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/feedback/feedback_client.dart';
import 'package:presence_app/main.dart';
import 'package:presence_app/tab_memory.dart';

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

    test('no profile signed out; a sign-in gets the account\'s', () async {
      final auth = FakeAuthService();
      final client = FakeRolesClient.none()..profile = 'brave_calm_otter';
      final roles = RolesService(auth: auth, client: client);
      await settle();
      expect(roles.profile, isNull, reason: 'signed out');

      // Even without access, the account has a profile.
      await auth.signIn();
      await settle();
      expect(roles.state, AccessState.denied);
      expect(roles.profile, 'brave_calm_otter');

      // A failed check of the same account keeps it.
      client.error = Exception('down');
      await roles.refresh();
      expect(roles.profile, 'brave_calm_otter', reason: 'failed');

      await auth.signOut();
      expect(roles.profile, isNull, reason: 'signed out');
    });

    test('the same account gets the same profile on two devices', () async {
      // The auth API links the account to one profile.
      final api = FakeRolesClient();
      final phone = RolesService(auth: FakeAuthService.signedIn(), client: api);
      final laptop = RolesService(
        auth: FakeAuthService.signedIn(),
        client: api,
      );
      await settle();
      expect(phone.profile, 'automatic_paranoid_axolotl');
      expect(laptop.profile, phone.profile);
    });

    test('another account drops the last one\'s profile at once', () async {
      final auth = FakeAuthService.signedIn();
      final client = FakeRolesClient();
      final roles = RolesService(auth: auth, client: client);
      await settle();
      expect(roles.profile, 'automatic_paranoid_axolotl');

      client.profile = 'other_quiet_heron';
      await auth.signOut();
      final seen = <String?>[];
      roles.addListener(() => seen.add(roles.profile));
      await auth.signIn();
      await settle();
      expect(seen.first, isNull, reason: 'before the API answers');
      expect(roles.profile, 'other_quiet_heron');
    });

    test('DEV has no profile: nobody signs in', () async {
      final roles = RolesService(
        auth: FakeAuthService(),
        client: FakeRolesClient()..mode = ExecutionMode.dev,
      );
      await settle();
      expect(roles.state, AccessState.granted);
      expect(roles.profile, isNull);
    });

    test('HttpRolesClient: own roles from rbacr, the profile and its shared '
        'membership from the auth API', () async {
      Future<UserAccess> answer(RbacrMe me, String profile) => HttpRolesClient(
        Uri.parse('https://presence.test/'),
        rbacr: FakeRbacrClient()..answer = me,
        client: MockClient((request) async {
          expect(request.url.path, '/api/auth/profile');
          expect(request.headers['authorization'], 'Bearer t');
          // The API finds (or makes) the account's profile: none is sent.
          expect(request.url.queryParameters, isEmpty);
          return http.Response(profile, 200);
        }),
      ).fetch('t');
      const own =
          '{"profile":"automatic_paranoid_axolotl","shared":[],'
          '"accounts":[]}';

      final ana = await answer((
        email: 'ana@example.com',
        root: false,
        roles: {
          'presence': ['free'],
          'tabscan': ['admin'],
        },
      ), own);
      expect(ana.roles, [userRole]);
      expect(ana.profile, 'automatic_paranoid_axolotl');

      // A linked account shares the owner's membership, never more.
      final linked = await answer(
        (email: 'bo@example.com', root: false, roles: const {}),
        '{"profile":"automatic_paranoid_axolotl",'
        '"shared":["presence_premium","presence_user","presence_admin"]}',
      );
      expect(linked.roles, [premiumRole, userRole]);

      // Its own admin role, with the owner's premium.
      final both = await answer((
        email: 'cy@example.com',
        root: false,
        roles: {
          'presence': ['admin'],
        },
      ), '{"profile":"p","shared":["presence_user"]}');
      expect(both.roles, [adminRole, premiumRole, userRole]);

      // An API that didn't say.
      final none = await answer((
        email: 'a@b.c',
        root: false,
        roles: const {},
      ), '{"accounts":[]}');
      expect(none.roles, isEmpty);
      expect(none.profile, isNull);
    });

    test('HttpRolesClient fails when rbacr or the auth API does', () async {
      HttpRolesClient client(FakeRbacrClient rbacr, int status) =>
          HttpRolesClient(
            Uri.parse('https://presence.test/'),
            rbacr: rbacr,
            client: MockClient(
              (_) async => http.Response('{"profile":"p","shared":[]}', status),
            ),
          );
      expect(
        client(FakeRbacrClient()..error = RolesException(401), 200).fetch('t'),
        throwsA(isA<RolesException>()),
      );
      expect(
        client(FakeRbacrClient(), 503).fetch('t'),
        throwsA(
          isA<RolesException>().having((e) => e.statusCode, 'status', 503),
        ),
      );
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

    test('a failed roles check is retried on its own, sooner then less '
        'often, until it answers', () async {
      // An unattended phone that rebooted offline: the start check and
      // the roles check both fail, and nobody presses "Check again".
      final auth = FakeAuthService.signedIn();
      final client = FakeRolesClient()
        ..anonymousError = RolesException(502)
        ..error = RolesException(502);
      final roles = RolesService(
        auth: auth,
        client: client,
        oidcClient: true,
        retryDelays: const [
          Duration(milliseconds: 10),
          Duration(milliseconds: 20),
        ],
      );
      addTearDown(roles.dispose);
      await settle();
      expect(roles.state, AccessState.denied);
      final states = <AccessState>[];
      roles.addListener(() => states.add(roles.state));

      // Still offline: checked again, without flashing "checking".
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(client.tokens.length, greaterThanOrEqualTo(3));
      expect(states, isNot(contains(AccessState.checking)));
      expect(roles.state, AccessState.denied);

      // Back online, the same token: access comes back by itself.
      client
        ..anonymousError = null
        ..error = null;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(roles.state, AccessState.granted);
      expect(roles.error, isNull);
      expect(client.tokens.toSet(), {'id-token-1'});

      // Answered: the retries stop.
      final calls = client.tokens.length;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(client.tokens.length, calls);
    });

    test('a failed roles check stops retrying once signed out', () async {
      final auth = FakeAuthService.signedIn();
      final client = FakeRolesClient()..error = RolesException(502);
      final roles = RolesService(
        auth: auth,
        client: client,
        retryDelays: const [Duration(milliseconds: 10)],
      );
      addTearDown(roles.dispose);
      await settle();
      expect(roles.state, AccessState.denied);
      await auth.signOut();
      final calls = client.tokens.length;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(client.tokens.length, calls);
      expect(roles.state, AccessState.signedOut);
    });

    test('dev mode: the anonymous user gets every role', () async {
      final auth = FakeAuthService();
      final client = FakeRolesClient()..mode = ExecutionMode.dev;
      final roles = RolesService(auth: auth, client: client);
      await settle();
      expect(roles.mode, ExecutionMode.dev);
      expect(roles.state, AccessState.granted);
      expect(
        roles.roles,
        containsAll([anonymousRole, userRole, adminRole, rootRole]),
      );
      expect(roles.isRoot, isTrue, reason: 'DEV is root');
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

    test('an unanswered start check is retried until the API answers, '
        'and each check is logged', () async {
      final printed = <String>[];
      final print = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add('$message');
      addTearDown(() => debugPrint = print);
      final client = FakeRolesClient()..anonymousError = RolesException(502);
      final roles = RolesService(
        auth: FakeAuthService(),
        client: client,
        oidcClient: true,
        retryDelays: const [
          Duration(milliseconds: 10),
          Duration(milliseconds: 20),
        ],
      );
      addTearDown(roles.dispose);
      await settle();
      expect(roles.apiError, 'Auth API HTTP 502');
      expect(
        printed.last,
        matches(
          r'^Presence: could not ask the execution mode \(after \d+ ms; '
          r'checking again\): Auth API HTTP 502$',
        ),
      );

      // Still failing: checked again, sooner then less often.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(client.anonymousCalls, greaterThanOrEqualTo(3));
      expect(
        printed.last,
        matches(
          r'^Presence: auth API health check failed after \d+ ms: '
          r'Auth API HTTP 502$',
        ),
      );

      // Answering: the error clears, it's logged, and the retries stop.
      client.anonymousError = null;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(roles.apiError, isNull);
      expect(
        printed.last,
        matches(
          r'^Presence: auth API health check answered in \d+ ms, after '
          r'failing: Auth API HTTP 502$',
        ),
      );
      final calls = client.anonymousCalls;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(client.anonymousCalls, calls);
      expect(roles.mode, ExecutionMode.rbac);
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
      FakeRolesClient roles, {
      FakeRbacrClient? rbacr,
      FakeFeedbackClient? feedback,
    }) async {
      tester.view.physicalSize = const Size(1280, 1300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final camera = FakeCameraSource('Main');
      await tester.pumpWidget(
        PresenceApp(
          consentGiven: true,
          cameras: openFakes([camera]),
          auth: FakeAuthService.signedIn(),
          rolesClient: roles,
          rbacrClient: rbacr ?? FakeRbacrClient(),
          feedbackClient: feedback ?? FakeFeedbackClient(),
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
      await launch(tester, roles);

      expect(find.byType(HomeNavigationBar), findsNothing);
      expect(find.byKey(const Key('clip')), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byKey(const Key('account-button')), findsOneWidget);
      expect(find.byKey(const Key('sign-up')), findsOneWidget);
      expect(find.byKey(const Key('camera-page')), findsOneWidget);

      await tester.tap(find.byKey(const Key('sign-up')));
      await tester.pumpAndSettle();
      // No asking for access: subscribe at nu01.com.
      expect(find.text('Subscribe'), findsOneWidget);
      expect(find.textContaining('ana@example.com'), findsOneWidget);
      expect(find.byKey(const Key('membership-message')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('subscribe')))
            .onPressed,
        isNotNull,
      );

      // Another role isn't enough.
      roles.roles = ['viewer'];
      await tester.tap(find.byKey(const Key('check-access')));
      await tester.pumpAndSettle();
      expect(find.byType(HomeNavigationBar), findsNothing);

      // Subscribed (rbacr gives presence_user): checking again unlocks
      // everything.
      roles.roles = [userRole];
      await tester.tap(find.byKey(const Key('check-access')));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byKey(const Key('sign-up-sheet'))))
          .pop();
      await tester.pumpAndSettle();
      expect(find.byType(HomeNavigationBar), findsOneWidget);
      expect(find.byKey(const Key('clip')), findsOneWidget);
      expect(find.byKey(const Key('sign-up')), findsNothing);
    });

    testWidgets('a voucher code redeemed in rbacr lets the user in at once', (
      tester,
    ) async {
      final roles = FakeRolesClient.none();
      final rbacr = FakeRbacrClient()
        ..vouchers['2026Q4-OTTER-FALCON-LEMUR'] = (discount: 100, active: true)
        ..onRedeem = (_) => roles.roles = [userRole];
      await launch(tester, roles, rbacr: rbacr);
      await tester.tap(find.byKey(const Key('sign-up')));
      await tester.pumpAndSettle();

      // Redeeming needs a code; a wrong one says so.
      final redeem = find.byKey(const Key('redeem-voucher'));
      expect(tester.widget<FilledButton>(redeem).onPressed, isNull);
      await tester.enterText(
        find.byKey(const Key('voucher-code')),
        'ZZZZ-ZZZZ-ZZZZ',
      );
      await tester.pump();
      await tester.tap(redeem);
      await tester.pumpAndSettle();
      expect(
        find.text('That code is invalid, expired or used up.'),
        findsOneWidget,
      );
      expect(find.byType(HomeNavigationBar), findsNothing);

      // The right one grants its role, and the roles are checked again.
      await tester.enterText(
        find.byKey(const Key('voucher-code')),
        ' 2026q4-otter-falcon-lemur ',
      );
      await tester.pump();
      await tester.tap(redeem);
      await tester.pumpAndSettle();
      expect(rbacr.redeemed, ['2026Q4-OTTER-FALCON-LEMUR']);
      expect(find.byKey(const Key('voucher-error')), findsNothing);
      Navigator.of(tester.element(find.byKey(const Key('sign-up-sheet'))))
          .pop();
      await tester.pumpAndSettle();
      expect(find.byType(HomeNavigationBar), findsOneWidget);
      expect(find.byKey(const Key('sign-up')), findsNothing);
    });

    Future<String> redeemFails(
      WidgetTester tester,
      FakeRbacrClient rbacr,
      String code,
    ) async {
      final roles = FakeRolesClient.none();
      await launch(tester, roles, rbacr: rbacr);
      await tester.tap(find.byKey(const Key('sign-up')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('voucher-code')), code);
      await tester.pump();
      await tester.tap(find.byKey(const Key('redeem-voucher')));
      await tester.pumpAndSettle();
      expect(roles.roles, isEmpty);
      return tester.widget<Text>(find.byKey(const Key('voucher-error'))).data!;
    }

    testWidgets('a partly discounted voucher lets nobody in yet', (
      tester,
    ) async {
      final rbacr = FakeRbacrClient()
        ..vouchers['AUTUMN-OTTER-4821'] = (discount: 25, active: true);
      expect(
        await redeemFails(tester, rbacr, 'autumn-otter-4821'),
        startsWith('That code gives 25% off'),
      );
      expect(rbacr.redeemed, isEmpty);
    });

    testWidgets('rbacr\'s 409, 402 without a percent and 429 say so', (
      tester,
    ) async {
      final rbacr = FakeRbacrClient()
        ..vouchers['SPENT-CODE-1'] = (discount: 100, active: false);
      expect(
        await redeemFails(tester, rbacr, 'SPENT-CODE-1'),
        'That code is invalid, expired or used up.',
      );
      rbacr.error = PaymentRequiredException(null);
      await tester.tap(find.byKey(const Key('redeem-voucher')));
      await tester.pumpAndSettle();
      expect(find.textContaining('That code needs a payment'), findsOneWidget);
      rbacr.error = RolesException(429);
      await tester.tap(find.byKey(const Key('redeem-voucher')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Too many tries'), findsOneWidget);
    });

    group('the Log tab', () {
      final logTab = find.byTooltip('Log');
      const message = 'Presence: cloud sync failed: S3 HTTP 403: denied';

      Future<void> open(
        WidgetTester tester,
        FakeRolesClient roles, {
        FakeAuthService? auth,
        TabMemory? tabMemory,
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
            tabMemory: tabMemory,
          ),
        );
        await tester.pumpAndSettle();
      }

      final logSwitch = find.byKey(const Key('show-log-switch'));

      /// Flips Settings' "Show the Log tab" switch.
      Future<void> toggleLog(WidgetTester tester) async {
        await tester.tap(find.byTooltip('Settings'));
        await tester.pumpAndSettle();
        // At the list's edge: a drag in its middle can land on the
        // location map or a slider.
        await scrollSettingsTo(tester, logSwitch);
        await tester.tap(logSwitch);
        await tester.pumpAndSettle();
      }

      testWidgets(
        'OIDC: an admin sees it once Settings shows it, with the log',
        (tester) async {
          AppLog.instance.add(message);
          await open(tester, FakeRolesClient([userRole, adminRole]));
          expect(logTab, findsNothing, reason: 'hidden by default');
          await toggleLog(tester);
          expect(logTab, findsOneWidget);
          await tester.tap(logTab);
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('log-view')), findsOneWidget);
          expect(find.text(message), findsOneWidget);

          // Turned off again: gone, staying on Settings.
          await toggleLog(tester);
          expect(logTab, findsNothing);
          expect(find.byKey(const Key('settings-page')), findsOneWidget);
        },
      );

      testWidgets('OIDC: with the Log tab shown, the Admin tab comes after', (
        tester,
      ) async {
        await open(tester, FakeRolesClient([userRole, adminRole]));
        final adminTab = find.byTooltip('Admin');
        TabController tabs() => tester
            .widget<HomeNavigationBar>(find.byType(HomeNavigationBar))
            .controller;
        await toggleLog(tester);
        // With Help, and Profile last.
        expect(tabs().length, 7, reason: 'with Help');
        expect(
          tester.getCenter(logTab).dx,
          lessThan(tester.getCenter(adminTab).dx),
        );
        await tester.tap(adminTab);
        await tester.pumpAndSettle();
        expect(tabs().index, HomeTab.admin.index);
        expect(find.byKey(const Key('admin-view')), findsOneWidget);
        await tester.tap(logTab);
        await tester.pumpAndSettle();
        expect(tabs().index, HomeTab.log.index);
        expect(find.byKey(const Key('log-view')), findsOneWidget);

        // The Log tab hidden again: the Admin tab takes its place.
        await toggleLog(tester);
        expect(tabs().length, 6, reason: 'with Help and Profile');
        await tester.tap(adminTab);
        await tester.pumpAndSettle();
        expect(tabs().index, 4);
        expect(find.byKey(const Key('admin-view')), findsOneWidget);
      });

      testWidgets('DEV: no Admin tab, even with the Log tab', (tester) async {
        await open(
          tester,
          FakeRolesClient()..mode = ExecutionMode.dev,
          auth: FakeAuthService(),
          tabMemory: InMemoryTabMemory('admin'),
        );
        expect(logTab, findsOneWidget);
        expect(find.byTooltip('Admin'), findsNothing);
        expect(find.byKey(const Key('admin-view')), findsNothing);
        expect(find.byKey(const Key('camera-page')), findsOneWidget);
      });

      testWidgets('OIDC: a root sees it once Settings shows it', (
        tester,
      ) async {
        await open(tester, FakeRolesClient([userRole, adminRole, rootRole]));
        expect(logTab, findsNothing);
        await toggleLog(tester);
        expect(logTab, findsOneWidget);
      });

      testWidgets('OIDC: nobody else sees it', (tester) async {
        final cases = <String, (FakeRolesClient, FakeAuthService)>{
          'signed out': (
            FakeRolesClient([userRole, adminRole]),
            FakeAuthService(),
          ),
          'signed in, no role': (
            FakeRolesClient.none(),
            FakeAuthService.signedIn(),
          ),
          'a member': (FakeRolesClient([userRole]), FakeAuthService.signedIn()),
          'an admin without presence_user': (
            FakeRolesClient([adminRole]),
            FakeAuthService.signedIn(),
          ),
          'a failed roles check': (
            FakeRolesClient([userRole, adminRole])
              ..error = Exception('Auth API HTTP 503'),
            FakeAuthService.signedIn(),
          ),
        };
        for (final MapEntry(key: who, value: (roles, auth)) in cases.entries) {
          await open(tester, roles, auth: auth);
          expect(logTab, findsNothing, reason: who);
          expect(logSwitch, findsNothing, reason: who);
          expect(find.byKey(const Key('log-view')), findsNothing, reason: who);
          await tester.pumpWidget(const SizedBox());
        }
      });

      testWidgets('OIDC: a member never comes back to it after a refresh', (
        tester,
      ) async {
        final memory = InMemoryTabMemory('log');
        await open(tester, FakeRolesClient([userRole]), tabMemory: memory);
        expect(logTab, findsNothing);
        expect(find.byKey(const Key('log-view')), findsNothing);
      });

      testWidgets('OIDC: it goes when the admin role does, or on sign-out', (
        tester,
      ) async {
        final roles = FakeRolesClient([userRole, adminRole]);
        final auth = FakeAuthService.signedIn();
        await open(tester, roles, auth: auth);
        await toggleLog(tester);
        await tester.tap(logTab);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('log-view')), findsOneWidget);

        // Demoted: the next roles check (here, signing in again) drops it.
        roles.roles = [userRole];
        await auth.signOut();
        await auth.signIn();
        await tester.pumpAndSettle();
        expect(logTab, findsNothing);
        expect(find.byKey(const Key('log-view')), findsNothing);

        roles.roles = [userRole, adminRole];
        await auth.signOut();
        await auth.signIn();
        await tester.pumpAndSettle();
        expect(logTab, findsOneWidget);
        await tester.tap(logTab);
        await tester.pumpAndSettle();

        await auth.signOut();
        await tester.pumpAndSettle();
        expect(logTab, findsNothing);
        expect(find.byKey(const Key('log-view')), findsNothing);
      });

      testWidgets("DEV: the anonymous user is root, so sees it; it can go", (
        tester,
      ) async {
        await open(
          tester,
          FakeRolesClient()..mode = ExecutionMode.dev,
          auth: FakeAuthService(),
        );
        expect(logTab, findsOneWidget, reason: 'on by default in DEV');
        await toggleLog(tester);
        expect(logTab, findsNothing);
      });
    });

    testWidgets('the Admin tab: feedback, and vouchers and maintenance in '
        'rbacr', (tester) async {
      final opened = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AdminView(
              auth: FakeAuthService.signedIn(),
              feedback: FakeFeedbackClient(),
              rbacr: Uri.parse('https://rbacr.nu01.com'),
              openLink: (url) async {
                opened.add(url);
                return true;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Feedback'), findsOneWidget);
      // Nothing of Presence's own vouchers or maintenance mode is left.
      expect(find.text('Voucher codes'), findsNothing);
      expect(find.text('Maintenance mode'), findsNothing);
      expect(find.byKey(const Key('maintenance-switch')), findsNothing);
      expect(find.textContaining('managed in rbacr'), findsOneWidget);
      await tester.tap(find.byKey(const Key('admin-rbacr')));
      await tester.pumpAndSettle();
      expect(opened, [Uri.parse('https://rbacr.nu01.com')]);
    });

    testWidgets('a presence_user: everything but Admin', (tester) async {
      await launch(tester, FakeRolesClient([userRole]));
      expect(find.byType(HomeNavigationBar), findsOneWidget);
      expect(find.byKey(const Key('clip')), findsOneWidget);
      expect(find.byKey(const Key('sign-up')), findsNothing);
      expect(find.byTooltip('Admin'), findsNothing);
    });

    testWidgets('an admin without presence_user gets nothing', (tester) async {
      await launch(tester, FakeRolesClient([adminRole]));
      expect(find.byType(HomeNavigationBar), findsNothing);
      expect(find.byTooltip('Admin'), findsNothing);
      expect(find.byKey(const Key('sign-up')), findsOneWidget);
    });

    group('the Admin tab', () {
      final adminTab = find.byTooltip('Admin');
      TabController tabs(WidgetTester tester) => tester
          .widget<HomeNavigationBar>(find.byType(HomeNavigationBar))
          .controller;

      testWidgets('an admin flips to it like the other tabs: no back button', (
        tester,
      ) async {
        await launch(tester, FakeRolesClient([userRole, adminRole]));
        // In the tab bar, after Settings and before the account button.
        expect(adminTab, findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(HomeNavigationBar),
            matching: adminTab,
          ),
          findsOneWidget,
        );
        expect(
          tabs(tester).length,
          6,
          reason: 'with Help; the Log tab is hidden; Profile is last',
        );
        // In the navigation bar, after Settings and before Profile.
        final settings = tester.getCenter(find.byTooltip('Settings'));
        final admin = tester.getCenter(adminTab);
        expect(settings.dx, lessThan(admin.dx));
        expect(
          admin.dx,
          lessThan(
            tester.getCenter(find.byKey(const Key('account-button'))).dx,
          ),
        );
        expect(
          tester.getRect(find.byType(HomeNavigationBar)).contains(admin),
          isTrue,
        );

        await tester.tap(adminTab);
        await tester.pumpAndSettle();
        // Where the Log tab would be: indices map through the shown tabs.
        expect(tabs(tester).index, 4);
        expect(find.byKey(const Key('admin-view')), findsOneWidget);
        expect(find.text('Feedback'), findsOneWidget);
        // A page of the tabs, not a screen over them.
        expect(find.byType(BackButton), findsNothing);
        expect(find.byTooltip('Back'), findsNothing);
        expect(find.byType(HomeNavigationBar), findsOneWidget);
        expect(find.byKey(const Key('account-button')), findsOneWidget);

        // The navigation bar flips back to Settings, and on to the Admin
        // tab again.
        await tester.tap(find.byTooltip('Settings'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('settings-page')), findsOneWidget);
        expect(find.byKey(const Key('admin-view')), findsNothing);
        await tester.tap(adminTab);
        await tester.pumpAndSettle();
        expect(tabs(tester).index, 4);
        expect(find.byKey(const Key('admin-view')), findsOneWidget);
      });

      testWidgets('reload fetches the feedback again', (tester) async {
        final feedback = FakeFeedbackClient();
        await launch(
          tester,
          FakeRolesClient([userRole, adminRole]),
          feedback: feedback,
        );
        await tester.tap(adminTab);
        await tester.pumpAndSettle();
        expect(find.text('No feedback yet.'), findsOneWidget);
        feedback.conversations['bob@example.com'] = [
          FeedbackMessage(
            fromAdmin: false,
            message: 'The map is blank',
            sentAt: DateTime.utc(2026, 10, 1),
          ),
        ];
        await tester.tap(find.byKey(const Key('admin-reload')));
        await tester.pumpAndSettle();
        expect(find.text('No feedback yet.'), findsNothing);
        expect(find.textContaining('bob@example.com'), findsWidgets);
      });

      testWidgets('a refresh comes back to it, and it is remembered by name', (
        tester,
      ) async {
        Future<void> open(TabMemory memory) async {
          tester.view.physicalSize = const Size(1280, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            PresenceApp(
              key: UniqueKey(),
              consentGiven: true,
              cameras: openFakes([FakeCameraSource('Main')]),
              auth: FakeAuthService.signedIn(),
              rolesClient: FakeRolesClient([userRole, adminRole]),
              rbacrClient: FakeRbacrClient(),
              mapTiles: const SizedBox(),
              locator: NoLocation(),
              tabMemory: memory,
            ),
          );
          await tester.pumpAndSettle();
        }

        final memory = InMemoryTabMemory();
        await open(memory);
        await tester.tap(adminTab);
        await tester.pumpAndSettle();
        expect(memory.tab, 'admin', reason: 'not the Log at its index');

        await open(memory);
        expect(tabs(tester).index, 4);
        expect(find.byKey(const Key('admin-view')), findsOneWidget);
      });

      testWidgets('a member never comes back to it after a refresh', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          PresenceApp(
            consentGiven: true,
            cameras: openFakes([FakeCameraSource('Main')]),
            auth: FakeAuthService.signedIn(),
            rolesClient: FakeRolesClient([userRole]),
            rbacrClient: FakeRbacrClient(),
            mapTiles: const SizedBox(),
            locator: NoLocation(),
            tabMemory: InMemoryTabMemory('admin'),
          ),
        );
        await tester.pumpAndSettle();
        expect(adminTab, findsNothing);
        expect(find.byKey(const Key('admin-view')), findsNothing);
        expect(tabs(tester).index, 0);
      });
    });

    testWidgets('a failed roles check shows only the account and sign-up', (
      tester,
    ) async {
      await launch(tester, FakeRolesClient()..error = RolesException(503));
      expect(find.byType(HomeNavigationBar), findsNothing);
      expect(find.byKey(const Key('sign-up')), findsOneWidget);
    });
  });
}
