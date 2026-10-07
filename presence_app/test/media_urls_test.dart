import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_client_memory.dart';
import 'package:presence_app/cameras/camera_source.dart';
import 'package:presence_app/storage/event_store.dart';
import 'package:presence_app/storage/media_store.dart';

import 'fakes.dart';

/// On web every live recording and every stored one played is a Blob URL
/// held in memory until revoked: these check each is revoked once nothing
/// needs it (counted here, since tests run off the browser).
void main() {
  late List<String> revoked;
  late MediaUrls urls;
  final original = MediaUrls.instance;

  setUp(() {
    revoked = [];
    MediaUrls.instance = urls = MediaUrls(revoke: revoked.add);
  });
  tearDown(() => MediaUrls.instance = original);

  ClipMedia live(String url) => ClipMedia(
    url: url,
    start: Duration.zero,
    end: const Duration(seconds: 10),
  );

  test('a live recording keeps its URL until it lets go', () {
    final media = live('blob:a');
    expect(urls.tracked, 1);
    media.discard();
    expect(revoked, ['blob:a']);
    expect(urls.tracked, 0);
    expect(media.liveUrl, isNull);
  });

  test('a URL two clips share is revoked when both let go', () {
    final a = live('blob:shared');
    final b = live('blob:shared');
    a.discard();
    expect(revoked, isEmpty);
    b.discard();
    expect(revoked, ['blob:shared']);
  });

  test('a player holding a live URL keeps it past the save', () async {
    final media = live('blob:live');
    final url = await media.acquireUrl();
    expect(url, 'blob:live');
    var loads = 0;
    media.persisted(() async => 'blob:stored-${++loads}');
    expect(media.liveUrl, isNull, reason: 'played from storage now');
    expect(revoked, isEmpty, reason: 'still playing');
    media.releaseUrl(url);
    expect(revoked, ['blob:live']);
  });

  test('a stored recording\'s URL is revoked when its last user lets go, '
      'and loaded again next time', () async {
    var loads = 0;
    final media = ClipMedia.stored(
      load: () async => 'blob:stored-${++loads}',
      start: Duration.zero,
      end: const Duration(seconds: 10),
    );
    final a = await media.acquireUrl();
    final b = await media.acquireUrl();
    expect([a, b], ['blob:stored-1', 'blob:stored-1']);
    expect(loads, 1);
    media.releaseUrl(a);
    expect(revoked, isEmpty);
    media.releaseUrl(b);
    expect(revoked, ['blob:stored-1']);
    expect(urls.tracked, 0);

    final c = await media.acquireUrl();
    expect(c, 'blob:stored-2');
    media.releaseUrl(c);
    expect(revoked, ['blob:stored-1', 'blob:stored-2']);
  });

  test('a failed load is tried again next time', () async {
    var fail = true;
    final media = ClipMedia.stored(
      load: () async => fail ? throw StateError('missing') : 'blob:ok',
      start: Duration.zero,
      end: const Duration(seconds: 10),
    );
    await expectLater(media.acquireUrl(), throwsStateError);
    fail = false;
    expect(await media.acquireUrl(), 'blob:ok');
  });

  test('saving to IndexedDB switches the clip to the stored copy and frees '
      'the live one', () async {
    final store = await EventStore.open(newIdbFactoryMemory());
    final media = IdbMediaStore(store, fakeMediaIo);
    final clip = live('blob:recorded');
    await media.save('clip-full', clip);
    expect(revoked, ['blob:recorded']);
    expect(clip.liveUrl, isNull);
    final url = await clip.acquireUrl();
    expect(url, 'restored:blob:recorded');
    clip.releaseUrl(url);
    expect(revoked.last, 'restored:blob:recorded');
  });

  test('untracked URLs (files on Android) stay as they are', () async {
    MediaUrls.instance = MediaUrls.none();
    final clip = live('/data/clip.mp4');
    clip.persisted(() async => '/data/stored.mp4');
    expect(clip.liveUrl, '/data/clip.mp4');
    final url = await clip.acquireUrl();
    clip.releaseUrl(url);
    expect(url, '/data/clip.mp4');
  });
}
