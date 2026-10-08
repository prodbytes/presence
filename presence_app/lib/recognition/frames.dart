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
  /// video decoder on Android (`keyframesAt` on `presence/cameras`).
  factory ClipFrameSampler() = platform.PlatformFrameSampler;

  /// How wide frames are at most, unless asked otherwise: a 720p
  /// recording whole. The detector shrinks it (or tiles of it), but faces
  /// and looks are cropped from it at full size: far faces need every
  /// pixel (under 9 px between the eyes, they can't be compared).
  static const int defaultMaxWidth = 1280;

  bool get supported;

  /// A frame of [media] [every] so long, from its start to its end, at most
  /// [maxWidth] wide. Frames that can't be read are skipped. On Android
  /// each is the keyframe nearest to its time (and at its own time).
  Stream<SampledFrame> sample(
    ClipMedia media, {
    required Duration every,
    int maxWidth = defaultMaxWidth,
  });
}

/// The times (ms) to sample [media] at: from its start, [every] so long,
/// before its end.
List<int> sampleTimes(ClipMedia media, Duration every) => [
  for (var at = media.start; at < media.end; at += every) at.inMilliseconds,
];
