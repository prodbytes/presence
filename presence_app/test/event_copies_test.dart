import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';
import 'package:presence_app/cloud/cloud_sync.dart';
import 'package:presence_app/cloud/event_copies.dart';
import 'package:presence_app/cloud/live_sync.dart';
import 'package:presence_app/cloud/sigv4.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/copies_badge.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/storage/event_store.dart';
import 'package:presence_app/storage/media_store.dart';

import 'fakes.dart';

const identity = 'us-east-1:identity';
const acksTopic = 'presence/prod/$identity/acks';

/// A connection to [RoutingBroker], in memory.
class RoutedConnection implements LiveConnection {
  RoutedConnection(this.broker);

  final RoutingBroker broker;
  final _messages = StreamController<(String, Uint8List)>.broadcast();
  final _done = Completer<void>();
  final topics = <String>{};
  final published = <(String, Uint8List)>[];

  @override
  Stream<(String, Uint8List)> get messages => _messages.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> subscribe(String topic) async => topics.add(topic);

  @override
  Future<void> publish(String topic, Uint8List payload) async {
    published.add((topic, payload));
    broker.route(topic, payload);
  }

  @override
  Future<void> close() async => broker.connections.remove(this);

  void deliver(String topic, Uint8List payload) {
    if (topics.contains(topic)) _messages.add((topic, payload));
  }

  /// What was published on [topic], decoded.
  List<Map<String, Object?>> sentOn(String topic) => [
    for (final (t, payload) in published)
      if (t == topic)
        (jsonDecode(utf8.decode(payload)) as Map).cast<String, Object?>(),
  ];
}

/// AWS IoT in memory: each message goes to every connection subscribed to
/// its topic, the sender's included (as AWS IoT does).
class RoutingBroker {
  final connections = <RoutedConnection>[];

  Future<LiveConnection> connect(
    String url,
    String clientId, {
    bool persistent = false,
  }) async {
    final connection = RoutedConnection(this);
    connections.add(connection);
    return connection;
  }

  void route(String topic, Uint8List payload) {
    for (final c in List.of(connections)) {
      c.deliver(topic, payload);
    }
  }
}

class Settings implements DeviceSettings {
  Settings(this.id);

  final String id;

  @override
  Future<String> get deviceId async => id;

  @override
  Future<Map<String, Object?>> settingsRecord() async => {
    'deviceId': id,
    'updatedAt': 0,
    'config': <String, Object?>{},
  };

  @override
  Future<void> applySettings(Map<String, Object?> record) async {}

  @override
  Future<void> claimSettings(String profileId) async {}
}

/// Waits (real time) until [condition] holds.
Future<void> until(bool Function() condition, {String? reason}) async {
  for (var i = 0; i < 600 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue, reason: reason ?? 'timed out');
}

