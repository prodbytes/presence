import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';
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
      'id': 'e1',
      'type': 'appStarted',
      'title': 'Application started',
      'time': 1,
    });
    await store.putEvent({
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
        'us-east-1:identity/clips/c1.webm',
        'us-east-1:identity/clips/c1.jpg',
        'us-east-1:identity/clips/c1.json',
        'us-east-1:identity/events/e1.json',
        'us-east-1:identity/events/e2.json',
      });
      final video = backend.uploads['us-east-1:identity/clips/c1.webm']!;
      expect(video.bytes, [1, 2, 3]);
      expect(video.contentType, 'video/webm;codecs=vp8,opus');
      final details = jsonDecode(
        utf8.decode(backend.uploads['us-east-1:identity/clips/c1.json']!.bytes),
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
        'id': 'e1',
        'type': 'appStarted',
        'title': 'Application started',
        'time': 1,
        'detail': 'changed',
      });
      changes.add(null);
      await sync.idle();
      expect(backend.uploads.keys, {'us-east-1:identity/events/e1.json'});
    },
  );

  test('a new event while signed in is uploaded when saved', () async {
    await auth.signIn();
    await sync.idle();
    backend.uploads.clear();

    await store.putEvent({'id': 'e3', 'type': 'x', 'title': 'New', 'time': 3});
    changes.add(null);
    await sync.idle();
    expect(backend.uploads.keys, {'us-east-1:identity/events/e3.json'});
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

  test('signing out stops uploads', () async {
    await auth.signIn();
    await sync.idle();
    await auth.signOut();
    backend.uploads.clear();
    await store.putEvent({
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
}
