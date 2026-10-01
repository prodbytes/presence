import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/system_health.dart';

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
}
