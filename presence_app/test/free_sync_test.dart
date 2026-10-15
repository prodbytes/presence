import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/cloud/cloud_sync.dart';
import 'package:presence_app/cloud/live_sync.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/storage/event_store.dart';
import 'package:presence_app/storage/media_store.dart';

import 'fakes.dart';
import 'sealed.dart';
import 'live_sync_test.dart' show FakeBroker, eventsTopic, messageOf, until;

/// A JPEG's first bytes, then filler: what a thumbnail looks like.
Uint8List jpeg([int length = 64]) =>
    Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(length - 4, 7)]);

/// A thumbnail as clips hold it: a JPEG of [length] bytes, sealed.
Uint8List thumbnail([int length = 64]) => sealed(jpeg(length));

Map<String, Object?> clipRecord({
  String id = 'clip-1',
  String state = 'complete',
  Object? thumbnail,
}) => {
  'id': id,
  'eventId': 'event-1',
  'cameraId': 'cam',
  'cameraLabel': 'Back camera',
  'state': state,
  'full': {'mediaId': '$id-full', 'mimeType': 'video/webm'},
  'thumbnail': ?thumbnail,
};

void main() {
  group('a clip in a live message', () {
    test('goes as its record and its thumbnail, never its recording', () {
      final thumb = thumbnail();
      final message = LiveSync.clipMessageOf({
        ...clipRecord(thumbnail: thumb),
        'recording': Uint8List(100),
      })!;
      expect(message['id'], 'clip-1');
      expect(message.containsKey('recording'), isFalse);
      // Sealed, as held.
      expect(message['thumbnail'], base64Encode(thumb));
      // And comes back as it was.
      final clip = LiveSync.clipOf(message, clipId: 'clip-1')!;
      expect(clip['thumbnail'], thumb);
      expect(opened(clip['thumbnail']! as Uint8List), jpeg());
      expect((clip['full']! as Map)['mediaId'], 'clip-1-full');
    });

    test('only a complete clip, the event\'s, with a small sealed image', () {
      expect(LiveSync.clipMessageOf(clipRecord(state: 'partial')), isNull);
      // Too big, not sealed (even a JPEG), or not an image: the clip goes
      // without it.
      final big = LiveSync.clipMessageOf(
        clipRecord(thumbnail: thumbnail(LiveSync.maxThumbnailBytes + 1)),
      )!;
      expect(big.containsKey('thumbnail'), isFalse);
      final unsealed = LiveSync.clipMessageOf(clipRecord(thumbnail: jpeg()))!;
      expect(unsealed.containsKey('thumbnail'), isFalse);
      final notImage = LiveSync.clipMessageOf(
        clipRecord(thumbnail: Uint8List.fromList([1, 2, 3, 4, 5])),
      )!;
      expect(notImage.containsKey('thumbnail'), isFalse);

      final message = LiveSync.clipMessageOf(
        clipRecord(thumbnail: thumbnail()),
      )!;
      // Another clip's, or not complete: refused.
      expect(LiveSync.clipOf(message, clipId: 'clip-2'), isNull);
      expect(
        LiveSync.clipOf({...message, 'state': 'partial'}, clipId: 'clip-1'),
        isNull,
      );
      expect(
        LiveSync.clipOf({...message, 'id': '../x'}, clipId: '../x'),
        isNull,
      );
      // A thumbnail that isn't one, or isn't sealed: refused.
      expect(
        LiveSync.clipOf({
          ...message,
          'thumbnail': base64Encode(jpeg()),
        }, clipId: 'clip-1'),
        isNull,
      );
      expect(
        LiveSync.clipOf({
          ...message,
          'thumbnail': base64Encode([1, 2, 3, 4, 5]),
        }, clipId: 'clip-1'),
        isNull,
      );
      expect(
        LiveSync.clipOf({
          ...message,
          'thumbnail': 'not base64!',
        }, clipId: 'clip-1'),
        isNull,
      );
      expect(
        LiveSync.clipOf({
          ...message,
          'thumbnail': base64Encode(thumbnail(LiveSync.maxThumbnailBytes + 1)),
        }, clipId: 'clip-1'),
        isNull,
      );
    });

    test('a bad clip leaves the event as it is', () {
      final event = {'id': 'event-1', 'time': 1, 'clipId': 'clip-1'};
      final parsed = LiveSync.parse(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              ...messageOf(event),
              'clip': {'id': 'clip-2', 'state': 'complete'},
            }),
          ),
        ),
        identityId: 'us-east-1:identity',
      )!;
      expect(parsed.event['id'], 'event-1');
      expect(parsed.clip, isNull);
    });
  });

  group('a free profile', () {
    late EventStore store;
    late StreamController<Set<String>?> changes;
    late FakeCloudBackend backend;
    late FakeAuthService auth;
    late FakeRolesClient client;
    late RolesService roles;
    late FakeBroker broker;
    late LiveSync live;
    late CloudSync sync;
    late List<RemoteRecords> remote;
    const profile = 'automatic_paranoid_axolotl';

    setUp(() async {
      store = await EventStore.open(newIdbFactoryMemory());
      changes = StreamController<Set<String>?>.broadcast();
      backend = FakeCloudBackend();
      auth = FakeAuthService();
      // A member, not premium.
      client = FakeRolesClient(const [userRole]);
      roles = RolesService(auth: auth, client: client);
      broker = FakeBroker();
      remote = [];
      // As the app sets it for a free member (LiveConfig.effective), on
      // a short schedule.
      live = LiveSync(
        endpoint: 'abc-ats.iot.us-east-1.amazonaws.com',
        region: 'us-east-1',
        connect: broker.connect,
        config: const LiveConfig(
          every: Duration(milliseconds: 400),
          free: true,
        ),
        minRetry: const Duration(milliseconds: 5),
        drainQuiet: const Duration(milliseconds: 150),
        maxJitter: const Duration(milliseconds: 1),
        beatFirst: const Duration(hours: 1),
      );
      sync = CloudSync(
        auth: auth,
        roles: roles,
        backend: backend,
        store: Future.value(store),
        media: Future.value(IdbMediaStore(store)),
        changes: changes.stream,
        debounce: Duration.zero,
        live: live,
        onRemote: (r) async {
          remote.add(r);
          for (final c in r.clips) {
            await store.putClip(c);
          }
          for (final e in [...r.events, ...r.updated]) {
            await store.putEvent(e);
          }
        },
      );
      await auth.signIn();
      await until(() => roles.hasAccess);
      await sync.idle();
      // Connected at start, then idle until the next one.
      await until(() => live.state == LiveSyncState.idle);
    });

    tearDown(() {
      sync.dispose();
      live.dispose();
      roles.dispose();
      changes.close();
      store.close();
    });

    int now() => DateTime.now().millisecondsSinceEpoch;

    Iterable<Map<String, Object?>> eventsSent() => [
      for (final c in broker.connections)
        for (final (topic, payload) in c.published)
          if (topic == eventsTopic)
            (jsonDecode(utf8.decode(payload)) as Map).cast<String, Object?>(),
    ];

    /// Waits for the next scheduled connection to come and go.
    Future<void> nextConnection() async {
      final n = broker.connections.length;
      await until(() => broker.connections.length > n);
      await until(() => live.state == LiveSyncState.idle);
    }

    test('syncs over live sync only: nothing to or from the bucket', () async {
      expect(sync.premium, isFalse);
      expect(sync.state, CloudSyncState.synced);
      expect(backend.uploads, isEmpty);
      expect(backend.listings, isEmpty);
      expect(backend.downloads, isEmpty);
      // Credentials yes: live sync needs them.
      expect(backend.tokens, isNotEmpty);
    });

    test('an event saved here waits for the next scheduled connection, and '
        'goes once, final, with its clip', () async {
      await nextConnection();
      final event = {
        'id': 'event-1',
        'profileId': profile,
        'type': 'clip_requested',
        'time': now(),
        'clipId': 'clip-1',
      };
      await store.putEvent(event);
      await store.putClip(clipRecord(state: 'recording'));
      changes.add({'event-1'});
      await sync.idle();
      // Not at once: no connection for it.
      expect(eventsSent(), isEmpty);
      // Still recording at the next connection: it waits.
      await nextConnection();
      expect(eventsSent(), isEmpty);

      // Its clip completes: the next connection sends it, with the clip
      // and its thumbnail, sealed.
      final thumb = thumbnail();
      await store.putClip(clipRecord(thumbnail: thumb));
      changes.add({'event-1'});
      await sync.idle();
      await until(() => eventsSent().isNotEmpty);
      final sent = eventsSent().single;
      expect((sent['event']! as Map)['id'], 'event-1');
      final clip = sent['clip']! as Map;
      expect(clip['id'], 'clip-1');
      expect(clip['thumbnail'], base64Encode(thumb));

      // Changed later: never again.
      await store.putEvent({...event, 'title': 'Changed'});
      changes.add({'event-1'});
      await sync.idle();
      await nextConnection();
      await nextConnection();
      expect(eventsSent(), hasLength(1));
      expect(backend.uploads, isEmpty);
    });

    test('a thumbnail over 12 KB stays out of a free message', () async {
      await store.putEvent({
        'id': 'event-1',
        'profileId': profile,
        'type': 'clip_requested',
        'time': now(),
        'clipId': 'clip-1',
      });
      await store.putClip(clipRecord(thumbnail: thumbnail(20 * 1024)));
      changes.add({'event-1'});
      await sync.idle();
      await until(() => eventsSent().isNotEmpty);
      final clip = eventsSent().single['clip']! as Map;
      expect(clip['id'], 'clip-1');
      expect(clip.containsKey('thumbnail'), isFalse);
    });

    test('another device\'s event comes with its clip from the message, '
        'never the bucket', () async {
      final event = {
        'id': 'remote-event',
        'profileId': profile,
        'type': 'clip_requested',
        'time': now(),
        'clipId': 'clip-1',
      };
      // Delivered during a scheduled connection.
      await until(() => live.state == LiveSyncState.connected);
      broker.last.deliver(eventsTopic, {
        ...messageOf(event),
        'clip': LiveSync.clipMessageOf(clipRecord(thumbnail: thumbnail())),
      });
      await until(() => remote.any((r) => r.clips.isNotEmpty));
      await sync.idle();
      expect(remote.first.events.single['id'], 'remote-event');
      final clip = remote.firstWhere((r) => r.clips.isNotEmpty).clips.single;
      // Held sealed, as it came.
      expect(opened(clip['thumbnail']! as Uint8List), jpeg());
      expect(await store.getClip('clip-1'), isNotNull);
      expect(backend.downloads, isEmpty);
      expect(backend.listings, isEmpty);
      // Its recording is on the device that made it.
      expect(await sync.fetchRecording('clip-1', 'clip-1-full'), isFalse);
      expect(backend.downloads, isEmpty);
    });

    test(
      'becoming premium starts the bucket sync, with new credentials',
      () async {
        await store.putEvent({
          'id': 'mine',
          'profileId': profile,
          'type': 'generic',
          'title': 'Mine',
          'time': now(),
        });
        final resets = backend.resets;
        client.roles = const [userRole, premiumRole];
        await roles.refresh();
        await until(() => sync.premium);
        await until(
          () => backend.uploads.keys.any((k) => k.endsWith('mine.json')),
        );
        expect(backend.resets, greaterThan(resets));
      },
    );
  });
}
