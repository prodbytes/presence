import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';
import 'package:presence_app/cameras/camera_source.dart';
import 'package:presence_app/cloud/cloud_sync.dart';
import 'package:presence_app/cloud/live_sync.dart';
import 'package:presence_app/crypto/media_seal.dart';
import 'package:presence_app/storage/event_store.dart';
import 'package:presence_app/storage/media_platform_native.dart';
import 'package:presence_app/storage/media_store.dart';

import 'fakes.dart';
import 'sealed.dart';

void main() {
  Uint8List key(int fill) => Uint8List.fromList(List.filled(32, fill));

  group('device identity', () {
    test('the key is made with the ID, once', () async {
      final store = await EventStore.open(newIdbFactoryMemory());
      final first = await store.deviceIdentity(() => 'a_b_c', () => key(1));
      expect(first.id, 'a_b_c');
      expect(first.key, key(1));
      expect(first.purged, false);
      final again = await store.deviceIdentity(() => 'x_y_z', () => key(2));
      expect(again.id, 'a_b_c');
      expect(again.key, key(1));
      expect(again.purged, false);
      expect((await store.getSettings('device'))!['key'], base64Encode(key(1)));
    });

    test(
      "an older install's unsealed data goes when it gets its key",
      () async {
        final store = await EventStore.open(newIdbFactoryMemory());
        await store.putSettings('device', {'id': 'old_install_device'});
        await store.putSettings('consent', {'given': true});
        await store.putEvent({'id': 'e1', 'time': 1, 'type': 'appStarted'});
        await store.putClip({
          'id': 'c1',
          'eventId': 'e1',
          'thumbnail': [1],
        });
        await store.putMedia('c1-full', Uint8List.fromList([1, 2, 3]));
        await store.markSynced('id/events/e1.json', 'x');

        final identity = await store.deviceIdentity(
          () => 'new_id_unused',
          () => key(3),
        );
        expect(identity.id, 'old_install_device');
        expect(identity.key, key(3));
        expect(identity.purged, true);
        expect(await store.allEvents(), isEmpty);
        expect(await store.allClips(), isEmpty);
        expect(await store.mediaIds(), isEmpty);
        expect(await store.syncedKeys(), isEmpty);
        // Not the device's other settings.
        expect(await store.getSettings('consent'), {'given': true});
        // Once.
        expect(
          (await store.deviceIdentity(() => 'n', () => key(4))).purged,
          isFalse,
        );
      },
    );
  });

  group('recordings', () {
    test('IndexedDB keeps them sealed and opens them to play', () async {
      final store = await EventStore.open(newIdbFactoryMemory());
      final plain = Uint8List.fromList(List.generate(5000, (i) => i & 0xFF));
      Uint8List? played;
      final media = IdbMediaStore(
        store,
        MediaIo(
          readBytes: (_) async => plain,
          createUrl: (bytes, _) {
            played = bytes;
            return 'blob:played';
          },
        ),
      );
      await media.save(
        'c1-full',
        ClipMedia(url: 'blob:live', start: Duration.zero, end: Duration.zero),
      );
      final stored = (await store.getMedia('c1-full'))!;
      expect(SealFormat.isSealed(stored), isTrue);
      expect(opened(stored), plain);
      expect(await media.load('c1-full', 'video/webm'), 'blob:played');
      expect(played, plain);
      // Uploads read it sealed.
      final read = await media.read('c1-full');
      expect([for (final c in await read.stream.toList()) ...c], stored);
      // Downloads must be sealed.
      await expectLater(
        media.saveBytes('c2-full', Uint8List.fromList([1, 2, 3])),
        throwsA(isA<SealBroken>()),
      );
      await media.saveBytes('c2-full', sealed([1, 2, 3]));
      expect(await media.ids(), containsAll(['c1-full', 'c2-full']));
    });

    test('files are kept sealed, opened into copies, and old unsealed ones '
        'deleted', () async {
      final dir = await Directory.systemTemp.createTemp('sealed-media');
      addTearDown(() => dir.delete(recursive: true));
      final root = await Directory('${dir.path}/support').create();
      final cache = await Directory('${dir.path}/cache').create();
      // An older version's recording, unsealed.
      await Directory('${root.path}/clips').create();
      final legacy = File('${root.path}/clips/old-full.mp4')
        ..writeAsBytesSync([1, 2, 3]);
      final store = await EventStore.open(newIdbFactoryMemory());
      final media = FileMediaStore(store, root: root, cache: cache);

      final plain = Uint8List.fromList(List.generate(300 * 1024, (i) => i));
      final live = File('${cache.path}/live.mp4')..writeAsBytesSync(plain);
      final clip = ClipMedia(
        url: live.path,
        start: Duration.zero,
        end: const Duration(seconds: 1),
        mimeType: 'video/mp4',
      );
      await media.save('c1-full', clip);

      expect(await media.ids(), ['c1-full']);
      expect(legacy.existsSync(), isFalse);
      final stored = File('${root.path}/clips/c1-full.sealed');
      expect(SealFormat.isSealed(stored.readAsBytesSync()), isTrue);
      // The unsealed live file goes once nothing plays it.
      expect(clip.liveUrl, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(live.existsSync(), isFalse);

      final path = await media.load('c1-full', 'video/mp4');
      expect(path, startsWith('${cache.path}/open/'));
      expect(File(path).readAsBytesSync(), plain);
      await expectLater(
        media.saveBytes('c2-full', Uint8List.fromList([1])),
        throwsA(isA<SealBroken>()),
      );
    });
  });

  group('cloud', () {
    late EventStore store;
    late StreamController<Set<String>?> changes;
    late FakeCloudBackend backend;
    late FakeAuthService auth;
    late CloudSync sync;
    late MediaSeal seal;
    const prefix = 'us-east-1:identity';

    void object(String key, List<int> bytes, DateTime at) {
      backend.uploads['$prefix/$key'] = (
        bytes: Uint8List.fromList(bytes),
        contentType: 'application/json',
      );
      backend.modified['$prefix/$key'] = at;
    }

    setUp(() async {
      store = await EventStore.open(newIdbFactoryMemory());
      changes = StreamController<Set<String>?>.broadcast();
      backend = FakeCloudBackend();
      auth = FakeAuthService();
      seal = MediaSeal.forTests(deviceId: 'this_device_here');
      sync = CloudSync(
        auth: auth,
        backend: backend,
        store: Future.value(store),
        media: Future.value(IdbMediaStore(store)),
        changes: changes.stream,
        debounce: Duration.zero,
        seal: seal,
      );
    });

    tearDown(() {
      sync.dispose();
      changes.close();
      store.close();
    });

    test('the first sealing device marks the folder and deletes only what '
        'came before', () async {
      backend
        ..sealedSince = null
        ..now = () => DateTime.utc(2026, 10, 10, 12);
      final old = DateTime.utc(2026, 10, 1);
      object('events/year=2026/day=274/e1.json', utf8.encode('{}'), old);
      object('clips/year=2026/day=274/c1.json', utf8.encode('{}'), old);
      object('media/c1.jpg', [0xFF, 0xD8, 0xFF], old);
      object('media/c1/frames/f1.jpg', [0xFF, 0xD8, 0xFF], old);
      object('devices/other_device_one/settings.json', utf8.encode('{}'), old);
      // Sealed already, by a device that sealed after the marker.
      object('media/c9.jpg', sealed([1]), DateTime.utc(2026, 10, 10, 13));

      await auth.signIn();
      await sync.idle();

      expect(backend.sealedSince, DateTime.utc(2026, 10, 10, 12));
      expect(
        backend.deletes,
        unorderedEquals([
          'events/year=2026/day=274/e1.json',
          'clips/year=2026/day=274/c1.json',
          'media/c1.jpg',
          'media/c1/frames/f1.jpg',
        ]),
      );
      expect(backend.uploads.keys, contains('$prefix/media/c9.jpg'));
      expect(
        backend.uploads.keys,
        contains('$prefix/devices/other_device_one/settings.json'),
      );
      // Once per device and folder.
      expect((await store.getSettings('sealed'))!['folders'], [prefix]);
    });

    test("a purge that's refused doesn't fail the pass, and isn't marked "
        'done', () async {
      backend
        ..sealedSince = DateTime.utc(2026, 10, 5)
        ..failDelete = StateError('AccessDenied');
      object('media/c1.jpg', [0xFF], DateTime.utc(2026, 10, 1));
      await auth.signIn();
      await sync.idle();
      expect(sync.state, CloudSyncState.synced);
      expect(await store.getSettings('sealed'), isNull);
    });

    test("other devices' keys come from their settings", () async {
      final other = MediaSeal.forTests(deviceId: 'other_device_two');
      final otherKey = (await other.keys.own).key;
      object(
        CloudSync.settingsKey('other_device_two'),
        utf8.encode(
          jsonEncode({
            'deviceId': 'other_device_two',
            'mediaKey': MediaKeys.encode(otherKey),
            'updatedAt': 1,
            'config': <String, Object?>{},
          }),
        ),
        DateTime.utc(2026, 10, 10),
      );
      // Not another device's key under the wrong name.
      object(
        CloudSync.settingsKey('liar_device_x'),
        utf8.encode(
          jsonEncode({
            'deviceId': 'someone_else',
            'mediaKey': MediaKeys.encode(key(9)),
            'config': <String, Object?>{},
          }),
        ),
        DateTime.utc(2026, 10, 10),
      );
      final thumbnail = await other.seal(Uint8List.fromList([1, 2, 3]));
      await expectLater(seal.open(thumbnail), throwsA(isA<SealKeyMissing>()));

      await auth.signIn();
      await sync.idle();

      expect(seal.keys.keyOf('other_device_two'), otherKey);
      expect(seal.keys.keyOf('liar_device_x'), isNull);
      expect(seal.keys.keyOf('someone_else'), isNull);
      expect(await seal.open(thumbnail), [1, 2, 3]);
    });
  });

  group('live sync', () {
    test('an event message carries its sender\'s key', () {
      final payload = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'v': LiveSync.version,
            'kind': 'event',
            'deviceId': 'other_device_three',
            'identityId': 'us-east-1:identity',
            'mediaKey': MediaKeys.encode(key(5)),
            'event': {'id': 'e1', 'time': 1},
          }),
        ),
      );
      final event = LiveSync.parse(payload, identityId: 'us-east-1:identity')!;
      expect(MediaKeys.decode(event.mediaKey), key(5));
    });

    test('only a sealed thumbnail goes, or is taken', () {
      final clip = {
        'id': 'c1',
        'eventId': 'e1',
        'cameraId': 'cam',
        'state': 'complete',
      };
      final jpeg = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3];
      expect(
        LiveSync.clipMessageOf({...clip, 'thumbnail': jpeg})!['thumbnail'],
        isNull,
      );
      final message = LiveSync.clipMessageOf({
        ...clip,
        'thumbnail': sealed(jpeg),
      })!;
      expect(opened(base64Decode(message['thumbnail']! as String)), jpeg);
      expect(
        LiveSync.clipOf(message, clipId: 'c1')!['thumbnail'],
        isA<Uint8List>(),
      );
      expect(
        LiveSync.clipOf({
          ...clip,
          'thumbnail': base64Encode(jpeg),
        }, clipId: 'c1'),
        isNull,
      );
    });
  });
}
