import '../cameras/camera_source.dart';
import 'frames.dart';

/// No frame sampling on this platform yet: recognition stays off.
class PlatformFrameSampler implements ClipFrameSampler {
  @override
  bool get supported => false;

  @override
  Stream<SampledFrame> sample(
    ClipMedia media, {
    required Duration every,
    int maxWidth = 960,
  }) => const Stream.empty();
}
