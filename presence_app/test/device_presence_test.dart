import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/auth/account_sheet.dart';
import 'package:presence_app/camera_feeds.dart';
import 'package:presence_app/cloud/live_sync.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/device_presence.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/theme.dart';

import 'fakes.dart';
import 'live_sync_test.dart'
    show FakeBroker, acksTopic, credentials, identity, requestsTopic, until;

/// A ping or pong as another device publishes it.
Map<String, Object?> presenceOf(
  String kind, {
  String deviceId = 'other_device_one',
  String identityId = identity,
  int? sentAt,
  String? nonce,
}) => {
  'v': 1,
  'kind': kind,
  'deviceId': deviceId,
  'identityId': identityId,
  'sentAt': sentAt ?? DateTime.now().millisecondsSinceEpoch,
  'nonce': ?nonce,
};

/// Live sync as the widgets see it: connected (or not), with set answers.
class FakePresenceLive extends LiveSync {
  FakePresenceLive({this.connected = true, this.answers = const {}})
    : super(
        endpoint: 'abc-ats.iot.us-east-1.amazonaws.com',
        region: 'us-east-1',
        connect: (url, clientId, {persistent = false}) =>
            Completer<LiveConnection>().future,
      );

  final bool connected;
  final Map<String, DateTime> answers;
  int pings = 0;

  @override
  LiveSyncState get state =>
      connected ? LiveSyncState.connected : LiveSyncState.off;

  @override
  DateTime? seenOf(String deviceId) => answers[deviceId];

  @override
  Future<bool> ping() async {
    pings++;
    return true;
  }
}

