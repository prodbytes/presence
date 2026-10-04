import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'camera_source.dart';

/// Where a player opens [media]: at [at] (a point of the recording, as tags'
/// `frameMs` are), kept inside the clip's window, or at its start.
Duration startPosition(ClipMedia media, Duration? at) {
  if (at == null || at < media.start) return media.start;
  return at > media.end ? media.end : at;
}

/// A frame grabbed from a playing clip: a JPEG (at most
/// [ClipPlayerController.maxFrameWidth] wide) and where it is in the
/// recording.
@immutable
class CapturedFrame {
  const CapturedFrame({required this.jpeg, required this.position});

  final Uint8List jpeg;
  final Duration position;
}

/// Lets a screen ask the clip player for the frame it's showing. The
/// platform's `ClipPlayerView` answers while it's mounted.
class ClipPlayerController {
  /// Frames for tagging don't need the full resolution.
  static const int maxFrameWidth = 960;

  Future<CapturedFrame?> Function()? _capture;

  /// Called when someone clicks (on the web) or long-presses (on phones)
  /// the video picture, with where, as fractions (0 to 1) of the video
  /// frame itself (letterboxing excluded).
  void Function(Offset fraction)? onPictureTap;

  /// Used by `ClipPlayerView` to report a click on the picture.
  void pictureTapped(Offset fraction) => onPictureTap?.call(
    Offset(fraction.dx.clamp(0, 1), fraction.dy.clamp(0, 1)),
  );

  /// Where [local] (in a [box] the video is contained in, letterboxed) falls
  /// on a [video]-sized frame, as fractions; null outside the picture.
  static Offset? pictureFraction(Offset local, Size box, Size video) {
    if (video.isEmpty || box.isEmpty) return null;
    final scale = (box.width / video.width) < (box.height / video.height)
        ? box.width / video.width
        : box.height / video.height;
    final shown = video * scale;
    final left = (box.width - shown.width) / 2;
    final top = (box.height - shown.height) / 2;
    final fx = (local.dx - left) / shown.width;
    final fy = (local.dy - top) / shown.height;
    if (fx < 0 || fx > 1 || fy < 0 || fy > 1) return null;
    return Offset(fx, fy);
  }

  /// Pauses the clip and returns the frame it shows; null if the player
  /// isn't ready (nothing loaded yet) or the frame can't be read.
  Future<CapturedFrame?> captureFrame() async =>
      (debugCaptureOverride ?? _capture)?.call();

  /// Stands in for every player's frame grab (tests have no video decoder).
  @visibleForTesting
  static Future<CapturedFrame?> Function()? debugCaptureOverride;

  /// Used by `ClipPlayerView` to serve [captureFrame].
  void attach(Future<CapturedFrame?> Function() capture) => _capture = capture;

  void detach(Future<CapturedFrame?> Function() capture) {
    if (identical(_capture, capture)) _capture = null;
  }
}
