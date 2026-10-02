/// The web frame sampler on a real `MediaRecorder` WebM (what clips are on
/// web): `flutter test --platform chrome test/chrome/`.
@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

import 'package:presence_app/cameras/camera_source.dart';
import 'package:presence_app/recognition/frames.dart';

/// Records [seconds] of a canvas whose colour goes red → green → blue, one
/// per second, and returns the WebM's URL.
Future<String> recordCanvas(int seconds) async {
  final canvas = web.HTMLCanvasElement()
    ..width = 320
    ..height = 240;
  final context = canvas.getContext('2d')! as web.CanvasRenderingContext2D;
  const colours = ['#ff0000', '#00ff00', '#0000ff'];
  final stream = canvas.captureStream(30);
  final recorder = web.MediaRecorder(
    stream,
    web.MediaRecorderOptions(mimeType: 'video/webm'),
  );
  final chunks = <web.Blob>[];
  recorder.ondataavailable = ((web.BlobEvent e) => chunks.add(e.data)).toJS;
  final stopped = Completer<void>();
  recorder.onstop = ((web.Event _) => stopped.complete()).toJS;
  final started = DateTime.now();
  final paint = Timer.periodic(const Duration(milliseconds: 30), (_) {
    final second = DateTime.now().difference(started).inMilliseconds ~/ 1000;
    context
      ..fillStyle = colours[second % colours.length].toJS
      ..fillRect(0, 0, 320, 240);
  });
  recorder.start(250);
  await Future<void>.delayed(Duration(seconds: seconds));
  recorder.stop();
  await stopped.future;
  paint.cancel();
  final blob = web.Blob(chunks.toJS, web.BlobPropertyBag(type: 'video/webm'));
  return web.URL.createObjectURL(blob);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('samples a recorded WebM every half second, in order', () async {
    final url = await recordCanvas(3);
    final sampler = ClipFrameSampler();
    expect(sampler.supported, isTrue);
    final frames = <(Duration, int, int, int)>[];
    await for (final f in sampler.sample(
      ClipMedia(
        url: url,
        start: Duration.zero,
        end: const Duration(seconds: 3),
      ),
      every: const Duration(milliseconds: 500),
    )) {
      // The middle pixel's colour.
      final i = (f.image.height ~/ 2 * f.image.width + f.image.width ~/ 2) * 4;
      frames.add((
        f.position,
        f.image.pixels[i],
        f.image.pixels[i + 1],
        f.image.pixels[i + 2],
      ));
      expect(f.image.width, 320);
      expect((await f.jpeg())!.take(2), [0xFF, 0xD8], reason: 'a JPEG');
    }
    // ignore: avoid_print
    print('frames: $frames');
    expect(frames.length, greaterThanOrEqualTo(5));
    for (var i = 1; i < frames.length; i++) {
      expect(frames[i].$1, greaterThan(frames[i - 1].$1));
    }
    // Red at the start, then green after a second.
    expect(frames.first.$2, greaterThan(200));
    final green = frames.firstWhere(
      (f) => f.$1 >= const Duration(milliseconds: 1500),
    );
    expect(green.$3, greaterThan(200));
    expect(green.$2, lessThan(80));
  });
}
