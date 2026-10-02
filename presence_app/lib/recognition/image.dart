import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// A decoded picture: [width] × [height] pixels, 4 bytes each (RGBA).
class RgbaImage {
  RgbaImage(this.width, this.height, this.pixels)
    : assert(pixels.length == width * height * 4);

  final int width;
  final int height;
  final Uint8List pixels;

  /// Decodes a JPEG (or PNG), at most [maxWidth] wide. Null if it can't be.
  static Future<RgbaImage?> decode(Uint8List bytes, {int? maxWidth}) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      var image = (await codec.getNextFrame()).image;
      codec.dispose();
      if (maxWidth != null && image.width > maxWidth) {
        final smaller = await ui.instantiateImageCodec(
          bytes,
          targetWidth: maxWidth,
        );
        image.dispose();
        image = (await smaller.getNextFrame()).image;
        smaller.dispose();
      }
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final decoded = data == null
          ? null
          : RgbaImage(image.width, image.height, data.buffer.asUint8List());
      image.dispose();
      return decoded;
    } catch (_) {
      return null;
    }
  }
}

/// A rectangle on a picture, in fractions of its width and height (0 to 1).
class Box {
  const Box(this.left, this.top, this.right, this.bottom);

  /// Centered on ([cx], [cy]), [w] wide and [h] high.
  const Box.centered(double cx, double cy, double w, double h)
    : left = cx - w / 2,
      top = cy - h / 2,
      right = cx + w / 2,
      bottom = cy + h / 2;

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;
  double get cx => (left + right) / 2;
  double get cy => (top + bottom) / 2;
  double get area => math.max(0, width) * math.max(0, height);

  bool contains(double x, double y) =>
      x >= left && x <= right && y >= top && y <= bottom;

  Box clamped() => Box(
    left.clamp(0, 1),
    top.clamp(0, 1),
    right.clamp(0, 1),
    bottom.clamp(0, 1),
  );

  /// Intersection over union: 0 apart, 1 the same.
  double iou(Box other) {
    final w = math.min(right, other.right) - math.max(left, other.left);
    final h = math.min(bottom, other.bottom) - math.max(top, other.top);
    if (w <= 0 || h <= 0) return 0;
    final inter = w * h;
    return inter / (area + other.area - inter);
  }

  @override
  String toString() =>
      'Box(${left.toStringAsFixed(3)}, ${top.toStringAsFixed(3)}, '
      '${right.toStringAsFixed(3)}, ${bottom.toStringAsFixed(3)})';
}

/// How pixel values are scaled for a model's input.
enum PixelScale {
  /// 0 to 255, as integers (quantized models).
  bytes,

  /// 0 to 1.
  unit,

  /// −1 to 1.
  symmetric,

  /// (v − 127.5) / 128, as face embedders expect.
  centered,
}

/// The part of a picture a model looks at: centered on ([cx], [cy]), [w] ×
/// [h] in pixels, turned by [angle] radians (to level a face's eyes).
/// Outside the picture it's black.
class Region {
  const Region(this.cx, this.cy, this.w, this.h, [this.angle = 0]);

  /// All of [image], stretched to the model's shape.
  Region.whole(RgbaImage image)
    : this(
        image.width / 2,
        image.height / 2,
        image.width.toDouble(),
        image.height.toDouble(),
      );

  /// [box] of [image], grown by [scale]; as a square if [square].
  factory Region.box(
    RgbaImage image,
    Box box, {
    double scale = 1,
    bool square = false,
    double angle = 0,
  }) {
    var w = box.width * image.width * scale;
    var h = box.height * image.height * scale;
    if (square) w = h = math.max(w, h);
    return Region(box.cx * image.width, box.cy * image.height, w, h, angle);
  }

  final double cx;
  final double cy;
  final double w;
  final double h;
  final double angle;

  /// Where a point at ([fx], [fy]) of this region (fractions, unrotated
  /// regions only) is on an [image], in fractions of the image.
  (double, double) toImage(RgbaImage image, double fx, double fy) => (
    (cx + (fx - 0.5) * w) / image.width,
    (cy + (fy - 0.5) * h) / image.height,
  );

  /// A box in this region's fractions, as fractions of [image].
  Box boxToImage(RgbaImage image, Box box) {
    final (l, t) = toImage(image, box.left, box.top);
    final (r, b) = toImage(image, box.right, box.bottom);
    return Box(l, t, r, b);
  }
}

/// [region] of [image] resampled (bilinear) to a [width] × [height] × 3
/// tensor in [scale]: an `Int32List` for [PixelScale.bytes], otherwise a
/// `Float32List`.
TypedData toTensor(
  RgbaImage image,
  Region region, {
  required int width,
  required int height,
  required PixelScale scale,
}) {
  final n = width * height * 3;
  final floats = scale == PixelScale.bytes ? null : Float32List(n);
  final ints = scale == PixelScale.bytes ? Int32List(n) : null;
  final cos = math.cos(region.angle);
  final sin = math.sin(region.angle);
  final px = image.pixels;
  final iw = image.width;
  final ih = image.height;
  var o = 0;
  for (var v = 0; v < height; v++) {
    final ly = ((v + 0.5) / height - 0.5) * region.h;
    for (var u = 0; u < width; u++) {
      final lx = ((u + 0.5) / width - 0.5) * region.w;
      // Pixel centers are at +0.5.
      final sx = region.cx + lx * cos - ly * sin - 0.5;
      final sy = region.cy + lx * sin + ly * cos - 0.5;
      final x0 = sx.floor();
      final y0 = sy.floor();
      final fx = sx - x0;
      final fy = sy - y0;
      // The four neighbours, -1 when outside (black).
      int index(int x, int y) =>
          (x < 0 || y < 0 || x >= iw || y >= ih) ? -1 : (y * iw + x) * 4;
      final i00 = index(x0, y0), i10 = index(x0 + 1, y0);
      final i01 = index(x0, y0 + 1), i11 = index(x0 + 1, y0 + 1);
      final w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy);
      final w01 = (1 - fx) * fy, w11 = fx * fy;
      for (var c = 0; c < 3; c++) {
        final value =
            (i00 < 0 ? 0 : px[i00 + c] * w00) +
            (i10 < 0 ? 0 : px[i10 + c] * w10) +
            (i01 < 0 ? 0 : px[i01 + c] * w01) +
            (i11 < 0 ? 0 : px[i11 + c] * w11);
        switch (scale) {
          case PixelScale.bytes:
            ints![o] = value.round().clamp(0, 255);
          case PixelScale.unit:
            floats![o] = value / 255;
          case PixelScale.symmetric:
            floats![o] = value / 127.5 - 1;
          case PixelScale.centered:
            floats![o] = (value - 127.5) / 128;
        }
        o++;
      }
    }
  }
  return floats ?? ints!;
}