Uint8List bytesOf(Object json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

Map<String, Object?> ack(
  List<Object?> eventIds, {
  String deviceId = 'phone_b',
  Object? v = 1,
  Object? kind = 'copied',
  Object? identityId = identity,
  Object? sentAt = 5,
}) => {
  'v': v,
  'kind': kind,
  'deviceId': deviceId,
  'identityId': identityId,
  'sentAt': sentAt,
  'eventIds': eventIds,
};

/// One device of the profile: its storage, cloud sync and live sync.
class Device {
  Device(this.id, this.backend, this.auth, this.broker);

  final String id;
  final FakeCloudBackend backend;
  final FakeAuthService auth;
  final RoutingBroker broker;
  late final EventStore store;
  late final StreamController<Set<String>?> changes;
  late final LiveSync live;
  late final CloudSync sync;
  late final IdbMediaStore media;

  Future<void> start({LiveConfig config = LiveConfig.always}) async {
    store = await EventStore.open(newIdbFactoryMemory());
    media = IdbMediaStore(store);
    changes = StreamController<Set<String>?>.broadcast();
    live = LiveSync(
      endpoint: 'abc-ats.iot.us-east-1.amazonaws.com',
      region: 'us-east-1',
      connect: broker.connect,
      config: config,
      ackDelay: const Duration(milliseconds: 10),
      ackEvery: const Duration(milliseconds: 10),
    );
    sync = CloudSync(
      auth: auth,
      backend: backend,
      store: Future.value(store),
      media: Future.value(media),
      changes: changes.stream,
      debounce: Duration.zero,
      live: live,
      settings: Settings(id),
      prefetchRecordings: true,
      onRemote: (r) async {
        // As the app does (Persistence.importRemote).
        for (final c in r.clips) {
          await store.putClip(c);
        }
        for (final e in [...r.events, ...r.updated]) {
          await store.putEvent(e);
        }
      },
    );
  }

  CopiesSummary summaryOf(String eventId, {String? origin}) =>
      sync.copies.summaryOf(eventId, origin: origin);

  Future<void> stop() async {
    await sync.idle();
    sync.dispose();
    live.dispose();
    await changes.close();
    store.close();
  }
}

void main() {
  group('copied acks', () {
    test('a valid one is parsed', () {
      final parsed = LiveSync.parseCopied(
        bytesOf(ack(['e1', 'e2', 'e1'])),
        identityId: identity,
      )!;
      expect(parsed.deviceId, 'phone_b');
      expect(parsed.sentAt, 5);
      expect(parsed.eventIds, ['e1', 'e2']);
    });

    test('invalid ones are rejected', () {
      for (final bad in [
        ack(['e1'], v: 2),
        ack(['e1'], kind: 'pong'),
        ack(['e1'], identityId: 'us-east-1:other'),
        ack(['e1'], deviceId: '../etc'),
        ack(['e1'], sentAt: '5'),
        ack([]),
        ack(['../x']),
        ack([7]),
        ack([for (var i = 0; i < 33; i++) 'e$i']),
      ]) {
        expect(
          LiveSync.parseCopied(bytesOf(bad), identityId: identity),
          isNull,
          reason: '$bad',
        );
      }
      // Too big, and not JSON.
      expect(
        LiveSync.parseCopied(
          bytesOf({
            ...ack(['e1']),
            'pad': 'x' * 1100,
          }),
          identityId: identity,
        ),
        isNull,
      );
      expect(
        LiveSync.parseCopied(
          Uint8List.fromList([1, 2, 3]),
          identityId: identity,
        ),
        isNull,
      );
    });

    test(
      'are batched into few messages of at most 1 KB, and others\' are '
      'handed over (own ignored, repeats deduped, invalid dropped)',
      () async {
        final broker = RoutingBroker();
        final heard = <CopiedMessage>[];
        final live = LiveSync(
          endpoint: 'abc-ats.iot.us-east-1.amazonaws.com',
          region: 'us-east-1',
          connect: broker.connect,
          ackDelay: const Duration(milliseconds: 10),
          ackEvery: const Duration(milliseconds: 10),
        );
        addTearDown(live.dispose);
        live.start(
          LiveLink(
            identityId: identity,
            deviceId: 'phone_a',
            credentials: () async => const AwsCredentials(
              accessKeyId: 'AKIDEXAMPLE',
              secretAccessKey: 'secret',
              sessionToken: 'token',
            ),
            onEvent: (_) async {},
            onCopied: heard.add,
          ),
        );
        await until(() => live.state == LiveSyncState.connected);
        final ids = [for (var i = 0; i < 40; i++) 'mbx1abcd2e-0abc${i}xyz'];
        final sent = live.ackCopied(ids.take(20));
        final more = live.ackCopied(ids.skip(20));
        expect(await sent, isTrue);
        expect(await more, isTrue);
        final connection = broker.connections.single;
        final acks = connection.sentOn(acksTopic);
        expect(acks.length, inInclusiveRange(2, 3));
        expect([for (final a in acks) ...(a['eventIds']! as List)], ids);
        for (final (topic, payload) in connection.published) {
          if (topic == acksTopic) {
            expect(payload.length, lessThanOrEqualTo(1024));
          }
        }
        // Its own came back from the broker: ignored.
        expect(heard, isEmpty);

        // Another device's, twice, and a bad one.
        broker.route(acksTopic, bytesOf(ack(['e1'])));
        broker.route(acksTopic, bytesOf(ack(['e1'])));
        broker.route(acksTopic, bytesOf(ack(['e1'], identityId: 'other')));
        await until(() => heard.length == 2);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(heard, hasLength(2), reason: 'the bad one is dropped');
        expect(live.seenOf('phone_b'), isNotNull);
        final copies = EventCopies();
        for (final a in heard) {
          for (final id in a.eventIds) {
            copies.addDevice(id, a.deviceId, a.sentAt);
          }
        }
        expect(copies.of('e1')!.devices, {'phone_b': 5});
      },
    );

    test('not sent with live sync off', () async {
      final live = LiveSync(endpoint: '', region: 'us-east-1');
      addTearDown(live.dispose);
      expect(await live.ackCopied(['e1']), isFalse);
    });
  });

  group('EventCopies', () {
    test('a repeated ack changes nothing', () {
      final copies = EventCopies();
      var notified = 0;
      copies.addListener(() => notified++);
      expect(copies.addDevice('e1', 'phone_b', 1), isTrue);
      expect(copies.addDevice('e1', 'phone_b', 2), isFalse);
      expect(copies.addDevice('e1', '../x', 2), isFalse);
      expect(notified, 1);
      expect(copies.of('e1')!.devices, {'phone_b': 1});
    });

    test('the summary: count, label and tooltip', () {
      final copies = EventCopies()..deviceId = 'phone_a';
      // Recorded here, not uploaded yet.
      var s = copies.summaryOf('e1', origin: 'phone_a');
      expect(s.label, '1 copy — not uploaded yet');
      expect(s.tooltip, contains("other devices' copies are unknown"));
      copies
        ..liveOn = true
        ..setLocal('e1', self: true, cloud: true)
        ..addDevice('e1', 'phone_b', 1)
        // The origin and this device aren't counted twice.
        ..addDevice('e1', 'phone_a', 1);
      s = copies.summaryOf('e1', origin: 'phone_a');
      expect(s.count, 3);
      expect(s.label, '3 copies');
      expect(s.tooltip, 'This device, Cloud, phone_b');
      // Another device's, not here yet: the cloud and that device.
      copies.setLocal('e2', self: false, cloud: true);
      s = copies.summaryOf('e2', origin: 'phone_c');
      expect(s.holders, ['Cloud', 'phone_c']);
      expect(s.label, '2 copies');
    });

    test('kept across a restart, and bounded', () async {
      final store = EventStore.open(newIdbFactoryMemory());
      final copies = EventCopies(store: store, maxTracked: 3)..deviceId = 'a';
      await copies.loaded;
      copies
        ..setLocal('e1', self: true, cloud: false)
        ..setLocal('e2', self: true, cloud: true)
        ..addDevice('e2', 'phone_b', 7)
        ..markAcked(['e2'])
        ..setLocal('e3', self: false, cloud: true)
        ..setLocal('e4', self: true, cloud: true);
      await copies.flush();
      copies.dispose();

      final again = EventCopies(store: store, maxTracked: 3);
      await again.loaded;
      expect(again.of('e1'), isNull, reason: 'the oldest went');
      expect(again.of('e2')!.devices, {'phone_b': 7});
      expect(again.of('e2')!.acked, isTrue);
      expect(again.of('e2')!.cloud, isTrue);
      expect(again.of('e3')!.self, isFalse);
      expect(again.of('e4')!.self, isTrue);
      again.dispose();
      (await store).close();
    });
  });

  group('copyOf', () {
    const prefix = identity;
    final time = DateTime.utc(2026, 10, 6).millisecondsSinceEpoch;
    Map<String, Object?> event({
      String device = 'other',
      String? clipId = 'c1',
    }) => {'id': 'e1', 'time': time, 'deviceId': device, 'clipId': ?clipId};
    final key = CloudSync.eventKey(event());
    const complete = {
      'id': 'c1',
      'state': 'complete',
      'full': {'mediaId': 'c1-full', 'mimeType': 'video/webm'},
    };

    test('an event without media: its record, here and in the cloud', () {
      final e = event(clipId: null);
      expect(CloudSync.copyOf(e, synced: {}, prefix: prefix, deviceId: 'me'), (
        self: true,
        cloud: false,
      ));
      expect(
        CloudSync.copyOf(
          e,
          synced: {'$prefix/${CloudSync.eventKey(e)}': 'x'},
          prefix: prefix,
          deviceId: 'me',
        ),
        (self: true, cloud: true),
      );
    });

    test("another device's clip: held here once its recording is", () {
      final pending = {
        '$prefix/$key': 'x',
        '$prefix/media/c1.webm': 'c1-full',
        'fetch:$prefix/media/c1.webm': '1:c1-full',
      };
      expect(
        CloudSync.copyOf(
          event(),
          synced: pending,
          prefix: prefix,
          deviceId: 'me',
        ),
        (self: false, cloud: true),
        reason: 'no clip record here yet',
      );
      expect(
        CloudSync.copyOf(
          event(),
          clip: complete,
          synced: pending,
          prefix: prefix,
          deviceId: 'me',
        ),
        (self: false, cloud: true),
        reason: 'recording pending',
      );
      expect(
        CloudSync.copyOf(
          event(),
          clip: complete,
          synced: {...pending}..remove('fetch:$prefix/media/c1.webm'),
          prefix: prefix,
          deviceId: 'me',
        ),
        (self: true, cloud: true),
      );
    });

    test('a clip recorded here: held here at once, in the cloud once its '
        'recording is', () {
      final mine = event(device: 'me');
      expect(
        CloudSync.copyOf(
          mine,
          clip: const {'id': 'c1', 'state': 'recording'},
          synced: {'$prefix/$key': 'x'},
          prefix: prefix,
          deviceId: 'me',
        ),
        (self: true, cloud: false),
      );
      expect(
        CloudSync.copyOf(
          mine,
          clip: complete,
          synced: {'$prefix/$key': 'x', '$prefix/media/c1.webm': 'c1-full'},
          prefix: prefix,
          deviceId: 'me',
        ),
        (self: true, cloud: true),
      );
    });

    test('tagged frames must be there too', () {
      final tagged = {
        ...event(clipId: null),
        'clipId': 'c1',
        'annotations': [
          {'name': 'Rex', 'frameId': 'f1'},
        ],
      };
      final synced = {'$prefix/$key': 'x', '$prefix/media/c1.webm': 'c1-full'};
      expect(
        CloudSync.copyOf(
          tagged,
          clip: complete,
          synced: synced,
          prefix: prefix,
          deviceId: 'me',
        ),
        (self: false, cloud: false),
      );
      expect(
        CloudSync.copyOf(
          {
            ...tagged,
            'frames': {'f1': Uint8List(1)},
          },
          clip: complete,
          synced: {...synced, '$prefix/media/c1/frames/f1.jpg': 'f1'},
          prefix: prefix,
          deviceId: 'me',
        ),
        (self: true, cloud: true),
      );
    });
  });

  group('two devices', () {
    late FakeCloudBackend backend;
    late FakeAuthService auth;
    late RoutingBroker broker;
    late Device a;
    late Device b;

    setUp(() async {
      backend = FakeCloudBackend();
      auth = FakeAuthService();
      broker = RoutingBroker();
      a = Device('phone_a', backend, auth, broker);
      b = Device('phone_b', backend, auth, broker);
      await a.start();
      await b.start();
      await auth.signIn();
      await a.sync.idle();
      await b.sync.idle();
      await until(
        () =>
            a.live.state == LiveSyncState.connected &&
            b.live.state == LiveSyncState.connected,
      );
    });

    tearDown(() async {
      await a.stop();
      await b.stop();
    });

    test('a capture goes up, is published, copied with its media by the '
        'other device, which acks it: the count goes up', () async {
      final time = DateTime.now().millisecondsSinceEpoch;
      final event = <String, Object?>{
        'id': 'cap-1',
        'type': 'clip_requested',
        'title': 'Clip',
        'time': time,
        'deviceId': 'phone_a',
        'profileId': '1',
        'clipId': 'clip-1',
        'clipState': 'recording',
      };
      final clip = <String, Object?>{
        'id': 'clip-1',
        'eventId': 'cap-1',
        'cameraId': 'cam',
        'requestedAt': time,
        'beforeMs': 0,
        'afterMs': 1000,
        'state': 'recording',
      };
      // Taken: saved here while it records.
      await a.store.putEvent(event);
      await a.store.putClip(clip);
      a.changes.add({'cap-1'});
      await a.sync.idle();
      expect(
        a.summaryOf('cap-1', origin: 'phone_a').label,
        '1 copy — not uploaded yet',
      );
      // Up first, then published.
      expect(
        backend.uploads.keys,
        contains('$identity/${CloudSync.eventKey(event)}'),
      );
      final eventsTopic = 'presence/prod/$identity/events';
      expect(
        broker.connections.expand((c) => c.sentOn(eventsTopic)),
        hasLength(1),
      );
      await until(() => b.live.received == 1);
      await b.live.drained;
      await b.sync.idle();
      expect(await b.store.getEvent('cap-1'), isNotNull);
      expect(
        b.sync.copies.of('cap-1')?.self ?? false,
        isFalse,
        reason: 'its clip is still recording',
      );

      // The clip completes: recording, thumbnail and the event go up, and
      // the event is published again.
      await a.media.saveBytes('clip-1-full', Uint8List.fromList([1, 2, 3]));
      await a.store.putClip({
        ...clip,
        'state': 'complete',
        'thumbnail': Uint8List.fromList([9, 9]),
        'full': {
          'mediaId': 'clip-1-full',
          'startMs': 0,
          'endMs': 1000,
          'mimeType': 'video/webm',
        },
      });
      await a.store.putEvent({...event, 'clipState': 'complete'});
      a.changes.add({'cap-1'});
      await a.sync.idle();
      expect(a.summaryOf('cap-1', origin: 'phone_a').holders, [
        'This device',
        'Cloud',
      ]);

      // The other device gets it, its clip and its recording...
      await until(() => b.live.received == 2);
      await b.live.drained;
      await until(
        () => b.sync.copies.of('cap-1')?.self ?? false,
        reason: 'copied with its media',
      );
      expect(await b.store.getMedia('clip-1-full'), [1, 2, 3]);
      expect(b.summaryOf('cap-1', origin: 'phone_a').holders, [
        'This device',
        'Cloud',
        'phone_a',
      ]);
      // ...and says so: the count goes up on the first.
      await until(
        () =>
            a.sync.copies.of('cap-1')?.devices.containsKey('phone_b') ?? false,
        reason: 'acked',
      );
      final summary = a.summaryOf('cap-1', origin: 'phone_a');
      expect(summary.label, '3 copies');
      expect(summary.tooltip, 'This device, Cloud, phone_b');
      await until(() => b.sync.copies.of('cap-1')?.acked ?? false);

      // Not acked again by the next passes.
      final acks = broker.connections
          .expand((c) => c.sentOn(acksTopic))
          .where((m) => m['kind'] == 'copied')
          .length;
      b.changes.add(null);
      await b.sync.idle();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        broker.connections
            .expand((c) => c.sentOn(acksTopic))
            .where((m) => m['kind'] == 'copied'),
        hasLength(acks),
      );
    });
  });

  test('with live sync off: this device and the cloud, and the tooltip says '
      "other devices' copies are unknown", () async {
    final backend = FakeCloudBackend();
    final auth = FakeAuthService();
    final device = Device('phone_a', backend, auth, RoutingBroker());
    await device.start(config: LiveConfig.never);
    addTearDown(device.stop);
    await auth.signIn();
    await device.sync.idle();
    final event = <String, Object?>{
      'id': 'quiet',
      'type': 'generic',
      'title': 'Hello',
      'time': DateTime.now().millisecondsSinceEpoch,
      'deviceId': 'phone_a',
      'profileId': '1',
    };
    await device.store.putEvent(event);
    device.changes.add({'quiet'});
    await device.sync.idle();
    expect(device.sync.copies.liveOn, isFalse);
    final summary = device.summaryOf('quiet', origin: 'phone_a');
    expect(summary.holders, ['This device', 'Cloud']);
    expect(summary.tooltip, contains("other devices' copies are unknown"));
  });

  group('the badge', () {
    Future<void> pumpTimeline(
      WidgetTester tester,
      EventCopies copies,
      List<AppEvent> events,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final log = EventLog(const Stream.empty())..addHistory(events);
      addTearDown(log.dispose);
      await tester.pumpWidget(
        EventCopiesScope(
          copies: copies,
          child: MaterialApp(
            home: Scaffold(
              body: EventTimeline(
                log: log,
                deviceId: 'automatic_paranoid_gadget',
                showSystemEvents: ValueNotifier(true),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    AppEvent eventOf(String id, String device) => AppEvent(
      icon: Icons.door_front_door,
      title: 'Door opened',
      id: id,
      deviceId: device,
      time: DateTime(2026, 10, 6, 9),
    )..os = 'Web (Chrome, macOS)';

    testWidgets('shows the count on every card, with the holders in its '
        'tooltip, at 320 dp', (tester) async {
      final copies = EventCopies()
        ..deviceId = 'automatic_paranoid_gadget'
        ..liveOn = true
        ..setLocal('e1', self: true, cloud: true)
        ..addDevice('e1', 'loud_shy_kettle', 1);
      await pumpTimeline(tester, copies, [
        eventOf('e1', 'automatic_paranoid_gadget'),
        eventOf('e2', 'automatic_paranoid_gadget'),
      ]);
      expect(tester.takeException(), isNull);
      expect(find.text('2 copies'), findsNothing);
      expect(find.text('3 copies'), findsOneWidget);
      expect(find.text('1 copy — not uploaded yet'), findsOneWidget);
      final tooltip = tester.widget<Tooltip>(
        find
            .ancestor(of: find.text('3 copies'), matching: find.byType(Tooltip))
            .first,
      );
      expect(tooltip.message, 'This device, Cloud, loud_shy_kettle');
      // Fits: the badge stays inside the screen.
      final badge = tester.getRect(find.byKey(const Key('event-copies-e1')));
      expect(badge.right, lessThanOrEqualTo(320));

      // An ack comes in: the count goes up.
      copies.addDevice('e2', 'loud_shy_kettle', 2);
      copies.setLocal('e2', self: true, cloud: true);
      await tester.pump();
      expect(find.text('3 copies'), findsNWidgets(2));
    });

    testWidgets('in the details, the holders are listed', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final copies = EventCopies()
        ..deviceId = 'me'
        ..setLocal('e1', self: false, cloud: true);
      await tester.pumpWidget(
        EventCopiesScope(
          copies: copies,
          child: MaterialApp(
            home: Scaffold(
              body: EventCopiesBadge(
                event: eventOf('e1', 'loud_shy_kettle'),
                detailed: true,
              ),
            ),
          ),
        ),
      );
      expect(find.text('2 copies: Cloud, loud_shy_kettle'), findsOneWidget);
      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, contains("other devices' copies are unknown"));
    });
  });
}
