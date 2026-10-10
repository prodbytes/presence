import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'image.dart';
import 'runtime.dart';

/// What a detection is. Cats and dogs are both [SeenKind.isPet].
enum SeenKind {
  person,
  cat,
  dog;

  bool get isPet => this != person;

  /// Whether a [other] may be the same subject: people with people, pets
  /// with pets (the detector can mistake a cat for a dog).
  bool sameAs(SeenKind other) => isPet == other.isPet;
}

/// A person or pet found on a picture.
class Detection {
  const Detection(this.box, this.score, this.kind);

  final Box box;
  final double score;
  final SeenKind kind;
}

/// A face found on a picture, with its eyes, and its nose and mouth when
/// known (fractions of the picture). The right eye is the person's, on the
/// left of the picture.
class Face {
  const Face(
    this.box,
    this.score,
    this.rightEye,
    this.leftEye, {
    this.nose,
    this.mouth,
  });

  final Box box;
  final double score;
  final (double, double) rightEye;
  final (double, double) leftEye;
  final (double, double)? nose;
  final (double, double)? mouth;
}

/// One person or pet on a frame, with what recognition compares: their
/// face (people, when one shows) and their look (everyone).
class Seen {
  const Seen(this.detection, {this.face, this.faceVector, this.lookVector});

  final Detection detection;
  final Face? face;

  /// Unit-length embeddings ([VisionModels.faceVector],
  /// [VisionModels.lookVector]).
  final Float32List? faceVector;
  final Float32List? lookVector;

  /// Where to tag them: their face's center if one shows, otherwise the
  /// middle of the detection.
  (double, double) get spot {
    final face = this.face;
    if (face != null) return (face.box.cx, face.box.cy);
    return (detection.box.cx, detection.box.cy);
  }
}

/// What one frame shows: the people and pets on it, as [seen] by the
/// subjects' segment (with embeddings), and the [objects] on it, by label,
/// with their best score, for the object tags' segment.
@immutable
class FrameAnalysis {
  const FrameAnalysis({this.seen = const [], this.objects = const {}});

  final List<Seen> seen;
  final Map<String, double> objects;
}

/// What recognition needs from the models: everyone on a picture, with
/// their embeddings (unless not [subjects]), and the objects on it.
/// [VisionModels] runs them on the calling isolate; on Android a worker
/// isolate does (`vision_worker.dart`).
abstract class Vision {
  /// Everyone on [image] and the objects on it ([faces]: whether to look
  /// for faces at all; [subjects]: whether to embed anyone, or only list
  /// the objects). Only detections of [kinds] (all if null) are kept, at
  /// most [maxSeen] of them (all if null), best first: the others aren't
  /// embedded.
  Future<FrameAnalysis> analyse(
    RgbaImage image, {
    bool faces = true,
    bool subjects = true,
    Set<SeenKind>? kinds,
    int? maxSeen,
  });

  /// Frees the models' memory, if it can; they're loaded again when next
  /// needed.
  void release() {}
}

/// The five models recognition runs, all TensorFlow Lite, bundled under
/// `assets/models/` (see its README for sources, licenses and how they were
/// chosen):
///
/// - EfficientDet-Lite2 (COCO): people, cats and dogs on a frame, and every
///   other object it knows (object tags);
/// - BlazeFace (short range): a face on a person;
/// - MobileFaceNet: a face's embedding;
/// - OSNet: a person's look (trained to tell people apart);
/// - MobileNetV3 small (image embedder): a pet's look.
class VisionModels extends Vision {
  VisionModels._(
    this._detector,
    this._faces,
    this._faceNet,
    this._personNet,
    this._petNet,
  );

  static const String detectorAsset = 'assets/models/efficientdet_lite2.tflite';
  static const String faceAsset = 'assets/models/blaze_face_short_range.tflite';
  static const String faceNetAsset = 'assets/models/mobilefacenet.tflite';
  static const String personNetAsset = 'assets/models/osnet.tflite';
  static const String petNetAsset = 'assets/models/mobilenet_v3_small.tflite';

