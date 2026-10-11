import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:presence_app/auth/payment_links_editor.dart';
import 'package:presence_app/auth/payments_client.dart';
import 'package:presence_app/auth/roles_service.dart';

import 'fakes.dart';

const monthly = 'https://buy.stripe.com/dRm9AT6F71VfbaN1tl2Ji03';
const yearly = 'https://buy.stripe.com/yearly00';

/// The payments API, in memory: [stored] until [save]d; [status] fails it.
class FakePaymentsClient implements PaymentsClient {
  PaymentLinks stored = const PaymentLinks(monthly: monthly);
  int? status;
  final tokens = <String>[];

  @override
  Future<PaymentLinks> links(String idToken) async {
    tokens.add(idToken);
    if (status case final s?) throw RolesException(s, 'Payments API');
    return stored;
  }

  @override
  Future<PaymentLinks> save(
    String idToken, {
    required String monthly,
    required String yearly,
  }) async {
    tokens.add(idToken);
    if (status case final s?) throw RolesException(s, 'Payments API');
    return stored = PaymentLinks(
      monthly: monthly,
      yearly: yearly,
      saved: true,
      updatedAt: DateTime(2026, 10, 11),
    );
  }
}

void main() {
  group('PaymentLinks.fromJson', () {
    test('takes Stripe HTTPS links only', () {
      final links = PaymentLinks.fromJson({
        'monthly': monthly,
        'yearly': 'https://evil.example/pay',
        'saved': true,
        'updatedAt': 1790000000000,
      });
      expect(links.monthly, monthly);
      expect(links.yearly, '');
      expect(links.saved, isTrue);
      expect(
        links.updatedAt,
        DateTime.fromMillisecondsSinceEpoch(1790000000000),
      );
      expect(PaymentLinks.fromJson({}).isEmpty, isTrue);
    });
  });

  group('HttpPaymentsClient', () {
    test('reads and saves the links with the ID token', () async {
      final requests = <http.Request>[];
      final client = HttpPaymentsClient(
        Uri.parse('https://presence.example/app/'),
        client: MockClient((request) async {
          requests.add(request);
          return switch (request.method) {
            'GET' => http.Response(
              jsonEncode({'monthly': monthly, 'yearly': '', 'saved': false}),
              200,
            ),
            'PUT' => http.Response(
              jsonEncode({
                ...jsonDecode(request.body) as Map,
                'saved': true,
                'updatedAt': 1790000000000,
              }),
              200,
            ),
            _ => http.Response('', 404),
          };
        }),
      );
      expect(await client.links('tok'), const PaymentLinks(monthly: monthly));
      final saved = await client.save(
        'tok',
        monthly: ' $monthly ',
        yearly: yearly,
      );
      expect(saved.yearly, yearly);
      expect(saved.saved, isTrue);
      expect(requests.map((r) => '${r.method} ${r.url}'), [
        'GET https://presence.example/api/payments/links',
        'PUT https://presence.example/api/payments/links',
      ]);
      expect(requests.map((r) => r.headers['authorization']).toSet(), {
        'Bearer tok',
      });
      expect(jsonDecode(requests.last.body), {
        'monthly': monthly,
        'yearly': yearly,
      });
    });

    test('a refusal throws its status', () async {
      final client = HttpPaymentsClient(
        Uri.parse('https://presence.example/'),
        client: MockClient((_) async => http.Response('{}', 403)),
      );
      await expectLater(
        client.save('tok', monthly: '', yearly: ''),
        throwsA(
          isA<RolesException>().having((e) => e.statusCode, 'status', 403),
        ),
      );
    });
  });

  group('PaymentsService', () {
    test('loads at sign-in, forgets at sign-out', () async {
      final auth = FakeAuthService();
      final client = FakePaymentsClient();
      final payments = PaymentsService(auth: auth, client: client);
      addTearDown(payments.dispose);
      expect(payments.links, isNull);
      expect(client.tokens, isEmpty);

      await auth.signIn();
      await pumpEventQueue();
      expect(payments.links, const PaymentLinks(monthly: monthly));
      expect(client.tokens, ['id-token-1']);

      await auth.signOut();
      expect(payments.links, isNull);
    });

    test("stays unknown when the API doesn't answer", () async {
      final client = FakePaymentsClient()..status = 502;
      final payments = PaymentsService(
        auth: FakeAuthService.signedIn(),
        client: client,
      );
      addTearDown(payments.dispose);
      await pumpEventQueue();
      expect(payments.links, isNull);
    });
  });

  group('PaymentLinksEditor', () {
    Future<(FakePaymentsClient, PaymentsService)> show(
      WidgetTester tester,
    ) async {
      final client = FakePaymentsClient();
      final payments = PaymentsService(
        auth: FakeAuthService.signedIn(),
        client: client,
      );
      addTearDown(payments.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PaymentLinksEditor(payments: payments),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (client, payments);
    }

    testWidgets("shows the deploy's links, and saves new ones", (tester) async {
      final (client, payments) = await show(tester);
      expect(find.byKey(const Key('admin-payments-defaults')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('admin-payments-monthly')))
            .controller!
            .text,
        monthly,
      );

      await tester.enterText(
        find.byKey(const Key('admin-payments-yearly')),
        yearly,
      );
      await tester.tap(find.byKey(const Key('admin-payments-save')));
      await tester.pumpAndSettle();
      expect(client.stored.yearly, yearly);
      expect(client.stored.monthly, monthly);
      expect(payments.links!.saved, isTrue);
      expect(find.text('Payment links saved'), findsOneWidget);
      expect(find.byKey(const Key('admin-payments-defaults')), findsNothing);
    });

    testWidgets('refuses links that are not Stripe\'s', (tester) async {
      await show(tester);
      await tester.enterText(
        find.byKey(const Key('admin-payments-monthly')),
        'https://evil.example/pay',
      );
      await tester.pump();
      expect(find.text('Empty, or an https link on stripe.com'), findsOne);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('admin-payments-save')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('says why a save failed', (tester) async {
      final (client, _) = await show(tester);
      client.status = 403;
      await tester.tap(find.byKey(const Key('admin-payments-save')));
      await tester.pumpAndSettle();
      expect(find.textContaining("Couldn't save the links"), findsOneWidget);
    });
  });
}
