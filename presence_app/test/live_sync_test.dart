import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';
import 'package:presence_app/cloud/cloud_sync.dart';
import 'package:presence_app/cloud/live_sync.dart';
import 'package:presence_app/cloud/sigv4.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/crypto/media_seal.dart';
import 'package:presence_app/storage/event_store.dart';
import 'package:presence_app/storage/media_store.dart';

import 'fakes.dart';
import 'sealed.dart';

/// A connection to the broker, in memory.
class FakeLiveConnection implements LiveConnection {
  final _messages = StreamController<(String, Uint8List)>.broadcast();
  final _done = Completer<void>();
  final subscriptions = <String>[];
  final published = <(String, Uint8List)>[];
  bool closed = false;

  @override
  Stream<(String, Uint8List)> get messages => _messages.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> subscribe(String topic) async => subscriptions.add(topic);

  @override
  Future<void> publish(String topic, Uint8List payload) async =>
      published.add((topic, payload));

  @override
  Future<void> close() async => closed = true;

  /// A message from the broker.
  void deliver(String topic, Object message) => _messages.add((
    topic,
    message is Uint8List
        ? message
        : Uint8List.fromList(utf8.encode(jsonEncode(message))),
  ));

  /// The connection drops.
  void drop() => _done.complete();

  /// What was published, decoded.
  List<Map<String, Object?>> get sent => [
    for (final (_, payload) in published)
      (jsonDecode(utf8.decode(payload)) as Map).cast<String, Object?>(),
  ];
}

/// The broker: records each connection, and can refuse the next ones.
class FakeBroker {
  final connections = <FakeLiveConnection>[];
  final urls = <String>[];
  final clientIds = <String>[];

  /// Whether each connection asked for a persistent session.
  final persistent = <bool>[];

  /// How many of the next connections are refused.
  int refuse = 0;

  Future<LiveConnection> connect(
    String url,
    String clientId, {
    bool persistent = false,
  }) async {
    urls.add(url);
    clientIds.add(clientId);
    this.persistent.add(persistent);
    if (refuse > 0) {
      refuse--;
      throw StateError('refused');
    }
    final connection = FakeLiveConnection();
    connections.add(connection);
    return connection;
  }

  FakeLiveConnection get last => connections.last;
}

/// Waits (real time) until [condition] holds.
Future<void> until(bool Function() condition, {String? reason}) async {
  for (var i = 0; i < 400 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue, reason: reason ?? 'timed out');
}

const identity = 'us-east-1:identity';
const eventsTopic = 'presence/prod/$identity/events';
const requestsTopic = 'presence/prod/$identity/requests';
const acksTopic = 'presence/prod/$identity/acks';

const credentials = AwsCredentials(
  accessKeyId: 'AKIDEXAMPLE',
  secretAccessKey: 'secret',
  sessionToken: 'token',
);

/// A message as another device publishes it.
Map<String, Object?> messageOf(
  Map<String, Object?> event, {
  String deviceId = 'other_device_one',
  String identityId = identity,
  String? etag,
}) => {
  'v': 1,
  'kind': 'event',
  'deviceId': deviceId,
  'identityId': identityId,
  'sentAt': 1,
  'key': CloudSync.eventKey(event),
  'etag': ?etag,
  'event': event,
};