  static const int detectorSize = 448;
  static const int faceSize = 128;
  static const int faceNetSize = 112;
  static const int personNetWidth = 128;
  static const int personNetHeight = 256;
  static const int petNetSize = 224;

  /// The least detection score that counts (people, cats and dogs): on
  /// COCO, 0.5 keeps 88 % of the boxes right, 0.4 only 83 %.
  static const double minDetection = 0.5;

  /// The least score for an object to count on a frame: higher, as a wrong
  /// label can't be caught by matching. On COCO, 0.6 gives about 96 % of
  /// labels right (0.5: 92 %), finding fewer (recall 0.47 against 0.57).
  static const double minObject = 0.6;
  static const double minFace = 0.5;

  /// How far apart a face's eyes must be (frame pixels) for it to be
  /// compared: closer, its embedding can't tell people apart, and the look
  /// is compared instead.
  static const double minEyeDistance = 9;

  /// A detection overlapping a better one of its kind this much (as
  /// intersection over union), or this much inside it, is the same one: a
  /// tile cuts people at its edge.
  static const double maxOverlap = 0.5;
  static const double maxContained = 0.8;

  /// Every model's asset.
  static const List<String> assets = [
    detectorAsset,
    faceAsset,
    faceNetAsset,
    personNetAsset,
    petNetAsset,
  ];

