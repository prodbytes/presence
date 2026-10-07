import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_client_memory.dart';
import 'package:idb_shim/idb_shim.dart';

import 'package:presence_app/clips.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/storage/event_store.dart';
import 'package:presence_app/storage/media_platform_native.dart';
import 'package:presence_app/storage/media_store.dart';
import 'package:presence_app/storage/persistence.dart';
import 'package:presence_app/storage/records.dart';

void main() {
  group('Records', () {
    test('an event needs an id and an integer time; integral doubles are '
        'made ints, and text fields of the wrong type dropped', () {
      expect(Records.tryParseEvent({'time': 1}), isNull);
      expect(Records.tryParseEvent({'id': 'e', 'time': 'x'}), isNull);
      expect(Records.tryParseEvent({'id': 'e', 'time': 1.5}), isNull);
      expect(Records.tryParseEvent({'id': 7, 'time': 1}), isNull);
      final event = Records.tryParseEvent({
        'id': 'e',
        'time': 5.0,
        'title': 3,
        'deviceId': 'd',
        'deletedAt': 'soon',
        'annotations': [],
      })!;
      expect(event['time'], 5);
      expect(event['time'], isA<int>());
      expect(event.containsKey('title'), isFalse);
      expect(event.containsKey('deletedAt'), isFalse);
      expect(event['deviceId'], 'd');
      expect(event['annotations'], isEmpty, reason: 'the rest is kept');
    });

    test('from the bucket, IDs must be safe', () {
      expect(
        Records.tryParseEvent({'id': '../e', 'time': 1}, safeIds: true),
        isNull,
      );
      expect(
        Records.tryParseEvent({
          'id': 'e',
          'time': 1,
          'clipId': 'c/../../x',
        }, safeIds: true),
        isNull,
      );
      expect(Records.tryParseClip({'id': 'a/b'}, safeIds: true), isNull);
      expect(Records.tryParseClip({'id': 'a/b'}), isNotNull);
    });

    test('a clip keeps what it can: a damaged recording reference goes, '
        'durations become ints', () {
      final clip = Records.tryParseClip({
        'id': 'c',
        'cameraId': 5,
        'beforeMs': 5000.0,
        'afterMs': 'long',
        'past': {'mediaId': '../../etc/passwd', 'startMs': 0},
        'full': {'mediaId': 'c-full', 'startMs': 0.0, 'mimeType': 4},
        'thumbnail': 'not bytes',
      })!;
      expect(clip.containsKey('cameraId'), isFalse);
      expect(clip['beforeMs'], 5000);
      expect(clip.containsKey('afterMs'), isFalse);
      expect(clip.containsKey('past'), isFalse);
      expect(clip['full'], {'mediaId': 'c-full', 'startMs': 0, 'endMs': 0});
      expect(clip.containsKey('thumbnail'), isFalse);
      expect(Records.tryParseClip({'cameraId': 'cam'}), isNull);
    });

    test('settings need a device ID and a config', () {
      expect(Records.tryParseSettings('x'), isNull);
      expect(Records.tryParseSettings({'deviceId': 'd'}), isNull);
      expect(
        Records.tryParseSettings({
          'deviceId': 'd',
          'config': <String, Object?>{},
          'updatedAt': 'never',
        })!['updatedAt'],
        0,
      );
    });

    test('decode: a JSON object, or null', () {
      Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));
      expect(Records.decode(bytes('{"a":1}')), {'a': 1});
      expect(Records.decode(bytes('[1]')), isNull);
      expect(Records.decode(bytes('{nope')), isNull);
      expect(Records.decode(Uint8List.fromList([0xff, 0xfe])), isNull);
    });

    test('media IDs that could leave the recordings folder are refused', () {
      expect(Records.isSafeMediaId('c1-full'), isTrue);
      for (final bad in ['../x', 'a/b', 'a.b', '', null, 3]) {
        expect(Records.isSafeMediaId(bad), isFalse, reason: '$bad');
      }
      final files = FileMediaStore(_NoStore());
      expect(() => files.load('../../x', 'video/mp4'), throwsArgumentError);
      expect(() => files.saveBytes('a/b', Uint8List(1)), throwsArgumentError);
    });
  });

  group('Persistence', () {
    late IdbFactory factory;
    late AppEventBus bus;
    late Persistence persistence;
    late EventStore store;
    late EventLog log;
    late ConfigController config;

    Persistence open() => Persistence(
      factory: Future.value(factory),
      bus: bus,
      config: config,
      mediaStore: IdbMediaStore.new,
    );

    setUp(() async {
      factory = newIdbFactoryMemory();
      bus = AppEventBus();
      config = ConfigController();
      persistence = open();
      store = await persistence.store;
      log = EventLog(bus.stream);
    });

    tearDown(() {
      log.dispose();
      persistence.dispose();
      bus.close();
    });

    Map<String, Object?> clip(String id, String eventId) => {
      'id': id,
      'eventId': eventId,
      'cameraId': 'cam',
      'beforeMs': 5000,
      'afterMs': 10000,
      'state': 'complete',
      'full': {'mediaId': '$id-full', 'startMs': 0, 'endMs': 15000},
    };

    Map<String, Object?> clipEvent(String id, String clipId, int time) => {
      'id': id,
      'type': ClipRequested.clipRequestedType,
      'title': 'Clip',
      'time': time,
      'clipId': clipId,
    };

    test('damaged records are skipped on restore; the rest of the history '
        'comes back', () async {
      await store.putEvent(clipEvent('good', 'c1', 1));
      await store.putClip(clip('c1', 'good'));
      // Missing fields, and fields of the wrong type.
      await store.putEvent({'id': 'no-time', 'type': 'x', 'title': 'x'});
      await store.putEvent({
        'id': 'double-time',
        'type': AppEvent.genericType,
        'title': 7,
        'time': 3.0,
        'userId': 5,
      });
      await store.putEvent(clipEvent('bad-clip', 'c2', 4));
      await store.putClip({
        'id': 'c2',
        'eventId': 'bad-clip',
        'beforeMs': 'five',
        'full': {'mediaId': 42, 'startMs': '0'},
      });
      await store.putCamera({'id': 'cam'});

      await persistence.restore(log);

      final ids = log.events.map((e) => e.id).toSet();
      expect(ids, {'good', 'double-time', 'bad-clip'});
      final good = log.events.firstWhere((e) => e.id == 'good');
      expect(good, isA<ClipRequested>());
      expect((good as ClipRequested).clip.full, isNotNull);
      final damaged = log.events.firstWhere((e) => e.id == 'bad-clip');
      expect((damaged as ClipRequested).clip.full, isNull);
      expect(
        log.events.firstWhere((e) => e.id == 'double-time').time,
        DateTime.fromMillisecondsSinceEpoch(3),
      );
    });

    test('importRemote stores only usable records, cleaned up, and an '
        'unrelated damaged clip here doesn\'t stop it', () async {
      await store.putClip({'id': 'broken', 'beforeMs': 'x'});
      await persistence.restore(log);
      final events = await persistence.importRemote(
        events: [
          clipEvent('r1', 'rc1', 10),
          {'id': 'r2', 'time': 'later'},
          {'id': '../r3', 'time': 1},
          {'id': 'r4', 'type': 'x', 'time': 11.0},
        ],
        clips: [
          clip('rc1', 'r1'),
          {'id': '../evil', 'eventId': 'r1'},
          {'eventId': 'r1'},
        ],
      );
      expect(events.map((e) => e.id), ['r1', 'r4']);
      expect((await store.getEvent('r4'))!['time'], 11);
      expect(await store.getEvent('r2'), isNull);
      expect((await store.allClips()).map((c) => c['id']).toSet(), {
        'broken',
        'rc1',
      });
    });

    test('settings that can\'t be read leave the defaults, and changes are '
        'saved all the same', () async {
      persistence.dispose();
      await Future<void>.delayed(Duration.zero);
      // A config record that isn't a map.
      final db = await factory.open(EventStore.dbName);
      final txn = db.transaction(EventStore.settings, idbModeReadWrite);
      await txn.objectStore(EventStore.settings).put('garbage', 'config');
      await txn.completed;
      db.close();

      persistence = open();
      await persistence.restore(log);
      expect(config.config, const PresenceConfig());
      config.update(
        (c) => c.copyWith(motion: c.motion.copyWith(enabled: false)),
      );
      await persistence.flush();
      final saved = await (await persistence.store).getSettings('config');
      expect(saved?['motion'], containsPair('enabled', false));
    });

    test('settings from a newer version of the app are not applied', () async {
      await persistence.restore(log);
      final newer = {
        ...config.config.toJson(),
        'version': PresenceConfig.version + 1,
        'motion': {'enabled': false},
      };
      await persistence.applySettings({
        'deviceId': await persistence.deviceId,
        'updatedAt': 99,
        'config': newer,
      });
      expect(config.config.motion.enabled, isTrue);
      expect((await persistence.settingsRecord())['updatedAt'], 0);
    });

    test('recordings no clip uses are deleted, and clips left recording by '
        'a crash are settled, at the next retention pass', () async {
      await store.putEvent(clipEvent('e1', 'c1', 1));
      await store.putClip(clip('c1', 'e1'));
      await store.putMedia('c1-full', Uint8List.fromList([1]));
      // Saved just before a crash, never committed.
      await store.putMedia('c9-full', Uint8List.fromList([9]));
      // Left recording: with its before part, and without.
      await store.putClip({
        'id': 'c2',
        'eventId': 'e2',
        'state': 'recording',
        'past': {'mediaId': 'c2-past', 'startMs': 0, 'endMs': 5000},
      });
      await store.putMedia('c2-past', Uint8List.fromList([2]));
      await store.putClip({'id': 'c3', 'eventId': 'e3', 'state': 'recording'});
      // Requested just now (another tab may be recording it): left alone.
      await store.putClip({
        'id': 'c4',
        'eventId': 'e4',
        'state': 'recording',
        'requestedAt': DateTime.now().millisecondsSinceEpoch,
      });
      await store.putMedia('c4-full', Uint8List.fromList([4]));
      await persistence.restore(log);

      await persistence.deleteEventsBefore(DateTime(1970));

      expect((await store.mediaIds()).toSet(), {
        'c1-full',
        'c2-past',
        'c4-full',
      });
      expect((await store.getClip('c4'))!['state'], 'recording');
      expect((await store.getClip('c2'))!['state'], 'complete');
      expect((await store.getClip('c3'))!['state'], 'failed');
      expect((await store.getClip('c1'))!['state'], 'complete');
    });

    test('moving to another profile brings the account\'s events from the '
        'one before that never went up; uploaded ones stay', () async {
      final device = await persistence.deviceId;
      Map<String, Object?> event(String id, {String? dev, String? user}) => {
        'id': id,
        'type': AppEvent.genericType,
        'title': id,
        'time': 1,
        'userId': user ?? 'u1',
        'profileId': 'pa',
        'deviceId': dev ?? device,
      };
      await store.putEvent(event('stranded'));
      await store.putEvent(event('uploaded'));
      await store.putEvent(event('other-device', dev: 'phone_b'));
      await store.putEvent(event('other-user', user: 'u2'));
      await store.markSynced(
        'us-east-1:pa/events/year=1970/day=001/uploaded.json',
        'x',
      );
      // An ETag entry alone isn't an upload.
      await store.markSynced(
        'etag:us-east-1:pa/events/year=1970/day=001/stranded.json',
        'x',
      );
      await persistence.restore(log);

      await persistence.claimForProfile('pb', 'u1', from: 'pa');
      Future<String?> profileOf(String id) async =>
          AppEvent.profileOf((await store.getEvent(id))!);
      expect(await profileOf('stranded'), 'pb');
      expect(await profileOf('uploaded'), 'pa');
      expect(await profileOf('other-device'), 'pa');
      expect(await profileOf('other-user'), 'pa');
      expect(log.events.firstWhere((e) => e.id == 'stranded').profileId, 'pb');

      // Without a profile before (a sign-in), nothing of pa's moves.
      await store.putEvent(event('later'));
      await persistence.claimForProfile('pb', 'u1');
      expect(await profileOf('later'), 'pa');
    });
  });
}

/// An [EventStore] that's never reached (the media ID is refused first).
class _NoStore implements EventStore {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('not reached');
}
