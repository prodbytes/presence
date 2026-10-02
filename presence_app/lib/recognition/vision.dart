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

/// A face found on a picture, with its eyes (fractions of the picture).
class Face {
  const Face(this.box, this.score, this.rightEye, this.leftEye);

  final Box box;
  final double score;
  final (double, double) rightEye;
  final (double, double) leftEye;
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

/// The four models recognition runs, all TensorFlow Lite, bundled under
/// `assets/models/` (see its README for sources and licenses):
///
/// - EfficientDet-Lite0 (COCO): people, cats and dogs on a frame, and every
///   other object it knows (object tags);
/// - BlazeFace (short range): a face on a person;
/// - MobileFaceNet: a face's embedding;
/// - MobileNetV3 small (image embedder): a person's or pet's look.
class VisionModels {
  VisionModels._(this._detector, this._faces, this._faceNet, this._embedder);

  static const String detectorAsset = 'assets/models/efficientdet_lite0.tflite';
  static const String faceAsset = 'assets/models/blaze_face_short_range.tflite';
  static const String faceNetAsset = 'assets/models/mobilefacenet.tflite';
  static const String embedderAsset = 'assets/models/mobilenet_v3_small.tflite';

  static const int detectorSize = 320;
  static const int faceSize = 128;
  static const int faceNetSize = 112;
  static const int embedderSize = 224;

  /// The least detection score that counts.
  static const double minDetection = 0.4;

  /// The least score for an object tag: higher, as a wrong label can't be
  /// caught by matching.
  static const double minObject = 0.5;
  static const double minFace = 0.5;

  static Future<VisionModels> load(
    TfliteRuntime runtime, {
    AssetBundle? bundle,
  }) async {
    final assets = bundle ?? rootBundle;
    Future<TfliteModel> model(String asset) async =>
        runtime.load((await assets.load(asset)).buffer.asUint8List());
    return VisionModels._(
      await model(detectorAsset),
      await model(faceAsset),
      await model(faceNetAsset),
      await model(embedderAsset),
    );
  }

  final TfliteModel _detector;
  final TfliteModel _faces;
  final TfliteModel _faceNet;
  final TfliteModel _embedder;

  /// The people, cats and dogs on [image], and every object's best score.
  Future<(List<Detection>, Map<String, double>)> detect(RgbaImage image) async {
    final outputs = await _detector.run(
      toTensor(
        image,
        Region.whole(image),
        width: detectorSize,
        height: detectorSize,
        scale: PixelScale.bytes,
      ),
    );
    final n = efficientDetAnchors.length ~/ 4;
    final scores = outputs.firstWhere((o) => o.length == n * cocoClasses);
    final boxes = outputs.firstWhere((o) => o.length == n * 4);
    return (
      decodeDetections(scores, boxes, threshold: minDetection),
      decodeObjects(scores, threshold: minObject),
    );
  }

  /// The face on the person at [box] of [image], if one shows.
  Future<Face?> face(RgbaImage image, Box box) async {
    // A square around the person, so the face isn't stretched.
    final region = Region.box(image, box, square: true);
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
    return Face(
      region.boxToImage(image, f.box),
      f.score,
      region.toImage(image, f.rightEye.$1, f.rightEye.$2),
      region.toImage(image, f.leftEye.$1, f.leftEye.$2),
    );
  }

  /// [face]'s embedding: the face cropped square, 1.1 times its box, turned
  /// so the eyes are level.
  Future<Float32List> faceVector(RgbaImage image, Face face) async {
    final dx = (face.leftEye.$1 - face.rightEye.$1) * image.width;
    final dy = (face.leftEye.$2 - face.rightEye.$2) * image.height;
    final region = Region.box(
      image,
      face.box,
      scale: 1.1,
      square: true,
      angle: math.atan2(dy, dx),
    );
    final outputs = await _faceNet.run(
      toTensor(
        image,
        region,
        width: faceNetSize,
        height: faceNetSize,
        scale: PixelScale.centered,
      ),
    );
    return normalized(outputs.single);
  }

  /// The embedding of how whoever is in [box] looks.
  Future<Float32List> lookVector(RgbaImage image, Box box) async {
    final outputs = await _embedder.run(
      toTensor(
        image,
        Region.box(image, box),
        width: embedderSize,
        height: embedderSize,
        scale: PixelScale.unit,
      ),
    );
    return normalized(outputs.single);
  }

  /// Everyone on [image], with their embeddings ([faces]: whether to look
  /// for faces at all; [subjects]: whether to embed anyone, or only list
  /// the objects), and the objects on it.
  Future<FrameAnalysis> analyse(
    RgbaImage image, {
    bool faces = true,
    bool subjects = true,
  }) async {
    final (detections, objects) = await detect(image);
    if (!subjects) return FrameAnalysis(objects: objects);
    final seen = <Seen>[];
    for (final d in detections) {
      final found = faces && d.kind == SeenKind.person
          ? await face(image, d.box)
          : null;
      seen.add(
        Seen(
          d,
          face: found,
          faceVector: found == null ? null : await faceVector(image, found),
          lookVector: await lookVector(image, d.box),
        ),
      );
    }
    return FrameAnalysis(seen: seen, objects: objects);
  }

  void dispose() {
    _detector.dispose();
    _faces.dispose();
    _faceNet.dispose();
    _embedder.dispose();
  }
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

/// EfficientDet-Lite0's anchors at 320 px, as (cy, cx, h, w) fractions,
/// flattened: levels 3 to 7, then rows, columns, 3 scales and 3 aspect
/// ratios (19206 in all), as the model was trained.
final Float32List efficientDetAnchors = () {
  final anchors = <double>[];
  const size = VisionModels.detectorSize;
  for (var level = 3; level <= 7; level++) {
    final stride = 1 << level;
    final cells = (size / stride).ceil();
    for (var y = 0; y < cells; y++) {
      for (var x = 0; x < cells; x++) {
        for (var octave = 0; octave < 3; octave++) {
          for (final ratio in const [1.0, 2.0, 0.5]) {
            final base = 4 * stride * math.pow(2, octave / 3);
            anchors.addAll([
              (y + 0.5) * stride / size,
              (x + 0.5) * stride / size,
              base / math.sqrt(ratio) / size,
              base * math.sqrt(ratio) / size,
            ]);
          }
        }
      }
    }
  }
  return Float32List.fromList(anchors);
}();

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
/// anchor, 16 [regressors] (box center offset and size, then 6 keypoints,
/// in input pixels) and a [scores] logit. Best first.
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