  static Future<VisionModels> load(
    TfliteRuntime runtime, {
    AssetBundle? bundle,
  }) {
    final assets = bundle ?? rootBundle;
    return open((asset) async {
      final data = await assets.load(asset);
      return runtime.load(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    });
  }

  /// The models, each of [assets] loaded by [model].
  static Future<VisionModels> open(
    Future<TfliteModel> Function(String asset) model,
  ) async {
    final models = VisionModels._(
      await model(detectorAsset),
      await model(faceAsset),
      await model(faceNetAsset),
      await model(personNetAsset),
      await model(petNetAsset),
    );
    // Build the anchors now, not on the first frame.
    efficientDetAnchors.length;
    blazeFaceAnchors.length;
    return models;
  }

  final TfliteModel _detector;
  final TfliteModel _faces;
  final TfliteModel _faceNet;
  final TfliteModel _personNet;
  final TfliteModel _petNet;

  /// The people, cats and dogs on [image], and every object's best score:
  /// the detector runs on each of [detectorRegions] (the whole frame, and
  /// tiles along it), and what they find is put together.
  Future<(List<Detection>, Map<String, double>)> detect(RgbaImage image) async {
    final detections = <Detection>[];
    final objects = <String, double>{};
    for (final region in detectorRegions(image)) {
      final outputs = await _detector.run(
        toTensor(
          image,
          region,
          width: detectorSize,
          height: detectorSize,
          scale: PixelScale.bytes,
        ),
      );
      final n = efficientDetAnchors.length ~/ 4;
      final scores = outputs.firstWhere((o) => o.length == n * cocoClasses);
      final boxes = outputs.firstWhere((o) => o.length == n * 4);
      for (final d in decodeDetections(
        scores,
        boxes,
        threshold: minDetection,
      )) {
        final box = region.boxToImage(image, d.box).clamped();
        if (box.area > 0) detections.add(Detection(box, d.score, d.kind));
      }
      for (final MapEntry(key: label, value: score) in decodeObjects(
        scores,
        threshold: minObject,
      ).entries) {
        if (score > (objects[label] ?? 0)) objects[label] = score;
      }
      // On web the models share the page's thread: let it draw.
      await Future<void>.delayed(Duration.zero);
    }
    return (mergeDetections(detections), objects);
  }

  /// The face on the person at [box] of [image], if one shows: first in a
  /// square around their head ([headRegion]), where it's big enough for
  /// BlazeFace even far away; else in a square around all of them, kept
  /// only if it's in their top [maxFaceDepth].
  Future<Face?> face(RgbaImage image, Box box) async {
    final head = await _faceIn(image, headRegion(image, box));
    if (head != null) return head;
    final whole = await _faceIn(image, Region.box(image, box, square: true));
    if (whole == null || whole.box.cy > box.top + box.height * maxFaceDepth) {
      return null;
    }
    return whole;
  }

  /// How far down a person their face may be, as a fraction of their box.
  static const double maxFaceDepth = 0.35;

  /// The square BlazeFace looks for a face in first: as wide as the person
  /// (at least 7/16 of their height, as for someone seen sideways, at most
  /// their box's longer side), centered on them, from a little above their
  /// top. Measured on COCO's people with a visible face (see the models'
  /// README), it finds more faces than a square around all of them, and far
  /// fewer in the wrong place.
  static Region headRegion(RgbaImage image, Box box) {
    final w = box.width * image.width;
    final h = box.height * image.height;
    final side = math.min(math.max(w, h * 7 / 16), math.max(w, h));
    return Region(
      box.cx * image.width,
      box.top * image.height - 0.05 * side + side / 2,
      side,
      side,
    );
  }

  Future<Face?> _faceIn(RgbaImage image, Region region) async {
    final outputs = await _faces.run(
      toTensor(
        image,
        region,
        width: faceSize,
        height: faceSize,
        scale: PixelScale.symmetric,
      ),
    );
    final regressors = outputs.firstWhere(
      (o) => o.length == blazeFaceAnchors.length * 8,
    );
    final scores = outputs.firstWhere(
      (o) => o.length == blazeFaceAnchors.length ~/ 2,
    );
    final faces = decodeFaces(regressors, scores, threshold: minFace);
    if (faces.isEmpty) return null;
    final f = faces.first;
    (double, double) point((double, double) p) =>
        region.toImage(image, p.$1, p.$2);
    return Face(
      region.boxToImage(image, f.box),
      f.score,
      point(f.rightEye),
      point(f.leftEye),
      nose: f.nose == null ? null : point(f.nose!),
      mouth: f.mouth == null ? null : point(f.mouth!),
    );
  }

  /// [face]'s embedding: the face aligned to the template the embedder was
  /// trained on ([faceRegion]), and the mean with its mirror image.
  Future<Float32List> faceVector(RgbaImage image, Face face) async {
    final tensor = toTensor(
      image,
      faceRegion(image, face),
      width: faceNetSize,
      height: faceNetSize,
      scale: PixelScale.centered,
    ) as Float32List;
    final straight = (await _faceNet.run(tensor)).single;
    // Read before the next run: the output may be the model's own memory.
    final sum = Float32List.fromList(straight);
    final flipped = (await _faceNet.run(
      mirrored(tensor, faceNetSize, faceNetSize),
    )).single;
    for (var i = 0; i < sum.length; i++) {
      sum[i] += flipped[i];
    }
    return normalized(sum);
  }

  /// Where [face]'s eyes, nose and mouth sit on MobileFaceNet's 112 px
  /// input (ArcFace's template; the mouth halfway between its corners).
  static const List<(double, double)> faceTemplate = [
    (38.2946, 51.6963),
    (73.5318, 51.5014),
    (56.0252, 71.7366),
    (56.1396, 92.2848),
  ];

  /// The region of [image] that puts [face]'s eyes, nose and mouth where
  /// [faceTemplate] has them: the best fit by turning, scaling and moving
  /// (no stretching). Cropped from BlazeFace's box instead, faces of the same
  /// person were barely closer than different people's (LFW: 76 % right,
  /// against 98.7 % aligned).
  static Region faceRegion(RgbaImage image, Face face) {
    (double, double) px((double, double) p) =>
        (p.$1 * image.width, p.$2 * image.height);
    final from = [
      px(face.rightEye),
      px(face.leftEye),
      if (face.nose case final nose? when face.mouth != null) ...[
        px(nose),
        px(face.mouth!),
      ],
    ];
    final to = faceTemplate.sublist(0, from.length);
    // The similarity w = a·z + b (as complex numbers) that fits the points
    // best (least squares).
    var zx = 0.0, zy = 0.0, wx = 0.0, wy = 0.0;
    for (var i = 0; i < from.length; i++) {
      zx += from[i].$1;
      zy += from[i].$2;
      wx += to[i].$1;
      wy += to[i].$2;
    }
    zx /= from.length;
    zy /= from.length;
    wx /= from.length;
    wy /= from.length;
    var re = 0.0, im = 0.0, norm = 0.0;
    for (var i = 0; i < from.length; i++) {
      final dzx = from[i].$1 - zx, dzy = from[i].$2 - zy;
      final dwx = to[i].$1 - wx, dwy = to[i].$2 - wy;
      // (dw) · conj(dz)
      re += dwx * dzx + dwy * dzy;
      im += dwy * dzx - dwx * dzy;
      norm += dzx * dzx + dzy * dzy;
    }
    if (norm == 0) {
      return Region.box(image, face.box, scale: 1.1, square: true);
    }
    final scale = math.sqrt(re * re + im * im) / norm;
    final angle = math.atan2(im, re);
    // The template's center, back on the image: z = (w − b) / a, with
    // b = w̄ − a·z̄, so z = z̄ + (w − w̄) / a.
    const center = VisionModels.faceNetSize / 2;
    final dx = center - wx, dy = center - wy;
    final cos = math.cos(-angle), sin = math.sin(-angle);
    return Region(
      zx + (dx * cos - dy * sin) / scale,
      zy + (dx * sin + dy * cos) / scale,
      faceNetSize / scale,
      faceNetSize / scale,
      -angle,
    );
  }

  /// The embedding of how whoever is in [box] looks: OSNet for a person
  /// (their box, as it was trained), MobileNetV3 for a pet (a square
  /// around it, not stretched).
  Future<Float32List> lookVector(
    RgbaImage image,
    Box box,
    SeenKind kind,
  ) async {
    final outputs = kind == SeenKind.person
        ? await _personNet.run(
            toTensor(
              image,
              Region.box(image, box),
              width: personNetWidth,
              height: personNetHeight,
              scale: PixelScale.unit,
            ),
          )
        : await _petNet.run(
            toTensor(
              image,
              Region.box(image, box, square: true),
              width: petNetSize,
              height: petNetSize,
              scale: PixelScale.unit,
            ),
          );
    return normalized(outputs.single);
  }

  @override
  Future<FrameAnalysis> analyse(
    RgbaImage image, {
    bool faces = true,
    bool subjects = true,
    Set<SeenKind>? kinds,
    int? maxSeen,
  }) async {
    final (detections, objects) = await detect(image);
    if (!subjects) return FrameAnalysis(objects: objects);
    final seen = <Seen>[];
    for (final d in keepDetections(detections, kinds: kinds, max: maxSeen)) {
      final found = faces && d.kind == SeenKind.person
          ? await face(image, d.box)
          : null;
      final comparable =
          found != null && eyeDistance(image, found) >= minEyeDistance;
      seen.add(
        Seen(
          d,
          face: found,
          faceVector: comparable ? await faceVector(image, found) : null,
          lookVector: await lookVector(image, d.box, d.kind),
        ),
      );
    }
    return FrameAnalysis(seen: seen, objects: objects);
  }

  /// How far apart [face]'s eyes are on [image], in pixels.
  static double eyeDistance(RgbaImage image, Face face) {
    final dx = (face.leftEye.$1 - face.rightEye.$1) * image.width;
    final dy = (face.leftEye.$2 - face.rightEye.$2) * image.height;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Models loaded here stay until [dispose]d.
  @override
  void release() {}

  void dispose() {
    _detector.dispose();
    _faces.dispose();
    _faceNet.dispose();
    _personNet.dispose();
    _petNet.dispose();
  }
}

/// Where the detector looks on [image]: the whole of it (a square around
/// it, black outside, so it isn't stretched), and for a frame wider (or
/// taller) than [tileAbove] times the other side, squares as tall (or wide)
/// as it, overlapping, from one end to the other: people far away are
/// twice as big there as on the whole frame. Measured on COCO, the tiles
/// find twice as many small people.
List<Region> detectorRegions(RgbaImage image) {
  final w = image.width.toDouble();
  final h = image.height.toDouble();
  final side = math.max(w, h);
  final regions = [Region(w / 2, h / 2, side, side)];
  final short = math.min(w, h);
  if (side > short * tileAbove) {
    final count = math.max(2, (side / short).ceil());
    for (var i = 0; i < count; i++) {
      final along = short / 2 + i * (side - short) / (count - 1);
      regions.add(
        w >= h
            ? Region(along, h / 2, short, short)
            : Region(w / 2, along, short, short),
      );
    }
  }
  return regions;
}

/// How much longer than wide a frame must be to be tiled ([detectorRegions]).
const double tileAbove = 1.15;

/// [detections] from several regions as one list, best first: one that
/// overlaps a better one of its kind ([VisionModels.maxOverlap]), or lies
/// mostly inside it ([VisionModels.maxContained]: the part of someone a
/// tile's edge cut), is the same one and dropped.
List<Detection> mergeDetections(List<Detection> detections) {
  final sorted = [...detections]..sort((a, b) => b.score.compareTo(a.score));
  final kept = <Detection>[];
  for (final d in sorted) {
    if (kept.every(
      (k) =>
          k.kind != d.kind ||
          (k.box.iou(d.box) <= VisionModels.maxOverlap &&
              k.box.containment(d.box) <= VisionModels.maxContained),
    )) {
      kept.add(d);
    }
  }
  return kept;
}

/// Of [detections] (best first), those of [kinds] (all if null), at most
/// [max] (all if null).
List<Detection> keepDetections(
  List<Detection> detections, {
  Set<SeenKind>? kinds,
  int? max,
}) {
  final kept = kinds == null
      ? detections
      : [
          for (final d in detections)
            if (kinds.contains(d.kind)) d,
        ];
  return max == null || kept.length <= max ? kept : kept.sublist(0, max);
}

/// [v] scaled to unit length (cosine similarity is then a dot product).
Float32List normalized(Float32List v) {
  var sum = 0.0;
  for (final x in v) {
    sum += x * x;
  }
  final norm = math.sqrt(sum);
  return Float32List.fromList([for (final x in v) norm == 0 ? 0 : x / norm]);
}

/// The dot product of two unit vectors: their cosine similarity.
double cosine(Float32List a, Float32List b) {
  var dot = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
  }
  return dot;
}

/// EfficientDet-Lite0's COCO class count, and the classes kept as
/// subjects.
const int cocoClasses = 90;
const Map<int, SeenKind> keptClasses = {
  0: SeenKind.person,
  16: SeenKind.cat,
  17: SeenKind.dog,
};

/// Object tags' labels, by COCO class (the 80 the model was trained on; the
/// other 10 are unused). People are `human`.
const Map<int, String> cocoLabels = {
  0: 'human',
  1: 'bicycle',
  2: 'car',
  3: 'motorcycle',
  4: 'airplane',
  5: 'bus',
  6: 'train',
  7: 'truck',
  8: 'boat',
  9: 'traffic light',
  10: 'fire hydrant',
  12: 'stop sign',
  13: 'parking meter',
  14: 'bench',
  15: 'bird',
  16: 'cat',
  17: 'dog',
  18: 'horse',
  19: 'sheep',
  20: 'cow',
  21: 'elephant',
  22: 'bear',
  23: 'zebra',
  24: 'giraffe',
  26: 'backpack',
  27: 'umbrella',
  30: 'handbag',
  31: 'tie',
  32: 'suitcase',
  33: 'frisbee',
  34: 'skis',
  35: 'snowboard',
  36: 'sports ball',
  37: 'kite',
  38: 'baseball bat',
  39: 'baseball glove',
  40: 'skateboard',
  41: 'surfboard',
  42: 'tennis racket',
  43: 'bottle',
  45: 'wine glass',
  46: 'cup',
  47: 'fork',
  48: 'knife',
  49: 'spoon',
  50: 'bowl',
  51: 'banana',
  52: 'apple',
  53: 'sandwich',
  54: 'orange',
  55: 'broccoli',
  56: 'carrot',
  57: 'hot dog',
  58: 'pizza',
  59: 'donut',
  60: 'cake',
  61: 'chair',
  62: 'couch',
  63: 'potted plant',
  64: 'bed',
  66: 'dining table',
  69: 'toilet',
  71: 'tv',
  72: 'laptop',
  73: 'mouse',
  74: 'remote',
  75: 'keyboard',
  76: 'cell phone',
  77: 'microwave',
  78: 'oven',
  79: 'toaster',
  80: 'sink',
  81: 'refrigerator',
  83: 'book',
  84: 'clock',
  85: 'vase',
  86: 'scissors',
  87: 'teddy bear',
  88: 'hair drier',
  89: 'toothbrush',
};

/// EfficientDet-Lite2's anchors at 448 px, as (cy, cx, h, w) fractions,
/// flattened: levels 3 to 7, then rows, columns, 3 scales and 3 aspect
/// ratios (37629 in all), as the model was trained. A level's grid is
/// the input divided by 2^level, rounded up (56 … 4 cells a side), its
/// anchors centered on its cells and 3 cells (times 2^(scale/3)) across:
/// the same as the anchors the model file lists in its metadata.
final Float32List efficientDetAnchors = efficientDetAnchorsFor(
  VisionModels.detectorSize,
);

/// EfficientDet's anchors for a [size] px input (see [efficientDetAnchors]).
Float32List efficientDetAnchorsFor(int size) {
  final anchors = <double>[];
  for (var level = 3; level <= 7; level++) {
    final cells = (size / (1 << level)).ceil();
    for (var y = 0; y < cells; y++) {
      for (var x = 0; x < cells; x++) {
        for (var octave = 0; octave < 3; octave++) {
          for (final ratio in const [1.0, 2.0, 0.5]) {
            final base = anchorScale * math.pow(2, octave / 3) / cells;
            anchors.addAll([
              (y + 0.5) / cells,
              (x + 0.5) / cells,
              base / math.sqrt(ratio),
              base * math.sqrt(ratio),
            ]);
          }
        }
      }
    }
  }
  return Float32List.fromList(anchors);
}

/// How many cells an EfficientDet-Lite anchor spans (at its first scale).
const double anchorScale = 3;

/// People, cats and dogs from EfficientDet's raw outputs: per anchor,
/// [scores] for every COCO class (already 0 to 1) and [boxes] as (ty, tx,
/// th, tw) offsets from the anchor. Overlaps of a kind are merged
/// (non-maximum suppression), best first.
List<Detection> decodeDetections(
  Float32List scores,
  Float32List boxes, {
  double threshold = VisionModels.minDetection,
}) {
  final anchors = efficientDetAnchors;
  final n = anchors.length ~/ 4;
  final found = <Detection>[];
  for (var i = 0; i < n; i++) {
    for (final MapEntry(key: cls, value: kind) in keptClasses.entries) {
      final score = scores[i * cocoClasses + cls];
      if (score < threshold) continue;
      final ay = anchors[i * 4], ax = anchors[i * 4 + 1];
      final ah = anchors[i * 4 + 2], aw = anchors[i * 4 + 3];
      final cy = boxes[i * 4] * ah + ay;
      final cx = boxes[i * 4 + 1] * aw + ax;
      final h = math.exp(boxes[i * 4 + 2]) * ah;
      final w = math.exp(boxes[i * 4 + 3]) * aw;
      found.add(Detection(Box.centered(cx, cy, w, h).clamped(), score, kind));
    }
  }
  return nonMaxSuppression(
    found,
    (d) => d.box,
    (d) => d.score,
    0.5,
    sameGroup: (a, b) => a.kind == b.kind,
  );
}

/// The objects in EfficientDet's raw [scores] (per anchor, every COCO
/// class, 0 to 1): each label scoring [threshold] or more on some anchor,
/// with its best score.
Map<String, double> decodeObjects(
  Float32List scores, {
  double threshold = VisionModels.minObject,
}) {
  final found = <String, double>{};
  for (var i = 0; i < scores.length; i++) {
    final score = scores[i];
    if (score < threshold) continue;
    final label = cocoLabels[i % cocoClasses];
    if (label == null) continue;
    if (score > (found[label] ?? 0)) found[label] = score;
  }
  return found;
}

/// BlazeFace (short range)'s anchors at 128 px, as (cx, cy) fractions:
/// 2 per cell of a 16 × 16 grid, then 6 per cell of an 8 × 8 one (896).
final Float32List blazeFaceAnchors = () {
  final anchors = <double>[];
  for (final (stride, count) in const [(8, 2), (16, 6)]) {
    final cells = VisionModels.faceSize ~/ stride;
    for (var y = 0; y < cells; y++) {
      for (var x = 0; x < cells; x++) {
        for (var k = 0; k < count; k++) {
          anchors.addAll([(x + 0.5) / cells, (y + 0.5) / cells]);
        }
      }
    }
  }
  return Float32List.fromList(anchors);
}();

/// Faces from BlazeFace's raw outputs, as fractions of its input: per
/// anchor, 16 [regressors] (box center offset and size, then 6 keypoints:
/// the eyes, nose, mouth and ears, in input pixels) and a [scores] logit.
/// Best first.
List<Face> decodeFaces(
  Float32List regressors,
  Float32List scores, {
  double threshold = VisionModels.minFace,
}) {
  const size = VisionModels.faceSize;
  final anchors = blazeFaceAnchors;
  final faces = <Face>[];
  for (var i = 0; i < anchors.length ~/ 2; i++) {
    final score = 1 / (1 + math.exp(-scores[i].clamp(-100.0, 100.0)));
    if (score < threshold) continue;
    final r = i * 16;
    final ax = anchors[i * 2], ay = anchors[i * 2 + 1];
    (double, double) point(int k) => (
      regressors[r + 4 + k * 2] / size + ax,
      regressors[r + 5 + k * 2] / size + ay,
    );
    faces.add(
      Face(
        Box.centered(
          regressors[r] / size + ax,
          regressors[r + 1] / size + ay,
          regressors[r + 2] / size,
          regressors[r + 3] / size,
        ),
        score,
        point(0),
        point(1),
        nose: point(2),
        mouth: point(3),
      ),
    );
  }
  return nonMaxSuppression(faces, (f) => f.box, (f) => f.score, 0.3);
}

/// [items] best first, dropping any that overlaps a better one (of the
/// same group) by more than [maxOverlap].
List<T> nonMaxSuppression<T>(
  List<T> items,
  Box Function(T) box,
  double Function(T) score,
  double maxOverlap, {
  bool Function(T a, T b)? sameGroup,
}) {
  final sorted = [...items]..sort((a, b) => score(b).compareTo(score(a)));
  final kept = <T>[];
  for (final item in sorted) {
    if (kept.every(
      (k) =>
          (sameGroup != null && !sameGroup(k, item)) ||
          box(k).iou(box(item)) <= maxOverlap,
    )) {
      kept.add(item);
    }
  }
  return kept;
}
