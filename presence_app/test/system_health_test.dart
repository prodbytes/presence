import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/system_health.dart';
import 'package:presence_app/theme.dart';

import 'fakes.dart';

void main() {
  test('the auth API reports which settings are set', () async {
    Future<AnonymousAccess> answer(String body) => HttpRolesClient(
      Uri.parse('https://presence.test/'),
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
    expect(access.settings, (oidc: true, aws: false));
    // An API from before the report: unknown.
    final older = await answer('{"mode":"DEV","roles":[]}');
    expect(older.settings, (oidc: null, aws: null));
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
      await pump(tester, api: (oidc: true, aws: false), oidcClient: true);
      expect(find.text('🔑 OIDC ✅'), findsOneWidget);
      // No cloud sync in this build, nor in the API.
      expect(find.text('☁️ AWS ⚪'), findsOneWidget);
      expect(
        tooltip(tester, 'aws'),
        'AWS: not set; events stay on this device',
      );
    });

    testWidgets('set on one side only: ⚠️, saying which', (tester) async {
      await pump(tester, api: (oidc: false, aws: true), oidcClient: true);
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
      await pump(tester, api: (oidc: null, aws: null), oidcClient: false);
      expect(find.text('🔑 OIDC ⚪'), findsOneWidget);
      expect(
        tooltip(tester, 'oidc'),
        'OIDC: not set in this build; sign-in is off',
      );
    });
  });

  group('the Log tab\'s health panel', () {
    testWidgets('checks the auth API at open and every 30 s', (tester) async {
      final client = FakeRolesClient()..settings = (oidc: true, aws: false);
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
      expect(find.text('🔌 API ✅'), findsOneWidget);
      expect(find.text('🔑 OIDC ✅'), findsOneWidget);

      // The API goes away: the next check says so.
      client.anonymousError = Exception('offline');
      await tester.pump(const Duration(seconds: 29));
      expect(client.anonymousCalls, 2);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(client.anonymousCalls, 3);
      expect(find.text('🔌 API ❌'), findsOneWidget);

      // And back, with a setting changed.
      client
        ..anonymousError = null
        ..settings = (oidc: false, aws: false);
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(client.anonymousCalls, 4);
      expect(find.text('🔌 API ✅'), findsOneWidget);
      expect(find.text('🔑 OIDC ⚠️'), findsOneWidget);

      // A brick per check: green, red, then green again.
      expect(history.checks.map((c) => c.failed), [false, true, true]);
      Color brick(int i) =>
          (tester
                      .widget<Container>(
                        find.descendant(
                          of: find.byKey(Key('health-brick-$i')),
                          matching: find.byType(Container),
                        ),
                      )
                      .decoration!
                  as BoxDecoration)
              .color!;
      expect(brick(0), Gruvbox.green);
      expect(brick(1), isNot(Gruvbox.green));

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
      await tester.pump(const Duration(seconds: 60));
      expect(client.anonymousCalls, 4);
      expect(history.checks, hasLength(3));
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
      expect(find.text('📱 Devices 2'), findsOneWidget);

      log.addHistory([event('c', user: 'ana')]);
      await tester.pump();
      expect(find.text('📱 Devices 3'), findsOneWidget);
    });
  });
}
