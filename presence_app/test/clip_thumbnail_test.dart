import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_client_memory.dart';

import 'package:presence_app/cameras/camera_source.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/clips/clip_thumbnail.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/recognition/frames.dart';
import 'package:presence_app/recognition/image.dart';
import 'package:presence_app/storage/event_store.dart';
import 'package:presence_app/storage/media_store.dart';
import 'package:presence_app/storage/persistence.dart';

import 'sealed.dart';

/// A [width] × [height] picture of one gray [level].
RgbaImage gray(int level, {int width = 1, int height = 1}) => RgbaImage(
  width,
  height,
  Uint8List.fromList([
    for (var i = 0; i < width * height; i++) ...[level, level, level, 255],
  ]),
);

/// "Decodes" an opened image whose first byte is its gray level.
Future<RgbaImage?> decodeLevel(Uint8List image) async =>
    image.isEmpty ? null : gray(image.first);

/// A recording whose frames, from where it's asked to start, have the gray
/// [levels] in turn; each frame's "JPEG" is its level.
class LevelSampler implements ClipFrameSampler {
  LevelSampler(this.levels);

  final List<int> levels;
  final calls = <({Duration every, Duration? from})>[];
  int jpegs = 0;

  @override
  bool get supported => true;

  @override
  Stream<SampledFrame> sample(
    ClipMedia media, {
    required Duration every,
    Duration? from,
    int maxWidth = ClipFrameSampler.defaultMaxWidth,
  }) async* {
    calls.add((every: every, from: from));
    var at = from ?? media.start;
    for (final level in levels) {
      yield SampledFrame(at, gray(level), () async {
        jpegs++;
        return Uint8List.fromList([level]);
      });
      at += every;
    }
  }
}

