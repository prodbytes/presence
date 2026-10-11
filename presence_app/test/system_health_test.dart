import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/cloud/live_sync.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/system_health.dart';
import 'package:presence_app/theme.dart';

import 'fakes.dart';
import 'live_sync_test.dart' show FakeBroker, credentials, until;

void main() {
  test('the auth API reports which settings are set', () async {
    Future<AnonymousAccess> answer(String body) => HttpRolesClient(
      Uri.parse('https://presence.test/'),
      rbacr: FakeRbacrClient(),
      client: MockClient((request) async {
        expect(request.url.path, '/api/auth/anonymous');
        return http.Response(body, 200);
      }),
    ).anonymous();

    final access = await answer(
      '{"mode":"RBAC","roles":["presence_anonymous"],'
      '"settings":{"oidc":true,"aws":false}}',
    );
    expect(access.mode, ExecutionMode.rbac);
    expect(access.settings, (oidc: true, aws: false, rbacr: null));
    // An API from before the report: unknown.
    final older = await answer('{"mode":"DEV","roles":[]}');
    expect(older.settings, (oidc: null, aws: null, rbacr: null));
  });

  test('the auth API reports whether RBACR is set', () async {
    final client = HttpRolesClient(
      Uri.parse('https://presence.test/'),
      rbacr: FakeRbacrClient(),
      client: MockClient(
        (_) async => http.Response(
          '{"mode":"RBAC","roles":[],"settings":{"oidc":true,"aws":true,"rbacr":true}}',
          200,
        ),
      ),
    );
    expect((await client.anonymous()).settings.rbacr, isTrue);
  });

  group('the RBACR check', () {
    Future<RolesService> rolesWith(
      ApiSettings settings, {
      List<String> roles = const [userRole],
    }) async {
      final auth = FakeAuthService();
      final service = RolesService(
        auth: auth,
        client: FakeRolesClient(roles)..settings = settings,
        oidcClient: true,
      );
      addTearDown(service.dispose);
      await auth.signIn();
      for (var i = 0; i < 20 && service.mode == null; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      for (var i = 0; i < 20 && !service.hasAccess && roles.isNotEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      return service;
    }

    test('set: says whether this profile is Premium or Free', () async {
      const set = (oidc: true, aws: true, rbacr: true);
      final free = SystemHealth.rbacrOf(await rolesWith(set));
      expect(free.$1, '✅');
      expect(free.$2, contains('Free'));
      final premium = SystemHealth.rbacrOf(
        await rolesWith(set, roles: const [userRole, premiumRole]),
      );
      expect(premium.$2, contains('Premium'));
    });

    test('missing: a warning, a failed check, cloud sync or not', () async {
      final roles = await rolesWith((oidc: true, aws: true, rbacr: false));
      final part = SystemHealth.rbacrOf(roles);
      expect(part.$1, '⚠️');
      expect(part.$2, contains('nobody who signs in has a role'));
      expect(healthPartFailed(part), isTrue);
      expect(
        HealthWarningPill.failedChecks(roles, null, oidcClient: true),
        contains(part.$2),
      );
      // Roles come from RBACR alone, so no cloud sync doesn't excuse it.
      expect(
        SystemHealth.rbacrOf(
          await rolesWith((oidc: true, aws: false, rbacr: false)),
        ).$1,
        '⚠️',
      );
      // An API that doesn't say: not a failure.
      expect(
        SystemHealth.rbacrOf(
          await rolesWith((oidc: true, aws: true, rbacr: null)),
        ).$1,
        '⚪',
      );
    });
  });

  group('the health line', () {
    Future<void> pump(
      WidgetTester tester, {
      required ApiSettings api,
      required bool oidcClient,
    }) async {
      final client = FakeRolesClient()..settings = api;
      final roles = RolesService(
        auth: FakeAuthService(),
        client: client,
        oidcClient: oidcClient,
      );
      addTearDown(roles.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SystemHealth(roles: roles, oidcClient: oidcClient),
          ),
        ),
      );
      await tester.pump();
    }

    String tooltip(WidgetTester tester, String key) => tester
        .widget<Tooltip>(
          find.ancestor(
            of: find.byKey(Key('health-$key')),
            matching: find.byType(Tooltip),
          ),
        )
        .message!;

    testWidgets('set in the auth API and the build: ✅', (tester) async {
      await pump(
        tester,
        api: (oidc: true, aws: false, rbacr: null),
        oidcClient: true,
      );
      expect(find.text('🔑 OIDC ✅'), findsOneWidget);
      // No cloud sync in this build, nor in the API.
      expect(find.text('☁️ AWS ⚪'), findsOneWidget);
      expect(
        tooltip(tester, 'aws'),
        'AWS: not set; events stay on this device',
      );
    });

    testWidgets('set on one side only: ⚠️, saying which', (tester) async {
      await pump(
        tester,
        api: (oidc: false, aws: true, rbacr: null),
        oidcClient: true,
      );
      expect(find.text('🔑 OIDC ⚠️'), findsOneWidget);
      expect(
        tooltip(tester, 'oidc'),
        'OIDC: set in this build but not in the auth API',
      );
      expect(find.text('☁️ AWS ⚠️'), findsOneWidget);
      expect(
        tooltip(tester, 'aws'),
        contains('set in the auth API but not in this build'),
      );
    });

    testWidgets('the API didn\'t say: the build decides', (tester) async {
      await pump(
        tester,
        api: (oidc: null, aws: null, rbacr: null),
        oidcClient: false,
      );
      expect(find.text('🔑 OIDC ⚪'), findsOneWidget);
      expect(
        tooltip(tester, 'oidc'),
        'OIDC: not set in this build; sign-in is off',
      );
    });
  });

  group('the Log tab\'s health panel', () {
    testWidgets('checks the auth API at open and every 60 s in RBAC', (
      tester,
    ) async {
      final client = FakeRolesClient()
        ..settings = (oidc: true, aws: false, rbacr: null);
      final roles = RolesService(
        auth: FakeAuthService(),
        client: client,
        oidcClient: true,
      );
      addTearDown(roles.dispose);
      final history = HealthHistory();
      await tester.pump();
      expect(client.anonymousCalls, 1);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HealthPanel(roles: roles, oidcClient: true, history: history),
          ),
        ),
      );
      await tester.pump();
      expect(client.anonymousCalls, 2);
      expect(find.textContaining('Last update '), findsOneWidget);
      // A card per check, its status in a pill.
      String status(String key) => tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(Key('health-$key-status')),
              matching: find.byType(Text),
            ),
          )
          .data!;
      expect(status('api'), 'OK');
      expect(status('aws'), 'Off');
      expect(status('oidc'), 'OK');
      expect(
        find.descendant(
          of: find.byKey(const Key('health-api')),
          matching: find.textContaining('Answered (rbac mode)'),
        ),
        findsOneWidget,
      );

      // The API goes away: the next check says so.
      client.anonymousError = Exception('offline');
      await tester.pump(const Duration(seconds: 59));
      expect(client.anonymousCalls, 2);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(client.anonymousCalls, 3);
      expect(status('api'), 'Failed');

      // And back, with a setting changed.
      client
        ..anonymousError = null
        ..settings = (oidc: false, aws: false, rbacr: null);
      await tester.pump(const Duration(seconds: 60));
      await tester.pump();
      expect(client.anonymousCalls, 4);
      expect(status('api'), 'OK');
      expect(status('oidc'), 'Mismatch');

      // The timeline: a block per run, red if any check failed, green if
      // all passed; the time under the first run.
      expect(history.checks.map((c) => c.failed), [false, true, true]);
      Color block(int i) =>
          (tester
                      .widget<Container>(find.byKey(Key('health-block-$i')))
                      .decoration!
                  as BoxDecoration)
              .color!;
      final red = Theme.of(
        tester.element(find.byKey(const Key('health-panel'))),
      ).colorScheme.error;
      expect(block(0), Gruvbox.green);
      expect(block(1), red);
      expect(block(2), red);
      expect(find.byKey(const Key('health-cell-0-api')), findsNothing);
      expect(find.text('3 checks · every 1 min'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('health-brick-0')),
          matching: find.textContaining(RegExp(r'^\d\d:\d\d$')),
        ),
        findsOneWidget,
      );

      // Tapping one shows its details; tapping it again hides them.
      await tester.tap(find.byKey(const Key('health-brick-1')));
      await tester.pump();
      expect(find.textContaining('failed'), findsOneWidget);
      expect(find.textContaining('Auth API: unreachable'), findsOneWidget);
      await tester.tap(find.byKey(const Key('health-brick-1')));
      await tester.pump();
      expect(find.byKey(const Key('health-detail')), findsNothing);

      // Closed: no more checks, but the history stays.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 120));
      expect(client.anonymousCalls, 4);
      expect(history.checks, hasLength(3));
    });

    testWidgets('checks every 15 s in DEV', (tester) async {
      final client = FakeRolesClient()
        ..mode = ExecutionMode.dev
        ..settings = (oidc: false, aws: false, rbacr: null);
      final roles = RolesService(
        auth: FakeAuthService(),
        client: client,
        oidcClient: false,
      );
      addTearDown(roles.dispose);
      final history = HealthHistory();
      await tester.pump();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HealthPanel(
              roles: roles,
              oidcClient: false,
              history: history,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(client.anonymousCalls, 2);
      await tester.pump(const Duration(seconds: 14));
      expect(client.anonymousCalls, 2);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(client.anonymousCalls, 3);
      expect(find.text('2 checks · every 15 s'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    test('the period follows the mode', () {
      expect(
        HealthPanel.intervalFor(ExecutionMode.dev, oidcClient: true),
        const Duration(seconds: 15),
      );
      expect(
        HealthPanel.intervalFor(ExecutionMode.rbac, oidcClient: false),
        const Duration(seconds: 60),
      );
      // Before the start check, the build says which mode it will be.
      expect(
        HealthPanel.intervalFor(null, oidcClient: false),
        const Duration(seconds: 15),
      );
      expect(
        HealthPanel.intervalFor(null, oidcClient: true),
        const Duration(seconds: 60),
      );
    });
  });

  group('the health panel\'s device count', () {
    AppEvent event(String? device, {String? user}) => AppEvent(
      icon: Icons.circle,
      title: 'e',
      deviceId: device,
      profileId: user,
    );

    test('counts distinct devices; unsaved events are this device\'s', () {
      expect(HealthPanel.devicesIn([]), 0);
      expect(
        HealthPanel.devicesIn([
          event('a'),
          event('b'),
          event('a'),
          event(null),
        ], deviceId: 'c'),
        3,
      );
      expect(HealthPanel.devicesIn([event('a'), event(null)]), 1);
    });

    testWidgets('shows the count of the user\'s devices, kept up to date', (
      tester,
    ) async {
      final roles = RolesService(
        auth: FakeAuthService(),
        client: FakeRolesClient(),
        oidcClient: true,
      );
      addTearDown(roles.dispose);
      final bus = StreamController<AppEvent>();
      final log = EventLog(bus.stream);
      addTearDown(() {
        log.dispose();
        bus.close();
      });
      log.addHistory([
        event('a', user: 'ana'),
        event('b', user: 'ana'),
        event('z', user: 'bob'),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HealthPanel(
              roles: roles,
              oidcClient: true,
              history: HealthHistory(),
              events: log,
              profileId: 'ana',
              deviceId: 'a',
              interval: const Duration(hours: 1),
            ),
          ),
        ),
      );
      await tester.pump();
      String count() => tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const Key('health-devices-count')),
              matching: find.byType(Text),
            ),
          )
          .data!;
      expect(count(), '2');

      log.addHistory([event('c', user: 'ana')]);
      await tester.pump();
      expect(count(), '3');
    });
  });

  group('the health panel\'s layout', () {
    Future<HealthHistory> show(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final roles = RolesService(
        auth: FakeAuthService(),
        client: FakeRolesClient()
          ..settings = (oidc: true, aws: true, rbacr: null),
        oidcClient: true,
      );
      addTearDown(roles.dispose);
      final bus = StreamController<AppEvent>();
      final log = EventLog(bus.stream);
      addTearDown(() {
        log.dispose();
        bus.close();
      });
      // An hour of runs, every 30 s; the panel adds its own when it opens.
      final history = HealthHistory();
      final start = DateTime(2026, 10, 5, 7);
      final ok = SystemHealth.statusOf(roles, null, oidcClient: true);
      for (var i = 0; i < 119; i++) {
        history.add(
          HealthCheck(start.add(Duration(seconds: 30 * i)), (
            api: i == 100 ? ('❌', 'Auth API: unreachable (x)') : ok.api,
            aws: ok.aws,
            oidc: ok.oidc,
            rbacr: ok.rbacr,
            live: ok.live,
          )),
        );
      }
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HealthPanel(
              roles: roles,
              oidcClient: true,
              history: history,
              events: log,
              interval: const Duration(hours: 1),
            ),
          ),
        ),
      );
      await tester.pump();
      return history;
    }

    Rect rect(WidgetTester tester, String key) =>
        tester.getRect(find.byKey(Key(key)));

    testWidgets('wide: the four cards in one row, aligned and as tall', (
      tester,
    ) async {
      await show(tester, 1280);
      final cards = [
        for (final k in ['api', 'aws', 'oidc', 'devices'])
          rect(tester, 'health-$k'),
      ];
      expect(cards.map((r) => r.top).toSet(), hasLength(1));
      expect(cards.map((r) => r.height).toSet(), hasLength(1));
      expect(cards.map((r) => r.width.round()).toSet(), hasLength(1));
      for (var i = 1; i < cards.length; i++) {
        expect(cards[i].left, greaterThan(cards[i - 1].right));
      }
    });

    testWidgets('a 320 dp phone: two across, nothing overflowing', (
      tester,
    ) async {
      await show(tester, 320);
      expect(tester.takeException(), isNull);
      final api = rect(tester, 'health-api');
      final aws = rect(tester, 'health-aws');
      final oidc = rect(tester, 'health-oidc');
      final rbacr = rect(tester, 'health-rbacr');
      final live = rect(tester, 'health-live');
      final devices = rect(tester, 'health-devices');
      expect(aws.top, api.top);
      expect(aws.height, api.height);
      expect(oidc.top, greaterThan(api.bottom));
      expect(oidc.left, api.left);
      expect(rbacr.top, oidc.top);
      expect(live.top, greaterThan(oidc.bottom));
      expect(live.left, api.left);
      expect(devices.top, live.top);
      expect(rbacr.right, lessThanOrEqualTo(320));
      expect(devices.right, lessThanOrEqualTo(320));
    });

    testWidgets('the timeline starts at the newest run and scrolls back', (
      tester,
    ) async {
      final history = await show(tester, 1280);
      final timeline = rect(tester, 'health-history');
      // The newest run is on screen, at the right; the oldest isn't built.
      expect(rect(tester, 'health-brick-119').right, lessThan(timeline.right));
      expect(
        rect(tester, 'health-brick-119').right,
        greaterThan(timeline.right - 40),
      );
      expect(find.byKey(const Key('health-brick-0')), findsNothing);
      // Times every 2 minutes: 07:58 under the run that started it.
      expect(
        find.descendant(
          of: find.byKey(const Key('health-brick-116')),
          matching: find.text('07:58'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('health-brick-117')),
          matching: find.byType(Text),
        ),
        findsNothing,
      );

      await tester.drag(
        find.byKey(const Key('health-history')),
        const Offset(5000, 0),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('health-brick-0')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('health-brick-0')),
          matching: find.text('07:00'),
        ),
        findsOneWidget,
      );
      expect(history.checks, hasLength(120));
    });
  });

  group('the Live check', () {
    late FakeBroker broker;
    setUp(() => broker = FakeBroker());

    LiveSync live(LiveConfig config) {
      final live = LiveSync(
        endpoint: 'abc-ats.iot.us-east-1.amazonaws.com',
        region: 'us-east-1',
        connect: broker.connect,
        config: config,
        drainQuiet: const Duration(milliseconds: 20),
        minRetry: const Duration(seconds: 10),
      );
      addTearDown(live.dispose);
      return live;
    }

    void start(LiveSync live) => live.start(
      LiveLink(
        identityId: 'us-east-1:identity',
        deviceId: 'this_device_one',
        credentials: () async => credentials,
        onEvent: (_) async {},
      ),
    );

    /// A run with [part] as its Live check, the others passing.
    HealthCheck runWith(HealthPart part) => HealthCheck(DateTime(2026), (
      api: ('✅', 'Auth API: answered'),
      aws: ('✅', 'AWS: synced'),
      oidc: ('✅', 'OIDC: set'),
      rbacr: ('✅', 'RBACR: set'),
      live: part,
    ));

    test('not in this build, or Never: off, not a failure', () {
      final none = SystemHealth.liveStatusOf(null);
      expect(none.$1, '⚪');
      final never = SystemHealth.liveStatusOf(live(LiveConfig.never));
      expect(never, (
        '⚪',
        'Live: off (Never); events arrive with each sync (15 s)',
      ));
      expect(runWith(none).failed, isFalse);
      expect(runWith(never).failed, isFalse);
    });

    test('connected, then idle between scheduled connections with a '
        'countdown: neither a failure', () async {
      final scheduled = live(const LiveConfig());
      start(scheduled);
      await until(() => scheduled.state == LiveSyncState.connected);
      final connected = SystemHealth.liveStatusOf(scheduled);
      expect(connected.$1, '✅');
      expect(connected.$2, startsWith('Live: connected'));
      await until(() => scheduled.state == LiveSyncState.idle);
      final idle = SystemHealth.liveStatusOf(scheduled);
      expect(idle.$1, '💤');
      expect(idle.$2, matches(RegExp(r'^Live: idle · next in 1:[01]\d ')));
      expect(idle.$2, contains('every 1 min'));
      expect(runWith(connected).failed, isFalse);
      expect(runWith(idle).failed, isFalse);
    });

    test('every 30 s: idle with a countdown under 41 s', () async {
      final scheduled = live(const LiveConfig(every: Duration(seconds: 30)));
      start(scheduled);
      await until(() => scheduled.state == LiveSyncState.idle);
      final idle = SystemHealth.liveStatusOf(scheduled);
      expect(idle.$1, '💤');
      expect(idle.$2, matches(RegExp(r'^Live: idle · next in 0:[34]\d ')));
      expect(idle.$2, contains('every 30 s'));
    });

    test('an admin\'s, set to every minute: always connected, ✅', () async {
      final admin = live(const LiveConfig().effective(isAdmin: true));
      start(admin);
      await until(() => admin.state == LiveSyncState.connected);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final status = SystemHealth.liveStatusOf(admin);
      expect(admin.state, LiveSyncState.connected);
      expect(status.$1, '✅');
      expect(status.$2, startsWith('Live: connected'));
    });

    test('a failed connection is a failure', () async {
      broker.refuse = 100;
      final failing = live(LiveConfig.always);
      start(failing);
      await until(() => failing.state == LiveSyncState.error);
      final error = SystemHealth.liveStatusOf(failing);
      expect(error.$1, '❌');
      expect(error.$2, contains('refused'));
      expect(runWith(error).failed, isTrue);
    });

    test('the countdown reads minutes and seconds', () {
      expect(SystemHealth.formatNextIn(const Duration(seconds: 42)), '0:42');
      expect(
        SystemHealth.formatNextIn(const Duration(minutes: 12, seconds: 5)),
        '12:05',
      );
      expect(
        SystemHealth.formatNextIn(const Duration(milliseconds: 100)),
        '0:01',
      );
      expect(SystemHealth.formatNextIn(null), '0:00');
    });
  });
}
