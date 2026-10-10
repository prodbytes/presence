import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:presence_app/auth/membership_client.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/home/home_navigation_bar.dart';
import 'package:presence_app/main.dart';

import 'fakes.dart';

void main() {
  const on = (on: true, message: 'Back at 3 pm', since: null);
  final sorry = find.byKey(const Key('maintenance'));

  Future<void> open(
    WidgetTester tester,
    FakeRolesClient roles, {
    FakeAuthService? auth,
    FakeMembershipClient? membership,
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
        membershipClient: membership ?? FakeMembershipClient(),
        mapTiles: const SizedBox(),
        locator: NoLocation(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a member sees only the sorry message, with the admin\'s', (
    tester,
  ) async {
    await open(tester, FakeRolesClient()..maintenance = on);
    expect(sorry, findsOneWidget);
    expect(find.text('Sorry, Presence is down for maintenance.'), findsOne);
    expect(find.text('Back at 3 pm'), findsOneWidget);
    expect(find.byType(HomeNavigationBar), findsNothing);
    expect(find.byType(HomeScreen), findsNothing);
  });

  testWidgets('signed out, no sign-in either', (tester) async {
    await open(
      tester,
      FakeRolesClient()..maintenance = on,
      auth: FakeAuthService(),
    );
    expect(sorry, findsOneWidget);
    expect(find.byKey(const Key('google-sign-in')), findsNothing);
  });

  testWidgets('a running app follows the switch within a minute', (
    tester,
  ) async {
    final roles = FakeRolesClient();
    await open(tester, roles);
    expect(sorry, findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);

    roles.maintenance = on;
    await tester.pump(const Duration(minutes: 1));
    await tester.pump();
    expect(sorry, findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);

    roles.maintenance = noMaintenance;
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(sorry, findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('a root keeps the app, under a strip, and switches it off', (
    tester,
  ) async {
    final roles = FakeRolesClient([userRole, adminRole, rootRole])
      ..maintenance = on;
    final membership = FakeMembershipClient()
      ..switched = (state: on, by: 'boss@nu01.com')
      ..onMaintenance = (state) => roles.maintenance = state;
    await open(tester, roles, membership: membership);
    expect(sorry, findsNothing);
    expect(find.byKey(const Key('maintenance-strip')), findsOneWidget);
    expect(find.byType(HomeScreen), findsOneWidget);

    await tester.tap(find.byTooltip('Admin'));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('maintenance-message-field'));
    expect(find.text('Back at 3 pm'), findsOneWidget, reason: 'its message');

    await tester.tap(find.byKey(const Key('maintenance-switch')));
    await tester.pumpAndSettle();
    expect(membership.switched.state.on, isFalse);
    expect(find.byKey(const Key('maintenance-strip')), findsNothing);
    expect(find.text('Maintenance mode is off'), findsOneWidget);

    // And on again, with a new message.
    await tester.enterText(field, 'Until noon');
    await tester.tap(find.byKey(const Key('maintenance-switch')));
    await tester.pumpAndSettle();
    expect(membership.switched.state, (
      on: true,
      message: 'Until noon',
      since: membership.switched.state.since,
    ));
    expect(roles.maintenance.on, isTrue);
    expect(find.byKey(const Key('maintenance-strip')), findsOneWidget);
  });

  testWidgets('an admin who isn\'t a root sees it but can\'t switch it', (
    tester,
  ) async {
    final roles = FakeRolesClient([userRole, adminRole]);
    final membership = FakeMembershipClient();
    await open(tester, roles, membership: membership);
    await tester.tap(find.byTooltip('Admin'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Only roots switch it.'), findsOneWidget);
    final toggle = tester.widget<SwitchListTile>(
      find.byKey(const Key('maintenance-switch')),
    );
    expect(toggle.onChanged, isNull);
    await tester.tap(find.byKey(const Key('maintenance-switch')));
    await tester.pumpAndSettle();
    expect(membership.switched.state.on, isFalse);
  });

  group('the API client', () {
    test('reads maintenance from the start check', () async {
      final client = HttpRolesClient(
        Uri.parse('https://presence.test/'),
        client: MockClient(
          (_) async => http.Response(
            '{"mode":"RBAC","roles":["presence_anonymous"],'
            '"settings":{"oidc":true,"aws":true,"rbacr":true},'
            '"maintenance":{"on":true,"message":"Soon","since":1760097600000}}',
            200,
          ),
        ),
      );
      final access = await client.anonymous();
      expect(access.maintenance.on, isTrue);
      expect(access.maintenance.message, 'Soon');
      expect(
        access.maintenance.since,
        DateTime.fromMillisecondsSinceEpoch(1760097600000, isUtc: true),
      );
    });

    test('an API that doesn\'t say isn\'t in maintenance', () {
      expect(maintenanceFromJson(null), noMaintenance);
      expect(maintenanceFromJson({'on': 'yes'}).on, isFalse);
    });

    test('admins switch it with a form', () async {
      late http.Request sent;
      final client = HttpMembershipClient(
        Uri.parse('https://presence.test/'),
        client: MockClient((request) async {
          sent = request;
          return http.Response(
            jsonEncode({
              'on': true,
              'message': 'Back & soon',
              'since': 1,
              'by': 'adam@example.com',
            }),
            200,
          );
        }),
      );
      final answer = await client.setMaintenance(
        'token',
        on: true,
        message: ' Back & soon ',
      );
      expect(sent.url.path, '/api/auth/maintenance');
      expect(sent.headers['authorization'], 'Bearer token');
      expect(Uri.splitQueryString(sent.body), {
        'on': 'true',
        'message': 'Back & soon',
      });
      expect(answer.state.on, isTrue);
      expect(answer.by, 'adam@example.com');
    });
  });
}
