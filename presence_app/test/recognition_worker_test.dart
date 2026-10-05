import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/cameras/camera_source.dart';
import 'package:presence_app/recognition/frames.dart';
import 'package:presence_app/recognition/frames_native.dart';
import 'package:presence_app/recognition/image.dart';
import 'package:presence_app/recognition/vision.dart';
import 'package:presence_app/recognition/vision_worker.dart';

/// Opened in the worker: says what it got, as objects.
Future<Vision> _echo(Map<String, String> files) async =>
    _EchoVision(files.length);

Future<Vision> _broken(Map<String, String> files) async =>
    throw StateError('no models');

class _EchoVision extends Vision {
  _EchoVision(this.files);

  final int files;

  @override
  Future<FrameAnalysis> analyse(
    RgbaImage image, {
    bool faces = true,
    bool subjects = true,
    Set<SeenKind>? kinds,
    int? maxSeen,
  }) async => FrameAnalysis(
    seen: [
      Seen(
        Detection(const Box(0, 0, 1, 1), 0.9, kinds!.single),
        lookVector: Float32List.fromList([1, 0]),
      ),
    ],
    objects: {
      'files': files.toDouble(),
      'width': image.width.toDouble(),
      'first': image.pixels.first.toDouble(),
      'maxSeen': maxSeen!.toDouble(),
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('worker isolate', () {
    WorkerVision worker({
      VisionOpener open = _echo,
      Duration idle = WorkerVision.defaultIdleTimeout,
    }) => WorkerVision(
      files: () async => {'a': 'a.tflite', 'b': 'b.tflite'},
      open: open,
      idleTimeout: idle,
    );

    Future<FrameAnalysis> analyse(WorkerVision w, int first) => w.analyse(
      RgbaImage(2, 1, Uint8List.fromList([first, 0, 0, 255, 0, 0, 0, 255])),
      kinds: {SeenKind.dog},
      maxSeen: 3,
    );

    test('frames go in, only what is on them comes back', () async {
      final w = worker();
      final a = await analyse(w, 7);
      expect(a.objects, {'files': 2, 'width': 2, 'first': 7, 'maxSeen': 3});
      expect(a.seen.single.detection.kind, SeenKind.dog);
      expect(a.seen.single.lookVector, [1, 0]);
      expect(w.running, isTrue);
      w.release();
    });

    test('released, it stops; the next frame starts it again', () async {
      final w = worker();
      await analyse(w, 1);
      w.release();
      expect(w.running, isFalse);
      expect((await analyse(w, 2)).objects['first'], 2);
      w.release();
    });

    test('idle for a while, it stops by itself', () async {
      final w = worker(idle: const Duration(milliseconds: 20));
      await analyse(w, 1);
      expect(w.running, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(w.running, isFalse);
    });

    test(
      'models that fail to load fail the frame, and are tried again',
      () async {
        final w = worker(open: _broken);
        await expectLater(w.start(), throwsStateError);
        await expectLater(analyse(w, 1), throwsStateError);
        expect(w.running, isFalse);
      },
    );
  });

  group('Android frames', () {
    const channel = MethodChannel('presence/cameras');
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            final args = call.arguments as Map<Object?, Object?>;
            switch (call.method) {
              case 'keyframesAt':
                // A keyframe every second; each once per call.
                final keyframes = <int>{
                  for (final ms in args['ms']! as List<Object?>)
                    ((ms! as int) / 1000).round() * 1000,
                };
                return [
                  for (final k in keyframes)
                    {
                      'ms': k,
                      'width': 2,
                      'height': 1,
                      'pixels': Uint8List(8)..[0] = k ~/ 1000,
                    },
                ];
              case 'encodeJpeg':
                return Uint8List.fromList([0xFF, 0xD8]);
            }
            return null;
          });
    });
    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    test('sample times: from the start, every so long, before the end', () {
      final media = ClipMedia(
        url: 'clip.mp4',
        start: const Duration(milliseconds: 300),
        end: const Duration(milliseconds: 3400),
      );
      expect(sampleTimes(media, const Duration(milliseconds: 500)), [
        300,
        800,
        1300,
        1800,
        2300,
        2800,
        3300,
      ]);
      expect(sampleTimes(media, const Duration(seconds: 1)), [
        300,
        1300,
        2300,
        3300,
      ]);
    });

    test('each keyframe in the clip once, as RGBA; a JPEG if asked', () async {
      final frames = await PlatformFrameSampler()
          .sample(
            ClipMedia(
              url: 'clip.mp4',
              start: const Duration(milliseconds: 300),
              end: const Duration(milliseconds: 3400),
            ),
            every: const Duration(milliseconds: 500),
          )
          .toList();
      // 300 ms is nearest the keyframe at 0, before the clip: left out.
      expect(frames.map((f) => f.position.inMilliseconds), [1000, 2000, 3000]);
      expect(frames.map((f) => f.image.pixels.first), [1, 2, 3]);
      final asks = calls.where((c) => c.method == 'keyframesAt').toList();
      expect(asks, hasLength(3));
      expect(
        asks.first.arguments,
        containsPair('maxWidth', ClipFrameSampler.defaultMaxWidth),
      );
      expect(
        (asks.first.arguments as Map)['ms'],
        hasLength(PlatformFrameSampler.batch),
      );
      expect(calls.where((c) => c.method == 'encodeJpeg'), isEmpty);

      expect(await frames[1].jpeg(), [0xFF, 0xD8]);
      final encode = calls.last;
      expect(encode.method, 'encodeJpeg');
      expect(encode.arguments, containsPair('width', 2));
      expect((encode.arguments as Map)['pixels'], frames[1].image.pixels);
    });
  });
}
