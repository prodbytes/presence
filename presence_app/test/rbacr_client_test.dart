import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:presence_app/auth/rbacr_client.dart';
import 'package:presence_app/auth/roles_service.dart';

void main() {
  final base = Uri.parse('https://rbacr.test');

  HttpRbacrClient client(
    Future<http.Response> Function(http.Request request) answer,
  ) => HttpRbacrClient(base, system: 'presence', client: MockClient(answer));

  group('presenceRoles', () {
    RbacrMe me(List<String> roles, {bool root = false}) => (
      email: 'ana@example.com',
      root: root,
      roles: {
        'presence': roles,
        'other': const ['admin'],
      },
    );

    test('maps rbacr\'s presence roles to the app\'s', () {
      expect(presenceRoles(me([]), 'presence'), isEmpty);
      expect(presenceRoles(me(['free']), 'presence'), [userRole]);
      expect(presenceRoles(me(['premium']), 'presence'), [
        premiumRole,
        userRole,
      ]);
      expect(presenceRoles(me(['admin']), 'presence'), [
        adminRole,
        premiumRole,
        userRole,
      ]);
      // Another system's roles, or unknown ones, give nothing.
      expect(presenceRoles(me(['viewer']), 'presence'), isEmpty);
      expect(presenceRoles(me(['free']), 'tabscan'), isEmpty);
    });

    test('a root gets every role, even without presence roles', () {
      expect(presenceRoles(me([], root: true), 'presence'), [
        adminRole,
        premiumRole,
        rootRole,
        userRole,
      ]);
    });
  });

  group('HttpRbacrClient', () {
    test('GET /api/me with the ID token', () async {
      late http.Request sent;
      final me = await client((request) async {
        sent = request;
        return http.Response(
          jsonEncode({
            'email': 'ana@example.com',
            'root': false,
            'globalRoles': [],
            'roles': {
              'presence': ['premium', 'free'],
              'tabscan': [],
            },
          }),
          200,
        );
      }).me('google-id-token');
      expect(sent.method, 'GET');
      expect(sent.url, Uri.parse('https://rbacr.test/api/me'));
      expect(sent.headers['authorization'], 'Bearer google-id-token');
      expect(me.email, 'ana@example.com');
      expect(me.root, isFalse);
      expect(me.roles['presence'], ['premium', 'free']);
      expect(presenceRoles(me, 'presence'), [premiumRole, userRole]);
    });

    test('a root, and rbacr refusing the token', () async {
      final root = await client(
        (_) async => http.Response(
          '{"email":"r@nu01.com","root":true,"globalRoles":["root"],'
          '"roles":{"presence":[]}}',
          200,
        ),
      ).me('t');
      expect(root.root, isTrue);
      expect(presenceRoles(root, 'presence'), contains(rootRole));
      expect(
        client((_) async => http.Response('{"error":"no"}', 401)).me('t'),
        throwsA(
          isA<RolesException>().having((e) => e.statusCode, 'status', 401),
        ),
      );
    });

    test('the system\'s maintenance status', () async {
      late http.Request sent;
      Future<bool> status(bool on) => client((request) async {
        sent = request;
        return http.Response(
          jsonEncode({
            'id': 'presence',
            'name': 'Presence',
            'url': 'https://presence.nu01.com',
            'maintenance': on,
          }),
          200,
        );
      }).maintenance('t');
      expect(await status(true), isTrue);
      expect(sent.url.path, '/api/systems/presence/status');
      expect(sent.headers['authorization'], 'Bearer t');
      expect(await status(false), isFalse);
      expect(
        client((_) async => http.Response('', 503)).maintenance('t'),
        throwsA(isA<RolesException>()),
      );
    });

    test('redeems a code as JSON, as the user', () async {
      late http.Request sent;
      await client((request) async {
        sent = request;
        return http.Response('{"grants":[]}', 201);
      }).redeem('t', ' 2026Q4-OTTER-FALCON-LEMUR ');
      expect(sent.method, 'POST');
      expect(sent.url.path, '/api/vouchers/redeem');
      expect(sent.headers['authorization'], 'Bearer t');
      expect(sent.headers['content-type'], startsWith('application/json'));
      expect(jsonDecode(sent.body), {'code': '2026Q4-OTTER-FALCON-LEMUR'});
    });

    test('redeem failures carry rbacr\'s status, and 402 its discount', () {
      Future<void> redeem(int status, String body) =>
          client((_) async => http.Response(body, status)).redeem('t', 'X');
      for (final status in [404, 409, 429]) {
        expect(
          redeem(status, '{"error":"nope"}'),
          throwsA(
            isA<RolesException>().having((e) => e.statusCode, 'status', status),
          ),
        );
      }
      expect(
        redeem(
          402,
          '{"error":"payment required","payment":{"code":"X",'
          '"systemId":"presence","roles":["premium"],"role":"premium",'
          '"discountPercent":25}}',
        ),
        throwsA(
          isA<PaymentRequiredException>().having(
            (e) => e.discount,
            'discount',
            25,
          ),
        ),
      );
      expect(
        redeem(402, 'not json'),
        throwsA(
          isA<PaymentRequiredException>().having(
            (e) => e.discount,
            'discount',
            isNull,
          ),
        ),
      );
    });

    test('only sends ID tokens over HTTPS (or to localhost)', () {
      expect(
        () => HttpRbacrClient(Uri.parse('http://rbacr.nu01.com')),
        throwsArgumentError,
      );
      expect(
        HttpRbacrClient(Uri.parse('http://localhost:8686')).base.host,
        'localhost',
      );
      expect(
        RbacrConfig.isSafe(Uri.parse('https://rc.rbacr.nu01.com')),
        isTrue,
      );
      expect(RbacrConfig.isSafe(Uri.parse('ftp://rbacr.nu01.com')), isFalse);
      // This build has no RBACR_URL: GA rbacr.
      expect(RbacrConfig.baseUrl, Uri.parse('https://rbacr.nu01.com'));
      expect(RbacrConfig.system, 'presence');
    });
  });
}