void main() {
  final recording = ClipMedia.stored(
    load: () async => 'unused',
    start: Duration.zero,
    end: const Duration(seconds: 15),
  );

  group('black frames', () {
    test('mean luma: black is dark, a dim night picture is not', () {
      expect(ThumbnailMaker.meanLuma(gray(0)), 0);
      expect(ThumbnailMaker.meanLuma(gray(200)), closeTo(200, 0.01));
      expect(ThumbnailMaker.isDark(ThumbnailMaker.meanLuma(gray(0))), isTrue);
      expect(ThumbnailMaker.isDark(ThumbnailMaker.meanLuma(gray(15))), isTrue);
      // Night starts at 40 (NightDetector): a night picture isn't black.
      expect(ThumbnailMaker.isDark(ThumbnailMaker.meanLuma(gray(30))), isFalse);
    });

    test('luma weighs green most (BT.601) and reads a big picture on a '
        'grid', () {
      final green = RgbaImage(1, 1, Uint8List.fromList([0, 100, 0, 255]));
      expect(ThumbnailMaker.meanLuma(green), closeTo(58.7, 0.01));
      final big = gray(80, width: 1280, height: 720);
      expect(ThumbnailMaker.meanLuma(big), closeTo(80, 0.01));
    });
  });

  group('ThumbnailMaker.check', () {
    ThumbnailMaker maker(LevelSampler sampler) =>
        ThumbnailMaker(sampler: sampler, decode: decodeLevel);

    test('a bright thumbnail is kept, the recording not read', () async {
      final sampler = LevelSampler([200]);
      final found = await maker(sampler).check(sealed([120]), recording);
      expect(found!.check, ThumbnailCheck.ok);
      expect(found.thumbnail, isNull);
      expect(sampler.calls, isEmpty);
    });

    test('a black thumbnail: the first bright frame from the middle on '
        'replaces it', () async {
      final sampler = LevelSampler([3, 90, 150]);
      final found = await maker(sampler).check(sealed([2]), recording);
      expect(found!.check, ThumbnailCheck.ok);
      expect(opened(found.thumbnail!), [90]);
      // From the middle, then 0.7 and 0.9 of the way; stops at the first.
      expect(sampler.calls.single.from, const Duration(milliseconds: 7500));
      expect(sampler.calls.single.every, const Duration(seconds: 3));
      expect(sampler.jpegs, 2);
    });

    test('a missing thumbnail is made from the recording', () async {
      final found = await maker(LevelSampler([60])).check(null, recording);
      expect(found!.check, ThumbnailCheck.ok);
      expect(opened(found.thumbnail!), [60]);
    });

    test('all dark (a night scene): the brightest is kept, shown as a '
        'placeholder', () async {
      final found = await maker(LevelSampler([4, 11, 7]))
          .check(sealed([1]), recording);
      expect(found!.check, ThumbnailCheck.dark);
      expect(found.check.placeholder, isTrue);
      expect(opened(found.thumbnail!), [11]);
    });

    test('all darker than the thumbnail: the thumbnail stays', () async {
      final found = await maker(LevelSampler([2, 3]))
          .check(sealed([12]), recording);
      expect(found!.check, ThumbnailCheck.dark);
      expect(found.thumbnail, isNull);
    });

    test('without the recording: nothing to make one from', () async {
      final sampler = LevelSampler([200]);
      final found = await maker(sampler).check(sealed([0]), null);
      expect(found!.check, ThumbnailCheck.noRecording);
      expect(found.thumbnail, isNull);
      expect(sampler.calls, isEmpty);
    });

    test('a thumbnail that doesn\'t open counts as missing', () async {
      final found = await maker(LevelSampler([100]))
          .check(Uint8List.fromList([1, 2, 3]), recording);
      expect(found!.check, ThumbnailCheck.ok);
      expect(opened(found.thumbnail!), [100]);
    });
  });

  group('Persistence regenerates thumbnails', () {
    late AppEventBus bus;
    late Persistence persistence;
    late EventStore store;
    late EventLog log;
    late LevelSampler sampler;

    setUp(() async {
      bus = AppEventBus();
      persistence = Persistence(
        factory: Future.value(newIdbFactoryMemory()),
        bus: bus,
        config: ConfigController(),
        mediaStore: IdbMediaStore.new,
      );
      sampler = LevelSampler([140]);
      persistence.thumbnails = ThumbnailMaker(
        sampler: sampler,
        decode: decodeLevel,
      );
      store = await persistence.store;
      log = EventLog(bus.stream);
    });

    tearDown(() {
      log.dispose();
      persistence.dispose();
      bus.close();
    });

    Future<void> putClip(String id, int time, Object? thumbnail) async {
      await store.putEvent({
        'id': 'e-$id',
        'type': ClipRequested.clipRequestedType,
        'title': 'Clip',
        'time': time,
        'clipId': id,
      });
      await store.putClip({
        'id': id,
        'eventId': 'e-$id',
        'cameraId': 'cam',
        'state': 'complete',
        'thumbnail': ?thumbnail,
        'full': {'mediaId': '$id-full', 'startMs': 0, 'endMs': 15000},
      });
    }

    VideoClip clipOf(String id) => log.events
        .whereType<ClipRequested>()
        .firstWhere((e) => e.clip.id == id)
        .clip;

    Future<Map<String, Object?>> checked(String id) async {
      for (var i = 0; i < 200; i++) {
        final record = (await store.getClip(id))!;
        if (record.containsKey('thumbnailCheck')) return record;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      fail('clip $id was never checked');
    }

    test('a black or missing thumbnail of a recording stored here is made '
        'again, stored, shown and named changed for cloud sync', () async {
      await putClip('black', 2, sealed([1]));
      await putClip('missing', 1, null);
      await store.putMedia('black-full', sealed([0]));
      await store.putMedia('missing-full', sealed([0]));
      final changed = <String>{};
      final sub = persistence.changes.listen(changed.addAll);
      addTearDown(sub.cancel);

      await persistence.restore(log);
      for (final id in ['black', 'missing']) {
        final record = await checked(id);
        expect(record['thumbnailCheck'], 'ok');
        expect(record['thumbnailRedone'], isA<int>());
        expect(opened(record['thumbnail']! as Uint8List), [140]);
        final clip = clipOf(id);
        expect(opened(clip.thumbnail!), [140]);
        expect(clip.thumbnailPlaceholder, isFalse);
      }
      expect(changed, containsAll(['e-black', 'e-missing']));
    });

    test('a black thumbnail whose recording isn\'t here (another device\'s, '
        'not downloaded) shows a placeholder; nothing is fetched', () async {
      var fetched = 0;
      persistence.fetchMissingMedia = (clipId, mediaId) async {
        fetched++;
        throw StateError('not here');
      };
      await putClip('remote', 1, sealed([1]));

      await persistence.restore(log);
      final record = await checked('remote');
      expect(record['thumbnailCheck'], 'noRecording');
      expect(opened(record['thumbnail']! as Uint8List), [1]);
      expect(clipOf('remote').thumbnailPlaceholder, isTrue);
      expect(sampler.calls, isEmpty);
      expect(fetched, 0);
    });

    test('a bright thumbnail is kept, and a checked one isn\'t checked '
        'again', () async {
      await putClip('bright', 2, sealed([100]));
      await putClip('done', 1, sealed([1]));
      await store.putClip({
        ...(await store.getClip('done'))!,
        'thumbnailCheck': 'dark',
      });
      await store.putMedia('bright-full', sealed([0]));
      await store.putMedia('done-full', sealed([0]));

      await persistence.restore(log);
      expect((await checked('bright'))['thumbnailCheck'], 'ok');
      expect(opened(clipOf('bright').thumbnail!), [100]);
      expect(clipOf('done').thumbnailPlaceholder, isTrue);
      expect(sampler.calls, isEmpty);
    });
  });

  group('the card', () {
    Future<void> pumpCard(WidgetTester tester, VideoClip clip) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: ClipEventCard(event: ClipRequested(clip))),
          ),
        );

    VideoClip restored({Uint8List? thumbnail, bool placeholder = false}) =>
        VideoClip.restored(
          id: 'c1',
          cameraId: 'cam',
          cameraLabel: 'Front door',
          before: const Duration(seconds: 5),
          after: const Duration(seconds: 10),
          past: null,
          full: null,
          thumbnail: thumbnail,
          thumbnailPlaceholder: placeholder,
        );

    testWidgets('a missing thumbnail shows a placeholder', (tester) async {
      await pumpCard(tester, restored());
      expect(find.byKey(const Key('clip-thumbnail-placeholder')), findsOne);
      expect(find.byKey(const Key('clip-thumbnail')), findsNothing);
    });

    testWidgets('a black one too; once made again, the new one shows', (
      tester,
    ) async {
      final clip = restored(thumbnail: sealed([1]), placeholder: true);
      await pumpCard(tester, clip);
      expect(find.byKey(const Key('clip-thumbnail-placeholder')), findsOne);
      expect(find.byKey(const Key('clip-thumbnail')), findsNothing);

      clip.replaceThumbnail(sealed([140]), placeholder: false);
      await tester.pump();
      expect(find.byKey(const Key('clip-thumbnail')), findsOne);
      expect(find.byKey(const Key('clip-thumbnail-placeholder')), findsNothing);
    });
  });
}
