import 'dart:typed_data';

/// Size of the grayscale frames cameras supply for motion detection.
const int motionFrameWidth = 64;
const int motionFrameHeight = 48;

/// Measures how much of the picture changed between consecutive frames.
///
/// Frames are small grayscale (luma) images, [motionFrameWidth] ×
/// [motionFrameHeight], sampled a few times a second. The score is the
/// percentage of pixels whose brightness changed by more than
/// [pixelThreshold], after removing any overall brightness shift, so
/// auto-exposure adjusting or a light switching on isn't counted as motion.
///
/// The overall shift is the *median* per-pixel change: an object covering
/// less than half the picture leaves it at 0 (a mean would move with the
/// object and make the whole background look changed), while a global
/// brightness change moves every pixel, and so the median, by the same
/// amount.
class MotionDetector {
  MotionDetector({
    this.pixelThreshold = 24,
    this.warmup = const Duration(seconds: 3),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// How much a pixel's brightness (0–255) must change to count as moving.
  final int pixelThreshold;

  /// Frames are ignored for this long after [reset] (a camera just opened:
  /// exposure and focus are still settling).
  final Duration warmup;

  final DateTime Function() _now;

  Uint8List? _previous;
  DateTime? _start;

  /// Starts over, e.g. when a different camera opens.
  void reset() {
    _previous = null;
    _start = null;
  }

  /// Adds the next frame. Returns the motion score (0–100 % of pixels
  /// changed), or null while warming up or for the first frame.
  double? add(Uint8List luma) {
    final now = _now();
    _start ??= now;
    final previous = _previous;
    _previous = Uint8List.fromList(luma);

    if (previous == null || previous.length != luma.length) return null;
    if (now.difference(_start!) < warmup) return null;

    final shift = _medianDelta(luma, previous);
    var changed = 0;
    for (var i = 0; i < luma.length; i++) {
      if ((luma[i] - previous[i] - shift).abs() > pixelThreshold) changed++;
    }
    return changed * 100 / luma.length;
  }

  /// Median of the per-pixel changes, via a histogram (linear time).
  static int _medianDelta(Uint8List a, Uint8List b) {
    final histogram = Int32List(511);
    for (var i = 0; i < a.length; i++) {
      histogram[a[i] - b[i] + 255]++;
    }
    var seen = 0;
    final half = a.length ~/ 2;
    for (var d = 0; d < histogram.length; d++) {
      seen += histogram[d];
      if (seen > half) return d - 255;
    }
    return 0;
  }
}

/// Turns luma samples from an RGBA image (as from a canvas) into a luma
/// frame, using Rec. 601 weights.
Uint8List lumaFromRgba(Uint8List rgba) {
  final out = Uint8List(rgba.length ~/ 4);
  for (var i = 0, j = 0; j < out.length; i += 4, j++) {
    out[j] = (rgba[i] * 77 + rgba[i + 1] * 150 + rgba[i + 2] * 29) >> 8;
  }
  return out;
}
