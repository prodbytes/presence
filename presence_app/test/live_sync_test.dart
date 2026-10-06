import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';
import 'package:presence_app/cloud/cloud_sync.dart';
import 'package:presence_app/cloud/live_sync.dart';
import 'package:presence_app/cloud/sigv4.dart';
import 'package:presence_app/storage/event_store.dart';
import 'package:presence_app/storage/media_store.dart';

import 'fakes.dart';

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

  /// How many of the next connections are refused.
  int refuse = 0;

  Future<LiveConnection> connect(String url, String clientId) async {
    urls.add(url);
    clientIds.add(clientId);
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

    LiveLink link({
      String deviceId = 'this_device_one',
      AwsCredentials creds = credentials,
    }) => LiveLink(
      identityId: identity,
      deviceId: deviceId,
      credentials: () async => creds,
      onEvent: (e) async => received.add(e),
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
      expect(broker.last.subscriptions, [eventsTopic]);
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
      expect(live.published, 1);
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
      expect(broker.last.subscriptions, [eventsTopic]);
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
            'f1': Uint8List.fromList([1, 2, 3]),
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
        // The frame itself is in the bucket.
        expect(
          backend.uploads.keys,
          contains('$identity/${CloudSync.frameKeyOf('new-clip', 'f1')}'),
        );
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

      // Inline media in the message is dropped.
      broker.last.deliver(
        eventsTopic,
        messageOf({
          ...event,
          'thumbnail': List.filled(100, 1),
        }, etag: CloudSync.etagOf(bytes)),
      );
      await until(() => remote.isNotEmpty);
      await live.drained;
      expect(remote.single.live, isTrue);
      expect(remote.single.events.single['id'], 'from-phone');
      expect(remote.single.events.single.containsKey('thumbnail'), isFalse);
      expect(await store.getEvent('from-phone'), isNotNull);

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
        bytes: Uint8List.fromList([9, 9]),
        contentType: 'image/jpeg',
      );
      backend.uploads['$identity/media/remote-clip.webm'] = (
        bytes: Uint8List.fromList([1]),
        contentType: 'video/webm',
      );
      final complete = {...event, 'clipState': 'complete'};
      broker.last.deliver(eventsTopic, messageOf(complete));
      await until(() => remote.any((r) => r.clips.isNotEmpty));
      await sync.idle();

      final clips = remote.firstWhere((r) => r.clips.isNotEmpty);
      expect(clips.live, isTrue);
      expect(clips.clips.single['id'], 'remote-clip');
      expect(clips.clips.single['thumbnail'], [9, 9]);
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

    test('signing out disconnects', () async {
      await auth.signOut();
      expect(live.state, LiveSyncState.off);
      expect(broker.last.closed, isTrue);
    });
  });
}