void main() {
  group('ping and pong', () {
    late FakeBroker broker;
    late LiveSync live;
    late DateTime clock;

    setUp(() {
      broker = FakeBroker();
      clock = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch,
      );
      live = LiveSync(
        endpoint: 'abc-ats.iot.us-east-1.amazonaws.com',
        region: 'us-east-1',
        connect: broker.connect,
        now: () => clock,
        random: Random(1),
      );
    });

    tearDown(() => live.dispose());

    Future<void> connect() async {
      live.start(
        LiveLink(
          identityId: identity,
          deviceId: 'this_device_one',
          credentials: () async => credentials,
          onEvent: (_) async {},
        ),
      );
      await until(() => live.state == LiveSyncState.connected);
    }

    List<(String, Map<String, Object?>)> published() => [
      for (final (topic, payload) in broker.last.published)
        (
          topic,
          (jsonDecode(utf8.decode(payload)) as Map).cast<String, Object?>(),
        ),
    ];

    test('a ping goes out on requests; a pong answering it makes its '
        'sender live now', () async {
      await connect();
      expect(await live.ping(), isTrue);
      final (topic, ping) = published().single;
      expect(topic, requestsTopic);
      expect(ping['kind'], 'ping');
      expect(ping['deviceId'], 'this_device_one');
      final nonce = ping['nonce']! as String;
      expect(nonce, matches(RegExp(r'^[a-z0-9]{16}$')));

      // Its clock is an hour behind: answering this ping, it's live now.
      clock = clock.add(const Duration(seconds: 2));
      broker.last.deliver(
        acksTopic,
        presenceOf(
          'pong',
          nonce: nonce,
          sentAt: clock
              .subtract(const Duration(hours: 1))
              .millisecondsSinceEpoch,
        ),
      );
      await until(() => live.seenOf('other_device_one') != null);
      expect(live.seenOf('other_device_one'), clock);
      // Pongs aren't events.
      expect(live.received, 0);
      expect(live.sent, 0);
    });

    test('pings go at most every 25 s', () async {
      await connect();
      expect(await live.ping(), isTrue);
      clock = clock.add(const Duration(seconds: 10));
      expect(await live.ping(), isFalse);
      clock = clock.add(LiveSync.pingEvery);
      expect(await live.ping(), isTrue);
      expect(broker.last.published, hasLength(2));
    });

    test('no ping while disconnected or off', () async {
      expect(await live.ping(), isFalse);
      final off = LiveSync(endpoint: '', region: 'us-east-1');
      addTearDown(off.dispose);
      expect(await off.ping(), isFalse);
    });

    test('another device\'s ping is answered with a pong on acks, and its '
        'sender is seen; its own aren\'t', () async {
      await connect();
      final sentAt = clock.subtract(const Duration(seconds: 3));
      broker.last.deliver(
        requestsTopic,
        presenceOf(
          'ping',
          nonce: 'abcdefgh12345678',
          sentAt: sentAt.millisecondsSinceEpoch,
        ),
      );
      await until(() => broker.last.published.isNotEmpty);
      final (topic, pong) = published().single;
      expect(topic, acksTopic);
      expect(pong['kind'], 'pong');
      expect(pong['deviceId'], 'this_device_one');
      expect(pong['identityId'], identity);
      expect(pong['nonce'], 'abcdefgh12345678');
      // Not an answer to this device's ping: as old as it says.
      expect(live.seenOf('other_device_one'), sentAt);

      // Its own ping (another tab of this device): not answered or seen.
      clock = clock.add(const Duration(minutes: 1));
      broker.last.deliver(
        requestsTopic,
        presenceOf(
          'ping',
          deviceId: 'this_device_one',
          nonce: 'abcdefgh12345678',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(broker.last.published, hasLength(1));
      expect(live.seenOf('this_device_one'), isNull);
    });

    test('pings close together get one pong; a stale one none', () async {
      await connect();
      broker.last
        ..deliver(requestsTopic, presenceOf('ping', nonce: 'aaaaaaaa'))
        ..deliver(
          requestsTopic,
          presenceOf('ping', deviceId: 'other_two', nonce: 'bbbbbbbb'),
        );
      await until(() => live.seenOf('other_two') != null);
      expect(broker.last.published, hasLength(1));

      // Kept by a persistent session for 3 min: seen then, not answered.
      clock = clock.add(const Duration(minutes: 1));
      final stale = clock.subtract(const Duration(minutes: 3));
      broker.last.deliver(
        requestsTopic,
        presenceOf(
          'ping',
          deviceId: 'other_three',
          nonce: 'cccccccc',
          sentAt: stale.millisecondsSinceEpoch,
        ),
      );
      await until(() => live.seenOf('other_three') != null);
      expect(live.seenOf('other_three'), stale);
      expect(broker.last.published, hasLength(1));
    });

    test('invalid presence messages are dropped', () async {
      await connect();
      final c = broker.last;
      final bad = <(String, Object)>[
        // A ping without a nonce, or with a bad one.
        (requestsTopic, presenceOf('ping', deviceId: 'd1')),
        (requestsTopic, presenceOf('ping', deviceId: 'd2', nonce: 'a/b')),
        // Another identity's, another version, the wrong kind for the topic.
        (
          requestsTopic,
          presenceOf(
            'ping',
            deviceId: 'd3',
            nonce: 'aaaaaaaa',
            identityId: 'x',
          ),
        ),
        (
          requestsTopic,
          {...presenceOf('ping', deviceId: 'd4', nonce: 'aaaaaaaa'), 'v': 2},
        ),
        (acksTopic, presenceOf('ping', deviceId: 'd5', nonce: 'aaaaaaaa')),
        // An unsafe device ID, no sentAt, not JSON, too big.
        (acksTopic, presenceOf('pong', deviceId: '../d6')),
        (acksTopic, {...presenceOf('pong', deviceId: 'd7'), 'sentAt': 'x'}),
        (acksTopic, Uint8List.fromList(utf8.encode('{not json'))),
        (acksTopic, {...presenceOf('pong', deviceId: 'd8'), 'pad': 'x' * 2000}),
      ];
      for (final (topic, message) in bad) {
        c.deliver(topic, message);
      }
      c.deliver(acksTopic, presenceOf('pong', deviceId: 'good'));
      await until(() => live.seenOf('good') != null);
      for (final id in ['d1', 'd2', 'd3', 'd4', 'd5', '../d6', 'd7', 'd8']) {
        expect(live.seenOf(id), isNull, reason: id);
      }
      expect(c.published, isEmpty);
    });

    test('a pong dated in the future counts as now', () async {
      await connect();
      broker.last.deliver(
        acksTopic,
        presenceOf(
          'pong',
          sentAt: clock.add(const Duration(hours: 2)).millisecondsSinceEpoch,
        ),
      );
      await until(() => live.seenOf('other_device_one') != null);
      expect(live.seenOf('other_device_one'), clock);
    });
  });

  group('DevicePresence', () {
    final now = DateTime(2026, 10, 6, 12);

    DevicePresence of({
      Duration? answered,
      Duration? event,
      bool available = true,
    }) => DevicePresence.of(
      answeredAt: answered == null ? null : now.subtract(answered),
      lastEvent: event == null ? null : now.subtract(event),
      now: now,
      liveAvailable: available,
    );

    test('green: answered within 90 s', () {
      final p = of(answered: const Duration(seconds: 5));
      expect(p.level, PresenceLevel.live);
      expect(p.reason, 'Live — answered 5 s ago');
      expect(p.color, Gruvbox.green);
      expect(
        of(answered: const Duration(seconds: 89)).level,
        PresenceLevel.live,
      );
    });

    test('yellow: heard from or an event within 24 h', () {
      final p = of(answered: const Duration(seconds: 90));
      expect(p.level, PresenceLevel.recent);
      expect(p.reason, 'Last seen 1 min ago');
      expect(of(event: const Duration(hours: 3)).reason, 'Last seen 3 h ago');
      // The newer of the two.
      expect(
        of(
          answered: const Duration(hours: 30),
          event: const Duration(hours: 2),
        ).level,
        PresenceLevel.recent,
      );
      expect(of(event: const Duration(hours: 3)).color, Gruvbox.yellow);
    });

    test('red: older than 24 h, or never', () {
      final p = of(event: const Duration(days: 4));
      expect(p.level, PresenceLevel.old);
      expect(p.reason, 'Last seen 4 d ago');
      expect(p.color, Gruvbox.red);
      expect(of(event: const Duration(hours: 24)).level, PresenceLevel.old);
      expect(of().reason, 'Never seen');
    });

    test('without live sync, never green, and it says so', () {
      final p = of(answered: const Duration(seconds: 5), available: false);
      expect(p.level, PresenceLevel.recent);
      expect(p.reason, 'Last seen 5 s ago · live status unavailable');
    });

    test('this device: green while connected', () {
      expect(
        DevicePresence.of(
          now: now,
          liveAvailable: true,
          thisDevice: true,
          connected: true,
        ).level,
        PresenceLevel.live,
      );
      expect(
        DevicePresence.of(
          now: now,
          liveAvailable: false,
          thisDevice: true,
        ).reason,
        'This device — live status unavailable',
      );
    });
  });

  group('indicators', () {
    final now = DateTime.now();

    AppEvent eventOf(String device, Duration ago) => AppEvent.appStarted(
      deviceId: device,
      profileId: 'user-1',
      time: now.subtract(ago),
    );

    Color colorOf(WidgetTester tester, String key) {
      final dot = find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(Container),
      );
      return (tester.widget<Container>(dot).decoration! as BoxDecoration)
          .color!;
    }

    testWidgets('in the All grid, each device\'s dot; the grid pings when it '
        'shows', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final bus = StreamController<AppEvent>.broadcast();
      addTearDown(bus.close);
      final log = EventLog(bus.stream)
        ..addHistory([
          eventOf('brave_fox', const Duration(hours: 2)),
          eventOf('quiet_cat', const Duration(days: 3)),
          eventOf('zesty_owl', const Duration(days: 3)),
        ]);
      final rig = CameraRig(
        backend: openFakes([FakeCameraSource('Main')]),
        config: ConfigController(),
      );
      await rig.load();
      final live = FakePresenceLive(
        answers: {'zesty_owl': now.subtract(const Duration(seconds: 5))},
      );
      addTearDown(live.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: CameraFeedsView(
            rig: rig,
            log: log,
            deviceId: 'this_device',
            profileId: 'user-1',
            showAll: true,
            live: live,
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(live.pings, 1);
      expect(colorOf(tester, 'presence-this-device'), Gruvbox.green);
      expect(colorOf(tester, 'presence-zesty_owl'), Gruvbox.green);
      expect(colorOf(tester, 'presence-brave_fox'), Gruvbox.yellow);
      expect(colorOf(tester, 'presence-quiet_cat'), Gruvbox.red);
      expect(find.bySemanticsLabel(RegExp('^Live — answered')), findsOneWidget);
      expect(find.byTooltip('Last seen 2 h ago'), findsOneWidget);
      // And every 30 s while it shows.
      await tester.pump(const Duration(seconds: 30));
      expect(live.pings, 2);
      await tester.pumpWidget(const SizedBox());
      rig.dispose();
    });

    testWidgets('in the devices list, each device\'s dot, at 320 dp', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final live = FakePresenceLive(
        answers: {'brave_fox': now.subtract(const Duration(seconds: 20))},
      );
      addTearDown(live.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PresencePinger(
                live: live,
                builder: (_) => ProfileDevices(
                  profile: 'automatic_paranoid_axolotl',
                  thisDevice: 'calm_sunny_radio_with_a_long_name',
                  now: () => now,
                  live: live,
                  devices: [
                    (
                      id: 'calm_sunny_radio_with_a_long_name',
                      os: 'Android',
                      lastEvent: now,
                    ),
                    (
                      id: 'brave_fox',
                      os: 'Web (Firefox, Windows)',
                      lastEvent: now.subtract(const Duration(days: 2)),
                    ),
                    (id: 'old_device', os: null, lastEvent: null),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(live.pings, 1);
      expect(
        colorOf(tester, 'presence-calm_sunny_radio_with_a_long_name'),
        Gruvbox.green,
      );
      expect(colorOf(tester, 'presence-brave_fox'), Gruvbox.green);
      expect(colorOf(tester, 'presence-old_device'), Gruvbox.red);
      expect(find.byTooltip('Live — answered 20 s ago'), findsOneWidget);
      expect(find.byTooltip('Never seen'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('without live sync: yellow and red from events, and it says '
        'live status is unavailable', (tester) async {
      final live = FakePresenceLive(connected: false);
      addTearDown(live.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProfileDevices(
              profile: 'p',
              thisDevice: 'this_device',
              now: () => now,
              live: live,
              devices: [
                (id: 'this_device', os: null, lastEvent: now),
                (
                  id: 'brave_fox',
                  os: null,
                  lastEvent: now.subtract(const Duration(hours: 3)),
                ),
              ],
            ),
          ),
        ),
      );
      expect(colorOf(tester, 'presence-this_device'), Gruvbox.yellow);
      expect(colorOf(tester, 'presence-brave_fox'), Gruvbox.yellow);
      expect(
        find.byTooltip('Last seen 3 h ago · live status unavailable'),
        findsOneWidget,
      );
    });
  });
}
