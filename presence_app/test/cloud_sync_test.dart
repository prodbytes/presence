import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/cloud/cloud_sync.dart';
import 'package:presence_app/cloud/cognito.dart';
import 'package:presence_app/cloud/s3.dart';
import 'package:presence_app/storage/event_store.dart';
import 'package:presence_app/storage/media_store.dart';

import 'fakes.dart';

void main() {
  late EventStore store;
  late StreamController<void> changes;
  late FakeCloudBackend backend;
  late FakeAuthService auth;
  late CloudSync sync;

  Future<void> seed() async {
    await store.putEvent({
      'userId': '1',
      'profileId': '1',
      'id': 'e1',
      'type': 'appStarted',
      'title': 'Application started',
      'time': 1,
    });
    await store.putEvent({
      'userId': '1',
      'profileId': '1',
      'id': 'e2',
      'type': 'clipRequested',
      'title': 'Clip',
      'time': 2,
      'clipId': 'c1',
      'clipState': 'complete',
    });
    await store.putMedia('c1-full', Uint8List.fromList([1, 2, 3]));
    await store.putClip({
      'id': 'c1',
      'eventId': 'e2',
      'cameraId': 'cam',
      'state': 'complete',
      'thumbnail': Uint8List.fromList([9, 9]),
      'full': {
        'mediaId': 'c1-full',
        'startMs': 0,
        'endMs': 30000,
        'mimeType': 'video/webm;codecs=vp8,opus',
      },
    });
    // Still recording: not uploaded yet.
    await store.putClip({'id': 'c2', 'cameraId': 'cam', 'state': 'recording'});
  }

  setUp(() async {
    store = await EventStore.open(newIdbFactoryMemory());
    changes = StreamController<void>.broadcast();
    backend = FakeCloudBackend();
    auth = FakeAuthService();
    await seed();
    sync = CloudSync(
      auth: auth,
      backend: backend,
      store: Future.value(store),
      media: Future.value(IdbMediaStore(store)),
      changes: changes.stream,
      debounce: Duration.zero,
    );
  });

  tearDown(() {
    sync.dispose();
    changes.close();
    store.close();
  });

  test('signed out: nothing is uploaded', () async {
    changes.add(null);
    await sync.idle();
    expect(backend.uploads, isEmpty);
    expect(backend.tokens, isEmpty);
    expect(sync.state, CloudSyncState.off);
  });

  test(
    'signing in uploads stored clips and events, under the identity',
    () async {
      await auth.signIn();
      await sync.idle();

      expect(backend.tokens, ['id-token-1']);
      expect(backend.uploads.keys, {
        'us-east-1:identity/media/c1.webm',
        'us-east-1:identity/media/c1.jpg',
        'us-east-1:identity/clips/year=1970/day=001/c1.json',
        'us-east-1:identity/events/year=1970/day=001/e1.json',
        'us-east-1:identity/events/year=1970/day=001/e2.json',
      });
      final video = backend.uploads['us-east-1:identity/media/c1.webm']!;
      expect(video.bytes, [1, 2, 3]);
      expect(video.contentType, 'video/webm;codecs=vp8,opus');
      final details = jsonDecode(
        utf8.decode(
          backend
              .uploads['us-east-1:identity/clips/year=1970/day=001/c1.json']!
              .bytes,
        ),
      );
      expect(details['id'], 'c1');
      expect(details.containsKey('thumbnail'), isFalse);
      expect(sync.state, CloudSyncState.synced);
      expect(sync.uploaded, 5);
    },
  );

  test(
    'nothing is uploaded twice, and a changed event goes up again',
    () async {
      await auth.signIn();
      await sync.idle();
      backend.uploads.clear();

      changes.add(null);
      await sync.idle();
      expect(backend.uploads, isEmpty);

      await store.putEvent({
        'userId': '1',
        'profileId': '1',
        'id': 'e1',
        'type': 'appStarted',
        'title': 'Application started',
        'time': 1,
        'detail': 'changed',
      });
      changes.add(null);
      await sync.idle();
      expect(backend.uploads.keys, {
        'us-east-1:identity/events/year=1970/day=001/e1.json',
      });
    },
  );

  test('a new event while signed in is uploaded when saved', () async {
    await auth.signIn();
    await sync.idle();
    backend.uploads.clear();

    await store.putEvent({
      'userId': '1',
      'profileId': '1',
      'id': 'e3',
      'type': 'x',
      'title': 'New',
      'time': 3,
    });
    changes.add(null);
    await sync.idle();
    expect(backend.uploads.keys, {
      'us-east-1:identity/events/year=1970/day=001/e3.json',
    });
  });

  test('rejected credentials are renewed once and the sync goes on', () async {
    backend.failPut = S3Exception(403, '<Code>ExpiredToken</Code>');
    await auth.signIn();
    await sync.idle();
    expect(backend.resets, greaterThanOrEqualTo(2)); // sign-in + renewal
    expect(backend.tokens.length, 2);
    expect(backend.uploads.length, 5);
    expect(sync.state, CloudSyncState.synced);
  });

  test('a rejected Google token asks to sign in again', () async {
    backend.failConnect = CognitoException(
      'NotAuthorizedException',
      'Token expired',
    );
    await auth.signIn();
    await sync.idle();
    expect(sync.state, CloudSyncState.error);
    expect(sync.error, 'Sign in again to resume uploads');
    expect(backend.uploads, isEmpty);
  });

  test('a credentials failure stops syncing until sign-in or retry', () async {
    backend.failConnect = CognitoException(
      'HTTP 502 from /api/auth/credentials',
      'the profile service failed',
    );
    await auth.signIn();
    await sync.idle();
    expect(sync.state, CloudSyncState.error);
    expect(sync.stopped, isTrue);
    expect(backend.tokens, hasLength(1));

    // New events and unchanged auth don't try again.
    changes.add(null);
    auth.notify();
    await sync.idle();
    expect(backend.tokens, hasLength(1));
    expect(backend.uploads, isEmpty);

    // Retry does.
    sync.retry();
    await sync.idle();
    expect(sync.stopped, isFalse);
    expect(sync.state, CloudSyncState.synced);
    expect(backend.tokens, hasLength(2));
    expect(backend.uploads, isNotEmpty);
  });

  test('a new ID token resumes a stopped sync', () async {
    backend.failConnect = CognitoException('HTTP 502', 'failed');
    await auth.signIn();
    await sync.idle();
    expect(sync.stopped, isTrue);

    auth.refreshToken();
    await sync.idle();
    expect(sync.stopped, isFalse);
    expect(sync.state, CloudSyncState.synced);
    expect(backend.tokens.last, 'id-token-1-r1');
  });

  test('signing out stops uploads', () async {
    await auth.signIn();
    await sync.idle();
    await auth.signOut();
    backend.uploads.clear();
    await store.putEvent({
      'userId': '1',
      'profileId': '1',
      'id': 'e4',
      'type': 'x',
      'title': 'Later',
      'time': 4,
    });
    changes.add(null);
    await sync.idle();
    expect(backend.uploads, isEmpty);
    expect(sync.state, CloudSyncState.off);
  });

  test('only the profile\'s own events, and their clips, go up', () async {
    // Recorded signed out (no profile yet), and by someone else who used
    // this device, with a finished clip.
    await store.putEvent({
      'id': 'anon',
      'type': 'x',
      'title': 'Signed out',
      'time': 5,
      'userId': 'anonymous',
    });
    await store.putEvent({
      'id': 'legacy',
      'type': 'x',
      'title': 'From before owners',
      'time': 6,
    });
    await store.putEvent({
      'id': 'other',
      'type': 'clipRequested',
      'title': 'Clip',
      'time': 7,
      'clipId': 'c3',
      'userId': '2',
    });
    await store.putMedia('c3-full', Uint8List.fromList([4]));
    await store.putClip({
      'id': 'c3',
      'eventId': 'other',
      'cameraId': 'cam',
      'state': 'complete',
      'full': {'mediaId': 'c3-full', 'startMs': 0, 'endMs': 1000},
    });

    await auth.signIn();
    await sync.idle();
    expect(backend.uploads.keys, {
      'us-east-1:identity/media/c1.webm',
      'us-east-1:identity/media/c1.jpg',
      'us-east-1:identity/clips/year=1970/day=001/c1.json',
      'us-east-1:identity/events/year=1970/day=001/e1.json',
      'us-east-1:identity/events/year=1970/day=001/e2.json',
    });
  });

  test('what went up under the old layout isn\'t uploaded again', () async {
    // Marked as uploaded to the old keys (clips/<id>.webm, .jpg, .json),
    // as a device that synced before the layout changed remembers.
    const prefix = 'us-east-1:identity';
    final clip = (await store.allClips()).firstWhere((c) => c['id'] == 'c1');
    final details = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          for (final MapEntry(:key, :value) in clip.entries)
            if (key != 'thumbnail') key: value,
        }),
      ),
    );
    await store.markSynced('$prefix/clips/c1.webm', 'c1-full');
    await store.markSynced('$prefix/clips/c1.jpg', 'thumbnail');
    await store.markSynced(
      '$prefix/clips/c1.json',
      sha256.convert(details).toString(),
    );
    await auth.signIn();
    await sync.idle();
    // Only the events: their keys didn't change.
    expect(backend.uploads.keys, {
      '$prefix/events/year=1970/day=001/e1.json',
      '$prefix/events/year=1970/day=001/e2.json',
    });
  });

  group('fetch and periodic sync', () {
    Uint8List json(Map<String, Object?> m) =>
        Uint8List.fromList(utf8.encode(jsonEncode(m)));

    test(
      'on sign-in, the folder is fetched first and not uploaded back',
      () async {
        sync.dispose();
        const prefix = 'us-east-1:identity';
        // Another device's clip and event, already in the cloud.
        backend.uploads['$prefix/clips/year=1970/day=001/r1.json'] = (
          bytes: json({
            'id': 'r1',
            'eventId': 're1',
            'cameraId': 'cam',
            'state': 'complete',
            'full': {
              'mediaId': 'r1-full',
              'startMs': 0,
              'endMs': 30000,
              'mimeType': 'video/mp4',
            },
          }),
          contentType: 'application/json',
        );
        backend.uploads['$prefix/media/r1.mp4'] = (
          bytes: Uint8List.fromList([7, 7, 7]),
          contentType: 'video/mp4',
        );
        backend.uploads['$prefix/media/r1.jpg'] = (
          bytes: Uint8List.fromList([5]),
          contentType: 'image/jpeg',
        );
        backend.uploads['$prefix/events/re1.json'] = (
          bytes: json({
            'id': 're1',
            'type': 'clipRequested',
            'title': 'Clip',
            'time': 9,
            'clipId': 'r1',
          }),
          contentType: 'application/json',
        );
        // Partitioned, as uploads are now.
        backend.uploads['$prefix/events/year=2026/day=269/re2.json'] = (
          bytes: json({'id': 're2', 'type': 'x', 'title': 'Later', 'time': 10}),
          contentType: 'application/json',
        );
        final remote = <RemoteRecords>[];
        sync = CloudSync(
          auth: auth,
          backend: backend,
          store: Future.value(store),
          media: Future.value(IdbMediaStore(store)),
          changes: changes.stream,
          debounce: Duration.zero,
          onRemote: (r) async => remote.add(r),
          // These fixtures are from 1970: within a week of this.
          now: () => DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
        );
        final before = Set.of(backend.uploads.keys);

        await auth.signIn();
        await sync.idle();

        expect(remote, hasLength(1));
        expect(remote.single.events.map((e) => e['id']).toSet(), {
          're1',
          're2',
        });
        // Events in the profile's folder are the profile's.
        expect(remote.single.events.map((e) => e['profileId']).toSet(), {'1'});
        expect(remote.single.clips.single['id'], 'r1');
        expect(remote.single.clips.single['thumbnail'], [5]);
        expect(remote.single.media, {
          'r1-full': [7, 7, 7],
        });
        expect(
          backend.downloads,
          containsAll([
            'clips/year=1970/day=001/r1.json',
            'media/r1.mp4',
            'media/r1.jpg',
            'events/re1.json',
            'events/year=2026/day=269/re2.json',
          ]),
        );
        expect(sync.downloaded, 3);
        // The local clip and events go up; the fetched ones aren't sent back.
        final uploaded = backend.uploads.keys.toSet().difference(before);
        expect(
          uploaded,
          containsAll([
            '$prefix/media/c1.webm',
            '$prefix/events/year=1970/day=001/e1.json',
          ]),
        );
        expect(
          uploaded.where((k) => k.contains('r1') || k.contains('re1')),
          isEmpty,
        );
      },
    );

    test('a new device gets only the last two weeks', () async {
      sync.dispose();
      const prefix = 'us-east-1:identity';
      final now = DateTime.utc(2026, 9, 27, 12);
      int ms(DateTime t) => t.millisecondsSinceEpoch;
      void event(String key, String id, DateTime time, [String? clipId]) =>
          backend.uploads['$prefix/$key'] = (
            bytes: json({
              'id': id,
              'type': 'clipRequested',
              'title': 'Clip',
              'time': ms(time),
              'clipId': ?clipId,
            }),
            contentType: 'application/json',
          );
      void clip(String id, DateTime time) {
        backend.uploads['$prefix/${CloudSync.clipRecordKey(id, ms(time))}'] = (
          bytes: json({
            'id': id,
            'state': 'complete',
            'full': {'mediaId': '$id-full', 'startMs': 0, 'endMs': 30000},
          }),
          contentType: 'application/json',
        );
        backend.uploads['$prefix/media/$id.webm'] = (
          bytes: Uint8List.fromList([1]),
          contentType: 'video/webm',
        );
      }

      // 13 days ago (day 257): restored, with its clip.
      event(
        CloudSync.eventKey({
          'id': 'new',
          'time': ms(now.subtract(const Duration(days: 13))),
        }),
        'new',
        now.subtract(const Duration(days: 13)),
        'c-new',
      );
      clip('c-new', now.subtract(const Duration(days: 13)));
      // Earlier on the first day of the window (day 256): its partition is
      // read, but the event is 8 h too old.
      final edge = now.subtract(const Duration(days: 14, hours: 8));
      event(CloudSync.eventKey({'id': 'edge', 'time': ms(edge)}), 'edge', edge);
      // 20 days ago: its partition isn't even downloaded, nor its clip.
      final old = now.subtract(const Duration(days: 20));
      event(
        CloudSync.eventKey({'id': 'old', 'time': ms(old)}),
        'old',
        old,
        'c-old',
      );
      clip('c-old', old);
      // From before partitioning: read to learn its time, then skipped.
      event('events/flat.json', 'flat', old);

      final remote = <RemoteRecords>[];
      sync = CloudSync(
        auth: auth,
        backend: backend,
        store: Future.value(store),
        media: Future.value(IdbMediaStore(store)),
        changes: changes.stream,
        debounce: Duration.zero,
        onRemote: (r) async => remote.add(r),
        now: () => now,
      );
      await auth.signIn();
      await sync.idle();

      expect(remote.single.events.map((e) => e['id']), ['new']);
      expect(remote.single.clips.map((c) => c['id']), ['c-new']);
      expect(remote.single.media.keys, ['c-new-full']);
      expect(
        backend.downloads.where((k) => k.contains('old')),
        isEmpty,
        reason: 'nothing of the 20-day-old event is downloaded',
      );
      expect(backend.downloads, contains('events/flat.json'));
    });

    test('a shorter History setting shrinks the window to it', () async {
      sync.dispose();
      const prefix = 'us-east-1:identity';
      final now = DateTime.utc(2026, 9, 27, 12);
      void event(String id, DateTime time) {
        final record = {
          'id': id,
          'type': 'generic',
          'title': 'Door opened',
          'time': time.millisecondsSinceEpoch,
        };
        backend.uploads['$prefix/${CloudSync.eventKey(record)}'] = (
          bytes: json(record),
          contentType: 'application/json',
        );
      }

      // Kept 3 days: one from 2 days ago comes down; one from 5 days ago
      // would be deleted as too old, so it isn't even downloaded.
      event('recent', now.subtract(const Duration(days: 2)));
      event('too-old', now.subtract(const Duration(days: 5)));

      final remote = <RemoteRecords>[];
      sync = CloudSync(
        auth: auth,
        backend: backend,
        store: Future.value(store),
        media: Future.value(IdbMediaStore(store)),
        changes: changes.stream,
        debounce: Duration.zero,
        onRemote: (r) async => remote.add(r),
        keep: () => const Duration(days: 3),
        now: () => now,
      );
      await auth.signIn();
      await sync.idle();

      expect(remote.single.events.map((e) => e['id']), ['recent']);
      expect(backend.downloads.where((k) => k.contains('too-old')), isEmpty);
    });

    test('events already on the device aren\'t downloaded again', () async {
      await auth.signIn();
      await sync.idle();
      backend.downloads.clear();
      changes.add(null);
      await sync.idle();
      expect(backend.downloads, isEmpty);
    });

    test('a sync runs every interval, even without a change', () async {
      sync.dispose();
      sync = CloudSync(
        auth: auth,
        backend: backend,
        store: Future.value(store),
        media: Future.value(IdbMediaStore(store)),
        changes: changes.stream,
        debounce: Duration.zero,
        interval: const Duration(milliseconds: 50),
      );
      await auth.signIn();
      await sync.idle();
      backend.uploads.clear();

      // Saved without a change notification: only the timer finds it.
      await store.putEvent({
        'userId': '1',
        'profileId': '1',
        'id': 'e9',
        'type': 'x',
        'title': 'Quiet',
        'time': 9,
      });
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await sync.idle();
      expect(
        backend.uploads.keys,
        contains('us-east-1:identity/events/year=1970/day=001/e9.json'),
      );
    });

    group('every pass fetches too', () {
      const prefix = 'us-east-1:identity';
      final now = DateTime.utc(2026, 10, 1, 12);
      late DateTime clock;
      late List<RemoteRecords> remote;

      // Another device's event, uploaded to the user's folder.
      void uploadedElsewhere(String id, DateTime time) {
        final record = {'id': id, 'type': 'x', 'title': id, 'time': 0};
        record['time'] = time.millisecondsSinceEpoch;
        backend.uploads['$prefix/${CloudSync.eventKey(record)}'] = (
          bytes: json(record),
          contentType: 'application/json',
        );
      }

      Future<void> start({int maxFetch = 1000}) async {
        sync.dispose();
        clock = now;
        remote = [];
        sync = CloudSync(
          auth: auth,
          backend: backend,
          store: Future.value(store),
          media: Future.value(IdbMediaStore(store)),
          changes: changes.stream,
          debounce: Duration.zero,
          // Passes run by hand (changes.add) rather than on the timer.
          interval: const Duration(hours: 24),
          maxFetch: maxFetch,
          onRemote: (r) async {
            remote.add(r);
            // As the app does: stored, so later passes skip them.
            for (final e in r.events) {
              await store.putEvent(e);
            }
          },
          now: () => clock,
        );
        await auth.signIn();
        await sync.idle();
      }

      Future<void> pass() async {
        backend.listings.clear();
        changes.add(null);
        await sync.idle();
      }

      test('another device\'s new event comes down on the next pass, '
          'which lists only today and yesterday', () async {
        await start();
        expect(backend.listings.first, 'events/', reason: 'first: all');

        uploadedElsewhere(
          'from-phone',
          now.subtract(const Duration(minutes: 1)),
        );
        clock = now.add(const Duration(seconds: 15));
        await pass();
        expect(remote.last.events.single['id'], 'from-phone');
        expect(remote.last.events.single['profileId'], '1');
        expect(
          backend.listings.where((p) => p.startsWith('events/')).toList(),
          ['events/year=2026/day=274/', 'events/year=2026/day=273/'],
        );

        // Already here: not downloaded again.
        backend.downloads.clear();
        await pass();
        expect(backend.downloads, isEmpty);
      });

      test('once an hour, a pass lists every day of the two weeks', () async {
        await start();
        // Uploaded late, by a device that was offline: ten days old.
        uploadedElsewhere('late', now.subtract(const Duration(days: 10)));
        clock = now.add(const Duration(minutes: 30));
        await pass();
        expect(
          remote.where((r) => r.events.any((e) => e['id'] == 'late')),
          isEmpty,
        );

        clock = now.add(const Duration(hours: 1));
        await pass();
        expect(
          backend.listings.where((p) => p.startsWith('events/')),
          hasLength(15),
          reason: 'today and the 14 days before',
        );
        expect(remote.last.events.single['id'], 'late');
      });

      test('at most maxFetch events per pass, the newest first', () async {
        for (var d = 1; d <= 3; d++) {
          uploadedElsewhere('day-$d', now.subtract(Duration(days: d)));
        }
        await start(maxFetch: 2);
        expect(remote.single.events.map((e) => e['id']), ['day-1', 'day-2']);
        // The rest on the next full pass.
        clock = now.add(const Duration(hours: 1));
        await pass();
        expect(remote.last.events.map((e) => e['id']), ['day-3']);
      });
    });
  });

  group('event keys', () {
    int ms(DateTime t) => t.millisecondsSinceEpoch;
    test('partitioned by the UTC day of the year', () {
      expect(
        CloudSync.eventKey({
          'id': 'a',
          'time': ms(DateTime.utc(2026, 9, 26, 12)),
        }),
        'events/year=2026/day=269/a.json',
      );
      expect(
        CloudSync.eventKey({'id': 'b', 'time': ms(DateTime.utc(2026, 1, 1))}),
        'events/year=2026/day=001/b.json',
      );
      expect(
        CloudSync.eventKey({
          'id': 'c',
          'time': ms(DateTime.utc(2024, 12, 31, 23, 59)),
        }),
        'events/year=2024/day=366/c.json',
      );
    });

    test('the day is UTC, whatever the local time zone', () {
      // 23:30 UTC on 26 September is already the 27th east of UTC.
      expect(
        CloudSync.eventKey({
          'id': 'd',
          'time': ms(DateTime.utc(2026, 9, 26, 23, 30)),
        }),
        'events/year=2026/day=269/d.json',
      );
      expect(
        CloudSync.eventKey({'id': 'e', 'time': ms(DateTime.utc(2026, 9, 27))}),
        'events/year=2026/day=270/e.json',
      );
    });
  });

  test(
    'tagged frames upload as images; the event JSON keeps the tags',
    () async {
      await store.putEvent({
        'userId': '1',
        'profileId': '1',
        'id': 't1',
        'type': 'clipRequested',
        'title': 'Clip',
        'time': 5,
        'clipId': 'c1',
        'annotations': [
          {
            'id': 'a1',
            'name': 'Rex',
            'x': 0.2,
            'y': 0.3,
            'frameId': 'f1',
            'frameMs': 7400,
          },
        ],
        'frames': {
          'f1': Uint8List.fromList([9, 8, 7]),
        },
      });
      await auth.signIn();
      await sync.idle();

      const prefix = 'us-east-1:identity';
      final frame = backend.uploads['$prefix/media/c1/frames/f1.jpg'];
      expect(frame?.bytes, [9, 8, 7]);
      expect(frame?.contentType, 'image/jpeg');
      final eventKey = backend.uploads.keys.singleWhere(
        (k) => k.endsWith('/t1.json'),
      );
      final json =
          jsonDecode(utf8.decode(backend.uploads[eventKey]!.bytes)) as Map;
      expect(json.containsKey('frames'), isFalse);
      expect((json['annotations'] as List).single['name'], 'Rex');
      expect((json['annotations'] as List).single['frameId'], 'f1');

      // Another device fetches the event and gets its frame back.
      final fetched = <RemoteRecords>[];
      final other = await EventStore.open(newIdbFactoryMemory());
      final otherSync = CloudSync(
        auth: auth,
        backend: backend,
        store: Future.value(other),
        media: Future.value(IdbMediaStore(other)),
        changes: const Stream.empty(),
        debounce: Duration.zero,
        onRemote: (r) async => fetched.add(r),
        // The event is from 1970: within a week of this.
        now: () => DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
      );
      await Future<void>.delayed(Duration.zero);
      await otherSync.idle();
      final event = fetched.single.events.singleWhere((e) => e['id'] == 't1');
      expect((event['frames'] as Map)['f1'], [9, 8, 7]);
      otherSync.dispose();
      other.close();
    },
  );

  test('without a role, nothing syncs', () async {
    sync.dispose();
    final roles = RolesService(auth: auth, client: FakeRolesClient.none());
    sync = CloudSync(
      auth: auth,
      roles: roles,
      backend: backend,
      store: Future.value(store),
      media: Future.value(IdbMediaStore(store)),
      changes: changes.stream,
      debounce: Duration.zero,
    );
    await auth.signIn();
    await Future<void>.delayed(Duration.zero);
    changes.add(null);
    await sync.idle();
    expect(backend.uploads, isEmpty);
    expect(backend.tokens, isEmpty);
    expect(sync.state, CloudSyncState.off);
    roles.dispose();
  });

  test('with access, the profile the auth API answers with syncs: its '
      'events go up, and fetched ones become its', () async {
    sync.dispose();
    final client = FakeRolesClient()..profile = null;
    final roles = RolesService(auth: auth, client: client);
    await store.putEvent({
      'id': 'p1',
      'type': 'x',
      'title': 'The profile\'s',
      'time': 3,
      'userId': '1',
      'profileId': 'automatic_paranoid_axolotl',
    });
    backend.uploads['us-east-1:identity/events/year=1970/day=001/r1.json'] = (
      bytes: Uint8List.fromList(
        utf8.encode(
          jsonEncode({'id': 'r1', 'type': 'x', 'title': 'Old', 'time': 4}),
        ),
      ),
      contentType: 'application/json',
    );
    final fetched = <RemoteRecords>[];
    sync = CloudSync(
      auth: auth,
      roles: roles,
      backend: backend,
      store: Future.value(store),
      media: Future.value(IdbMediaStore(store)),
      changes: changes.stream,
      debounce: Duration.zero,
      onRemote: (r) async => fetched.add(r),
      now: () => DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
    );
    final before = Set.of(backend.uploads.keys);

    // Access, but the API answered with no profile: nothing syncs.
    await auth.signIn();
    await Future<void>.delayed(Duration.zero);
    await sync.idle();
    expect(roles.hasAccess, isTrue);
    expect(backend.tokens, isEmpty);
    expect(sync.state, CloudSyncState.off);

    client.profile = 'automatic_paranoid_axolotl';
    await roles.refresh();
    await sync.idle();
    expect(backend.uploads.keys.toSet().difference(before), {
      'us-east-1:identity/events/year=1970/day=001/p1.json',
    }, reason: 'only the profile\'s event, not user 1\'s without one');
    expect(
      fetched.single.events.single['profileId'],
      'automatic_paranoid_axolotl',
    );

    await auth.signOut();
    await sync.idle();
    expect(sync.state, CloudSyncState.off);
    roles.dispose();
  });

  group("this device's settings", () {
    late FakeDeviceSettings settings;
    late CloudSync withSettings;
    const key = 'us-east-1:identity/devices/dev-1/settings.json';

    setUp(() {
      sync.dispose();
      settings = FakeDeviceSettings();
      withSettings = sync = CloudSync(
        auth: auth,
        backend: backend,
        store: Future.value(store),
        media: Future.value(IdbMediaStore(store)),
        changes: changes.stream,
        debounce: Duration.zero,
        settings: settings,
      );
    });

    test('listed only on the first pass, and uploaded when changed', () async {
      await auth.signIn();
      await withSettings.idle();
      expect(backend.uploads.keys, contains(key));
      changes.add(null);
      await withSettings.idle();
      expect(backend.listings.where((l) => l.startsWith('devices/')), [
        'devices/dev-1/',
      ]);

      final before = backend.uploads[key]!.bytes;
      settings.record = {...settings.record, 'updatedAt': 5};
      changes.add(null);
      await withSettings.idle();
      expect(backend.uploads[key]!.bytes, isNot(before));
      expect(settings.applied, isEmpty);
    });

    void putRemote(Map<String, Object?> record) => backend.uploads[key] = (
      bytes: Uint8List.fromList(utf8.encode(jsonEncode(record))),
      contentType: 'application/json',
    );

    test("a sign-in restores the profile's record over another profile's "
        'newer settings', () async {
      settings.record = {
        ...settings.record,
        'profileId': 'other',
        'updatedAt': 9,
      };
      putRemote({'deviceId': 'dev-1', 'profileId': '1', 'updatedAt': 5});
      await auth.signIn();
      await withSettings.idle();
      expect(settings.applied.single['updatedAt'], 5);
      expect(settings.claimed, ['1']);
    });

    test("the profile's own newer settings stay, and are claimed with no "
        'record', () async {
      settings.record = {...settings.record, 'profileId': '1', 'updatedAt': 9};
      putRemote({'deviceId': 'dev-1', 'profileId': '1', 'updatedAt': 5});
      await auth.signIn();
      await withSettings.idle();
      expect(settings.applied, isEmpty);
      expect(settings.claimed, ['1']);

      backend.uploads.remove(key);
      settings.record = {...settings.record, 'profileId': 'other'};
      await auth.signOut();
      await auth.signIn();
      await withSettings.idle();
      expect(settings.applied, isEmpty);
      expect(settings.claimed, ['1', '1']);
    });

    test("another device's record, or a damaged one, is ignored", () async {
      backend.uploads[key] = (
        bytes: Uint8List.fromList(
          utf8.encode(jsonEncode({'deviceId': 'other', 'updatedAt': 99})),
        ),
        contentType: 'application/json',
      );
      await auth.signIn();
      await withSettings.idle();
      expect(settings.applied, isEmpty);
      // And replaced with this device's.
      expect(
        jsonDecode(utf8.decode(backend.uploads[key]!.bytes)),
        containsPair('deviceId', 'dev-1'),
      );
    });
  });
}

class FakeDeviceSettings implements DeviceSettings {
  Map<String, Object?> record = {
    'deviceId': 'dev-1',
    'updatedAt': 0,
    'config': <String, Object?>{},
  };
  final applied = <Map<String, Object?>>[];

  @override
  Future<String> get deviceId async => record['deviceId']! as String;

  @override
  Future<Map<String, Object?>> settingsRecord() async => record;

  @override
  Future<void> applySettings(Map<String, Object?> remote) async {
    applied.add(remote);
    record = remote;
  }

  final claimed = <String>[];

  @override
  Future<void> claimSettings(String profileId) async {
    claimed.add(profileId);
    record = {...record, 'profileId': profileId};
  }
}
