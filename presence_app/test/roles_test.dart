import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:presence_app/app_log.dart';
import 'package:presence_app/auth/membership_client.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/auth/voucher_code.dart';
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

    test('HttpRolesClient reads the profile', () async {
      Future<UserAccess> answer(String body) => HttpRolesClient(
        Uri.parse('https://presence.test/'),
        client: MockClient((request) async {
          expect(request.url.path, '/api/auth');
          expect(request.headers['authorization'], 'Bearer t');
          // The API finds (or makes) the account's profile: none is sent.
          expect(request.url.queryParameters, isEmpty);
          return http.Response(body, 200);
        }),
      ).fetch('t');

      final ana = await answer(
        '{"email":"ana@example.com","profile":"automatic_paranoid_axolotl",'
        '"roles":["presence_user"]}',
      );
      expect(ana.roles, [userRole]);
      expect(ana.profile, 'automatic_paranoid_axolotl');
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

    testWidgets('a voucher code lets the user in at once', (tester) async {
      final roles = FakeRolesClient.none();
      final membership = FakeMembershipClient()
        ..codes.add(
          Voucher(
            code: 'ABCD-EFGH-JK23',
            role: userRole,
            expiresAt: DateTime.now().add(const Duration(days: 1)),
            maxUses: 1,
            uses: 0,
            createdAt: DateTime.now(),
          ),
        )
        ..onRedeem = (role) => roles.roles = [role];
      await launch(tester, roles, membership);
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
      expect(find.byKey(const Key('voucher-error')), findsOneWidget);
      expect(find.byType(TabBar), findsNothing);

      // The right one grants its role, and the roles are checked again.
      await tester.enterText(
        find.byKey(const Key('voucher-code')),
        ' abcd-efgh-jk23 ',
      );
      await tester.pump();
      await tester.tap(redeem);
      await tester.pumpAndSettle();
      expect(membership.redeemed, ['ABCD-EFGH-JK23']);
      expect(find.byKey(const Key('voucher-error')), findsNothing);
      Navigator.of(tester.element(find.byKey(const Key('sign-up-sheet'))))
          .pop();
      await tester.pumpAndSettle();
      expect(find.byType(TabBar), findsOneWidget);
      expect(find.byKey(const Key('sign-up')), findsNothing);
    });

    testWidgets('a partly discounted voucher lets nobody in yet', (
      tester,
    ) async {
      final roles = FakeRolesClient.none();
      final membership = FakeMembershipClient()
        ..codes.add(
          Voucher(
            code: 'AUTUMN-OTTER-4821',
            role: userRole,
            expiresAt: DateTime.now().add(const Duration(days: 1)),
            maxUses: 1,
            uses: 0,
            createdAt: DateTime.now(),
            discount: 25,
          ),
        )
        ..onRedeem = (role) => roles.roles = [role];
      await launch(tester, roles, membership);
      await tester.tap(find.byKey(const Key('sign-up')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('voucher-code')),
        'autumn-otter-4821',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('redeem-voucher')));
      await tester.pumpAndSettle();
      expect(find.textContaining('That code gives 25% off'), findsOneWidget);
      expect(membership.redeemed, isEmpty);
      expect(membership.codes.single.uses, 0);
      expect(roles.roles, isEmpty);
    });

    group('the Log tab', () {
      final logTab = find.byIcon(Icons.receipt_long);
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
            membershipClient: FakeMembershipClient(),
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
        await tester.scrollUntilVisible(
          logSwitch,
          300,
          scrollable: find.descendant(
            of: find.byKey(const Key('settings-page')),
            matching: find.byType(Scrollable),
          ),
        );
        await tester.pumpAndSettle();
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

    testWidgets('a presence_admin creates and deletes voucher codes', (
      tester,
    ) async {
      final membership = FakeMembershipClient()
        ..codes.add(
          Voucher(
            code: 'OLDC-ODEX-2222',
            role: adminRole,
            expiresAt: DateTime.now().subtract(const Duration(days: 1)),
            maxUses: 3,
            uses: 1,
            redeemedBy: const ['bob@example.com'],
            createdAt: DateTime.utc(2026, 9, 1),
          ),
        )
        ..codes.add(
          Voucher(
            code: 'NEXT-SEAS-3333',
            role: userRole,
            startsAt: DateTime.now().add(const Duration(days: 30)),
            expiresAt: DateTime.now().add(const Duration(days: 60)),
            maxUses: 3,
            uses: 0,
            createdAt: DateTime.utc(2026, 9, 1),
          ),
        );
      await launch(tester, FakeRolesClient([userRole, adminRole]), membership);
      await tester.tap(find.byKey(const Key('admin')));
      await tester.pumpAndSettle();
      expect(find.text('No pending requests.'), findsOneWidget);
      expect(find.text('Voucher codes'), findsOneWidget);
      expect(find.text('Expired'), findsOneWidget);
      expect(find.text('Not yet valid'), findsOneWidget);
      expect(
        find.textContaining('Admin · 100% off · 1 of 3 used'),
        findsOneWidget,
      );
      expect(find.text('Redeemed by bob@example.com'), findsOneWidget);

      // A code is suggested: the season, an animal and a number.
      final codeField = find.byKey(const Key('voucher-new-code'));
      final suggested = tester.widget<TextField>(codeField).controller!.text;
      expect(
        suggested,
        matches(RegExp(r'^(WINTER|SPRING|SUMMER|AUTUMN)-[A-Z]+-\d{3,4}$')),
      );

      // Uses must be 1 to 1000.
      final create = find.byKey(const Key('create-voucher'));
      await tester.enterText(find.byKey(const Key('voucher-max-uses')), '0');
      await tester.pump();
      expect(tester.widget<FilledButton>(create).onPressed, isNull);
      await tester.enterText(find.byKey(const Key('voucher-max-uses')), '5');
      await tester.pump();
      await tester.tap(create);
      await tester.pumpAndSettle();
      final voucher = membership.codes.first;
      expect(voucher.role, userRole);
      expect(voucher.maxUses, 5);
      expect(voucher.code, suggested);
      expect(voucher.discount, 100);
      // The current season: from its first day through its last.
      final now = DateTime.now();
      final last = seasonEnd(now);
      expect(voucher.startsAt, seasonStart(now));
      expect(voucher.expiresAt, DateTime(last.year, last.month, last.day + 1));
      expect(find.byKey(Key('voucher-${voucher.code}')), findsOneWidget);
      expect(
        find.textContaining('Member · 100% off · 0 of 5 used'),
        findsOneWidget,
      );
      // A new suggestion for the next one.
      expect(
        tester.widget<TextField>(codeField).controller!.text,
        isNot(suggested),
      );

      await tester.tap(find.byKey(Key('delete-${voucher.code}')));
      await tester.pumpAndSettle();
      expect(membership.codes.map((v) => v.code), [
        'OLDC-ODEX-2222',
        'NEXT-SEAS-3333',
      ]);
      expect(find.byKey(Key('voucher-${voucher.code}')), findsNothing);
    });

    testWidgets('an admin types the code and a discount', (tester) async {
      final membership = FakeMembershipClient();
      await launch(tester, FakeRolesClient([userRole, adminRole]), membership);
      await tester.tap(find.byKey(const Key('admin')));
      await tester.pumpAndSettle();
      final create = find.byKey(const Key('create-voucher'));
      final code = find.byKey(const Key('voucher-new-code'));
      final discount = find.byKey(const Key('voucher-discount'));

      await tester.enterText(code, 'no');
      await tester.pump();
      expect(tester.widget<FilledButton>(create).onPressed, isNull);
      await tester.enterText(code, 'friends-2026');
      await tester.enterText(discount, '0');
      await tester.pump();
      expect(tester.widget<FilledButton>(create).onPressed, isNull);
      await tester.enterText(discount, '101');
      await tester.pump();
      expect(tester.widget<FilledButton>(create).onPressed, isNull);
      await tester.enterText(discount, '25');
      await tester.pump();
      await tester.tap(create);
      await tester.pumpAndSettle();
      expect(membership.codes.single.code, 'FRIENDS-2026');
      expect(membership.codes.single.discount, 25);
      expect(find.textContaining('Member · 25% off'), findsOneWidget);

      // Taken.
      ScaffoldMessenger.of(
        tester.element(find.byKey(const Key('admin-screen'))),
      ).removeCurrentSnackBar();
      await tester.enterText(code, 'FRIENDS-2026');
      await tester.pump();
      await tester.tap(create);
      await tester.pumpAndSettle();
      expect(find.text('That code is taken; pick another.'), findsOneWidget);
      expect(membership.codes, hasLength(1));

      // Blank: a random code.
      await tester.enterText(code, '');
      await tester.pump();
      await tester.tap(create);
      await tester.pumpAndSettle();
      expect(membership.codes.first.code, startsWith('TEST-CODE-'));
    });

    Finder adminItem() =>
        find.widgetWithText(DropdownMenuItem<String>, 'Admin');
    Future<void> openVoucherRoles(
      WidgetTester tester,
      List<String> granted,
      FakeMembershipClient membership,
    ) async {
      await launch(tester, FakeRolesClient(granted), membership);
      await tester.tap(find.byKey(const Key('admin')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voucher-role')));
      await tester.pumpAndSettle();
    }

    testWidgets('a presence_admin creates Member vouchers only', (
      tester,
    ) async {
      await openVoucherRoles(tester, [
        userRole,
        adminRole,
      ], FakeMembershipClient());
      expect(adminItem(), findsNothing);
      expect(
        find.textContaining('Only roots create Admin codes'),
        findsOneWidget,
      );
    });

    testWidgets('a presence_root creates Admin vouchers', (tester) async {
      final membership = FakeMembershipClient();
      await openVoucherRoles(tester, [
        userRole,
        adminRole,
        rootRole,
      ], membership);
      expect(adminItem(), findsWidgets);
      await tester.tap(adminItem().last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('create-voucher')));
      await tester.pumpAndSettle();
      expect(membership.codes.single.role, adminRole);
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
