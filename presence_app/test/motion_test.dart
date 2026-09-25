import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/motion.dart';

const int w = motionFrameWidth;
const int h = motionFrameHeight;

/// A flat grey frame, optionally with a bright square at [x], [y].
Uint8List frame({int base = 100, int? x, int? y, int size = 0}) {
  final f = Uint8List(w * h)..fillRange(0, w * h, base);
  if (x != null && y != null) {
    for (var j = y; j < y + size && j < h; j++) {
      for (var i = x; i < x + size && i < w; i++) {
        f[j * w + i] = 250;
      }
    }
  }
  return f;
}

void main() {
  late DateTime now;
  late MotionDetector detector;

  setUp(() {
    now = DateTime(2026, 9, 25, 12);
    detector = MotionDetector(now: () => now);
  });

  /// Feeds [f] after the warm-up period.
  double? afterWarmup(Uint8List f) {
    now = now.add(const Duration(seconds: 5));
    return detector.add(f);
  }

  test('ignores frames while warming up', () {
    expect(detector.add(frame()), isNull);
    now = now.add(const Duration(seconds: 1));
    expect(detector.add(frame(x: 0, y: 0, size: 30)), isNull);
  });

  test('a still picture scores zero', () {
    detector.add(frame());
    expect(afterWarmup(frame()), 0);
  });

  test('sensor noise below the pixel threshold scores zero', () {
    detector.add(frame());
    final noisy = frame();
    for (var i = 0; i < noisy.length; i++) {
      noisy[i] += (i % 7) - 3; // ±3
    }
    expect(afterWarmup(noisy), 0);
  });

  test('scores the share of the picture that changed', () {
    detector.add(frame());
    // A 24×24 square appears: 576 of 3072 pixels = 18.75 %.
    expect(afterWarmup(frame(x: 10, y: 10, size: 24)), closeTo(18.75, 0.5));
  });

  test('a moving object scores where it left and where it arrived', () {
    detector.add(frame(x: 0, y: 0, size: 16));
    // Moves 30 px right: 256 px vacated + 256 px newly covered = 16.7 %.
    expect(afterWarmup(frame(x: 30, y: 0, size: 16)), closeTo(16.7, 0.5));
  });

  test('an overall brightness change is not motion', () {
    detector.add(frame(base: 80));
    expect(afterWarmup(frame(base: 140)), 0);
  });

  test('reset restarts the warm-up', () {
    detector.add(frame());
    afterWarmup(frame());
    detector.reset();
    expect(detector.add(frame(x: 0, y: 0, size: 40)), isNull);
  });

  test('lumaFromRgba weights green most', () {
    final rgba = Uint8List.fromList([255, 0, 0, 255, 0, 255, 0, 255]);
    final luma = lumaFromRgba(rgba);
    expect(luma[0], lessThan(luma[1]));
  });
}
