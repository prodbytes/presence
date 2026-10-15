import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../cameras/camera_source.dart';
import '../crypto/media_seal.dart';
import '../recognition/frames.dart';
import '../recognition/image.dart';

/// How a clip's thumbnail was found, kept in its local record as
/// `thumbnailCheck` ([ThumbnailMaker.check]).
enum ThumbnailCheck {
  /// Bright enough: kept, never checked again.
  ok,

  /// Missing or dark, and every frame of its recording too (a night
  /// scene): the brightest kept, the card shows a placeholder.
  dark,

  /// Missing or dark, and its recording isn't here (another device's, not
  /// downloaded): checked again once it is.
  noRecording;

  /// Whether the card shows a placeholder instead of the thumbnail.
  bool get placeholder => this != ok;

  static ThumbnailCheck? of(Object? value) =>
      value is String ? values.asNameMap()[value] : null;
}

/// What [ThumbnailMaker.check] found: [check], and a better thumbnail
/// ([thumbnail], sealed) when it made one.
typedef ThumbnailResult = ({ThumbnailCheck check, Uint8List? thumbnail});

/// Keeps clips' thumbnails from being black: a thumbnail is the camera's
/// frame at the trigger, which is black while the camera is starting (its
/// exposure still opening up), at night just before the torch or the
/// screen lights the scene, or when the frame couldn't be decoded. Such a
/// thumbnail is made again from a later frame of the recording.
class ThumbnailMaker {
  ThumbnailMaker({
    ClipFrameSampler? sampler,
    this._seal,
    Future<RgbaImage?> Function(Uint8List image)? decode,
  }) : _sampler = sampler ?? ClipFrameSampler(),
       _decode = decode ?? _decodeSmall;

  final ClipFrameSampler _sampler;
  final MediaSeal? _seal;
  final Future<RgbaImage?> Function(Uint8List image) _decode;

  MediaSeal get seal => _seal ?? MediaSeal.instance;

  /// Whether this platform can read frames out of recordings.
  bool get supported => _sampler.supported;

  /// Mean luma (0–255) below which a picture is black. A camera that is
  /// starting, or a frame that failed to decode, gives about 0; video's
  /// own black level is 16. A dim night picture is brighter than this (the
  /// night detector, `NightDetector.darkBelow`, starts at 40), so it stays.
  static const double darkBelow = 16;

  /// How wide a thumbnail made from a recording is at most: as wide as
  /// the camera's (`captureFrame`, 480 px).
  static const int maxWidth = 480;

  /// The mean luma (BT.601, 0–255) of [image], read on a grid of at most
  /// 64 × 64 pixels: cheap at any size.
  static double meanLuma(RgbaImage image) {
    if (image.width == 0 || image.height == 0) return 0;
    final stepX = image.width > 64 ? image.width ~/ 64 : 1;
    final stepY = image.height > 64 ? image.height ~/ 64 : 1;
    final pixels = image.pixels;
    var sum = 0;
    var count = 0;
    for (var y = 0; y < image.height; y += stepY) {
      for (var x = 0; x < image.width; x += stepX) {
        final i = (y * image.width + x) * 4;
        sum += 299 * pixels[i] + 587 * pixels[i + 1] + 114 * pixels[i + 2];
        count++;
      }
    }
    return sum / count / 1000;
  }

  static bool isDark(double luma) => luma < darkBelow;

  /// Checks [thumbnail] (sealed, or none), and when it's missing or dark
  /// makes another from [recording] (none when it isn't here): the first
  /// bright frame from its middle on (its middle, then later ones: the
  /// scene lit by then), or else the brightest, if brighter than the
  /// thumbnail. Null when it can't tell (the thumbnail's key isn't known
  /// yet, or the recording couldn't be read): checked again another time.
  Future<ThumbnailResult?> check(
    Uint8List? thumbnail,
    ClipMedia? recording,
  ) async {
    double? current;
    if (thumbnail != null) {
      try {
        final image = await _decode(await seal.openImage(thumbnail));
        if (image != null) current = meanLuma(image);
      } on SealKeyMissing {
        return null;
      } catch (_) {
        // Doesn't open: as good as none.
      }
    }
    if (current != null && !isDark(current)) {
      return (check: ThumbnailCheck.ok, thumbnail: null);
    }
    final length = recording == null
        ? Duration.zero
        : recording.end - recording.start;
    if (recording == null || !supported || length <= Duration.zero) {
      return (check: ThumbnailCheck.noRecording, thumbnail: null);
    }
    // Its middle, and two later frames (0.7 and 0.9 of the way).
    final every = length * 0.2;
    ({double luma, Uint8List jpeg})? brightest;
    try {
      await for (final frame in _sampler.sample(
        recording,
        every: every,
        from: recording.start + length ~/ 2,
        maxWidth: maxWidth,
      )) {
        final luma = meanLuma(frame.image);
        if (luma <= (brightest?.luma ?? current ?? -1)) continue;
        // Made before the next frame is asked for.
        final jpeg = await frame.jpeg();
        if (jpeg == null) continue;
        if (!isDark(luma)) {
          return (check: ThumbnailCheck.ok, thumbnail: await seal.seal(jpeg));
        }
        brightest = (luma: luma, jpeg: jpeg);
      }
    } catch (e) {
      debugPrint('Presence: could not read frames for a thumbnail: $e');
      return null;
    }
    return (
      check: ThumbnailCheck.dark,
      thumbnail: brightest == null ? null : await seal.seal(brightest.jpeg),
    );
  }

  /// [image] decoded 64 px wide: enough to tell black from not.
  static Future<RgbaImage?> _decodeSmall(Uint8List image) async {
    try {
      final codec = await ui.instantiateImageCodec(image, targetWidth: 64);
      final frame = (await codec.getNextFrame()).image;
      codec.dispose();
      final data = await frame.toByteData(format: ui.ImageByteFormat.rawRgba);
      final decoded = data == null
          ? null
          : RgbaImage(frame.width, frame.height, data.buffer.asUint8List());
      frame.dispose();
      return decoded;
    } catch (_) {
      return null;
    }
  }
}
