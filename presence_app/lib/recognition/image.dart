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

  /// How much of the smaller of the two is inside the other: 0 apart, 1
  /// when one holds the other.
  double containment(Box other) {
    final w = math.min(right, other.right) - math.max(left, other.left);
    final h = math.min(bottom, other.bottom) - math.max(top, other.top);
    if (w <= 0 || h <= 0) return 0;
    final smaller = math.min(area, other.area);
    return smaller <= 0 ? 0 : w * h / smaller;
  }

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
/// `Float32List`. Where it's shrunk, each value
/// is the mean of a grid of bilinear samples across the source
/// pixels it covers, so detail between them isn't skipped (aliasing).
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
  if (region.angle == 0) {
    _resampleSeparably(image, region, width, height, scale, floats, ints);
    return floats ?? ints!;
  }
  final cos = math.cos(region.angle);
  final sin = math.sin(region.angle);
  final px = image.pixels;
  final iw = image.width;
  final ih = image.height;
  // Source pixels per value, across and down: that many samples each way.
  final sxCount = samplesFor(region.w / width);
  final syCount = samplesFor(region.h / height);
  final perValue = 1 / (sxCount * syCount);
  final rgb = Float64List(3);
  var o = 0;
  for (var v = 0; v < height; v++) {
    for (var u = 0; u < width; u++) {
      rgb.fillRange(0, 3, 0);
      for (var j = 0; j < syCount; j++) {
        final ly = ((v + (j + 0.5) / syCount) / height - 0.5) * region.h;
        for (var i = 0; i < sxCount; i++) {
          final lx = ((u + (i + 0.5) / sxCount) / width - 0.5) * region.w;
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
            rgb[c] +=
                (i00 < 0 ? 0 : px[i00 + c] * w00) +
                (i10 < 0 ? 0 : px[i10 + c] * w10) +
                (i01 < 0 ? 0 : px[i01 + c] * w01) +
                (i11 < 0 ? 0 : px[i11 + c] * w11);
          }
        }
      }
      for (var c = 0; c < 3; c++) {
        final value = rgb[c] * perValue;
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

/// [toTensor] for an unturned [region]: the same samples and weights, but
/// a value's weight for a pixel is its weight across times its weight
/// down, so the picture is resampled across first (only the rows it
/// needs), then down. Several times faster than sampling each value.
void _resampleSeparably(
  RgbaImage image,
  Region region,
  int width,
  int height,
  PixelScale scale,
  Float32List? floats,
  Int32List? ints,
) {
  final across = _Taps(region.cx - region.w / 2, region.w, width, image.width);
  final down = _Taps(region.cy - region.h / 2, region.h, height, image.height);
  final px = image.pixels;
  final iw = image.width;
  final stride = width * 3;
  // The rows used, resampled across (each once): width × 3 values each.
  final rows = List<Float32List?>.filled(image.height, null);
  Float32List across_(int y) {
    final row = Float32List(stride);
    final base = y * iw * 4;
    final start = across.start, index = across.index, weight = across.weight;
    for (var u = 0, o = 0; u < width; u++, o += 3) {
      var r = 0.0, g = 0.0, b = 0.0;
      for (var k = start[u]; k < start[u + 1]; k++) {
        final i = base + index[k] * 4;
        final w = weight[k];
        r += px[i] * w;
        g += px[i + 1] * w;
        b += px[i + 2] * w;
      }
      row[o] = r;
      row[o + 1] = g;
      row[o + 2] = b;
    }
    return row;
  }

  // value × mul + add, in the model's scale.
  final (mul, add) = switch (scale) {
    PixelScale.bytes => (1.0, 0.0),
    PixelScale.unit => (1 / 255, 0.0),
    PixelScale.symmetric => (1 / 127.5, -1.0),
    PixelScale.centered => (1 / 128, -127.5 / 128),
  };
  final acc = Float32List(stride);
  for (var v = 0; v < height; v++) {
    acc.fillRange(0, stride, 0);
    for (var k = down.start[v]; k < down.start[v + 1]; k++) {
      final y = down.index[k];
      final row = rows[y] ??= across_(y);
      final w = down.weight[k];
      for (var i = 0; i < stride; i++) {
        acc[i] += row[i] * w;
      }
    }
    final o = v * stride;
    if (ints != null) {
      for (var i = 0; i < stride; i++) {
        ints[o + i] = acc[i].round().clamp(0, 255);
      }
    } else {
      for (var i = 0; i < stride; i++) {
        floats![o + i] = acc[i] * mul + add;
      }
    }
  }
}

/// Along one side, for each of [count] values from [length] source pixels
/// starting at [from]: the pixels it takes (inside the picture's [size];
/// those outside are black, so left out) and their weights, as
/// [toTensor]'s samples give them. Value i's are [start][i] to
/// [start][i + 1].
class _Taps {
  factory _Taps(double from, double length, int count, int size) {
    final samples = samplesFor(length / count);
    final index = <int>[];
    final weight = <double>[];
    final start = Int32List(count + 1);
    final each = 1 / samples;
    for (var i = 0; i < count; i++) {
      start[i] = index.length;
      final taps = <int, double>{};
      for (var j = 0; j < samples; j++) {
        // Pixel centers are at +0.5.
        final at = from + (i + (j + 0.5) / samples) / count * length - 0.5;
        final p0 = at.floor();
        final f = at - p0;
        if (p0 >= 0 && p0 < size) taps[p0] = (taps[p0] ?? 0) + (1 - f) * each;
        if (p0 + 1 >= 0 && p0 + 1 < size) {
          taps[p0 + 1] = (taps[p0 + 1] ?? 0) + f * each;
        }
      }
      for (final MapEntry(key: p, value: w) in taps.entries) {
        index.add(p);
        weight.add(w);
      }
    }
    start[count] = index.length;
    return _Taps._(
      Int32List.fromList(index),
      Float64List.fromList(weight),
      start,
    );
  }

  _Taps._(this.index, this.weight, this.start);

  final Int32List index;
  final Float64List weight;
  final Int32List start;
}

/// How many samples a value takes along one side when [step] source pixels
/// go to it: one when enlarging or nearly the same size, at most
/// [maxSamplesPerSide].
int samplesFor(double step) =>
    step <= 1.25 ? 1 : math.min(step.ceil(), maxSamplesPerSide);

/// The most samples per value along one side ([toTensor]): enough to shrink
/// a 1280 px frame for the detector without skipping pixels.
const int maxSamplesPerSide = 4;

/// [tensor] (a [width] × [height] × 3 `Float32List`, as [toTensor] makes)
/// mirrored left to right.
Float32List mirrored(Float32List tensor, int width, int height) {
  final out = Float32List(tensor.length);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final from = (y * width + x) * 3;
      final to = (y * width + width - 1 - x) * 3;
      out[to] = tensor[from];
      out[to + 1] = tensor[from + 1];
      out[to + 2] = tensor[from + 2];
    }
  }
  return out;
}
