import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:presence_app/auth/auth_service.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/cloud/dynamodb.dart';
import 'package:presence_app/cloud/sigv4.dart';
import 'package:presence_app/feedback/feedback_client.dart';
import 'package:presence_app/home/home_navigation_bar.dart';
import 'package:presence_app/main.dart';

import 'fakes.dart';

void main() {
  group('DynamoFeedbackClient', () {
    late List<(String, Map<String, Object?>)> calls;
    late List<http.Response> answers;
    late FakeCloudBackend backend;
    DateTime now = DateTime.utc(2026, 10, 10, 12);

    DynamoFeedbackClient client({String table = 'feedback-table'}) {
      calls = [];
      backend = FakeCloudBackend();
      return DynamoFeedbackClient(
        backend: backend,
        table: table,
        user: () => const AuthUser(
          id: '1',
          email: 'ana@example.com',
          name: 'Ana\nSmith',
        ),
        now: () => now,
        db: DynamoDb(
          region: 'us-east-1',
          clock: AwsClock(now: () => now),
          client: MockClient((request) async {
            calls.add((
              request.headers['x-amz-target']!.split('.').last,
              (jsonDecode(request.body) as Map).cast<String, Object?>(),
            ));
            expect(request.url.host, 'dynamodb.us-east-1.amazonaws.com');
            expect(request.headers['authorization'], contains('/dynamodb/'));
            return answers.isEmpty
                ? http.Response('{}', 200)
                : answers.removeAt(0);
          }),
        ),
      );
    }

    Map<String, Object?> item(
      String conversation,
      int sentAt,
      String message, {
      bool admin = false,
      String? email,
      String? name,
    }) => {
      'conversation': {'S': conversation},
      'sentAt': {'N': '$sentAt'},
      'message': {'S': message},
      if (admin) 'fromAdmin': {'BOOL': true},
      if (admin) 'by': {'S': 'boss@nu01.com'},
      'email': ?(email == null ? null : {'S': email}),
      'name': ?(name == null ? null : {'S': name}),
    };

    http.Response page(List<Map<String, Object?>> items, {Object? next}) =>
        http.Response(
          jsonEncode({'Items': items, 'LastEvaluatedKey': ?next}),
          200,
        );

    test("a member reads only their profile's conversation, oldest first, "
        "never the replying admin's email", () async {
      final feedback = client();
      answers = [
        page([
          item('us-east-1:identity', 2000, 'Thanks', admin: true),
          item('us-east-1:identity', 1000, 'Hi'),
        ]),
      ];
      final messages = await feedback.mine('token');
      expect(messages.map((m) => m.message), ['Hi', 'Thanks']);
      expect(messages.last.fromAdmin, isTrue);
      final (op, request) = calls.single;
      expect(op, 'Query');
      expect(request['TableName'], 'feedback-table');
      expect(request['Select'], 'SPECIFIC_ATTRIBUTES');
      expect((request['ExpressionAttributeValues']! as Map)[':c'], {
        'S': 'us-east-1:identity',
      });
      expect(
        (request['ExpressionAttributeNames']! as Map).values,
        isNot(contains('by')),
      );
    });

    test('sending puts the message in its own conversation, as the member, '
        'never as an admin', () async {
      final feedback = client();
      answers = [page([]), http.Response('{}', 200)];
      final sent = await feedback.send('token', '  The map is blank  ');
      expect(sent.message, 'The map is blank');
      expect(sent.fromAdmin, isFalse);
      final (op, request) = calls.last;
      expect(op, 'PutItem');
      expect(request['Item'], {
        'conversation': {'S': 'us-east-1:identity'},
        'message': {'S': 'The map is blank'},
        'email': {'S': 'ana@example.com'},
        'name': {'S': 'Ana'},
        'sentAt': {'N': '${now.millisecondsSinceEpoch}'},
      });
      expect(request['ConditionExpression'], 'attribute_not_exists(sentAt)');
    });

    test(
      'blank and long messages are refused; so is the 21st of a day',
      () async {
        final feedback = client();
        await expectLater(
          feedback.send('token', '  '),
          throwsA(
            isA<RolesException>().having((e) => e.statusCode, 'status', 400),
          ),
        );
        await expectLater(
          feedback.send('token', 'x' * (FeedbackClient.maxMessage + 1)),
          throwsA(
            isA<RolesException>().having((e) => e.statusCode, 'status', 400),
          ),
        );
        answers = [
          page([
            for (var i = 0; i < FeedbackClient.dailyLimit; i++)
              item('us-east-1:identity', now.millisecondsSinceEpoch - i, 'm$i'),
          ]),
        ];
        await expectLater(
          feedback.send('token', 'one more'),
          throwsA(
            isA<RolesException>().having((e) => e.statusCode, 'status', 409),
          ),
        );
        expect(calls.map((c) => c.$1), ['Query']);
      },
    );

    test('admins list every conversation, the latest active first, across '
        'pages, and reply to one', () async {
      final feedback = client();
      answers = [
        page(
          [item('id-ana', 1000, 'Hi', email: 'ana@example.com', name: 'Ana')],
          next: {
            'conversation': {'S': 'id-ana'},
          },
        ),
        page([
          item('id-bob', 3000, 'Help', email: 'bob@example.com'),
          item('id-ana', 2000, 'Sure', admin: true),
        ]),
      ];
      final threads = await feedback.threads('token');
      expect(threads.map((t) => t.conversation), ['id-bob', 'id-ana']);
      expect(threads.last.email, 'ana@example.com');
      expect(threads.last.name, 'Ana');
      expect(threads.last.awaitingReply, isFalse);
      expect(threads.first.awaitingReply, isTrue);
      expect(calls.map((c) => c.$1), ['Scan', 'Scan']);
      expect(calls.last.$2['ExclusiveStartKey'], {
        'conversation': {'S': 'id-ana'},
      });

      answers = [http.Response('{}', 200)];
      final reply = await feedback.reply('token', 'id-bob', 'On it');
      expect(reply.fromAdmin, isTrue);
      expect(calls.last.$2['Item'], {
        'conversation': {'S': 'id-bob'},
        'message': {'S': 'On it'},
        'fromAdmin': {'BOOL': true},
        'by': {'S': 'ana@example.com'},
        'sentAt': {'N': '${now.millisecondsSinceEpoch}'},
      });
    });

    test("AWS's refusals say why; no table is unavailable", () async {
      final feedback = client();
      answers = [
        http.Response(
          jsonEncode({
            '__type': 'com.amazon.coral.service#AccessDeniedException',
          }),
          400,
        ),
      ];
      await expectLater(
        feedback.threads('token'),
        throwsA(
          isA<RolesException>().having((e) => e.statusCode, 'status', 403),
        ),
      );
      await expectLater(
        client(table: '').mine('token'),
        throwsA(
          isA<RolesException>().having((e) => e.statusCode, 'status', 503),
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
