import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/cloud/cloud_sync.dart';
import 'package:presence_app/cloud/cognito.dart';
import 'package:presence_app/cloud/s3.dart';
import 'package:presence_app/storage/event_store.dart';
import 'package:presence_app/storage/media_store.dart';

import 'fakes.dart';
import 'sealed.dart';

void main() {
  late EventStore store;
  late StreamController<Set<String>?> changes;
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
    await store.putMedia('c1-full', sealed([1, 2, 3]));
    await store.putClip({
      'id': 'c1',
      'eventId': 'e2',
      'cameraId': 'cam',
      'state': 'complete',
      'thumbnail': sealed([9, 9]),
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
    changes = StreamController<Set<String>?>.broadcast();
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
      expect(opened(video.bytes), [1, 2, 3]);
      // Sealed: its type is in the clip's record, not on the object.
      expect(video.contentType, CloudSync.sealedType);
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

  test('halted (the camera Stopped), nothing syncs until it resumes', () async {
    await auth.signIn();
    await sync.idle();
    backend.uploads.clear();

    sync.setHalted(true);
    expect(sync.halted, isTrue);
    await store.putEvent({
      'userId': '1',
      'profileId': '1',
      'id': 'e4',
      'type': 'x',
      'title': 'While stopped',
      'time': 4,
    });
    changes.add(null);
    await sync.idle();
    expect(backend.uploads, isEmpty);

    // Resumed: a pass at once takes it.
    sync.setHalted(false);
    await sync.idle();
    expect(backend.uploads.keys, {
      'us-east-1:identity/events/year=1970/day=001/e4.json',
    });
  });

  test('signing in while halted waits for the resume', () async {
    sync.setHalted(true);
    await auth.signIn();
    await sync.idle();
    expect(backend.uploads, isEmpty);
    sync.setHalted(false);
    await sync.idle();
    expect(backend.uploads, isNotEmpty);
  });

  test('a pass uploads only the events named as changed, with their '
      'clips; recordings are streamed', () async {
    const p = 'us-east-1:identity';
    await auth.signIn();
    await sync.idle();
    expect(backend.streamed, ['media/c1.webm']);
    backend.uploads.clear();

    // Changed without saying so: left for the next reconciliation.
    await store.putEvent({
      'userId': '1',
      'profileId': '1',
      'id': 'e1',
      'type': 'appStarted',
      'title': 'Application started',
      'time': 1,
      'detail': 'quiet',
    });
    // A new clip, named.
    await store.putEvent({
      'userId': '1',
      'profileId': '1',
      'id': 'e5',
      'type': 'clipRequested',
      'title': 'Clip',
      'time': 5,
      'clipId': 'c5',
    });
    await store.putMedia('c5-full', sealed([5, 5]));
    await store.putClip({
      'id': 'c5',
      'eventId': 'e5',
      'cameraId': 'cam',
      'state': 'complete',
      'full': {
        'mediaId': 'c5-full',
        'startMs': 0,
        'endMs': 1000,
        'mimeType': 'video/mp4',
      },
    });
    changes.add({'e5'});
    await sync.idle();
    expect(backend.uploads.keys, {
      '$p/media/c5.mp4',
      '$p/clips/year=1970/day=001/c5.json',
      '$p/events/year=1970/day=001/e5.json',
    });
    expect(opened(backend.uploads['$p/media/c5.mp4']!.bytes), [5, 5]);

    // Named but unchanged: nothing goes up.
    backend.uploads.clear();
    changes.add({'e2', 'e5'});
    await sync.idle();
    expect(backend.uploads, isEmpty);

    // A reconciliation finds the quiet change.
    changes.add(null);
    await sync.idle();
    expect(backend.uploads.keys, {'$p/events/year=1970/day=001/e1.json'});
  });

  test('failed passes back off, doubling the wait up to maxBackoff, log '
      'the stack once, and keep what was to go up', () async {
    final logs = <String>[];
    final print = debugPrint;
    debugPrint = (message, {wrapWidth}) => logs.add('$message');
    addTearDown(() => debugPrint = print);
    sync.dispose();
    sync = CloudSync(
      auth: auth,
      backend: backend,
      store: Future.value(store),
      media: Future.value(IdbMediaStore(store)),
      changes: changes.stream,
      debounce: Duration.zero,
      interval: const Duration(milliseconds: 10),
      maxBackoff: 4,
    );
    backend.offline = Exception('offline');
    await auth.signIn();
    await sync.idle();
    expect(sync.state, CloudSyncState.error);
    expect(sync.backoff, const Duration(milliseconds: 10));

    await store.putEvent({
      'userId': '1',
      'profileId': '1',
      'id': 'e3',
      'type': 'x',
      'title': 'While offline',
      'time': 3,
    });
    changes.add({'e3'});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await sync.idle();
    // Waits of 1, 2, 4, 4… intervals: about 9 tries in 30, not 30.
    expect(backend.tokens.length, inInclusiveRange(4, 15));
    expect(sync.backoff, const Duration(milliseconds: 40));
    expect(logs.where((l) => l.contains('\n')), hasLength(1));
    expect(
      logs.where((l) => l.contains('failed again')).length,
      greaterThanOrEqualTo(2),
    );

    backend.offline = null;
    sync.retry();
    await sync.idle();
    expect(sync.state, CloudSyncState.synced);
    expect(sync.backoff, const Duration(milliseconds: 10));
    expect(
      backend.uploads.keys,
      containsAll([
        'us-east-1:identity/events/year=1970/day=001/e1.json',
        'us-east-1:identity/events/year=1970/day=001/e3.json',
      ]),
    );
    expect(logs.where((l) => l.contains('recovered')), hasLength(1));
  });

  test('a state that doesn\'t change notifies no one', () async {
    var notified = 0;
    sync.addListener(() => notified++);
    await auth.signOut();
    await sync.idle();
    changes.add(null);
    await sync.idle();
    expect(sync.state, CloudSyncState.off);
    expect(notified, 0);
  });

  test('synced-store keys of deleted events and clips are recognized', () {
    bool of(String key) => CloudSync.isSyncedKeyOf(key, {'e1', 'e.2'}, {'c1'});
    expect(of('id/events/year=2026/day=001/e1.json'), isTrue);
    expect(of('etag:id/events/year=2026/day=001/e1.json'), isTrue);
    expect(of('id/events/e.2.json'), isTrue);
    expect(of('id/media/c1.mp4'), isTrue);
    expect(of('fetch:id/media/c1.mp4'), isTrue);
    expect(of('id/media/c1/frames/f.jpg'), isTrue);
    expect(of('id/clips/year=2026/day=001/c1.json'), isTrue);
    expect(of('id/clips/c1/frames/f.jpg'), isTrue);
    expect(of('id/events/year=2026/day=001/e10.json'), isFalse);
    expect(of('id/media/c10.mp4'), isFalse);
    expect(of('id/devices/e1/settings.json'), isFalse);
    expect(of('no-folder'), isFalse);
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
    await store.putMedia('c3-full', sealed([4]));
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
          bytes: sealed([7, 7, 7]),
          contentType: CloudSync.sealedType,
        );
        backend.uploads['$prefix/media/r1.jpg'] = (
          bytes: sealed([5]),
          contentType: CloudSync.sealedType,
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
        expect(opened(remote.single.clips.single['thumbnail']! as Uint8List), [
          5,
        ]);
        // The recording is stored as it's downloaded, not handed over.
        expect(opened((await store.getMedia('r1-full'))!), [7, 7, 7]);
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
          bytes: sealed([1]),
          contentType: CloudSync.sealedType,
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
      expect(opened((await store.getMedia('c-new-full'))!), [1]);
      expect(await store.getMedia('c-old-full'), isNull);
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

      // Saved without a change notification: the timer's passes fetch,
      // but upload only what's named as changed...
      await store.putEvent({
        'userId': '1',
        'profileId': '1',
        'id': 'e9',
        'type': 'x',
        'title': 'Quiet',
        'time': 9,
      });
      backend.listings.clear();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await sync.idle();
      expect(backend.listings, isNotEmpty, reason: 'passes ran');
      expect(backend.uploads, isEmpty);

      // ...until a reconciliation, which looks at every stored event.
      changes.add(null);
      await sync.idle();
      expect(
        backend.uploads.keys,
        contains('us-east-1:identity/events/year=1970/day=001/e9.json'),
      );
    });

    test('each full fetch reconciles too', () async {
      sync.dispose();
      sync = CloudSync(
        auth: auth,
        backend: backend,
        store: Future.value(store),
        media: Future.value(IdbMediaStore(store)),
        changes: changes.stream,
        debounce: Duration.zero,
        interval: const Duration(milliseconds: 50),
        fullFetchEvery: Duration.zero,
      );
      await auth.signIn();
      await sync.idle();
      backend.uploads.clear();
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

      Future<void> start({int maxFetch = 1000, int fetchBatch = 25}) async {
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
          fetchBatch: fetchBatch,
          onRemote: (r) async {
            remote.add(r);
            // As the app does: stored, so later passes skip them.
            for (final e in [...r.events, ...r.updated]) {
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
        expect(
          backend.listings.where((p) => p != 'devices/').first,
          'events/',
          reason: 'first: all',
        );

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

      test("another device's change to an event here comes down on the "
          'next pass, once, and doesn\'t go back up', () async {
        await start();
        // Today's event, from the phone: downloaded, then not again.
        final time = now.subtract(const Duration(minutes: 1));
        uploadedElsewhere('from-phone', time);
        final key = CloudSync.eventKey({
          'id': 'from-phone',
          'time': time.millisecondsSinceEpoch,
        });
        await pass();
        expect(remote.single.events.single['id'], 'from-phone');
        await pass();
        expect(remote, hasLength(1), reason: 'own state is no change');

        // The phone tags it, and recognition saw a cat.
        final changed = {
          ...jsonDecode(utf8.decode(backend.uploads['$prefix/$key']!.bytes))
              as Map<String, Object?>,
          'annotations': [
            {'id': 'a1', 'name': 'Rex', 'x': 0.5, 'y': 0.5},
          ],
          'objectTags': [
            {'label': 'cat', 'ms': 0, 'score': 0.9},
          ],
        };
        backend.uploads['$prefix/$key'] = (
          bytes: json(changed),
          contentType: 'application/json',
        );
        final downloaded = sync.downloaded;
        await pass();
        expect(remote.last.events, isEmpty);
        final updated = remote.last.updated.single;
        expect(updated['id'], 'from-phone');
        expect(updated['profileId'], '1');
        expect(updated['annotations'], changed['annotations']);
        expect(sync.downloaded, downloaded + 1);

        // Taken on: not uploaded back, nor downloaded again.
        backend.downloads.clear();
        final uploaded = sync.uploaded;
        await pass();
        expect(remote, hasLength(2));
        expect(backend.downloads, isEmpty);
        expect(sync.uploaded, uploaded);

        // Changed again over there (the tag removed): down again.
        backend.uploads['$prefix/$key'] = (
          bytes: json({...changed, 'annotations': <Object?>[]}),
          contentType: 'application/json',
        );
        await pass();
        expect(remote.last.updated.single['annotations'], isEmpty);
      });

      test('a change here not uploaded yet wins over one elsewhere', () async {
        await start();
        final time = now.subtract(const Duration(minutes: 1));
        uploadedElsewhere('from-phone', time);
        await pass();
        final key = CloudSync.eventKey({
          'id': 'from-phone',
          'time': time.millisecondsSinceEpoch,
        });
        backend.uploads['$prefix/$key'] = (
          bytes: json({
            'id': 'from-phone',
            'time': time.millisecondsSinceEpoch,
            'title': 'Theirs',
          }),
          contentType: 'application/json',
        );
        final local = (await store.allEvents()).firstWhere(
          (e) => e['id'] == 'from-phone',
        );
        await store.putEvent({...local, 'title': 'Mine'});
        await pass();
        expect(remote, hasLength(1));
        final cloud = jsonDecode(
          utf8.decode(backend.uploads['$prefix/$key']!.bytes),
        );
        expect(cloud['title'], 'Mine');
      });

      test(
        'events synced before ETags were kept are fetched at most once more',
        () async {
          uploadedElsewhere(
            'from-phone',
            now.subtract(const Duration(hours: 1)),
          );
          await start();
          // Uploaded by this device, too.
          await store.putEvent({
            'userId': '1',
            'profileId': '1',
            'id': 'mine',
            'type': 'x',
            'title': 'Mine',
            'time': now.millisecondsSinceEpoch,
          });
          await pass();
          remote.clear();
          // As left by an older version: the uploads remembered, not ETags.
          final store2 = await EventStore.open(newIdbFactoryMemory());
          addTearDown(store2.close);
          for (final e in await store.allEvents()) {
            await store2.putEvent(e);
          }
          for (final MapEntry(:key, :value)
              in (await store.syncedKeys()).entries) {
            if (!key.startsWith('etag:')) await store2.markSynced(key, value);
          }
          sync.dispose();
          sync = CloudSync(
            auth: auth,
            backend: backend,
            store: Future.value(store2),
            media: Future.value(IdbMediaStore(store2)),
            changes: changes.stream,
            debounce: Duration.zero,
            interval: const Duration(hours: 24),
            onRemote: (r) async => remote.add(r),
            now: () => clock,
          );
          backend.downloads.clear();
          await sync.idle();
          // This device's upload is known by its bytes. The one it
          // downloaded is stored with its profile, so it's fetched once
          // more, to learn its ETag.
          expect(remote.single.updated.map((e) => e['id']), ['from-phone']);
          expect(backend.downloads.where((k) => k.contains('mine')), isEmpty);
          backend.downloads.clear();
          await pass();
          expect(remote, hasLength(1));
          expect(backend.downloads, isEmpty);
        },
      );

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

      test('a fetch hands events over in batches, newest first', () async {
        for (var d = 1; d <= 3; d++) {
          uploadedElsewhere('day-$d', now.subtract(Duration(days: d)));
        }
        await start(fetchBatch: 2);
        expect(
          [
            for (final r in remote) [for (final e in r.events) e['id']],
          ],
          [
            ['day-1', 'day-2'],
            ['day-3'],
          ],
        );
        expect(sync.downloaded, 3);
      });
    });

    group('recordings come down after their events', () {
      const prefix = 'us-east-1:identity';
      late List<RemoteRecords> remote;
      late DateTime clock;
      // What had been downloaded when each batch was handed over.
      late List<List<String>> downloadedAtDelivery;

      bool isRecording(String key) =>
          key.endsWith('.webm') || key.endsWith('.mp4');

      // Another device's clip (thumbnail and recording) and its event,
      // [n] ms after the epoch.
      void remoteClip(String id, int n) {
        backend.uploads['$prefix/${CloudSync.clipRecordKey(id, n)}'] = (
          bytes: json({
            'id': id,
            'eventId': 'e-$id',
            'cameraId': 'cam',
            'state': 'complete',
            'full': {
              'mediaId': '$id-full',
              'startMs': 0,
              'endMs': 30000,
              'mimeType': 'video/mp4',
            },
          }),
          contentType: 'application/json',
        );
        backend.uploads['$prefix/media/$id.mp4'] = (
          bytes: sealed([n, n]),
          contentType: CloudSync.sealedType,
        );
        backend.uploads['$prefix/media/$id.jpg'] = (
          bytes: sealed([n]),
          contentType: CloudSync.sealedType,
        );
        final event = {
          'id': 'e-$id',
          'type': 'clipRequested',
          'title': 'Clip',
          'time': n,
          'clipId': id,
        };
        backend.uploads['$prefix/${CloudSync.eventKey(event)}'] = (
          bytes: json(event),
          contentType: 'application/json',
        );
      }

      Future<void> start({required bool prefetch, int fetchBatch = 25}) async {
        sync.dispose();
        remote = [];
        downloadedAtDelivery = [];
        clock = DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true);
        sync = CloudSync(
          auth: auth,
          backend: backend,
          store: Future.value(store),
          media: Future.value(IdbMediaStore(store)),
          changes: changes.stream,
          debounce: Duration.zero,
          interval: const Duration(hours: 24),
          fetchBatch: fetchBatch,
          prefetchRecordings: prefetch,
          onRemote: (r) async {
            remote.add(r);
            downloadedAtDelivery.add(List.of(backend.downloads));
            // As the app does: stored.
            for (final c in r.clips) {
              await store.putClip(c);
            }
            for (final e in r.events) {
              await store.putEvent(e);
            }
          },
          now: () => clock,
        );
        await auth.signIn();
        await sync.idle();
      }

      test('every event, clip and thumbnail is handed over before any '
          'recording is downloaded; then they come down, newest first, '
          'marked as synced', () async {
        remoteClip('r1', 1);
        remoteClip('r2', 2);
        remoteClip('r3', 3);
        await start(prefetch: true, fetchBatch: 2);

        expect(remote, hasLength(2));
        expect(remote.expand((r) => r.events).map((e) => e['id']), [
          'e-r3',
          'e-r2',
          'e-r1',
        ]);
        expect(
          remote
              .expand((r) => r.clips)
              .map((c) => opened(c['thumbnail']! as Uint8List)),
          [
            [3],
            [2],
            [1],
          ],
        );
        for (final downloaded in downloadedAtDelivery) {
          expect(downloaded.where(isRecording), isEmpty);
        }
        // Then, in the background, the recordings, newest first.
        expect(backend.downloads.where(isRecording), [
          'media/r3.mp4',
          'media/r2.mp4',
          'media/r1.mp4',
        ]);
        expect(opened((await store.getMedia('r1-full'))!), [1, 1]);
        expect(opened((await store.getMedia('r3-full'))!), [3, 3]);
        final synced = await store.syncedKeys();
        expect(synced['$prefix/media/r1.mp4'], 'r1-full');
        expect(synced.keys.where((k) => k.startsWith('fetch:')), isEmpty);

        // Nothing goes back up, nor comes down again.
        final before = Map.of(backend.uploads);
        backend.downloads.clear();
        changes.add(null);
        await sync.idle();
        expect(backend.uploads.keys, before.keys);
        expect(backend.downloads.where(isRecording), isEmpty);
      });

      test("a recording that fails to download doesn't hold up events, nor "
          'later passes; the next full fetch gets it', () async {
        remoteClip('r1', 1);
        remoteClip('r2', 2);
        backend.failGets.add('media/r2.mp4');
        await start(prefetch: true);

        expect(remote.single.events.map((e) => e['id']), ['e-r2', 'e-r1']);
        expect(sync.state, CloudSyncState.synced);
        // The other one came down.
        expect(opened((await store.getMedia('r1-full'))!), [1, 1]);
        expect(await store.getMedia('r2-full'), isNull);
        final synced = await store.syncedKeys();
        expect(synced['fetch:$prefix/media/r2.mp4'], '2:r2-full');
        // Never uploaded back, though it isn't here.
        expect(synced['$prefix/media/r2.mp4'], 'r2-full');

        // An ordinary pass doesn't try it again…
        backend.failGets.clear();
        backend.downloads.clear();
        changes.add({});
        await sync.idle();
        expect(sync.state, CloudSyncState.synced);
        expect(backend.downloads.where(isRecording), isEmpty);

        // …a full fetch does.
        clock = clock.add(const Duration(hours: 1));
        changes.add({});
        await sync.idle();
        expect(backend.downloads.where(isRecording), ['media/r2.mp4']);
        expect(opened((await store.getMedia('r2-full'))!), [2, 2]);
        expect(
          (await store.syncedKeys()).keys.where((k) => k.startsWith('fetch:')),
          isEmpty,
        );
      });

      test('a recording whose download meets expired credentials comes down '
          'with new ones, in the same run', () async {
        remoteClip('r1', 1);
        backend.failGetsOnce['media/r1.mp4'] = S3Exception(
          403,
          '<Code>ExpiredToken</Code>',
        );
        await start(prefetch: true);
        expect(backend.resets, greaterThan(0));
        expect(opened((await store.getMedia('r1-full'))!), [1, 1]);
        expect(
          (await store.syncedKeys()).keys.where((k) => k.startsWith('fetch:')),
          isEmpty,
        );
      });

      test('on the web, recordings come down only when played', () async {
        remoteClip('r1', 1);
        await start(prefetch: false);

        expect(remote.single.clips.single['id'], 'r1');
        expect(backend.downloads.where(isRecording), isEmpty);
        expect(await store.getMedia('r1-full'), isNull);
        // A reconciliation doesn't try to upload what isn't here.
        changes.add(null);
        await sync.idle();
        expect(sync.state, CloudSyncState.synced);
        expect(backend.downloads.where(isRecording), isEmpty);

        // Played: downloaded then, and synced.
        expect(await sync.fetchRecording('r1', 'r1-full'), isTrue);
        expect(backend.downloads.where(isRecording), ['media/r1.mp4']);
        expect(opened((await store.getMedia('r1-full'))!), [1, 1]);
        final synced = await store.syncedKeys();
        expect(synced['$prefix/media/r1.mp4'], 'r1-full');
        expect(synced.containsKey('fetch:$prefix/media/r1.mp4'), isFalse);

        // Not in the cloud, or signed out: nothing to play.
        expect(await sync.fetchRecording('nope', 'nope-full'), isFalse);
        await auth.signOut();
        await sync.idle();
        expect(await sync.fetchRecording('r1', 'r1-full'), isFalse);
      });
    });
  });

  group('integrity', () {
    const prefix = 'us-east-1:identity';
    Uint8List json(Map<String, Object?> m) =>
        Uint8List.fromList(utf8.encode(jsonEncode(m)));
    void put(String key, Uint8List bytes) => backend.uploads['$prefix/$key'] = (
      bytes: bytes,
      contentType: 'application/json',
    );
    const day = 'events/year=1970/day=001';

    test('signing out mid-pass uploads nothing more', () async {
      var first = true;
      backend.beforePut = (key) async {
        if (!first) return;
        first = false;
        await auth.signOut();
      };
      await auth.signIn();
      await sync.idle();
      expect(backend.uploads, hasLength(1), reason: 'only the one under way');
      expect(sync.state, CloudSyncState.off);
    });

    test('a pass that outlives its profile stamps, hands over and uploads '
        'nothing for the next one', () async {
      sync.dispose();
      final client = FakeRolesClient()..profile = 'pa';
      final roles = RolesService(auth: auth, client: client);
      addTearDown(roles.dispose);
      for (final p in ['pa', 'pb']) {
        await store.putEvent({
          'id': '${p}1',
          'type': 'x',
          'title': p,
          'time': 3,
          'userId': '1',
          'profileId': p,
        });
      }
      put('$day/r1.json', json({'id': 'r1', 'type': 'x', 'time': 4}));
      var switched = false;
      backend.beforeGet = (key) async {
        if (switched || !key.endsWith('r1.json')) return;
        switched = true;
        // The account moves to profile pb, whose folder is another.
        client.profile = 'pb';
        backend.prefix = 'us-east-1:other';
        await roles.refresh();
      };
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
      await auth.signIn();
      await Future<void>.delayed(Duration.zero);
      await sync.idle();

      expect(switched, isTrue);
      expect(
        fetched.expand((r) => r.events),
        isEmpty,
        reason: "pa's event isn't handed over as pb's",
      );
      final keys = backend.uploads.keys;
      expect(
        keys.where((k) => k.startsWith('$prefix/') && k.contains('pb1')),
        isEmpty,
        reason: "pb's event doesn't go up to pa's folder",
      );
      expect(keys, contains('us-east-1:other/$day/pb1.json'));
      expect(
        keys.where(
          (k) => k.startsWith('us-east-1:other/') && k.contains('pa1'),
        ),
        isEmpty,
      );
      expect(sync.state, CloudSyncState.synced);
    });

    test('damaged or unsafe objects in the bucket are skipped, not read '
        'again, and the rest syncs', () async {
      sync.dispose();
      put('$day/bad.json', Uint8List.fromList(utf8.encode('not json{')));
      put('$day/wrong.json', json({'id': 'other', 'time': 5}));
      put('$day/notime.json', json({'id': 'notime', 'time': 'yesterday'}));
      put(
        '$day/badclip.json',
        json({'id': 'badclip', 'time': 7, 'clipId': '../../x'}),
      );
      // Integral doubles (JSON from another runtime) are fine.
      put(
        '$day/good.json',
        json({
          'id': 'good',
          'type': 'clipRequested',
          'title': 'Good',
          'time': 6.0,
          'clipId': 'cg',
          'annotations': [
            {'name': 'Ana', 'frameId': '../evil'},
          ],
        }),
      );
      put('media/cg/frames/../evil.jpg', sealed([6]));
      // Its clip's recording reference has no media ID: the clip comes
      // without it.
      put(
        CloudSync.clipRecordKey('cg', 6),
        json({
          'id': 'cg',
          'eventId': 'good',
          'state': 'complete',
          'beforeMs': 5000.0,
          'full': {'startMs': 0, 'endMs': 1000},
        }),
      );
      final fetched = <RemoteRecords>[];
      sync = CloudSync(
        auth: auth,
        backend: backend,
        store: Future.value(store),
        media: Future.value(IdbMediaStore(store)),
        changes: changes.stream,
        debounce: Duration.zero,
        onRemote: (r) async => fetched.add(r),
        now: () => DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
      );
      await auth.signIn();
      await sync.idle();

      expect(sync.state, CloudSyncState.synced);
      final events = fetched.expand((r) => r.events).toList();
      expect(events.map((e) => e['id']), ['good']);
      expect(events.single['time'], 6);
      final clip = fetched.expand((r) => r.clips).single;
      expect(clip['beforeMs'], 5000);
      expect(clip.containsKey('full'), isFalse);
      expect(backend.downloads, isNot(contains('media/cg/frames/../evil.jpg')));
      expect(
        (await store.syncedKeys()).keys.where((k) => k.startsWith('fetch:')),
        isEmpty,
      );
      // This device's events still went up.
      expect(backend.uploads.keys, contains('$prefix/$day/e1.json'));

      // The damaged ones aren't downloaded again until they change.
      backend.downloads.clear();
      changes.add(null);
      await sync.idle();
      expect(sync.state, CloudSyncState.synced);
      expect(
        backend.downloads.where(
          (k) => ['bad', 'wrong', 'notime', 'badclip'].any(k.contains),
        ),
        isEmpty,
      );
      put('$day/bad.json', json({'id': 'bad', 'type': 'x', 'time': 8}));
      changes.add(null);
      await sync.idle();
      expect(
        fetched.expand((r) => r.events).map((e) => e['id']),
        contains('bad'),
        reason: 'fixed since: read again',
      );
    });

    test('a request signed at the wrong time is made again, and one that '
        'keeps failing says the clock is off', () async {
      backend.failPut = S3Exception(
        403,
        '<Code>RequestTimeTooSkewed</Code>',
        clockOffset: const Duration(minutes: 20),
      );
      await auth.signIn();
      await sync.idle();
      expect(sync.state, CloudSyncState.synced);
      expect(backend.uploads, hasLength(5));

      backend.failEveryPut = S3Exception(
        403,
        '<Code>RequestTimeTooSkewed</Code>',
        clockOffset: const Duration(minutes: -20),
      );
      await store.putEvent({
        'userId': '1',
        'profileId': '1',
        'id': 'e9',
        'type': 'x',
        'title': 'Later',
        'time': 9,
      });
      changes.add({'e9'});
      await sync.idle();
      expect(sync.state, CloudSyncState.error);
      expect(sync.error, contains("This device's clock is off by 20 min"));
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
          'f1': sealed([9, 8, 7]),
        },
      });
      await auth.signIn();
      await sync.idle();

      const prefix = 'us-east-1:identity';
      final frame = backend.uploads['$prefix/media/c1/frames/f1.jpg'];
      expect(opened(frame!.bytes), [9, 8, 7]);
      expect(frame.contentType, CloudSync.sealedType);
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
      expect(opened((event['frames'] as Map)['f1'] as Uint8List), [9, 8, 7]);
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
      // Its own folder once; and every device's, once, for their media
      // keys (on the first pass and each full fetch).
      expect(backend.listings.where((l) => l.startsWith('devices/')), [
        'devices/dev-1/',
        'devices/',
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
      putRemote({
        'deviceId': 'dev-1',
        'profileId': '1',
        'updatedAt': 5,
        'config': <String, Object?>{},
      });
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

    test('settings in the cloud that aren\'t JSON count as none: the '
        'local ones go up over them', () async {
      backend.uploads[key] = (
        bytes: Uint8List.fromList(utf8.encode('{broken')),
        contentType: 'application/json',
      );
      await auth.signIn();
      await withSettings.idle();
      expect(withSettings.state, CloudSyncState.synced);
      expect(settings.applied, isEmpty);
      expect(settings.claimed, ['1']);
      expect(
        jsonDecode(utf8.decode(backend.uploads[key]!.bytes)),
        containsPair('deviceId', 'dev-1'),
      );
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
