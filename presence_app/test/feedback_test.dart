import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/feedback/feedback_client.dart';
import 'package:presence_app/home/home_navigation_bar.dart';
import 'package:presence_app/main.dart';

import 'fakes.dart';

void main() {
  group('HttpFeedbackClient', () {
    test('reads, sends and replies with the bearer token', () async {
      final requests = <http.Request>[];
      final client = HttpFeedbackClient(
        Uri.parse('https://presence.example'),
        client: MockClient((request) async {
          requests.add(request);
          return switch ('${request.method} ${request.url.path}') {
            'GET /api/auth/feedback' => http.Response(
              '{"messages":[{"from":"user","message":"hi","sentAt":"2026-10-10T12:00:00Z"},'
              '{"from":"admin","message":"hello","sentAt":"2026-10-10T12:05:00Z"}]}',
              200,
            ),
            'POST /api/auth/feedback' => http.Response(
              '{"from":"user","message":"Olá","sentAt":"2026-10-10T12:06:00Z"}',
              201,
            ),
            'GET /api/auth/feedback/threads' => http.Response(
              '{"threads":[{"email":"ana@example.com","name":"Ana","messages":['
              '{"from":"user","by":"","message":"hi","sentAt":"2026-10-10T12:00:00Z"}]}]}',
              200,
            ),
            _ => http.Response(
              '{"from":"admin","message":"ok","sentAt":"2026-10-10T12:07:00Z"}',
              201,
            ),
          };
        }),
      );

      final mine = await client.mine('token');
      expect(mine.map((m) => m.fromAdmin), [false, true]);
      expect(mine.last.message, 'hello');
      expect(mine.first.sentAt, DateTime.utc(2026, 10, 10, 12));

      final sent = await client.send('token', 'Olá');
      expect(sent.message, 'Olá');
      expect(utf8.decode(requests.last.bodyBytes), 'Olá');
      expect(requests.last.headers['content-type'], startsWith('text/plain'));

      final threads = await client.threads('token');
      expect(threads.single.email, 'ana@example.com');
      expect(threads.single.name, 'Ana');
      expect(threads.single.awaitingReply, isTrue);

      await client.reply('token', 'ana@example.com', 'Thanks & bye');
      expect(requests.last.url.path, '/api/auth/feedback/reply');
      expect(Uri.splitQueryString(requests.last.body), {
        'email': 'ana@example.com',
        'message': 'Thanks & bye',
      });
      expect(requests.map((r) => r.headers['authorization']).toSet(), {
        'Bearer token',
      });
    });

    test('failures throw the status', () async {
      final client = HttpFeedbackClient(
        Uri.parse('https://presence.example'),
        client: MockClient((_) async => http.Response('{}', 409)),
      );
      await expectLater(
        client.send('token', 'hi'),
        throwsA(
          isA<RolesException>().having((e) => e.statusCode, 'status', 409),
        ),
      );
    });
  });

  test('the Help tab comes after Settings, before the Log and Admin', () {
    expect(HomeTab.shown(help: true, log: true, admin: true), [
      HomeTab.camera,
      HomeTab.monitoring,
      HomeTab.settings,
      HomeTab.help,
      HomeTab.log,
      HomeTab.admin,
    ]);
    expect(
      HomeTab.shown(log: false, admin: false),
      isNot(contains(HomeTab.help)),
    );
    expect(HomeTab.help.label, 'Help');
    expect(HomeTab.help.title, 'Feedback & Help');
    expect(HomeTab.settings.title, 'Settings');
  });

  group('the app', () {
    Future<void> launch(
      WidgetTester tester,
      FakeRolesClient roles,
      FakeFeedbackClient feedback, {
      FakeAuthService? auth,
    }) async {
      tester.view.physicalSize = const Size(1280, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        PresenceApp(
          consentGiven: true,
          cameras: openFakes([FakeCameraSource('Main')]),
          auth: auth ?? FakeAuthService.signedIn(),
          rolesClient: roles,
          membershipClient: FakeMembershipClient(),
          feedbackClient: feedback,
          mapTiles: const SizedBox(),
          locator: NoLocation(),
        ),
      );
      await tester.pumpAndSettle();
    }

    final helpTab = find.byTooltip('Help');

    testWidgets('a member writes on the Help tab and reads the reply', (
      tester,
    ) async {
      final feedback = FakeFeedbackClient();
      await launch(tester, FakeRolesClient([userRole]), feedback);
      expect(
        find.descendant(of: find.byType(HomeNavigationBar), matching: helpTab),
        findsOneWidget,
      );
      expect(
        tester.getCenter(find.byTooltip('Settings')).dx,
        lessThan(tester.getCenter(helpTab).dx),
      );
      expect(find.byTooltip('Admin'), findsNothing);

      await tester.tap(helpTab);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('help-view')), findsOneWidget);
      expect(find.text('Feedback & Help'), findsOneWidget, reason: 'title');
      expect(find.text('No messages yet.'), findsOneWidget);

      final send = find.byKey(const Key('feedback-send'));
      ButtonStyleButton button() => tester.widget<ButtonStyleButton>(send);
      expect(button().onPressed, isNull, reason: 'blank');
      await tester.enterText(
        find.byKey(const Key('feedback-field')),
        '  The map is empty  ',
      );
      await tester.pump();
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(
        feedback.conversations['ana@example.com']!.single.message,
        'The map is empty',
      );
      expect(find.text('The map is empty'), findsOneWidget);
      expect(find.textContaining('You · '), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('feedback-field')))
            .controller!
            .text,
        isEmpty,
      );

      // An admin answers; Reload shows it.
      await feedback.reply('t', 'ana@example.com', 'Turn on location');
      await tester.tap(find.byKey(const Key('help-reload')));
      await tester.pumpAndSettle();
      expect(find.text('Turn on location'), findsOneWidget);
      expect(find.textContaining('Presence team · '), findsOneWidget);
    });

    testWidgets('a refused message keeps its text and says why', (
      tester,
    ) async {
      final feedback = FakeFeedbackClient();
      await launch(tester, FakeRolesClient([userRole]), feedback);
      await tester.tap(helpTab);
      await tester.pumpAndSettle();
      feedback.error = RolesException(409);
      await tester.enterText(find.byKey(const Key('feedback-field')), 'again');
      await tester.pump();
      await tester.tap(find.byKey(const Key('feedback-send')));
      await tester.pumpAndSettle();
      expect(
        find.text('You\'ve sent a lot today. Try again tomorrow.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('feedback-field')))
            .controller!
            .text,
        'again',
      );
    });

    testWidgets('no Help tab in DEV, signed out, or without access', (
      tester,
    ) async {
      await launch(
        tester,
        FakeRolesClient()..mode = ExecutionMode.dev,
        FakeFeedbackClient(),
        auth: FakeAuthService(),
      );
      expect(find.byType(HomeNavigationBar), findsOneWidget);
      expect(helpTab, findsNothing, reason: 'DEV');

      await launch(tester, FakeRolesClient.none(), FakeFeedbackClient());
      expect(helpTab, findsNothing, reason: 'no role');
    });

    testWidgets('an admin sees every conversation and replies', (tester) async {
      final feedback = FakeFeedbackClient(me: 'boss@nu01.com')
        ..names['bob@example.com'] = 'Bob'
        ..conversations['bob@example.com'] = [
          FeedbackMessage(
            fromAdmin: false,
            message: 'Clips are slow',
            sentAt: DateTime.utc(2026, 10, 9, 8),
          ),
        ]
        ..conversations['eve@example.com'] = [
          FeedbackMessage(
            fromAdmin: false,
            message: 'Thanks!',
            sentAt: DateTime.utc(2026, 10, 9, 9),
          ),
          FeedbackMessage(
            fromAdmin: true,
            by: 'boss@nu01.com',
            message: 'Glad to help',
            sentAt: DateTime.utc(2026, 10, 9, 10),
          ),
        ];
      await launch(tester, FakeRolesClient([userRole, adminRole]), feedback);
      await tester.tap(find.byTooltip('Admin'));
      await tester.pumpAndSettle();
      expect(find.text('Feedback'), findsOneWidget);
      final bob = find.byKey(const Key('feedback-bob@example.com'));
      final eve = find.byKey(const Key('feedback-eve@example.com'));
      expect(bob, findsOneWidget);
      expect(eve, findsOneWidget);
      // Eve's, answered last, comes first; Bob's awaits a reply.
      expect(tester.getTopLeft(eve).dy, lessThan(tester.getTopLeft(bob).dy));
      expect(
        find.descendant(of: bob, matching: find.byTooltip('Awaiting a reply')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: eve, matching: find.byTooltip('Answered')),
        findsOneWidget,
      );

      await tester.tap(find.descendant(of: bob, matching: find.text('Bob')));
      await tester.pumpAndSettle();
      expect(find.text('Clips are slow'), findsOneWidget);
      expect(find.textContaining('Member · '), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('feedback-reply-bob@example.com')),
          matching: find.byKey(const Key('feedback-field')),
        ),
        'Looking into it',
      );
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('feedback-reply-bob@example.com')),
          matching: find.byKey(const Key('feedback-send')),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        feedback.conversations['bob@example.com']!.last.message,
        'Looking into it',
      );
      expect(find.text('Looking into it'), findsOneWidget);
      expect(find.textContaining('boss@nu01.com · '), findsOneWidget);
      // Answered now, and first.
      expect(tester.getTopLeft(bob).dy, lessThan(tester.getTopLeft(eve).dy));
      expect(
        find.descendant(of: bob, matching: find.byTooltip('Answered')),
        findsOneWidget,
      );
    });
  });
}
