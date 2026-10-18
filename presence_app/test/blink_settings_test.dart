import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/blink_settings.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/l10n/gen/app_localizations.dart';

void main() {
  late List<(String, String, Map<String, Object?>)> sent;
  late Map<String, Object?>? status;
  late bool sendWorks;
  late List<String> reads;
  String? leader;

  Future<void> show(
    WidgetTester tester, {
    List<String> streamers = const ['calm_quiet_otter'],
    ConfigController? config,
    Duration poll = const Duration(hours: 1),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: BlinkSettings(
              streamers: () => streamers,
              putFile: (device, name, json) async {
                if (!sendWorks) return false;
                sent.add((device, name, json));
                return true;
              },
              getFile: (device, name) async {
                reads.add(device);
                return status;
              },
              leader: () => leader,
              config: config,
              poll: poll,
              now: () => DateTime.fromMillisecondsSinceEpoch(1000),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    sent = [];
    status = null;
    sendWorks = true;
    reads = [];
    leader = null;
  });

  testWidgets('without a Linux streamer, it says to set one up', (
    tester,
  ) async {
    await show(tester, streamers: const []);
    expect(find.byKey(const Key('blink-no-streamer')), findsOneWidget);
  });

  testWidgets('connect: the login goes to the streamer, sealed; then the '
      'PIN, without the password; then its cameras, and disconnect', (
    tester,
  ) async {
    await show(tester);
    expect(find.text('Not connected to Blink.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('blink-email')), 'a@b.c');
    await tester.enterText(find.byKey(const Key('blink-password')), 'secret');
    await tester.tap(find.byKey(const Key('blink-connect')));
    await tester.pumpAndSettle();
    expect(sent.single.$1, 'calm_quiet_otter');
    expect(sent.single.$2, 'blink.json');
    expect(sent.single.$3, {
      'email': 'a@b.c',
      'password': 'secret',
      'requestedAt': 1000,
    });
    expect(find.textContaining('Sent to calm_quiet_otter'), findsOneWidget);

    // Blink asks for a PIN.
    status = {'state': 'pin-required', 'account': 'a@b.c', 'requestedAt': 1000};
    await tester.pumpWidget(Container());
    await show(tester);
    // (A new screen: nothing sent from it yet, so the status shows.)
    expect(find.textContaining("Blink sent a PIN to a@b.c"), findsOneWidget);
    await tester.enterText(find.byKey(const Key('blink-pin')), '123456');
    await tester.tap(find.byKey(const Key('blink-send-pin')));
    await tester.pumpAndSettle();
    expect(sent.last.$3, {
      'email': 'a@b.c',
      'pin': '123456',
      'requestedAt': 1000,
    });
    expect(sent.last.$3.containsKey('password'), isFalse);

    // Connected: its cameras, each a device.
    status = {
      'state': 'connected',
      'account': 'a@b.c',
      'requestedAt': 1000,
      'cameras': [
        {'name': 'Porch', 'deviceId': 'brave_little_lamp'},
      ],
      'lastFetch': 2000,
    };
    await tester.pumpWidget(Container());
    await show(tester);
    expect(find.textContaining('Connected to Blink as a@b.c'), findsOneWidget);
    expect(
      find.byKey(const Key('blink-camera-brave_little_lamp')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('blink-email')), findsNothing);
    await tester.tap(find.byKey(const Key('blink-disconnect')));
    await tester.pumpAndSettle();
    expect(sent.last.$3, {'disconnect': true, 'requestedAt': 1000});
  });

  testWidgets('an error shows, with the login form again; a send that fails '
      'says so', (tester) async {
    status = {'state': 'error', 'error': 'bad password', 'requestedAt': 1};
    sendWorks = false;
    await show(tester);
    expect(find.text('Blink: bad password'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('blink-email')), 'a@b.c');
    await tester.enterText(find.byKey(const Key('blink-password')), 'x');
    await tester.tap(find.byKey(const Key('blink-connect')));
    await tester.pumpAndSettle();
    expect(find.textContaining("Couldn't send it"), findsOneWidget);
  });

  group('the streamer', () {
    const streamers = ['calm_quiet_otter', 'brave_little_lamp', 'odd_shy_fox'];

    Future<void> connect(WidgetTester tester) async {
      await tester.enterText(find.byKey(const Key('blink-email')), 'a@b.c');
      await tester.enterText(find.byKey(const Key('blink-password')), 'pw');
      await tester.tap(find.byKey(const Key('blink-connect')));
      await tester.pumpAndSettle();
    }

    Future<void> pick(WidgetTester tester, String item) async {
      await tester.tap(find.byKey(const Key('blink-streamer')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(item).last);
      await tester.pumpAndSettle();
    }

    testWidgets('by default, the leader: and a new leader at the next '
        'refresh', (tester) async {
      leader = 'brave_little_lamp';
      final config = ConfigController();
      await show(
        tester,
        streamers: streamers,
        config: config,
        poll: const Duration(seconds: 10),
      );
      expect(find.text('Leader (brave_little_lamp)'), findsOneWidget);
      expect(reads.toSet(), {'brave_little_lamp'});
      await connect(tester);
      expect(sent.last.$1, 'brave_little_lamp');

      leader = 'odd_shy_fox';
      reads.clear();
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(reads.toSet(), {'odd_shy_fox'});
      expect(find.text('Leader (odd_shy_fox)'), findsOneWidget);
      // A new streamer: nothing sent to it yet.
      expect(find.text('Not connected to Blink.'), findsOneWidget);
      await connect(tester);
      expect(sent.last.$1, 'odd_shy_fox');
      expect(config.integrations.streamerFor('blink'), isNull);
    });

    testWidgets('no leader known: the first, said so', (tester) async {
      await show(tester, streamers: streamers);
      expect(
        find.text('Leader (none yet; calm_quiet_otter for now)'),
        findsOneWidget,
      );
      await connect(tester);
      expect(sent.last.$1, 'calm_quiet_otter');
    });

    testWidgets('one picked sticks when another leads, and is kept; Leader '
        'again clears it', (tester) async {
      leader = 'brave_little_lamp';
      final config = ConfigController();
      await show(
        tester,
        streamers: streamers,
        config: config,
        poll: const Duration(seconds: 10),
      );
      await pick(tester, 'calm_quiet_otter');
      expect(config.integrations.streamerFor('blink'), 'calm_quiet_otter');
      expect(config.integrations.streamerFor('gopro'), isNull);

      leader = 'odd_shy_fox';
      reads.clear();
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(reads.toSet(), {'calm_quiet_otter'});
      await connect(tester);
      expect(sent.last.$1, 'calm_quiet_otter');

      // Shown again, from the config.
      await tester.pumpWidget(Container());
      reads.clear();
      await show(tester, streamers: streamers, config: config);
      expect(reads.toSet(), {'calm_quiet_otter'});

      await pick(tester, 'Leader (odd_shy_fox)');
      expect(config.integrations.streamerFor('blink'), isNull);
      await connect(tester);
      expect(sent.last.$1, 'odd_shy_fox');
    });

    testWidgets('one picked that is no longer a streamer: the leader, the '
        'pick kept', (tester) async {
      leader = 'brave_little_lamp';
      final config = ConfigController();
      config.update(
        (c) => c.copyWith(
          integrations: c.integrations.withStreamer('blink', 'gone_away_box'),
        ),
      );
      await show(tester, streamers: streamers, config: config);
      expect(reads.toSet(), {'brave_little_lamp'});
      expect(find.text('Leader (brave_little_lamp)'), findsOneWidget);
      await connect(tester);
      expect(sent.last.$1, 'brave_little_lamp');
      expect(config.integrations.streamerFor('blink'), 'gone_away_box');
    });
  });
}
