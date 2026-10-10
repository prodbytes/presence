import 'dart:io';

import 'package:flutter/services.dart';

import '../cameras/camera_source.dart';
import 'frames.dart';
import 'image.dart';

const _channel = MethodChannel('presence/cameras');

/// Asks the platform for frames of the recording file (`keyframesAt`:
/// `MediaMetadataRetriever` on Android, opened once per batch), [batch]
/// times at a time. Each time gets the keyframe nearest to it (the
/// recorder makes one a second), the cheapest frame to decode, each
/// keyframe once, as raw RGBA; a frame's JPEG is only made (`encodeJpeg`)
/// if it's asked for.
class PlatformFrameSampler implements ClipFrameSampler {
  /// Few at a time: each frame's pixels cross the channel at once.
  static const int batch = 3;

  @override
  bool get supported => Platform.isAndroid;

  @override
  Stream<SampledFrame> sample(
    ClipMedia media, {
    required Duration every,
    int maxWidth = ClipFrameSampler.defaultMaxWidth,
  }) async* {
    // Held while sampling: an opened copy of a sealed recording is
    // deleted once let go.
    final path = await media.acquireUrl();
    try {
      if (path.isEmpty) return;
      final times = sampleTimes(media, every);
      final seen = <int>{};
      for (var i = 0; i < times.length; i += batch) {
        final ms = times.sublist(i, (i + batch).clamp(0, times.length));
        final frames = await _channel.invokeListMethod<Map<Object?, Object?>>(
          'keyframesAt',
          {'path': path, 'ms': ms, 'maxWidth': maxWidth},
        );
        if (frames == null) return;
        for (final frame in frames) {
          final at = (frame['ms']! as num).toInt();
          final width = (frame['width']! as num).toInt();
          final height = (frame['height']! as num).toInt();
          final pixels = frame['pixels']! as Uint8List;
          // Keyframes outside the clip, or already sampled, are skipped.
          if (at < media.start.inMilliseconds ||
              at > media.end.inMilliseconds) {
            continue;
          }
          if (!seen.add(at) || pixels.length != width * height * 4) continue;
          yield SampledFrame(
            Duration(milliseconds: at),
            RgbaImage(width, height, pixels),
            () => _channel.invokeMethod<Uint8List>('encodeJpeg', {
              'width': width,
              'height': height,
              'pixels': pixels,
            }),
          );
        }
      }
    } finally {
      media.releaseUrl(path);
    }
  }
}
