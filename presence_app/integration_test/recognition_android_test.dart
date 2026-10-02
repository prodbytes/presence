/// Recognition on an Android device or emulator, for real: LiteRT running
/// the bundled models, `framesAt` reading MP4s, and the recognizer end to
/// end. The clips and portraits go in first:
///
/// ```sh
/// flutter install --debug        # once, so the app's files exist
/// integration_test/push_fixtures.sh
/// flutter test integration_test/recognition_android_test.dart
/// ```
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:presence_app/annotations.dart';
import 'package:presence_app/cameras/camera_source.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/recognition/frames.dart';
import 'package:presence_app/recognition/image.dart';
import 'package:presence_app/recognition/matching.dart';
import 'package:presence_app/recognition/recognizer.dart';
import 'package:presence_app/recognition/runtime.dart';
import 'package:presence_app/recognition/vision.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory fixtures;
  late VisionModels models;

  setUpAll(() async {
    fixtures = Directory(
      '${(await getApplicationSupportDirectory()).path}/fixtures',
    );
    expect(
      fixtures.existsSync(),
      isTrue,
      reason: 'run integration_test/push_fixtures.sh first',
    );
    expect(TfliteRuntime().supported, isTrue);
    expect(ClipFrameSampler().supported, isTrue);
    models = await VisionModels.load(TfliteRuntime());
  });

  String path(String name) => '${fixtures.path}/$name';

  Future<RgbaImage> image(String name) async =>
      (await RgbaImage.decode(await File(path(name)).readAsBytes()))!;

  ClipRequested clipOf(String file, {ClipAnnotations? annotations}) =>
      ClipRequested(
        VideoClip.restored(
          id: 'clip-$file',
          cameraId: 'cam',
          cameraLabel: 'Back camera',
          before: const Duration(seconds: 1),
          after: const Duration(seconds: 2),
          past: null,
          full: ClipMedia(
            url: path(file),
            start: Duration.zero,
            end: const Duration(seconds: 3),
            mimeType: 'video/mp4',
          ),
        ),
        annotations: annotations,
        id: 'event-$file',
      );

  testWidgets('the models find her, and tell people apart', (_) async {
    final hopper = await image('hopper_1.jpg');
    await models.analyse(hopper); // Warm up.
    final watch = Stopwatch()..start();
    final analysis = await models.analyse(hopper);
    final seen = analysis.seen;
    expect(analysis.objects['human'], greaterThan(VisionModels.minObject));
    // ignore: avoid_print
    print(
      'one ${hopper.width} × ${hopper.height} frame: '
      '${watch.elapsedMilliseconds} ms',
    );
    final person = seen.firstWhere((s) => s.detection.kind == SeenKind.person);
    expect(person.face, isNotNull);
    expect(person.faceVector, hasLength(192));

    Future<Float32List> face(String name) async =>
        (await models.analyse(await image(name))).seen
            .firstWhere((s) => s.faceVector != null)
            .faceVector!;
    final lincoln1 = await face('lincoln_1.jpg');
    final lincoln2 = await face('lincoln_2.jpg');
    final hopper1 = await face('hopper_1.jpg');
    final same = cosine(lincoln1, lincoln2);
    final other = cosine(lincoln1, hopper1);
    // ignore: avoid_print
    print(
      'Lincoln–Lincoln ${same.toStringAsFixed(2)}, '
      'Lincoln–Hopper ${other.toStringAsFixed(2)}',
    );
    expect(same, greaterThan(other));
    expect(faceConfidence(same), greaterThanOrEqualTo(0.8));
  });

  testWidgets('framesAt reads an MP4 every half second', (_) async {
    final frames = <(int, int, int, int)>[];
    await for (final f in ClipFrameSampler().sample(
      clipOf('colours.mp4').clip.full!,
      every: const Duration(milliseconds: 500),
    )) {
      final i = (f.image.height ~/ 2 * f.image.width + f.image.width ~/ 2) * 4;
      frames.add((
        f.position.inMilliseconds,
        f.image.pixels[i],
        f.image.pixels[i + 1],
        f.image.pixels[i + 2],
      ));
      expect(f.image.width, 640);
      expect((await f.jpeg())!.take(2), [0xFF, 0xD8]);
    }
    // ignore: avoid_print
    print('frames: $frames');
    expect(frames.map((f) => f.$1), [0, 500, 1000, 1500, 2000, 2500]);
    expect(frames.first.$2, greaterThan(200)); // red
    expect(frames[3].$3, greaterThan(100)); // green
    expect(frames.last.$4, greaterThan(200)); // blue
  });

  testWidgets('a new clip gets her tag, on the first frame she is on', (
    _,
  ) async {
    // Tagged before, on her photo, on her face.
    final reference = ClipAnnotations();
    final frame = reference.newFrame(
      await File(path('hopper_1.jpg')).readAsBytes(),
      0,
    );
    reference.add('Grace', 0.5, 0.3, frame: frame);
    final bus = AppEventBus();
    final log = EventLog(bus.stream)
      ..addHistory([
        ClipRequested(
          clipOf('old.mp4').clip,
          annotations: reference,
          id: 'old',
          time: DateTime(2026, 10, 1),
        ),
      ]);
    final recognizer = SubjectRecognizer(
      bus: bus,
      log: log,
      config: ConfigController(),
    );
    final event = clipOf('hopper.mp4');
    final watch = Stopwatch()..start();
    await recognizer.recognize(event);
    // ignore: avoid_print
    print(
      'recognized in ${watch.elapsedMilliseconds} ms: '
      '${event.annotations.items.map((a) => (a.name, a.source.name, a.frameMs, a.confidence?.toStringAsFixed(2)))}',
    );
    final tag = event.annotations.tags.single;
    expect(tag.name, 'Grace');
    expect(tag.source, TagSource.detected);
    expect(tag.frameMs, inInclusiveRange(1000, 1500));
    expect(tag.confidence, greaterThanOrEqualTo(0.8));
    // Where she is: (100, 200) on 1280 × 720, her face in the upper part.
    expect(tag.x, inInclusiveRange(100 / 1280, 510 / 1280));
    expect(tag.y, inInclusiveRange(200 / 720, 440 / 720));
    recognizer.dispose();
  });
}
