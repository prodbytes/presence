import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// A window of recorded video inside an in-memory file.
///
/// [url] points at the whole recording (on web, a Blob object URL);
/// [start] and [end] are offsets into it that bound the part to play.
class ClipMedia {
  const ClipMedia({required this.url, required this.start, required this.end});

  final String url;
  final Duration start;
  final Duration end;

  Duration get length => end - start;
}

/// The two recordings a clip request produces.
class ClipCapture {
  const ClipCapture({required this.past, required this.full});

  /// Video from before the request, ready almost immediately.
  final Future<ClipMedia?> past;

  /// The whole clip, before and after the request, in one continuous file.
  /// Completes once the "after" period has been recorded.
  final Future<ClipMedia?> full;

  static final ClipCapture unsupported = ClipCapture(
    past: Future.value(),
    full: Future.value(),
  );
}

/// One open camera.
abstract class CameraSource {
  String get label;

  /// Whether this source keeps a rolling recording and can produce clips.
  bool get supportsVideo;

  Widget buildPreview(BuildContext context);

  /// The current frame as an encoded image, or null if unavailable.
  Future<Uint8List?> captureFrame();

  /// Starts a clip around the current moment.
  ClipCapture requestClip({required Duration before, required Duration after});

  void dispose();
}

/// A camera that was found but couldn't be opened (for example, because
/// another app is using it). Shown as an error tile.
class UnavailableCameraSource implements CameraSource {
  UnavailableCameraSource(this.label, this.error);

  @override
  final String label;
  final Object error;

  @override
  bool get supportsVideo => false;

  @override
  Widget buildPreview(BuildContext context) => const SizedBox.shrink();

  @override
  Future<Uint8List?> captureFrame() async => null;

  @override
  ClipCapture requestClip({
    required Duration before,
    required Duration after,
  }) => ClipCapture.unsupported;

  @override
  void dispose() {}
}

/// Opens every camera on the device. [preRoll] is read whenever the rolling
/// recording needs to know how much history to keep.
typedef CameraOpener = Future<List<CameraSource>> Function(
  Duration Function() preRoll,
);
