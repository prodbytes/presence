/// The real models, in TensorFlow.js, through the shared Dart decoding.
/// Needs `presence_app/` served with CORS (models, `web/tfjs/`, fixtures):
///
/// ```sh
/// python3 test/chrome/serve.py &
/// flutter test --platform chrome test/chrome/
/// ```
///
/// Skipped when the server isn't there. The fixtures are public-domain
/// portraits of Grace Hopper and Abraham Lincoln (Wikimedia Commons).
@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:presence_app/recognition/image.dart';
import 'package:presence_app/recognition/matching.dart';
import 'package:presence_app/recognition/runtime.dart';
import 'package:presence_app/recognition/runtime_web.dart';
import 'package:presence_app/recognition/vision.dart';

const server = String.fromEnvironment(
  'RECOGNITION_SERVER',
  defaultValue: 'http://127.0.0.1:8766/',
);

class _HttpBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(await _get(key));
}

Future<Uint8List> _get(String path) async {
  final response = await http.get(Uri.parse('$server$path'));
  if (response.statusCode != 200) throw StateError('$path: no');
  return response.bodyBytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late VisionModels models;
  var serving = false;

  setUpAll(() async {
    try {
      await _get('assets/models/README.md');
      serving = true;
    } catch (_) {
      return;
    }
    PlatformRuntime.root = '${server}web/tfjs/';
    models = await VisionModels.load(TfliteRuntime(), bundle: _HttpBundle());
  });

  Future<RgbaImage> fixture(String name) async =>
      (await RgbaImage.decode(await _get('test/chrome/fixtures/$name')))!;

  test('finds the person where she is, and her face', () async {
    if (!serving) return markTestSkipped('no server at $server');
    final hopper = await fixture('hopper_1.jpg');
    // On a grey 1280 × 720 frame, at (100, 200).
    final frame = RgbaImage(1280, 720, Uint8List(1280 * 720 * 4));
    for (var i = 0; i < frame.pixels.length; i += 4) {
      frame.pixels
        ..[i] = 120
        ..[i + 1] = 120
        ..[i + 2] = 120
        ..[i + 3] = 255;
    }
    for (var y = 0; y < hopper.height; y++) {
      final from = y * hopper.width * 4;
      frame.pixels.setRange(
        ((200 + y) * 1280 + 100) * 4,
        ((200 + y) * 1280 + 100 + hopper.width) * 4,
        hopper.pixels.sublist(from, from + hopper.width * 4),
      );
    }
    await models.analyse(frame); // Warm up.
    final watch = Stopwatch()..start();
    final analysis = await models.analyse(frame);
    // ignore: avoid_print
    print('one 1280 × 720 frame: ${watch.elapsedMilliseconds} ms');
    final seen = analysis.seen;
    // The object tags' segment sees her too.
    expect(analysis.objects['human'], greaterThan(VisionModels.minObject));
    final person = seen.firstWhere((s) => s.detection.kind == SeenKind.person);
    final truth = Box(
      100 / 1280,
      200 / 720,
      (100 + hopper.width) / 1280,
      (200 + hopper.height) / 720,
    );
    expect(person.detection.box.iou(truth), greaterThan(0.6));
    expect(person.face, isNotNull);
    expect(truth.contains(person.face!.box.cx, person.face!.box.cy), isTrue);
    // Her face, upper half of the picture.
    expect(person.face!.box.cy, lessThan(truth.cy));
    expect(person.faceVector, hasLength(192));
    // OSNet, for people.
    expect(person.lookVector, hasLength(512));

    // The same face on its own photo matches it surely.
    final alone = (await models.analyse(hopper)).seen.first;
    expect(
      faceConfidence(cosine(person.faceVector!, alone.faceVector!)),
      greaterThan(0.8),
    );
  });

  test('someone small, far off, is found by a tile, where they are', () async {
    if (!serving) return markTestSkipped('no server at $server');
    final hopper = await fixture('hopper_1.jpg');
    // A third of her size (nearest pixel), at the right of a grey frame.
    const k = 3;
    final w = hopper.width ~/ k, h = hopper.height ~/ k;
    const left = 1000, top = 400;
    final frame = RgbaImage(
      1280,
      720,
      Uint8List(1280 * 720 * 4)..fillRange(0, 1280 * 720 * 4, 120),
    );
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final from = ((y * k) * hopper.width + x * k) * 4;
        final to = ((top + y) * 1280 + left + x) * 4;
        frame.pixels.setRange(to, to + 4, hopper.pixels, from);
      }
    }
    final (detections, _) = await models.detect(frame);
    final truth = Box(
      left / 1280,
      top / 720,
      (left + w) / 1280,
      (top + h) / 720,
    );
    final person = detections.firstWhere((d) => d.kind == SeenKind.person);
    // ignore: avoid_print
    print('small person: $w × $h px, found at ${person.box}');
    expect(person.box.iou(truth), greaterThan(0.5));
    // Found once, not once per region.
    expect(detections.where((d) => d.kind == SeenKind.person), hasLength(1));
  });

  test('the same person is closer than someone else', () async {
    if (!serving) return markTestSkipped('no server at $server');
    Future<Float32List> face(String name) async {
      final seen = (await models.analyse(await fixture(name))).seen;
      return seen.firstWhere((s) => s.faceVector != null).faceVector!;
    }

    final lincoln1 = await face('lincoln_1.jpg');
    final lincoln2 = await face('lincoln_2.jpg');
    final hopper1 = await face('hopper_1.jpg');
    final hopper2 = await face('hopper_2.jpg');
    final same = cosine(lincoln1, lincoln2);
    final others = [
      cosine(lincoln1, hopper1),
      cosine(lincoln1, hopper2),
      cosine(lincoln2, hopper1),
      cosine(lincoln2, hopper2),
    ];
    // ignore: avoid_print
    print(
      'face cosines: Lincoln–Lincoln ${same.toStringAsFixed(2)}, '
      'Hopper–Hopper ${cosine(hopper1, hopper2).toStringAsFixed(2)}, '
      'across ${others.map((c) => c.toStringAsFixed(2)).join(' ')}',
    );
    for (final other in others) {
      expect(same, greaterThan(other));
    }
    expect(faceConfidence(same), greaterThanOrEqualTo(0.8));
  });
}
