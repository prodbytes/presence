import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// A window of recorded video inside a recording file.
///
/// The file is either live in memory (on web, a Blob object URL) or stored,
/// in which case it's loaded the first time it's played. [start] and [end]
/// are offsets into the file that bound the part to play.
class ClipMedia {
  const ClipMedia({
    required String this._url,
    required this.start,
    required this.end,
    this.mimeType = defaultMimeType,
  }) : _stored = null;

  /// A recording kept in storage; [load] makes it playable.
  ClipMedia.stored({
    required Future<String> Function() load,
    required this.start,
    required this.end,
    this.mimeType = defaultMimeType,
  }) : _url = null,
       _stored = _StoredUrl(load);

  static const String defaultMimeType = 'video/webm';

  final String? _url;
  final _StoredUrl? _stored;
  final Duration start;
  final Duration end;
  final String mimeType;

  Duration get length => end - start;

  /// The in-memory URL of a live recording, or null for a stored one.
  String? get liveUrl => _url;

  /// A playable URL for the recording, loading it from storage if needed.
  Future<String> resolveUrl() =>
      _url != null ? Future.value(_url) : _stored!.get();
}

class _StoredUrl {
  _StoredUrl(this._load);

  final Future<String> Function() _load;
  Future<String>? _url;

  // Load once; retry next time if loading failed.
  Future<String> get() => _url ??= _load()
    ..catchError((Object _) {
      _url = null;
      return '';
    });
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
  /// Stable across launches (on web, the browser's device ID), so stored
  /// clips and events can refer to the camera.
  String get id;

  String get label;

  /// Whether this source keeps a rolling recording and can produce clips.
  bool get supportsVideo;

  Widget buildPreview(BuildContext context);

  /// The current frame as an encoded image, or null if unavailable.
  Future<Uint8List?> captureFrame();

  /// Starts a clip around the current moment.
  ClipCapture requestClip({required Duration before, required Duration after});

  /// Stops recording and releases the camera. Completes once the camera is
  /// fully closed, so another one can be opened (phones allow only one).
  Future<void> dispose();
}

/// Which way a camera faces, when the platform knows.
enum CameraFacing { back, front, unknown }

/// A camera the device has, before it's opened.
class CameraDevice {
  const CameraDevice({
    required this.id,
    required this.label,
    this.facing = CameraFacing.unknown,
  });

  /// Stable across launches (on web, the browser's device ID).
  final String id;
  final String label;
  final CameraFacing facing;
}

/// The platform's cameras: lists them, and opens one at a time.
abstract class CameraBackend {
  /// Every camera, asking for camera (and microphone) permission first.
  Future<List<CameraDevice>> listCameras();

  /// Opens [device], always recording. [preRoll] is read whenever the
  /// rolling recording needs to know how much history to keep.
  Future<CameraSource> open(CameraDevice device, Duration Function() preRoll);
}