void main() {
  group('presigned URL', () {
    test('signed as AWS IoT expects, with the session token after', () {
      // Checked against an independent implementation of AWS's sample
      // (Python, hashlib/hmac).
      final url =
          const SigV4Signer(
            region: 'us-east-1',
            service: 'iotdevicegateway',
          ).presignWebSocket(
            host: 'abc123-ats.iot.us-east-1.amazonaws.com',
            credentials: const AwsCredentials(
              accessKeyId: 'AKIDEXAMPLE',
              secretAccessKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
              sessionToken: 'session/token+=',
            ),
            now: DateTime.utc(2026, 10, 6, 12, 34, 56),
          );
      expect(
        url,
        'wss://abc123-ats.iot.us-east-1.amazonaws.com/mqtt'
        '?X-Amz-Algorithm=AWS4-HMAC-SHA256'
        '&X-Amz-Credential=AKIDEXAMPLE%2F20261006%2Fus-east-1%2F'
        'iotdevicegateway%2Faws4_request'
        '&X-Amz-Date=20261006T123456Z'
        '&X-Amz-Expires=3600'
        '&X-Amz-SignedHeaders=host'
        '&X-Amz-Signature='
        '6b4979fbf8f64c22fa244292a972bf18532ea2ab3d7ca07d30b75d7e30da0134'
        '&X-Amz-Security-Token=session%2Ftoken%2B%3D',
      );
    });
  });

  group('messages', () {
    Uint8List bytes(Object message) =>
        Uint8List.fromList(utf8.encode(jsonEncode(message)));
    final event = {'id': 'e-1', 'type': 'clip_requested', 'time': 5};

    test('an event message parses', () {
      final parsed = LiveSync.parse(
        bytes(messageOf(event, etag: 'a' * 32)),
        identityId: identity,
      )!;
      expect(parsed.deviceId, 'other_device_one');
      expect(parsed.event, event);
      expect(parsed.etag, 'a' * 32);
    });

    test('inline media is stripped: messages carry metadata only', () {
      final parsed = LiveSync.parse(
        bytes(
          messageOf({
            ...event,
            'frames': {'f1': List.filled(400, 7)},
            'thumbnail': List.filled(400, 9),
            'jpeg': List.filled(400, 1),
            'annotations': [
              {'name': 'Rex', 'frameId': 'f1'},
            ],
          }),
        ),
        identityId: identity,
      )!;
      expect(parsed.event.keys, {'id', 'type', 'time', 'annotations'});
      // And never sent: metadataOf leaves it out before publishing.
      expect(
        LiveSync.metadataOf({
          ...event,
          'frames': {'f1': Uint8List(3)},
          'thumbnail': Uint8List(3),
        }).keys,
        {'id', 'type', 'time'},
      );
    });

    test('errors are logged without the presigned URL\'s query', () {
      expect(
        LiveSync.redact(
          StateError(
            "Connection to 'https://h:443/mqtt?X-Amz-Security-Token=secret#'"
            ' was not upgraded',
          ),
        ),
        "Bad state: Connection to 'https://h:443/mqtt?…' was not upgraded",
      );
    });

    test('malformed, foreign or oversized messages are dropped', () {
      LiveEvent? parse(Object message) =>
          LiveSync.parse(bytes(message), identityId: identity);
      expect(parse(messageOf(event, identityId: 'us-east-1:other')), isNull);
      expect(parse({...messageOf(event), 'v': 2}), isNull);
      expect(parse({...messageOf(event), 'kind': 'ack'}), isNull);
      expect(parse(messageOf({'type': 'x', 'time': 5})), isNull);
      expect(parse(messageOf({'id': 'e', 'time': '5'})), isNull);
      expect(parse(messageOf({'id': '../../x', 'time': 5})), isNull);
      expect(parse(messageOf({'id': '..', 'time': 5})), isNull);
      expect(parse(messageOf({...event, 'clipId': 'a/../b'})), isNull);
      expect(parse(messageOf(event, deviceId: 'a b')), isNull);
      expect(parse({...messageOf(event), 'etag': 'not-md5'}), isNull);
      expect(parse([1, 2, 3]), isNull);
      expect(
        LiveSync.parse(
          Uint8List.fromList(utf8.encode('{not json')),
          identityId: identity,
        ),
        isNull,
      );
      expect(
        parse(
          messageOf({...event, 'title': 'x' * (LiveSync.maxMessageBytes + 1)}),
        ),
        isNull,
      );
    });
  });

  group('LiveSync', () {
    late FakeBroker broker;
    late LiveSync live;
    late List<LiveEvent> received;

    // This device's media key, as CloudSync gives it.
    final mediaKey = MediaKeys.encode(Uint8List.fromList(List.filled(32, 3)));

    LiveLink link({
      String deviceId = 'this_device_one',
      AwsCredentials creds = credentials,
    }) => LiveLink(
      identityId: identity,
      deviceId: deviceId,
      credentials: () async => creds,
      onEvent: (e) async => received.add(e),
      mediaKey: mediaKey,
    );

    setUp(() {
      broker = FakeBroker();
      received = [];
      live = LiveSync(
        endpoint: 'abc-ats.iot.us-east-1.amazonaws.com',
        region: 'us-east-1',
        connect: broker.connect,
        minRetry: const Duration(milliseconds: 5),
        maxRetry: const Duration(milliseconds: 40),
      );
    });

    tearDown(() => live.dispose());

    test('off without an endpoint: nothing connects', () async {
      final off = LiveSync(
        endpoint: '',
        region: 'us-east-1',
        connect: broker.connect,
      );
      addTearDown(off.dispose);
      expect(off.enabled, isFalse);
      off.start(link());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(broker.urls, isEmpty);
      expect(off.state, LiveSyncState.off);
      expect(await off.publishEvent({'id': 'e', 'time': 1}, key: 'k'), isFalse);
    });

    test('connects with a signed URL, as the identity, to its topic', () async {
      live.start(link());
      await until(() => live.state == LiveSyncState.connected);
      expect(broker.urls.single, startsWith('wss://abc-ats.iot.us-east-1.'));
      expect(broker.urls.single, contains('iotdevicegateway'));
      expect(broker.urls.single, endsWith('&X-Amz-Security-Token=token'));
      expect(broker.clientIds.single, startsWith('$identity-this_device_one-'));
      // Always connected: a clean session.
      expect(broker.persistent.single, isFalse);
      expect(broker.last.subscriptions, [
        eventsTopic,
        requestsTopic,
        acksTopic,
      ]);
    });

    test('publishes an event\'s metadata, never its media', () async {
      live.start(link());
      await until(() => live.state == LiveSyncState.connected);
      final sent = await live.publishEvent(
        {
          'id': 'e-1',
          'time': 5,
          'clipId': 'c-1',
          'frames': {'f1': Uint8List(10)},
        },
        key: 'events/year=1970/day=001/e-1.json',
        etag: 'b' * 32,
      );
      expect(sent, isTrue);
      expect(broker.last.published.single.$1, eventsTopic);
      final message = broker.last.sent.single;
      expect(message, containsPair('deviceId', 'this_device_one'));
      expect(message, containsPair('identityId', identity));
      expect(message, containsPair('etag', 'b' * 32));
      expect(message, containsPair('key', 'events/year=1970/day=001/e-1.json'));
      expect(message['event'], {'id': 'e-1', 'time': 5, 'clipId': 'c-1'});
      // With the key that opens this device's sealed media elsewhere.
      expect(message, containsPair('mediaKey', mediaKey));
      expect(live.sent, 1);
    });

    test('hands over other devices\' events, in order; not its own, nor '
        'malformed or other topics\'', () async {
      live.start(link());
      await until(() => live.state == LiveSyncState.connected);
      final c = broker.last;
      c.deliver(eventsTopic, messageOf({'id': 'a', 'time': 1}));
      c.deliver(
        eventsTopic,
        messageOf({'id': 'own', 'time': 1}, deviceId: 'this_device_one'),
      );
      c.deliver(eventsTopic, {'garbage': true});
      c.deliver(
        'presence/prod/$identity/acks',
        messageOf({'id': 'x', 'time': 1}),
      );
      c.deliver(eventsTopic, messageOf({'id': 'b', 'time': 2}));
      await until(() => received.length == 2);
      await live.drained;
      expect(received.map((e) => e.event['id']), ['a', 'b']);
      expect(live.received, 2);
    });

    test('reconnects after a drop, and backs off while refused', () async {
      live.start(link());
      await until(() => live.state == LiveSyncState.connected);
      broker.refuse = 2;
      broker.last.drop();
      await until(() => broker.urls.length == 4, reason: 'reconnected');
      await until(() => live.state == LiveSyncState.connected);
      expect(broker.connections, hasLength(2));
      expect(broker.last.subscriptions, [
        eventsTopic,
        requestsTopic,
        acksTopic,
      ]);
    });

    test('a dropped connection is closed before reconnecting', () async {
      live.start(link());
      await until(() => live.state == LiveSyncState.connected);
      final dropped = broker.last;
      dropped.drop();
      await until(() => broker.connections.length == 2, reason: 'reconnected');
      expect(dropped.closed, isTrue, reason: 'its socket and timers go');
    });

    test('a change of the setting ends an ack flush under way: it says the '
        'rest didn\'t go, and only the new loop sends', () async {
      final acking = LiveSync(
        endpoint: 'abc-ats.iot.us-east-1.amazonaws.com',
        region: 'us-east-1',
        connect: broker.connect,
        ackDelay: const Duration(milliseconds: 5),
        ackEvery: const Duration(milliseconds: 60),
      );
      addTearDown(acking.dispose);
      acking.start(link());
      await until(() => acking.state == LiveSyncState.connected);
      final first = broker.last;
      final ids = [for (var i = 0; i < 40; i++) 'event_$i'];
      final sent = acking.ackCopied(ids);
      await until(() => first.published.isNotEmpty, reason: 'first batch');
      // The same link, started over in another mode of connecting.
      acking.config = const LiveConfig(
        mode: LiveMode.always,
        every: Duration(minutes: 2),
      );
      expect(await sent, isFalse);
      await until(() => acking.state == LiveSyncState.connected);
      final again = acking.ackCopied(['event_new']);
      expect(await again, isTrue);
      final acked = [
        for (final c in broker.connections)
          for (final m in c.sent)
            if (m['kind'] == 'copied') ...(m['eventIds']! as List),
      ];
      expect(acked, isNot(contains('event_39')));
      expect(acked.where((id) => id == 'event_new'), hasLength(1));
    });

    test('the wait doubles with each failure, up to the maximum', () async {
      broker.refuse = 100;
      live.start(link());
      await until(() => live.state == LiveSyncState.error);
      await until(() => broker.urls.length >= 5);
      expect(live.retryDelay, const Duration(milliseconds: 40));
      expect(live.error, contains('refused'));
    });

    test('renews its connection, with a new URL, before the credentials '
        'expire', () async {
      var calls = 0;
      live.start(
        LiveLink(
          identityId: identity,
          deviceId: 'this_device_one',
          // The first expire just after the renewal margin; the next later.
          credentials: () async => AwsCredentials(
            accessKeyId: 'AKID${calls++}',
            secretAccessKey: 'secret',
            sessionToken: 'token',
            expiration: DateTime.now().add(
              calls == 1
                  ? const Duration(minutes: 2, milliseconds: 50)
                  : const Duration(hours: 1),
            ),
          ),
          onEvent: (e) async => received.add(e),
        ),
      );
      await until(() => broker.connections.length == 2, reason: 'renewed');
      expect(broker.connections.first.closed, isTrue);
      expect(broker.urls.last, contains('AKID1'));
      await until(() => live.state == LiveSyncState.connected);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(broker.connections, hasLength(2));
    });

    test('stop disconnects, for good', () async {
      live.start(link());
      await until(() => live.state == LiveSyncState.connected);
      live.stop();
      expect(broker.last.closed, isTrue);
      expect(live.state, LiveSyncState.off);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(broker.urls, hasLength(1));
    });

    test('a hung attempt times out into the back-off', () async {
      // Credentials that never come, then a broker that never answers.
      var credentialCalls = 0;
      var connects = 0;
      final hung = LiveSync(
        endpoint: 'abc-ats.iot.us-east-1.amazonaws.com',
        region: 'us-east-1',
        connect: (url, clientId, {persistent = false}) {
          connects++;
          return Completer<LiveConnection>().future;
        },
        minRetry: const Duration(milliseconds: 5),
        maxRetry: const Duration(milliseconds: 10),
        connectTimeout: const Duration(milliseconds: 20),
      );
      addTearDown(hung.dispose);
      hung.start(
        LiveLink(
          identityId: identity,
          deviceId: 'this_device_one',
          credentials: () {
            if (++credentialCalls == 1) {
              return Completer<AwsCredentials>().future;
            }
            return Future.value(credentials);
          },
          onEvent: (_) async {},
        ),
      );
      await until(() => hung.state == LiveSyncState.error);
      expect(hung.error, contains('credentials took too long'));
      // It tries again: the connection hangs, and times out too.
      await until(() => connects >= 2, reason: 'retried after a hung connect');
      expect(hung.state, isNot(LiveSyncState.connected));
      expect(credentialCalls, greaterThanOrEqualTo(3));
    });
  });

  group('Connect to live sync', () {
    late FakeBroker broker;
    late List<LiveEvent> received;
    final made = <LiveSync>[];

    LiveLink link() => LiveLink(
      identityId: identity,
      deviceId: 'this_device_one',
      credentials: () async => credentials,
      onEvent: (e) async => received.add(e),
    );

    LiveSync make(
      LiveConfig config, {
      Duration drainQuiet = const Duration(milliseconds: 40),
      Duration drainMax = const Duration(milliseconds: 400),
      Duration maxJitter = const Duration(milliseconds: 20),
      Random? random,
    }) {
      final live = LiveSync(
        endpoint: 'abc-ats.iot.us-east-1.amazonaws.com',
        region: 'us-east-1',
        connect: broker.connect,
        config: config,
        random: random ?? Random(1),
        minRetry: const Duration(milliseconds: 5),
        maxRetry: const Duration(milliseconds: 40),
        drainQuiet: drainQuiet,
        drainMax: drainMax,
        maxJitter: maxJitter,
      );
      made.add(live);
      return live;
    }

    setUp(() {
      broker = FakeBroker();
      received = [];
    });

    tearDown(() {
      for (final live in made) {
        live.dispose();
      }
      made.clear();
    });

    test('Never: never connects, and publishes nothing', () async {
      final live = make(LiveConfig.never)..start(link());
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(broker.urls, isEmpty);
      expect(live.state, LiveSyncState.off);
      expect(
        await live.publishEvent({'id': 'e-1', 'time': 5}, key: 'k'),
        isFalse,
      );
      expect(broker.urls, isEmpty);
    });

    test('on a schedule: a persistent session with a stable client ID, '
        'disconnected once quiet, connecting again on time', () async {
      final live = make(const LiveConfig(every: Duration(milliseconds: 120)))
        ..start(link());
      await until(() => live.state == LiveSyncState.connected);
      expect(broker.persistent.single, isTrue);
      expect(broker.clientIds.single, '$identity-this_device_one');
      expect(broker.last.subscriptions, [
        eventsTopic,
        requestsTopic,
        acksTopic,
      ]);
      // Quiet: it disconnects until the next.
      await until(() => live.state == LiveSyncState.idle);
      expect(broker.last.closed, isTrue);
      expect(live.untilNext, isNotNull);
      expect(
        live.untilNext!,
        lessThanOrEqualTo(const Duration(milliseconds: 140)),
      );
      await until(() => broker.connections.length == 3, reason: 'on time');
      expect(broker.persistent, everyElement(isTrue));
      expect(broker.clientIds.toSet(), {'$identity-this_device_one'});
    });

    test('stays while queued messages come, at most its maximum', () async {
      final live = make(
        const LiveConfig(every: Duration(minutes: 1)),
        drainQuiet: const Duration(milliseconds: 80),
        drainMax: const Duration(milliseconds: 400),
      )..start(link());
      await until(() => live.state == LiveSyncState.connected);
      final c = broker.last;
      final started = DateTime.now();
      // What the broker kept while the device was away, then more: never
      // quiet for long.
      var n = 0;
      final drip = Timer.periodic(const Duration(milliseconds: 30), (_) {
        c.deliver(eventsTopic, messageOf({'id': 'q-${n++}', 'time': 1}));
      });
      addTearDown(drip.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(live.state, LiveSyncState.connected);
      await until(() => live.state == LiveSyncState.idle);
      drip.cancel();
      final stayed = DateTime.now().difference(started);
      expect(stayed, greaterThanOrEqualTo(const Duration(milliseconds: 350)));
      expect(stayed, lessThan(const Duration(seconds: 1)));
      await live.drained;
      expect(received, isNotEmpty);
      expect(received.first.event['id'], 'q-0');
    });

    test('a new event between connections connects at once to send it, '
        'then disconnects again', () async {
      final live = make(const LiveConfig(every: Duration(minutes: 1)))
        ..start(link());
      await until(() => live.state == LiveSyncState.idle);
      expect(broker.connections, hasLength(1));
      final sent = await live.publishEvent({
        'id': 'e-1',
        'time': 5,
      }, key: 'events/year=1970/day=001/e-1.json');
      expect(sent, isTrue);
      expect(broker.connections, hasLength(2));
      expect(broker.last.sent.single['event'], {'id': 'e-1', 'time': 5});
      expect(broker.persistent, [true, true]);
      expect(live.sent, 1);
      await until(() => live.state == LiveSyncState.idle);
      expect(broker.last.closed, isTrue);
    });

    test('the waits are the interval plus a new random jitter each time, '
        'within the persistent session\'s hour', () {
      final live = make(
        const LiveConfig(),
        maxJitter: const Duration(seconds: 10),
        random: Random(42),
      );
      const every = Duration(minutes: 1);
      final waits = [for (var i = 0; i < 200; i++) live.nextWait()];
      for (final wait in waits) {
        expect(wait, greaterThanOrEqualTo(every));
        expect(wait, lessThanOrEqualTo(every + const Duration(seconds: 10)));
      }
      expect(waits.toSet().length, greaterThan(100), reason: 'random');
      // The same seed, the same schedule.
      final again = make(
        const LiveConfig(),
        maxJitter: const Duration(seconds: 10),
        random: Random(42),
      );
      expect([for (var i = 0; i < 200; i++) again.nextWait()], waits);
      // 60 min: no later than a minute before the session would expire.
      final hourly = make(
        const LiveConfig(every: Duration(minutes: 60)),
        maxJitter: const Duration(seconds: 10),
      );
      for (var i = 0; i < 50; i++) {
        final wait = hourly.nextWait();
        expect(wait, greaterThanOrEqualTo(const Duration(minutes: 59)));
        expect(
          wait,
          lessThanOrEqualTo(const Duration(minutes: 59, seconds: 10)),
        );
      }
    });

    testWidgets('every 30 s, with the real timings: drains for 3 s, idles '
        '30 to 40 s, and connects again with the same session', (tester) async {
      var clock = DateTime.utc(2026, 10, 7, 12);
      final live = LiveSync(
        endpoint: 'abc-ats.iot.us-east-1.amazonaws.com',
        region: 'us-east-1',
        connect: broker.connect,
        config: const LiveConfig(every: Duration(seconds: 30)),
        now: () => clock,
        random: Random(7),
      );
      addTearDown(live.dispose);
      Future<void> advance(Duration d) async {
        const step = Duration(milliseconds: 500);
        for (var t = Duration.zero; t < d; t += step) {
          clock = clock.add(step);
          await tester.pump(step);
          // A cancelled subscription's future completes in the root
          // zone, outside the fake time: let it.
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        }
      }

      live.start(link());
      await advance(const Duration(milliseconds: 500));
      expect(live.state, LiveSyncState.connected);
      expect(broker.persistent.single, isTrue);
      // Quiet for 3 s: idle until the next, 30 s plus up to 10 s on.
      await advance(const Duration(seconds: 4));
      expect(live.state, LiveSyncState.idle);
      expect(broker.last.closed, isTrue);
      final left = live.untilNext!;
      expect(left, greaterThan(const Duration(seconds: 25)));
      expect(left, lessThanOrEqualTo(const Duration(seconds: 40)));
      await advance(left + const Duration(seconds: 1));
      expect(broker.connections, hasLength(2));
      expect(broker.persistent, [true, true]);
      expect(broker.clientIds.toSet(), {'$identity-this_device_one'});
      await advance(const Duration(seconds: 4));
      expect(live.state, LiveSyncState.idle);
      // Twice more within the next 80 s, never closer than 30 s apart.
      await advance(const Duration(seconds: 80));
      expect(broker.connections, hasLength(4));
      live.stop();
    });

    test('a change of the setting applies at once', () async {
      final live = make(LiveConfig.always)..start(link());
      await until(() => live.state == LiveSyncState.connected);
      expect(broker.persistent.single, isFalse);
      live.config = LiveConfig.never;
      expect(broker.last.closed, isTrue);
      expect(live.state, LiveSyncState.off);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(broker.connections, hasLength(1));
      live.config = const LiveConfig(every: Duration(minutes: 1));
      await until(() => broker.connections.length == 2);
      expect(broker.persistent.last, isTrue);
      expect(broker.clientIds.last, '$identity-this_device_one');
      await until(() => live.state == LiveSyncState.idle);
      live.config = LiveConfig.always;
      await until(() => live.state == LiveSyncState.connected);
      expect(broker.persistent.last, isFalse);
      // Always: stays connected.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(live.state, LiveSyncState.connected);
      expect(broker.connections, hasLength(3));
    });
  });

  group('with cloud sync', () {
    late EventStore store;
    late StreamController<Set<String>?> changes;
    late FakeCloudBackend backend;
    late FakeAuthService auth;
    late FakeBroker broker;
    late LiveSync live;
    late CloudSync sync;
    late List<RemoteRecords> remote;

    setUp(() async {
      store = await EventStore.open(newIdbFactoryMemory());
      changes = StreamController<Set<String>?>.broadcast();
      backend = FakeCloudBackend();
      auth = FakeAuthService();
      broker = FakeBroker();
      remote = [];
      live = LiveSync(
        endpoint: 'abc-ats.iot.us-east-1.amazonaws.com',
        region: 'us-east-1',
        connect: broker.connect,
        minRetry: const Duration(milliseconds: 5),
      );
      sync = CloudSync(
        auth: auth,
        backend: backend,
        store: Future.value(store),
        media: Future.value(IdbMediaStore(store)),
        changes: changes.stream,
        debounce: Duration.zero,
        live: live,
        prefetchRecordings: false,
        onRemote: (r) async {
          remote.add(r);
          // As the app does (Persistence.importRemote).
          for (final c in r.clips) {
            await store.putClip(c);
          }
          for (final e in [...r.events, ...r.updated]) {
            await store.putEvent(e);
          }
        },
      );
      await auth.signIn();
      await sync.idle();
      await until(() => live.state == LiveSyncState.connected);
    });

    tearDown(() {
      sync.dispose();
      live.dispose();
      changes.close();
      store.close();
    });

    int now() => DateTime.now().millisecondsSinceEpoch;

    test('off without an endpoint: syncs through the bucket only', () async {
      final off = LiveSync(
        endpoint: '',
        region: 'us-east-1',
        connect: broker.connect,
      );
      final other = CloudSync(
        auth: auth,
        backend: backend,
        store: Future.value(store),
        media: Future.value(IdbMediaStore(store)),
        changes: changes.stream,
        debounce: Duration.zero,
        live: off,
      );
      addTearDown(() {
        other.dispose();
        off.dispose();
      });
      await store.putEvent({
        'id': 'quiet',
        'profileId': '1',
        'type': 'x',
        'time': now(),
      });
      changes.add({'quiet'});
      await other.idle();
      expect(
        backend.uploads.keys.where((k) => k.endsWith('/quiet.json')),
        hasLength(1),
      );
      expect(off.state, LiveSyncState.off);
      expect(broker.connections, hasLength(1), reason: "only the main sync's");
    });

    test(
      'a saved event goes up, then is published, without its frames',
      () async {
        final record = {
          'id': 'new-event',
          'profileId': '1',
          'type': 'clip_requested',
          'time': now(),
          'clipId': 'new-clip',
          'annotations': [
            {'name': 'Rex', 'frameId': 'f1'},
          ],
          'frames': {
            'f1': sealed([1, 2, 3]),
          },
        };
        await store.putEvent(record);
        changes.add({'new-event'});
        await sync.idle();

        final key = CloudSync.eventKey(record);
        final uploaded = backend.uploads['$identity/$key']!.bytes;
        final message = broker.last.sent.single;
        expect(message['key'], key);
        expect(message['etag'], CloudSync.etagOf(uploaded));
        final event = message['event']! as Map;
        expect(event['id'], 'new-event');
        expect(event.containsKey('frames'), isFalse);
        // The frame itself is in the bucket, sealed.
        final frame = backend
            .uploads['$identity/${CloudSync.frameKeyOf('new-clip', 'f1')}'];
        expect(frame, isNotNull);
        expect(frame!.contentType, CloudSync.sealedType);
        expect(opened(frame.bytes), [1, 2, 3]);
      },
    );

    test('a received event is handed over at once, once, and neither '
        'uploaded back nor downloaded again', () async {
      final event = <String, Object?>{
        'id': 'from-phone',
        'profileId': '1',
        'type': 'generic',
        'title': 'From the phone',
        'time': now(),
      };
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(event)));
      final key = CloudSync.eventKey(event);
      final uploadedBefore = sync.uploaded;

      // Inline media in the message is dropped; the sender's media key is
      // taken, to open its sealed images.
      final phoneKey = Uint8List.fromList(List.filled(32, 5));
      broker.last.deliver(eventsTopic, {
        ...messageOf({
          ...event,
          'thumbnail': List.filled(100, 1),
        }, etag: CloudSync.etagOf(bytes)),
        'mediaKey': MediaKeys.encode(phoneKey),
      });
      await until(() => remote.isNotEmpty);
      await live.drained;
      expect(remote.single.live, isTrue);
      expect(remote.single.events.single['id'], 'from-phone');
      expect(remote.single.events.single.containsKey('thumbnail'), isFalse);
      expect(await store.getEvent('from-phone'), isNotNull);
      expect(MediaSeal.instance.keys.keyOf('other_device_one'), phoneKey);

      // The phone's upload lands in the bucket; passes run.
      backend.uploads['$identity/$key'] = (
        bytes: bytes,
        contentType: 'application/json',
      );
      // The same message again (QoS 1 may repeat it).
      broker.last.deliver(eventsTopic, messageOf(event));
      await live.drained;
      changes.add(null);
      await sync.idle();
      changes.add(null);
      await sync.idle();

      expect(remote, hasLength(1), reason: 'handed over once');
      expect(backend.downloads, isNot(contains(key)));
      expect(sync.uploaded, uploadedBefore, reason: 'not uploaded back');
      expect(broker.last.published, isEmpty, reason: 'not echoed');
    });

    test('a received clip event gets its clip and thumbnail from the bucket '
        'as soon as it completes', () async {
      final time = now();
      final event = <String, Object?>{
        'id': 'clip-event',
        'profileId': '1',
        'type': 'clip_requested',
        'time': time,
        'clipId': 'remote-clip',
        'clipState': 'partial',
      };
      broker.last.deliver(eventsTopic, messageOf(event));
      await until(() => remote.isNotEmpty);
      await sync.idle();
      // Still recording there: no clip in the bucket yet.
      expect(remote.where((r) => r.clips.isNotEmpty), isEmpty);

      // It completes there: clip record, thumbnail, recording go up, then
      // the event, which is published again.
      Uint8List json(Map<String, Object?> m) =>
          Uint8List.fromList(utf8.encode(jsonEncode(m)));
      backend
          .uploads['$identity/${CloudSync.clipRecordKey('remote-clip', time)}'] = (
        bytes: json({
          'id': 'remote-clip',
          'eventId': 'clip-event',
          'cameraId': 'cam',
          'state': 'complete',
          'full': {'mediaId': 'remote-clip-full', 'mimeType': 'video/webm'},
        }),
        contentType: 'application/json',
      );
      backend.uploads['$identity/media/remote-clip.jpg'] = (
        bytes: sealed([9, 9]),
        contentType: CloudSync.sealedType,
      );
      backend.uploads['$identity/media/remote-clip.webm'] = (
        bytes: sealed([1]),
        contentType: CloudSync.sealedType,
      );
      final complete = {...event, 'clipState': 'complete'};
      broker.last.deliver(eventsTopic, messageOf(complete));
      await until(() => remote.any((r) => r.clips.isNotEmpty));
      await sync.idle();

      final clips = remote.firstWhere((r) => r.clips.isNotEmpty);
      expect(clips.live, isTrue);
      expect(clips.clips.single['id'], 'remote-clip');
      // Held sealed, as it came.
      expect(opened(clips.clips.single['thumbnail']! as Uint8List), [9, 9]);
      // The recording isn't downloaded with it (on demand, or later).
      expect(backend.downloads, isNot(contains('media/remote-clip.webm')));
    });

    test('an event changed here and not uploaded yet wins over a received '
        'one', () async {
      final event = <String, Object?>{
        'id': 'mine',
        'profileId': '1',
        'type': 'clip_requested',
        'time': now(),
        'clipId': 'c',
      };
      broker.last.deliver(eventsTopic, messageOf(event));
      await until(() => remote.isNotEmpty);
      await live.drained;
      // Tagged here (not uploaded yet), and tagged differently there.
      await store.putEvent({
        ...event,
        'annotations': [
          {'name': 'Here'},
        ],
      });
      broker.last.deliver(
        eventsTopic,
        messageOf({
          ...event,
          'annotations': [
            {'name': 'There'},
          ],
        }),
      );
      await live.drained;
      expect(remote.where((r) => r.updated.isNotEmpty), isEmpty);
    });

    test('a pass doesn\'t put back an event live sync updated while it '
        'uploaded clips', () async {
      final time = now();
      final old = <String, Object?>{
        'id': 'raced',
        'profileId': '1',
        'type': 'clip_requested',
        'time': time,
        'clipId': 'raced-clip',
      };
      await store.putEvent(old);
      changes.add({'raced'});
      await sync.idle();
      final key = CloudSync.eventKey(old);
      expect(backend.uploads['$identity/$key'], isNotNull);
      final sentBefore = broker.last.sent.length;

      // Its clip completes here: the next pass uploads the recording
      // first, and that takes a while.
      await IdbMediaStore(store).saveBytes('raced-full', sealed(Uint8List(4)));
      await store.putClip({
        'id': 'raced-clip',
        'eventId': 'raced',
        'cameraId': 'cam',
        'requestedAt': time,
        'state': 'complete',
        'full': {'mediaId': 'raced-full', 'mimeType': 'video/webm'},
      });
      final recording = Completer<void>();
      var uploading = false;
      backend.beforePut = (k) async {
        if (k == 'media/raced-clip.webm') {
          uploading = true;
          await recording.future;
        }
      };
      changes.add({'raced'});
      await until(() => uploading);

      // Meanwhile another device tags it, uploads it and publishes it.
      final tagged = {
        ...old,
        'annotations': [
          {'name': 'Rex'},
        ],
      };
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(tagged)));
      backend.uploads['$identity/$key'] = (
        bytes: bytes,
        contentType: 'application/json',
      );
      broker.last.deliver(
        eventsTopic,
        messageOf(tagged, etag: CloudSync.etagOf(bytes)),
      );
      await until(() => remote.any((r) => r.updated.isNotEmpty));
      await live.drained;

      recording.complete();
      await sync.idle();
      expect(
        backend.uploads['$identity/$key']!.bytes,
        bytes,
        reason: 'the older version not put back',
      );
      expect((await store.getEvent('raced'))!['annotations'], isNotEmpty);
      expect(
        broker.last.sent.skip(sentBefore),
        isEmpty,
        reason: 'the older version not published',
      );
      expect(backend.uploads.keys, contains('$identity/media/raced-clip.webm'));
    });

    test('an event received while signing out is not taken', () async {
      backend.holdConnect = Completer<void>();
      // Its tagged frame is fetched from the bucket: held up.
      broker.last.deliver(
        eventsTopic,
        messageOf({
          'id': 'late',
          'profileId': '1',
          'type': 'clip_requested',
          'time': now(),
          'clipId': 'late-clip',
          'annotations': [
            {'name': 'Rex', 'frameId': 'f1'},
          ],
        }),
      );
      await until(() => backend.held > 0);
      final drained = live.drained;
      await auth.signOut();
      backend.holdConnect!.complete();
      backend.holdConnect = null;
      await drained;
      expect(remote, isEmpty);
      expect(await store.getEvent('late'), isNull);
    });

    Uint8List json(Map<String, Object?> m) =>
        Uint8List.fromList(utf8.encode(jsonEncode(m)));

    /// Puts clip [clipId] (of event [eventId] at [time]) in the bucket:
    /// record, thumbnail and recording.
    void clipInBucket(String clipId, String eventId, int time) {
      backend.uploads['$identity/${CloudSync.clipRecordKey(clipId, time)}'] = (
        bytes: json({
          'id': clipId,
          'eventId': eventId,
          'cameraId': 'cam',
          'state': 'complete',
          'full': {'mediaId': '$clipId-full', 'mimeType': 'video/webm'},
        }),
        contentType: 'application/json',
      );
      backend.uploads['$identity/media/$clipId.jpg'] = (
        bytes: sealed([9, 9]),
        contentType: CloudSync.sealedType,
      );
      backend.uploads['$identity/media/$clipId.webm'] = (
        bytes: sealed([1]),
        contentType: CloudSync.sealedType,
      );
    }

    test(
      'a wanted clip whose fetch fails is fetched at the next pass',
      () async {
        final time = now();
        clipInBucket('flaky-clip', 'flaky', time);
        final recordKey = CloudSync.clipRecordKey('flaky-clip', time);
        backend.failGets.add(recordKey);
        broker.last.deliver(
          eventsTopic,
          messageOf({
            'id': 'flaky',
            'profileId': '1',
            'type': 'clip_requested',
            'time': time,
            'clipId': 'flaky-clip',
            'clipState': 'complete',
          }),
        );
        await until(() => remote.isNotEmpty);
        await sync.idle();
        expect(backend.downloads, contains(recordKey), reason: 'tried');
        expect(remote.where((r) => r.clips.isNotEmpty), isEmpty);

        // The network is back: the next pass gets it.
        backend.failGets.clear();
        changes.add(<String>{});
        await sync.idle();
        final clips = remote.firstWhere((r) => r.clips.isNotEmpty);
        expect(clips.clips.single['id'], 'flaky-clip');
        expect(await store.clipIds(), contains('flaky-clip'));
      },
    );

    test('after a restart, the first pass fetches the clips of events whose '
        'clips never came', () async {
      final time = now();
      // Taken over live sync before the app closed; its clip is in the
      // bucket now, but the device has no record of it.
      await store.putEvent({
        'id': 'restarted',
        'profileId': '1',
        'type': 'clip_requested',
        'time': time,
        'clipId': 'restarted-clip',
        'clipState': 'complete',
      });
      clipInBucket('restarted-clip', 'restarted', time);
      final arrived = <RemoteRecords>[];
      final restarted = CloudSync(
        auth: auth,
        backend: backend,
        store: Future.value(store),
        media: Future.value(IdbMediaStore(store)),
        changes: const Stream.empty(),
        debounce: Duration.zero,
        prefetchRecordings: false,
        onRemote: (r) async {
          arrived.add(r);
          for (final c in r.clips) {
            await store.putClip(c);
          }
        },
      );
      addTearDown(restarted.dispose);
      await restarted.idle();
      expect(arrived.expand((r) => r.clips).map((c) => c['id']), [
        'restarted-clip',
      ]);
      expect(await store.clipIds(), contains('restarted-clip'));
    });

    test('signing out disconnects', () async {
      await auth.signOut();
      expect(live.state, LiveSyncState.off);
      expect(broker.last.closed, isTrue);
    });
  });
}
