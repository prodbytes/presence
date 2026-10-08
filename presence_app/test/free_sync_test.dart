import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/cloud/cloud_sync.dart';
import 'package:presence_app/cloud/live_sync.dart';
import 'package:presence_app/storage/event_store.dart';
import 'package:presence_app/storage/media_store.dart';

import 'fakes.dart';
import 'live_sync_test.dart' show FakeBroker, eventsTopic, messageOf, until;

/// A JPEG's first bytes, then filler: what a thumbnail looks like.
Uint8List jpeg([int length = 64]) =>
    Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(length - 4, 7)]);

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
      final message = LiveSync.clipMessageOf({
        ...clipRecord(thumbnail: jpeg()),
        'recording': Uint8List(100),
      })!;
      expect(message['id'], 'clip-1');
      expect(message.containsKey('recording'), isFalse);
      expect(message['thumbnail'], base64Encode(jpeg()));
      // And comes back as it was.
      final clip = LiveSync.clipOf(message, clipId: 'clip-1')!;
      expect(clip['thumbnail'], jpeg());
      expect((clip['full']! as Map)['mediaId'], 'clip-1-full');
    });

    test('only a complete clip, the event\'s, with a small image', () {
      expect(LiveSync.clipMessageOf(clipRecord(state: 'partial')), isNull);
      // Too big, or not an image: the clip goes without it.
      final big = LiveSync.clipMessageOf(
        clipRecord(thumbnail: jpeg(LiveSync.maxThumbnailBytes + 1)),
      )!;
      expect(big.containsKey('thumbnail'), isFalse);
      final notImage = LiveSync.clipMessageOf(
        clipRecord(thumbnail: Uint8List.fromList([1, 2, 3, 4, 5])),
      )!;
      expect(notImage.containsKey('thumbnail'), isFalse);

      final message = LiveSync.clipMessageOf(clipRecord(thumbnail: jpeg()))!;
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
      // A thumbnail that isn't one: refused.
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
          'thumbnail': base64Encode(jpeg(LiveSync.maxThumbnailBytes + 1)),
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
      live = LiveSync(
        endpoint: 'abc-ats.iot.us-east-1.amazonaws.com',
        region: 'us-east-1',
        connect: broker.connect,
        minRetry: const Duration(milliseconds: 5),
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
        prefetchRecordings: false,
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
      await until(() => live.state == LiveSyncState.connected);
    });

    tearDown(() {
      sync.dispose();
      live.dispose();
      roles.dispose();
      changes.close();
      store.close();
    });

    int now() => DateTime.now().millisecondsSinceEpoch;

    test('syncs over live sync only: nothing to or from the bucket', () async {
      expect(sync.premium, isFalse);
      expect(sync.state, CloudSyncState.synced);
      expect(backend.uploads, isEmpty);
      expect(backend.listings, isEmpty);
      expect(backend.downloads, isEmpty);
      // Credentials yes: live sync needs them.
      expect(backend.tokens, isNotEmpty);
    });

    test('an event saved here goes to the other devices with its clip, once '
        'per version', () async {
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
      await until(() => broker.last.published.isNotEmpty);
      var sent = broker.last.sent.single;
      expect((sent['event']! as Map)['id'], 'event-1');
      // Still recording: no clip yet.
      expect(sent.containsKey('clip'), isFalse);

      // Nothing new: not again.
      changes.add({'event-1'});
      await sync.idle();
      expect(broker.last.published, hasLength(1));

      // Its clip completes: again, with the clip and its thumbnail.
      await store.putClip(clipRecord(thumbnail: jpeg()));
      changes.add({'event-1'});
      await sync.idle();
      await until(() => broker.last.published.length == 2);
      sent = broker.last.sent.last;
      final clip = sent['clip']! as Map;
      expect(clip['id'], 'clip-1');
      expect(clip['thumbnail'], base64Encode(jpeg()));
      expect(backend.uploads, isEmpty);
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
      broker.last.deliver(eventsTopic, {
        ...messageOf(event),
        'clip': LiveSync.clipMessageOf(clipRecord(thumbnail: jpeg())),
      });
      await until(() => remote.any((r) => r.clips.isNotEmpty));
      await sync.idle();
      expect(remote.first.events.single['id'], 'remote-event');
      final clip = remote.firstWhere((r) => r.clips.isNotEmpty).clips.single;
      expect(clip['thumbnail'], jpeg());
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
