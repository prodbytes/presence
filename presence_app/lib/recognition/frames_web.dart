import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../cameras/camera_source.dart';
import '../cameras/web_dom.dart';
import 'frames.dart';
import 'image.dart';

/// Seeks a hidden, muted `<video>` through the recording and draws each
/// frame onto a canvas.
class PlatformFrameSampler implements ClipFrameSampler {
  /// How long a seek may take before the frame is skipped.
  static const Duration seekTimeout = Duration(seconds: 5);

  @override
  bool get supported => true;

  @override
  Stream<SampledFrame> sample(
    ClipMedia media, {
    required Duration every,
    int maxWidth = ClipFrameSampler.defaultMaxWidth,
  }) async* {
    // Held while sampling, so it isn't freed meanwhile (the clip being
    // saved), and let go after.
    final url = await media.acquireUrl();
    if (url.isEmpty) {
      media.releaseUrl(url);
      return;
    }
    final video = web.HTMLVideoElement()
      ..muted = true
      ..preload = 'auto'
      ..src = url;
    try {
      if (!await _once(video, 'loadeddata', const Duration(seconds: 15))) {
        return;
      }
      final width = video.videoWidth;
      final height = video.videoHeight;
      if (width == 0 || height == 0) return;
      final scale = width > maxWidth ? maxWidth / width : 1.0;
      final canvas = web.HTMLCanvasElement()
        ..width = (width * scale).round()
        ..height = (height * scale).round();
      final context =
          canvas.getContext('2d', {'willReadFrequently': true}.jsify())!
              as web.CanvasRenderingContext2D;
      for (var at = media.start; at < media.end; at += every) {
        video.currentTime = at.inMicroseconds / 1e6;
        if (!await _once(video, 'seeked', seekTimeout)) continue;
        context.drawImage(video, 0, 0, canvas.width, canvas.height);
        final data = context.getImageData(0, 0, canvas.width, canvas.height);
        final pixels = Uint8List.fromList(data.data.toDart);
        yield SampledFrame(
          Duration(microseconds: (video.currentTime * 1e6).round()),
          RgbaImage(canvas.width, canvas.height, pixels),
          () => canvasJpeg(canvas),
        );
      }
    } finally {
      video
        ..removeAttribute('src')
        ..load();
      media.releaseUrl(url);
    }
  }

  /// Whether [video] fired [event] within [timeout] (false on an error).
  static Future<bool> _once(
    web.HTMLVideoElement video,
    String event,
    Duration timeout,
  ) {
    final done = Completer<bool>();
    final onEvent = ((web.Event _) {
      if (!done.isCompleted) done.complete(true);
    }).toJS;
    final onError = ((web.Event _) {
      if (!done.isCompleted) done.complete(false);
    }).toJS;
    video.addEventListener(event, onEvent);
    video.addEventListener('error', onError);
    return done.future.timeout(timeout, onTimeout: () => false).whenComplete(
      () {
        video.removeEventListener(event, onEvent);
        video.removeEventListener('error', onError);
      },
    );
  }
}
