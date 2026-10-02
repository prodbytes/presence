import 'dart:io';

import 'package:flutter/services.dart';

import '../cameras/camera_source.dart';
import 'frames.dart';
import 'image.dart';

const _channel = MethodChannel('presence/cameras');

/// Asks the platform for frames of the recording file (`framesAt`:
/// `MediaMetadataRetriever` on Android, opened once per batch), as JPEGs,
/// [batch] at a time.
class PlatformFrameSampler implements ClipFrameSampler {
  static const int batch = 8;

  @override
  bool get supported => Platform.isAndroid;

  @override
  Stream<SampledFrame> sample(
    ClipMedia media, {
    required Duration every,
    int maxWidth = 960,
  }) async* {
    final path = await media.resolveUrl();
    if (path.isEmpty) return;
    final times = [
      for (var at = media.start; at < media.end; at += every) at.inMilliseconds,
    ];
    for (var i = 0; i < times.length; i += batch) {
      final ms = times.sublist(i, (i + batch).clamp(0, times.length));
      final jpegs = await _channel.invokeListMethod<Uint8List?>('framesAt', {
        'path': path,
        'ms': ms,
        'maxWidth': maxWidth,
      });
      if (jpegs == null) return;
      for (var k = 0; k < jpegs.length && k < ms.length; k++) {
        final jpeg = jpegs[k];
        if (jpeg == null) continue;
        final image = await RgbaImage.decode(jpeg);
        if (image == null) continue;
        yield SampledFrame(
          Duration(milliseconds: ms[k]),
          image,
          () async => jpeg,
        );
      }
    }
  }
}
