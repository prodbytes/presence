import 'dart:typed_data';

import '../cameras/camera_source.dart';
import 'frames_native.dart'
    if (dart.library.js_interop) 'frames_web.dart'
    as platform;
import 'image.dart';

/// One frame of a recording.
class SampledFrame {
  const SampledFrame(this.position, this.image, this.jpeg);

  /// Where it is in the recording (as tags' `frameMs` are).
  final Duration position;
  final RgbaImage image;

  /// The frame as a JPEG, to keep with a tag. Call it before asking for the
  /// next frame.
  final Future<Uint8List?> Function() jpeg;
}

/// Reads frames out of clips, for recognition.
abstract class ClipFrameSampler {
  /// This platform's sampler: a hidden `<video>` on web, the platform's
  /// video decoder on Android (`framesAt` on `presence/cameras`).
  factory ClipFrameSampler() = platform.PlatformFrameSampler;

  bool get supported;

  /// A frame of [media] [every] so long, from its start to its end, at most
  /// [maxWidth] wide. Frames that can't be read are skipped.
  Stream<SampledFrame> sample(
    ClipMedia media, {
    required Duration every,
    int maxWidth = 960,
  });
}
