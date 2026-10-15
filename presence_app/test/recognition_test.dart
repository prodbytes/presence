import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/annotations.dart';
import 'package:presence_app/cameras/camera_source.dart';
import 'package:presence_app/cameras/clip_player_controller.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/copies_badge.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/recognition/cloud_recognition.dart';
import 'package:presence_app/recognition/frames.dart';
import 'package:presence_app/recognition/image.dart';
import 'package:presence_app/recognition/matching.dart';
import 'package:presence_app/recognition/memory.dart';
import 'package:presence_app/recognition/recognizer.dart';
import 'package:presence_app/recognition/runtime.dart';
import 'package:presence_app/recognition/suggestion.dart';
import 'package:presence_app/recognition/vision.dart';
import 'package:presence_app/subjects.dart';

import 'fakes.dart';

import 'sealed.dart';

/// A unit vector pointing [degrees] around a circle: two of them have a
/// cosine of cos(difference).
Float32List direction(double degrees) {
  final r = degrees * math.pi / 180;
  return Float32List.fromList([math.cos(r), math.sin(r)]);
}

/// The angle between two unit vectors with cosine [c].
double angleFor(double c) => math.acos(c) * 180 / math.pi;

/// The face cosine [faceConfidence] makes [confidence] of.
double faceCos(double confidence) => 0.30 + 0.35 * confidence;

/// A unit vector along axis [i] of 6, turned toward axis [i] + 3 so its
/// cosine with axis [i] is [cos], and 0 with the other axes below 3: faces
/// of three people that don't look like one another.
Float32List axis(int i, {double cos = 1}) => Float32List(6)
  ..[i] = cos
  ..[i + 3] = math.sqrt(1 - cos * cos);

Seen seenAt(
  Box box, {
  SeenKind kind = SeenKind.person,
  double? face,
  Float32List? faceVector,
  double look = 0,
}) => Seen(
  Detection(box, 0.9, kind),
  face: face == null && faceVector == null
      ? null
      : Face(
          Box.centered(box.cx, box.top + 0.05, 0.04, 0.04),
          0.9,
          (box.cx - 0.01, box.top + 0.04),
          (box.cx + 0.01, box.top + 0.04),
        ),
  faceVector: faceVector ?? (face == null ? null : direction(face)),
  lookVector: direction(look),
);

GalleryEntry entry(
  String id, {
  SeenKind kind = SeenKind.person,
  double? face,
  double look = 0,
}) => GalleryEntry(
  subjectId: id,
  name: id[0].toUpperCase() + id.substring(1),
  kind: kind,
  look: direction(look),
  face: face == null ? null : direction(face),
);

class FakeRuntime implements TfliteRuntime {
  @override
  bool supported = true;

  @override
  Future<TfliteModel> load(Uint8List bytes) => throw UnimplementedError();
}

/// Frames whose width is their index, so [FakeVision] knows which it got.
class FakeSampler implements ClipFrameSampler {
  FakeSampler(this.count, {this.onSample});

  final int count;

  /// Called (and awaited) as each clip is sampled.
  final Future<void> Function(ClipMedia media)? onSample;
  int jpegs = 0;

  /// Clips sampled.
  int samples = 0;

  @override
  bool get supported => true;

  @override
  Stream<SampledFrame> sample(
    ClipMedia media, {
    required Duration every,
    int maxWidth = ClipFrameSampler.defaultMaxWidth,
  }) async* {
    samples++;
    await onSample?.call(media);
    for (var i = 0; i < count; i++) {
      yield SampledFrame(
        Duration(milliseconds: 1000 + i * every.inMilliseconds),
        RgbaImage(i + 1, 1, Uint8List(4 * (i + 1))),
        () async {
          jpegs++;
          return onePixelPng;
        },
      );
    }
  }
}

/// Answers from a script: per frame (by image width), who's there, and
/// which [objects].
class FakeVision extends Vision {
  FakeVision(
    this.frames,
    this.references, {
    this.objects = const {},
    this.pets = const {},
  });

  final Map<int, List<Seen>> frames;

  /// For reference frames (decoded as 1000 + n wide).
  final Map<int, List<Seen>> references;
  final Map<int, Map<String, double>> objects;

  /// The cats and dogs detected on each frame (with subjects or not).
  final Map<int, List<Detection>> pets;

  /// Pictures analysed for subjects (embeddings), and frames at all.
  int calls = 0;
  int frameCalls = 0;
  int releases = 0;

  /// What the last frame (not reference) was analysed for.
  Set<SeenKind>? kinds;
  int? maxSeen;

  @override
  Future<FrameAnalysis> analyse(
    RgbaImage image, {
    bool faces = true,
    bool subjects = true,
    Set<SeenKind>? kinds,
    int? maxSeen,
  }) async {
    if (subjects) calls++;
    if (image.width >= 1000) {
      return FrameAnalysis(seen: references[image.width - 1000] ?? []);
    }
    frameCalls++;
    this.kinds = kinds;
    this.maxSeen = maxSeen;
    final i = image.width - 1;
    return FrameAnalysis(
      seen: subjects ? frames[i] ?? [] : const [],
      objects: objects[i] ?? const {},
      pets: pets[i] ?? const [],
    );
  }

  @override
  void release() => releases++;
}

/// [FakeVision] whose frames (not reference frames) wait for [gate].
class _GatedVision extends FakeVision {
  _GatedVision(super.frames, super.references);

  final gate = Completer<void>();

  @override
  Future<FrameAnalysis> analyse(
    RgbaImage image, {
    bool faces = true,
    bool subjects = true,
    Set<SeenKind>? kinds,
    int? maxSeen,
  }) async {
    if (image.width < 1000) await gate.future;
    return super.analyse(
      image,
      faces: faces,
      subjects: subjects,
      kinds: kinds,
      maxSeen: maxSeen,
    );
  }
}

/// Memory that's [tight] for that many more reads.
class FakeMemory implements MemoryMonitor {
  int tight = 0;
  int reads = 0;

  @override
  Future<MemoryStatus?> status() async {
    reads++;
    final low = tight > 0;
    if (low) tight--;
    return MemoryStatus(
      lowMemory: low,
      availableBytes: 1 << 30,
      thresholdBytes: 1 << 20,
    );
  }
}

void main() {
  testWidgets('the card indicator: a spinner while it runs, then the '
      'error icon when it failed, the brain when it ran', (tester) async {
    final bus = AppEventBus();
    final log = EventLog(bus.stream);
    var fail = true;
    final loading = Completer<void>();
    final r = SubjectRecognizer(
      bus: bus,
      log: log,
      config: ConfigController(),
      runtime: FakeRuntime(),
      sampler: FakeSampler(1),
      loadVision: () async {
        await loading.future;
        if (fail) throw StateError('no models');
        return FakeVision({}, {});
      },
    );
    addTearDown(r.dispose);
    final event = ClipRequested(clip(), id: 'e1');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SubjectRecognizerScope(
            recognizer: r,
            child: EventIndicators(event: event),
          ),
        ),
      ),
    );
    final badge = find.byKey(const Key('event-recognition-e1'));
    IconData? icon() => tester
        .widgetList<Icon>(
          find.descendant(of: badge, matching: find.byType(Icon)),
        )
        .firstOrNull
        ?.icon;
    expect(icon(), Icons.psychology_outlined);

    await tester.tap(badge);
    await tester.pump();
    expect(
      find.descendant(
        of: badge,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
      reason: 'a spinner while it runs',
    );
    loading.complete();
    await tester.pumpAndSettle();
    expect(icon(), Icons.error_outline, reason: 'failed: the error icon');
    final tooltip = tester
        .widget<Tooltip>(
          find.descendant(of: badge, matching: find.byType(Tooltip)),
        )
        .message!;
    expect(tooltip, startsWith('Recognition failed:'));
    // With what went wrong, so it can be told.
    expect(tooltip, contains('no models'));

    // Tried again, and it runs: the brain again, in full.
    fail = false;
    await tester.tap(badge);
    await tester.pumpAndSettle();
    expect(icon(), Icons.psychology);
    await tester.pump(const Duration(seconds: 5));
  });

  group('decoding', () {
    test('EfficientDet: a scored anchor becomes a box of its kind', () {
      final anchors = efficientDetAnchors;
      final n = anchors.length ~/ 4;
      expect(n, 37629);
      final scores = Float32List(n * cocoClasses);
      final boxes = Float32List(n * 4);
      // A dog on an anchor exactly (row 10, column 10), and a weaker overlapping one.
      scores[5130 * cocoClasses + 17] = 0.9;
      // Same place, one scale up: overlapping.
      scores[5133 * cocoClasses + 17] = 0.6;
      // A person on the middle cell's anchor, shifted right by half its width.
      scores[14364 * cocoClasses] = 0.8;
      boxes[14364 * 4 + 1] = 0.5;
      // A car: not kept.
      scores[200 * cocoClasses + 2] = 0.99;
      final found = decodeDetections(scores, boxes);
      expect(found.map((d) => d.kind), [SeenKind.dog, SeenKind.person]);
      final dog = found.first;
      expect(dog.score, closeTo(0.9, 1e-6));
      expect(dog.box.cy, closeTo(anchors[5130 * 4], 1e-6));
      expect(dog.box.cx, closeTo(anchors[5130 * 4 + 1], 1e-6));
      final person = found.last;
      expect(
        person.box.cx,
        closeTo(anchors[14364 * 4 + 1] + 0.5 * anchors[14364 * 4 + 3], 1e-6),
      );
      expect(person.box.height, closeTo(anchors[14364 * 4 + 2], 1e-6));
    });

    test("EfficientDet's anchors are the ones its model file lists", () {
      // (cy, cx, h, w), from efficientdet_lite2.tflite's metadata.
      void expectAnchor(int i, List<double> expected) {
        for (var k = 0; k < 4; k++) {
          expect(efficientDetAnchors[i * 4 + k], closeTo(expected[k], 1e-5));
        }
      }

      expectAnchor(0, [0.0089286, 0.0089286, 0.0535714, 0.0535714]);
      expectAnchor(1234, [0.0446429, 0.4553571, 0.0378807, 0.0757615]);
      // Level 7: 4 cells a side, centered on them, 3 cells across.
      expectAnchor(37629 - 16 * 9, [0.125, 0.125, 0.75, 0.75]);
      expectAnchor(37628, [0.875, 0.875, 1.6836932, 0.8418465]);
    });

    test('the detector sees the whole frame, and tiles along a wide one', () {
      RgbaImage blank(int w, int h) => RgbaImage(w, h, Uint8List(w * h * 4));
      final wide = detectorRegions(blank(1280, 720));
      expect(wide, hasLength(3));
      // The whole frame, in a square (not stretched).
      expect(
        (wide[0].cx, wide[0].cy, wide[0].w, wide[0].h),
        (640.0, 360.0, 1280.0, 1280.0),
      );
      // Two 720 px squares, from one end to the other.
      expect((wide[1].cx, wide[1].w), (360.0, 720.0));
      expect((wide[2].cx, wide[2].w), (920.0, 720.0));
      final tall = detectorRegions(blank(720, 1280));
      expect(tall.map((r) => r.cy), [640.0, 360.0, 920.0]);
      // Square enough: only the whole frame.
      expect(detectorRegions(blank(640, 600)), hasLength(1));
      // Very wide: enough tiles to cover it.
      expect(detectorRegions(blank(2000, 500)), hasLength(5));
    });

    test('detections from the regions merge: cut-off parts are dropped', () {
      Detection d(Box box, double score, [SeenKind kind = SeenKind.person]) =>
          Detection(box, score, kind);
      final whole = d(const Box(0.40, 0.2, 0.60, 0.9), 0.8);
      // The same person seen by a tile, cut at its edge: mostly inside.
      final cut = d(const Box(0.40, 0.2, 0.50, 0.9), 0.9);
      // Someone else, beside them.
      final beside = d(const Box(0.62, 0.2, 0.80, 0.9), 0.5);
      // A dog on the same spot as the person: another kind, kept.
      final dog = d(const Box(0.40, 0.2, 0.60, 0.9), 0.6, SeenKind.dog);
      final merged = mergeDetections([whole, cut, beside, dog]);
      expect(merged, [cut, dog, beside]);
      expect(
        const Box(0, 0, 1, 1).containment(const Box(0.2, 0.2, 0.4, 0.4)),
        1,
      );
      expect(const Box(0, 0, 1, 1).containment(const Box(2, 2, 3, 3)), 0);
    });

    test('object tags: every known label, its best score, once', () {
      final n = efficientDetAnchors.length ~/ 4;
      final scores = Float32List(n * cocoClasses);
      scores[10 * cocoClasses + 1] = 0.7; // bicycle
      scores[20 * cocoClasses + 1] = 0.9; // a better bicycle
      scores[30 * cocoClasses + 43] = 0.6; // bottle
      scores[40 * cocoClasses] = 0.8; // a person: "human"
      scores[50 * cocoClasses + 17] = 0.45; // a dog, too unsure
      scores[60 * cocoClasses + 11] = 0.99; // unused class
      final found = decodeObjects(scores);
      expect(found.keys.toSet(), {'bicycle', 'bottle', 'human'});
      expect(found['bicycle'], closeTo(0.9, 1e-6));
      expect(cocoLabels, hasLength(80));
      expect(cocoLabels[16], 'cat');
      expect(cocoLabels[17], 'dog');
    });

    test('BlazeFace: box and eyes from an anchor, as fractions', () {
      final anchors = blazeFaceAnchors;
      expect(anchors.length ~/ 2, 896);
      final regressors = Float32List(896 * 16);
      final scores = Float32List(896)..fillRange(0, 896, -10);
      const i = 600;
      scores[i] = 4; // sigmoid ≈ 0.98
      regressors.setAll(i * 16, [
        12.8, 0, 32, 38.4, // center +0.1 x, 0.25 × 0.3
        -6.4, -12.8, 6.4, -12.8, // eyes
      ]);
      final faces = decodeFaces(regressors, scores);
      expect(faces, hasLength(1));
      final f = faces.single;
      expect(f.score, closeTo(1 / (1 + math.exp(-4)), 1e-6));
      expect(f.box.cx, closeTo(anchors[i * 2] + 0.1, 1e-6));
      expect(f.box.cy, closeTo(anchors[i * 2 + 1], 1e-6));
      expect(f.box.width, closeTo(0.25, 1e-6));
      expect(f.box.height, closeTo(0.3, 1e-6));
      expect(f.rightEye.$1, closeTo(anchors[i * 2] - 0.05, 1e-6));
      expect(f.leftEye.$2, closeTo(anchors[i * 2 + 1] - 0.1, 1e-6));
      // Nose and mouth too (zero offsets here: on the anchor).
      expect(f.nose!.$1, closeTo(anchors[i * 2], 1e-6));
      expect(f.mouth!.$2, closeTo(anchors[i * 2 + 1], 1e-6));
    });

    test('non-maximum suppression keeps the best of overlaps', () {
      const a = Box(0, 0, 1, 1);
      const b = Box(0.05, 0, 1, 1);
      const c = Box(2, 2, 3, 3);
      final kept = nonMaxSuppression(
        [(a, 0.5), (b, 0.9), (c, 0.1)],
        (x) => x.$1,
        (x) => x.$2,
        0.5,
      );
      expect(kept.map((x) => x.$1), [b, c]);
    });

    test('detections kept: only the kinds asked for, the best few', () {
      Detection d(SeenKind kind, double score) =>
          Detection(const Box(0, 0, 1, 1), score, kind);
      final all = [
        d(SeenKind.person, 0.9),
        d(SeenKind.dog, 0.8),
        d(SeenKind.person, 0.7),
        d(SeenKind.cat, 0.6),
        d(SeenKind.person, 0.5),
        d(SeenKind.person, 0.4),
      ];
      expect(keepDetections(all), all);
      expect(keepDetections(all, max: 3), all.sublist(0, 3));
      expect(
        keepDetections(
          all,
          kinds: {SeenKind.person},
          max: 3,
        ).map((d) => d.score),
        [0.9, 0.7, 0.5],
      );
      expect(keepDetections(all, kinds: {SeenKind.cat, SeenKind.dog}), [
        all[1],
        all[3],
      ]);
      expect(keepDetections(all, kinds: {}), isEmpty);
    });
  });

  group('images', () {
    // 2 × 2: red, green / blue, white.
    final image = RgbaImage(
      2,
      2,
      Uint8List.fromList([
        255, 0, 0, 255, 0, 255, 0, 255, //
        0, 0, 255, 255, 255, 255, 255, 255,
      ]),
    );

    test('the whole picture at its own size is the same pixels', () {
      final t = toTensor(
        image,
        Region.whole(image),
        width: 2,
        height: 2,
        scale: PixelScale.bytes,
      ) as Int32List;
      expect(t, [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255]);
    });

    test('pixel scales', () {
      List<double> first(PixelScale s) => (toTensor(
        image,
        Region.whole(image),
        width: 2,
        height: 2,
        scale: s,
      ) as Float32List).sublist(0, 3);
      expect(first(PixelScale.unit), [1, 0, 0]);
      expect(first(PixelScale.symmetric), [1, -1, -1]);
      expect(first(PixelScale.centered)[0], closeTo(127.5 / 128, 1e-6));
    });

    test('turned half a turn, the picture is upside down', () {
      final t = toTensor(
        image,
        Region(1, 1, 2, 2, math.pi),
        width: 2,
        height: 2,
        scale: PixelScale.bytes,
      ) as Int32List;
      expect(t.sublist(0, 3), [255, 255, 255]);
      expect(t.sublist(9), [255, 0, 0]);
    });

    test('outside the picture is black; boxes map back', () {
      final t = toTensor(
        image,
        const Region(-5, -5, 2, 2),
        width: 2,
        height: 2,
        scale: PixelScale.bytes,
      ) as Int32List;
      expect(t, everyElement(0));
      final region = Region.box(image, const Box(0, 0, 0.5, 0.5), scale: 2);
      final back = region.boxToImage(image, const Box(0.5, 0.5, 1, 1));
      expect(back.left, closeTo(0.25, 1e-9));
      expect(back.right, closeTo(0.75, 1e-9));
    });

    test('shrunk, each value is the mean of what it covers', () {
      // Black and white columns, 1 px each: any single sample is black or
      // white, the area they cover is grey.
      const n = 16;
      final stripes = Uint8List(n * n * 4);
      for (var y = 0; y < n; y++) {
        for (var x = 0; x < n; x++) {
          final i = (y * n + x) * 4;
          stripes.fillRange(i, i + 3, x.isEven ? 0 : 255);
          stripes[i + 3] = 255;
        }
      }
      final image = RgbaImage(n, n, stripes);
      final small = toTensor(
        image,
        Region.whole(image),
        width: 4,
        height: 4,
        scale: PixelScale.unit,
      ) as Float32List;
      for (final v in small) {
        expect(v, closeTo(0.5, 0.01));
      }
      expect(samplesFor(1), 1);
      expect(samplesFor(1.2), 1);
      expect(samplesFor(2.9), 3);
      expect(samplesFor(9), maxSamplesPerSide);
    });

    test('mirrored left to right', () {
      // 2 × 1, three channels: (1, 2, 3) then (4, 5, 6).
      final t = Float32List.fromList([1, 2, 3, 4, 5, 6]);
      expect(mirrored(t, 2, 1), [4, 5, 6, 1, 2, 3]);
    });

    test("the face is looked for around the person's head first", () {
      final frame = RgbaImage(1000, 1000, Uint8List(1000 * 1000 * 4));
      // Standing: 100 px wide, 400 px tall, from (450, 300).
      final head = VisionModels.headRegion(
        frame,
        const Box(0.45, 0.3, 0.55, 0.7),
      );
      // As wide as their height × 7/16 (wider than they are), on them,
      // starting a little above them.
      expect(head.w, closeTo(175, 1e-9));
      expect(head.h, head.w);
      expect(head.cx, closeTo(500, 1e-9));
      expect(head.cy - head.h / 2, closeTo(300 - 0.05 * 175, 1e-9));
      // Wide (lying down, or close): as wide as them.
      expect(
        VisionModels.headRegion(frame, const Box(0.2, 0.5, 0.8, 0.7)).w,
        closeTo(600, 1e-9),
      );
    });

    test("faces are aligned to the face embedder's template", () {
      final image = RgbaImage(400, 400, Uint8List(400 * 400 * 4));
      // The template's points, twice as big and turned 30°, moved to
      // (200, 150): the face's region must undo exactly that.
      const turn = math.pi / 6;
      (double, double) placed((double, double) p) {
        final x = (p.$1 - 56) * 2, y = (p.$2 - 56) * 2;
        return (
          (200 + x * math.cos(turn) - y * math.sin(turn)) / 400,
          (150 + x * math.sin(turn) + y * math.cos(turn)) / 400,
        );
      }

      final t = VisionModels.faceTemplate;
      final face = Face(
        const Box(0.4, 0.3, 0.6, 0.5),
        0.9,
        placed(t[0]),
        placed(t[1]),
        nose: placed(t[2]),
        mouth: placed(t[3]),
      );
      final region = VisionModels.faceRegion(image, face);
      expect(region.cx, closeTo(200, 1e-6));
      expect(region.cy, closeTo(150, 1e-6));
      expect(region.w, closeTo(224, 1e-6));
      expect(region.h, closeTo(224, 1e-6));
      expect(region.angle, closeTo(turn, 1e-9));
      // With the eyes only, the same.
      final eyes = VisionModels.faceRegion(
        image,
        Face(face.box, 0.9, face.rightEye, face.leftEye),
      );
      expect(eyes.cx, closeTo(200, 1e-6));
      expect(eyes.angle, closeTo(turn, 1e-9));
    });

    test('faces too small to compare: eyes closer than the minimum', () {
      final frame = RgbaImage(1000, 500, Uint8List(1000 * 500 * 4));
      const box = Box(0.4, 0.4, 0.42, 0.42);
      expect(
        VisionModels.eyeDistance(
          frame,
          const Face(box, 0.9, (0.400, 0.41), (0.408, 0.41)),
        ),
        closeTo(8, 1e-9),
      );
      expect(VisionModels.minEyeDistance, greaterThan(8));
    });
  });

  group('matching', () {
    test('confidence: faces and looks on their own scales', () {
      expect(faceConfidence(0.2), 0);
      expect(faceConfidence(0.475), closeTo(0.5, 1e-9));
      expect(faceConfidence(0.58), closeTo(0.8, 1e-9));
      expect(faceConfidence(0.7), 1);
      // People's looks (OSNet), and pets' (MobileNetV3).
      expect(lookConfidence(0.53), 0);
      expect(lookConfidence(0.762), closeTo(0.8, 1e-9));
      expect(lookConfidence(0.9), 1);
      expect(lookConfidence(0.45, kind: SeenKind.dog), 0);
      expect(lookConfidence(0.81, kind: SeenKind.cat), closeTo(0.8, 1e-9));
    });

    test('faces are compared when both show; looks otherwise', () {
      const box = Box(0, 0, 0.5, 1);
      final byFace = compare(
        seenAt(box, face: angleFor(faceCos(0.8)), look: 90),
        entry('ana', face: 0, look: 0),
      )!;
      expect(byFace.byFace, isTrue);
      expect(byFace.confidence, closeTo(0.8, 1e-6));
      final byLook = compare(
        seenAt(box, look: angleFor(0.762)),
        entry('ana', face: 0),
      )!;
      expect(byLook.byFace, isFalse);
      expect(byLook.confidence, closeTo(0.8, 1e-6));
      // A person is never a pet; a cat may be a "dog".
      expect(compare(seenAt(box), entry('rex', kind: SeenKind.dog)), isNull);
      expect(
        compare(
          seenAt(box, kind: SeenKind.cat),
          entry('rex', kind: SeenKind.dog),
        ),
        isNotNull,
      );
    });

    test('each subject to one of those seen, surest first', () {
      const left = Box(0, 0, 0.4, 1);
      const right = Box(0.6, 0, 1, 1);
      final seen = [seenAt(left, face: 0), seenAt(right, face: 40)];
      final gallery = [
        // Ana looks like both, but most like the left one.
        entry('ana', face: 5),
        entry('ana', face: 20),
        // Bo looks a bit like the left one, best like the right one.
        entry('bo', face: 30),
      ];
      final matches = matchFrame(seen, gallery);
      expect(matches.map((m) => m.subjectId), ['ana', 'bo']);
      expect(matches.first.seen, same(seen.first));
      expect(matches.last.seen, same(seen.last));
      // Skipped subjects, and weak pairs, are left out.
      expect(
        matchFrame(seen, gallery, skip: {'ana'}).single.seen,
        same(seen.first),
      );
      expect(
        matchFrame(seen, [entry('bo', face: 150)], minConfidence: 0.7),
        isEmpty,
      );
    });

    test('a tag picks the smallest detection around it, or the nearest', () {
      final big = seenAt(const Box(0, 0, 1, 1));
      final small = seenAt(const Box(0.4, 0.4, 0.6, 0.6));
      expect(SubjectRecognizer.pickTagged([big, small], 0.5, 0.5), small);
      expect(SubjectRecognizer.pickTagged([small], 0.64, 0.5), small);
      expect(SubjectRecognizer.pickTagged([small], 0.9, 0.9), isNull);
    });
  });

  group('settings and tags', () {
    test('recognition settings: defaults, limits, no ask level', () {
      const r = RecognitionConfig();
      expect(r.enabled, isTrue);
      expect(r.objects, isTrue);
      expect(r.autoTag, 0.85);
      expect(RecognitionConfig.askFloor, 0.5);
      expect(r.copyWith(autoTag: 2).autoTag, RecognitionConfig.maxConfidence);
      expect(r.copyWith(autoTag: 0).autoTag, RecognitionConfig.minConfidence);
      final config = const PresenceConfig().copyWith(
        recognition: r.copyWith(enabled: false, objects: false, autoTag: 0.9),
      );
      expect(PresenceConfig.fromJson(config.toJson()), config);
      expect(config.toJson()['recognition'], isNot(contains('ask')));
      expect(PresenceConfig.fromJson({'version': 1}).recognition, r);
      // A record from when it had an "Ask me when at least" level: ignored.
      expect(
        PresenceConfig.fromJson({
          'version': 1,
          'recognition': {'enabled': true, 'autoTag': 0.7, 'ask': 0.6},
        }).recognition,
        r.copyWith(autoTag: 0.7),
      );
      // A version 1 record left at its default (90 %): the new one, once.
      // Chosen: kept, at least the floor. Saved again (version 2), a 90 %
      // chosen later stays.
      RecognitionConfig stored(double autoTag, {int version = 1}) =>
          PresenceConfig.fromJson({
            'version': version,
            'recognition': {'autoTag': autoTag},
          }).recognition;
      expect(stored(0.90).autoTag, 0.85);
      expect(stored(0.90, version: 2).autoTag, 0.90);
      expect(stored(0.85).autoTag, 0.85);
      expect(
        PresenceConfig.fromJson(
          const PresenceConfig()
              .copyWith(recognition: r.copyWith(autoTag: 0.9))
              .toJson(),
        ).recognition.autoTag,
        0.9,
      );
      expect(stored(0.95).autoTag, 0.95);
      expect(stored(0.8).autoTag, 0.8);
      expect(stored(0.3).autoTag, RecognitionConfig.minConfidence);
    });

    test('tags keep their source and confidence; suggestions are not tags', () {
      final a = ClipAnnotations();
      final frame = testFrame(onePixelPng, 1500);
      final manual = a.add('Ana', 0.1, 0.1, frame: frame)!;
      final detected = a.add(
        'Rex',
        0.5,
        0.5,
        frame: frame,
        source: TagSource.detected,
        confidence: 0.86,
      )!;
      final other = testFrame(onePixelPng, 2500);
      final suggested = a.add(
        'Bo',
        0.2,
        0.2,
        frame: other,
        source: TagSource.suggested,
        confidence: 0.6,
      )!;
      expect(a.tags.map((t) => t.name), ['Ana', 'Rex']);
      expect(a.tagFrames.keys, [frame.id]);
      expect(a.frames.keys, unorderedEquals([frame.id, other.id]));
      expect(a.on(other.id), isEmpty);

      final restored = ClipAnnotations.fromJson(a.toJson(), a.framesToRecord());
      expect(restored.byId(manual.id)!.source, TagSource.manual);
      expect(a.toJson().first.containsKey('source'), isFalse);
      expect(restored.byId(detected.id)!.source, TagSource.detected);
      expect(restored.byId(detected.id)!.confidence, 0.86);
      expect(restored.byId(suggested.id)!.source, TagSource.suggested);
      expect(restored.frames.keys, contains(other.id));

      a.confirm(suggested.id);
      expect(a.byId(suggested.id)!.source, TagSource.confirmed);
      expect(TagSource.confirmed.vouched, isTrue);
      expect(TagSource.detected.vouched, isFalse);
    });

    test('object tags round-trip with the clip; none until searched', () {
      final event = ClipRequested(clip(), id: 'c1');
      expect(event.toRecord().containsKey('objectTags'), isFalse);
      event.annotations.setObjects(const [
        ObjectTag(label: 'cat', ms: 1500, score: 0.6),
      ]);
      final record = event.toRecord();
      expect(record['objectTags'], [
        {'label': 'cat', 'ms': 1500, 'score': 0.6},
      ]);
      final back = ClipAnnotations.fromJson(null, null, record['objectTags']);
      expect(back.objects, event.annotations.objects);
      expect(ClipAnnotations.fromJson(null).objects, isNull);
      // Searched, nothing seen: kept as such.
      expect(ClipAnnotations.fromJson(null, null, []).objects, isEmpty);
      expect(
        ClipAnnotations.fromJson(null, null, [
          {'label': '', 'ms': 0, 'score': 1},
          'junk',
        ]).objects,
        isEmpty,
      );
    });

    test('subjects leave out suggestions', () {
      final a = ClipAnnotations()
        ..add('Ana', 0.1, 0.1)
        ..add('Bo', 0.2, 0.2, source: TagSource.suggested);
      final subjects = subjectsOf([
        ClipRequested(clip(), annotations: a, id: 'c1'),
      ]);
      expect(subjects.map((s) => s.id), ['ana']);
    });

    test('a suggestion event round-trips', () {
      final s = SubjectSuggestion(
        clipEventId: 'c1',
        annotationId: 'a1',
        subjectName: 'Rex',
        confidence: 0.62,
        cameraId: 'cam',
        time: DateTime(2026, 10, 1, 12),
        id: 's1',
      );
      expect(s.title, 'Is this Rex?');
      expect(s.detail, '62 % sure');
      final back = SubjectSuggestion.fromRecord(s.toRecord())!;
      expect(back.clipEventId, 'c1');
      expect(back.annotationId, 'a1');
      expect(back.subjectName, 'Rex');
      expect(back.confidence, 0.62);
      expect(back.time, s.time);
      expect(SubjectSuggestion.fromRecord({'id': 'x', 'time': 0}), isNull);
    });
  });

  group('recognizer', () {
    late StreamController<AppEvent> stream;
    late AppEventBus bus;
    late EventLog log;
    late ConfigController config;
    late List<AppEvent> published;

    setUp(() {
      bus = AppEventBus();
      stream = StreamController<AppEvent>.broadcast();
      log = EventLog(bus.stream);
      config = ConfigController();
      published = [];
      bus.stream.listen(published.add);
    });
    tearDown(() => stream.close());

    /// An earlier clip with [names] tagged on reference frame [n].
    ClipRequested tagged(int n, List<String> names, {double x = 0.5}) {
      final a = ClipAnnotations();
      final frame = TagFrame(id: 'ref-$n', sealed: sealed([n]), ms: 0);
      for (final name in names) {
        a.add(name, x, 0.5, frame: frame);
      }
      return ClipRequested(
        clip(),
        annotations: a,
        id: 'old-$n',
        time: DateTime(2026, 10, 1, 10, n),
      );
    }

    SubjectRecognizer recognizer(FakeVision vision, FakeSampler sampler) =>
        SubjectRecognizer(
          bus: bus,
          log: log,
          config: config,
          runtime: FakeRuntime(),
          sampler: sampler,
          loadVision: () async => vision,
          // Reference frames hold their number.
          decode: (jpeg) async {
            final width = 1000 + jpeg.first;
            return RgbaImage(width, 1, Uint8List(width * 4));
          },
        );

    test(
      "a synced clip nobody searched for subjects is recognized here: "
      "an iPhone's, and a streamer's (its objects looked for again)",
      () async {
        final sampler = FakeSampler(2);
        final r = recognizer(FakeVision({}, {}), sampler);
        final now = DateTime.now();
        ClipRequested synced(String id, {String? os, DateTime? time}) =>
            ClipRequested(clip(), id: id, time: time ?? now)..os = os;
        final iphone = synced('iphone', os: 'iOS');
        // A Raspberry Pi streamer's: its cloud detector's object tags only.
        final pi = synced('pi', os: 'Linux')
          ..annotations.setObjects([
            const ObjectTag(label: 'bear', ms: 0, score: 0.76),
          ]);
        final old = synced(
          'old',
          os: 'iOS',
          time: now.subtract(const Duration(days: 2)),
        );
        // Searched for subjects on its own device already.
        final web = synced('web', os: 'macOS')
          ..annotations.setObjects(const []);
        web.annotations.setSubjectSearch(
          SubjectSearch(
            SubjectSearchOutcome.searched,
            now.millisecondsSinceEpoch,
          ),
        );
        r.recognizeSynced([iphone, pi, old, web], now: now);
        // Queued once the clip is known to be whole (a microtask on).
        await Future<void>.delayed(Duration.zero);
        await r.idle;
        expect(iphone.annotations.objects, isNotNull, reason: 'searched here');
        expect(
          pi.annotations.objects!.map((o) => o.label),
          isNot(contains('bear')),
          reason: "the streamer's tags looked for again",
        );
        expect(old.annotations.objects, isNull, reason: 'history, left');
        expect(
          sampler.samples,
          2,
          reason: 'the iPhone and the Pi, not the web',
        );
      },
    );

    test('a question about a hidden device\'s clip, asked by another '
        'device, shows nowhere here', () {
      final theClip = ClipRequested(clip(), id: 'c')
        ..deviceId = 'brave_little_lamp'
        ..profileId = 'p';
      final question =
          SubjectSuggestion(
              clipEventId: 'c',
              annotationId: 'a',
              subjectName: 'Rex',
              confidence: 0.6,
              clip: theClip,
            )
            ..deviceId = 'calm_quiet_otter'
            ..profileId = 'p';
      log.addHistory([theClip, question]);
      expect(log.eventsOf('p'), hasLength(2));
      log.hiddenDevices = {'brave_little_lamp'};
      expect(log.eventsOf('p'), isEmpty, reason: 'the clip and the question');
    });

    test("a device hidden here (the Profile tab): its clips aren't "
        'recognized here, synced or new; nor asked about', () async {
      final sampler = FakeSampler(2);
      final r = recognizer(FakeVision({}, {}), sampler);
      final now = DateTime.now();
      log.hiddenDevices = {'brave_little_lamp'};
      final hidden = ClipRequested(clip(), id: 'hidden', time: now)
        ..os = 'iOS'
        ..deviceId = 'brave_little_lamp';
      final shown = ClipRequested(clip(), id: 'shown', time: now)
        ..os = 'iOS'
        ..deviceId = 'calm_quiet_otter';
      r.recognizeSynced([hidden, shown], now: now);
      await Future<void>.delayed(Duration.zero);
      await r.idle;
      expect(hidden.annotations.objects, isNull, reason: 'hidden: left');
      expect(shown.annotations.objects, isNotNull);
      expect(sampler.samples, 1);
    });

    test('tags the sure, asks about the unsure, on their best frame', () async {
      const body = Box(0.3, 0.2, 0.7, 1);
      const other = Box(0.75, 0.2, 0.95, 1);
      log.addHistory([
        tagged(1, ['Rex']),
        tagged(2, ['Ana']),
        tagged(3, ['Bo']),
      ]);
      final vision = FakeVision(
        {
          // Frame 0: nobody. Frame 1: Rex, surely (100 %).
          1: [seenAt(body, face: angleFor(0.85))],
          // Frame 2: Rex again, and someone a bit like Ana (60 %).
          2: [
            seenAt(body, face: angleFor(0.85)),
            seenAt(other, face: 100 + angleFor(faceCos(0.6))),
          ],
          // Frame 3: the same one, a bit more like Ana (70 %): her surest
          // face, still unsure.
          3: [seenAt(other, face: 100 + angleFor(faceCos(0.7)))],
        },
        {
          1: [seenAt(body, face: 0)],
          2: [seenAt(body, face: 100)],
          // Bo's tag points at nobody.
          3: [seenAt(const Box(0, 0, 0.1, 0.1), face: 200)],
        },
      );
      final sampler = FakeSampler(4);
      final event = ClipRequested(clip(), id: 'new');
      await recognizer(vision, sampler).recognize(event);

      final rex = event.annotations.tags.single;
      expect(rex.name, 'Rex');
      expect(rex.source, TagSource.detected);
      expect(rex.confidence, closeTo(1, 1e-6));
      expect(rex.x, closeTo(0.5, 1e-9));
      expect(event.annotations.frames[rex.frameId]!.ms, 2000);

      final ana = event.annotations.items.firstWhere((a) => a.name == 'Ana');
      expect(ana.source, TagSource.suggested);
      expect(ana.confidence, closeTo(0.7, 1e-6));
      // Her best frame.
      expect(event.annotations.frames[ana.frameId]!.ms, 4000);
      expect(ana.x, closeTo(other.cx, 1e-9));

      await Future<void>.delayed(Duration.zero);
      final suggestion = published.whereType<SubjectSuggestion>().single;
      expect(suggestion.subjectName, 'Ana');
      expect(suggestion.annotationId, ana.id);
      expect(suggestion.clip, same(event));
      // A JPEG per frame someone was best on so far, not per match.
      expect(sampler.jpegs, 3);
    });

    test(
      'asks about anyone under the auto-tag level, from the floor up',
      () async {
        const left = Box(0, 0.2, 0.3, 1);
        const middle = Box(0.35, 0.2, 0.65, 1);
        const right = Box(0.7, 0.2, 1, 1);
        log.addHistory([
          tagged(1, ['Ana']),
          tagged(2, ['Bo']),
          tagged(3, ['Cy']),
        ]);
        final vision = FakeVision(
          {
            0: [
              // Ana at 80 %: under the 85 % default, so asked, not tagged.
              seenAt(left, faceVector: axis(0, cos: faceCos(0.80))),
              // Bo at 55 %: just over the 50 % floor, asked.
              seenAt(middle, faceVector: axis(1, cos: faceCos(0.55))),
              // Cy at 40 %: under the floor, a stranger; not asked.
              seenAt(right, faceVector: axis(2, cos: faceCos(0.4))),
            ],
          },
          {
            // Nobody is like the others.
            1: [seenAt(middle, faceVector: axis(0))],
            2: [seenAt(middle, faceVector: axis(1))],
            3: [seenAt(middle, faceVector: axis(2))],
          },
        );
        final event = ClipRequested(clip(), id: 'new');
        await recognizer(vision, FakeSampler(1)).recognize(event);

        expect(event.annotations.tags, isEmpty);
        expect(
          {
            for (final a in event.annotations.items)
              if (a.source == TagSource.suggested) a.name,
          },
          {'Ana', 'Bo'},
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          published.whereType<SubjectSuggestion>().map((s) => s.subjectName),
          unorderedEquals(['Ana', 'Bo']),
        );
      },
    );

    test('stops once everyone is surely found, skips who is tagged', () async {
      const body = Box(0.3, 0.2, 0.7, 1);
      log.addHistory([
        tagged(1, ['Rex']),
        tagged(2, ['Ana']),
      ]);
      final vision = FakeVision(
        {
          for (var i = 0; i < 10; i++) i: [seenAt(body, face: angleFor(0.9))],
        },
        {
          1: [seenAt(body, face: 0)],
          2: [seenAt(body, face: 100)],
        },
      );
      final a = ClipAnnotations()..add('Ana', 0.1, 0.1);
      final event = ClipRequested(clip(), annotations: a, id: 'new');
      await recognizer(vision, FakeSampler(10)).recognize(event);
      expect(event.annotations.tags.map((t) => t.name), ['Ana', 'Rex']);
      // Two references, then one frame: a sure face is enough.
      expect(vision.calls, 3);
    });

    test('sure by look takes as many frames as are pooled', () async {
      const body = Box(0.3, 0.2, 0.7, 1);
      log.addHistory([
        tagged(1, ['Rex']),
      ]);
      final vision = FakeVision(
        {
          for (var i = 0; i < 10; i++) i: [seenAt(body, look: angleFor(0.9))],
        },
        {
          1: [seenAt(body)],
        },
      );
      final event = ClipRequested(clip(), id: 'new');
      await recognizer(vision, FakeSampler(10)).recognize(event);
      expect(event.annotations.tags.single.name, 'Rex');
      expect(vision.calls, 1 + SubjectRecognizer.framesPooled);
    });

    /// The look cosine [lookConfidence] makes [confidence] of, for people.
    double lookCos(double confidence) => 0.53 + 0.29 * confidence;

    test('one lucky look of a stranger asks, it does not tag', () async {
      const body = Box(0.3, 0.2, 0.7, 1);
      log.addHistory([
        tagged(1, ['Rex']),
      ]);
      final vision = FakeVision(
        {
          // Looks like Rex on one frame (95 %), not on the others (35 %).
          0: [seenAt(body, look: angleFor(lookCos(0.35)))],
          1: [seenAt(body, look: angleFor(lookCos(0.95)))],
          2: [seenAt(body, look: angleFor(lookCos(0.35)))],
          3: [seenAt(body, look: angleFor(lookCos(0.35)))],
        },
        {
          1: [seenAt(body)],
        },
      );
      final event = ClipRequested(clip(), id: 'new');
      final result = await recognizer(vision, FakeSampler(4)).recognize(event);
      expect(result.tagged, isEmpty);
      expect(result.asked, ['Rex']);
      final rex = event.annotations.items.single;
      // The mean of the best three: (95 + 35 + 35) / 3.
      expect(rex.confidence, closeTo(0.55, 1e-6));
      // Asked about on the frame most like him.
      expect(event.annotations.frames[rex.frameId]!.ms, 2000);
    });

    test('one sure face tags, whatever the other frames', () async {
      const body = Box(0.3, 0.2, 0.7, 1);
      log.addHistory([
        tagged(1, ['Rex']),
      ]);
      final vision = FakeVision(
        {
          // His face once (95 %), turned away the rest (looks at 35 %).
          0: [seenAt(body, look: angleFor(lookCos(0.35)))],
          1: [seenAt(body, face: angleFor(faceCos(0.95)))],
          2: [seenAt(body, look: angleFor(lookCos(0.35)))],
        },
        {
          1: [seenAt(body, face: 0)],
        },
      );
      final event = ClipRequested(clip(), id: 'new');
      final result = await recognizer(vision, FakeSampler(3)).recognize(event);
      expect(result.tagged, ['Rex']);
      expect(event.annotations.tags.single.confidence, closeTo(0.95, 1e-6));
    });

    test('recognized tags never become references', () async {
      const body = Box(0.3, 0.2, 0.7, 1);
      final a = ClipAnnotations();
      final frame = TagFrame(
        id: 'f',
        sealed: sealed(Uint8List.fromList([1])),
        ms: 0,
      );
      a.add('Rex', 0.5, 0.5, frame: frame, source: TagSource.detected);
      log.addHistory([ClipRequested(clip(), annotations: a, id: 'old')]);
      final vision = FakeVision(
        {
          0: [seenAt(body, face: 0)],
        },
        {
          1: [seenAt(body, face: 0)],
        },
      );
      final event = ClipRequested(clip(), id: 'new');
      await recognizer(vision, FakeSampler(1)).recognize(event);
      expect(event.annotations.isEmpty, isTrue);
      expect(vision.calls, 0, reason: 'nothing to compare with');
    });

    test('off in Settings, or unsupported: nothing runs', () async {
      log.addHistory([
        tagged(1, ['Rex']),
      ]);
      final vision = FakeVision({}, {});
      config.update(
        (c) => c.copyWith(
          recognition: c.recognition.copyWith(enabled: false, objects: false),
        ),
      );
      final event = ClipRequested(clip(), id: 'new');
      await recognizer(vision, FakeSampler(1)).recognize(event);
      expect(vision.calls + vision.frameCalls, 0);
      expect(event.annotations.objects, isNull);
      expect(event.annotations.subjectSearch, isNull);
    });

    test('object tags: each label once, from its first frame', () async {
      // Nobody tagged before: only the object tags' segment runs.
      final vision = FakeVision(
        {},
        {},
        objects: {
          0: {'human': 0.7},
          1: {'cat': 0.6, 'human': 0.9},
          // A bottle on one frame, unsure: more often a mistake.
          2: {'bottle': 0.55},
          // A bicycle on one frame, but sure.
          3: {'bicycle': 0.8, 'cat': 0.95},
        },
      );
      final r = recognizer(vision, FakeSampler(4));
      final event = ClipRequested(clip(), id: 'new');
      final result = await r.recognize(event);
      expect(result.outcome, RecognitionOutcome.noReferences);
      expect(result.objects, ['human', 'cat', 'bicycle']);
      // Where each was first seen, with its best score.
      expect(event.annotations.objects, const [
        ObjectTag(label: 'human', ms: 1000, score: 0.9),
        ObjectTag(label: 'cat', ms: 2000, score: 0.95),
        ObjectTag(label: 'bicycle', ms: 4000, score: 0.8),
      ]);
      expect(vision.frameCalls, 4, reason: 'the whole clip');
      expect(vision.calls, 0, reason: 'nobody to embed');
      expect(event.annotations.isEmpty, isTrue, reason: 'no subject tags');

      // Searched once: not again, not even on request.
      await r.recognize(event);
      final again = await r.recognizeNow(event);
      expect(again.objects, isEmpty);
      expect(vision.frameCalls, 4);
      // Unless asked to run it all again (the recognition indicator).
      final rerun = await r.recognizeNow(event, again: true);
      expect(rerun.objects, ['human', 'cat', 'bicycle']);
      expect(vision.frameCalls, 8);
      expect(event.annotations.objects, hasLength(3));
    });

    test('object tags keep going once every subject is found', () async {
      const body = Box(0.3, 0.2, 0.7, 1);
      log.addHistory([
        tagged(1, ['Rex']),
      ]);
      final vision = FakeVision(
        {
          for (var i = 0; i < 3; i++) i: [seenAt(body, face: angleFor(0.9))],
        },
        {
          1: [seenAt(body, face: 0)],
        },
        objects: {
          4: {'dog': 0.8},
        },
      );
      final event = ClipRequested(clip(), id: 'new');
      final result = await recognizer(vision, FakeSampler(5)).recognize(event);
      expect(result.tagged, ['Rex']);
      expect(result.objects, ['dog']);
      // One reference, then subjects until Rex is sure (his face, at once).
      expect(vision.calls, 2);
      expect(vision.frameCalls, 5);
    });

    test('a one-frame clip keeps what it saw', () async {
      final vision = FakeVision(
        {},
        {},
        objects: {
          0: {'bottle': 0.55},
        },
      );
      final event = ClipRequested(clip(), id: 'new');
      final result = await recognizer(vision, FakeSampler(1)).recognize(event);
      expect(result.objects, ['bottle']);
    });

    test('object tags off: subjects only, and nothing stored', () async {
      config.update(
        (c) => c.copyWith(recognition: c.recognition.copyWith(objects: false)),
      );
      final vision = FakeVision(
        {},
        {},
        objects: {
          0: {'cat': 0.9},
        },
      );
      final event = ClipRequested(clip(), id: 'new');
      final result = await recognizer(vision, FakeSampler(2)).recognize(event);
      expect(result.outcome, RecognitionOutcome.noReferences);
      expect(vision.frameCalls, 0);
      expect(event.annotations.objects, isNull);
    });

    /// A new clip as the camera publishes it: [full] completes once its
    /// "after" part is recorded.
    ClipRequested recording(Completer<ClipMedia?> full) => ClipRequested(
      VideoClip(
        cameraId: 'cam',
        cameraLabel: 'Back camera',
        before: const Duration(seconds: 15),
        after: const Duration(seconds: 15),
        capture: ClipCapture(past: Future.value(), full: full.future),
      ),
      id: 'new',
    );

    final media = ClipMedia(
      url: 'blob:new',
      start: Duration.zero,
      end: const Duration(seconds: 30),
    );

    test('a new clip is searched once fully recorded, not before', () async {
      const body = Box(0.3, 0.2, 0.7, 1);
      log.addHistory([
        tagged(1, ['Rex']),
      ]);
      final vision = FakeVision(
        {
          // Rex surely on the second frame and every one after.
          1: [seenAt(body, face: angleFor(0.9))],
          2: [seenAt(body, face: angleFor(0.9))],
        },
        {
          1: [seenAt(body, face: 0)],
        },
      );
      final r = recognizer(vision, FakeSampler(3));
      final full = Completer<ClipMedia?>();
      final event = recording(full);
      bus.publish(event);
      await pumpEventQueue();
      expect(vision.calls, 0, reason: 'still recording');

      // Auto on another clip isn't held up by the one recording.
      final other = await r.recognizeNow(ClipRequested(clip(), id: 'other'));
      expect(other.tagged, ['Rex']);

      full.complete(media);
      await pumpEventQueue();
      await r.idle;
      final rex = event.annotations.items.single;
      expect(rex.name, 'Rex');
      expect(rex.source, TagSource.detected);
      // The first frame Rex is on, and none after.
      expect(event.annotations.frames[rex.frameId]!.ms, 2000);
      expect(event.annotations.frames, hasLength(1));
    });

    test('a new clip searched on request is not searched again', () async {
      log.addHistory([
        tagged(1, ['Rex']),
      ]);
      // Nobody on the clip, so only the "searched" mark stops a second run.
      final vision = FakeVision({}, {
        1: [seenAt(const Box(0.3, 0.2, 0.7, 1), face: 0)],
      });
      final r = recognizer(vision, FakeSampler(3));
      final full = Completer<ClipMedia?>();
      final event = recording(full);
      bus.publish(event);
      final asked = r.recognizeNow(event);
      await pumpEventQueue();
      full.complete(media);
      expect((await asked).outcome, RecognitionOutcome.searched);
      await pumpEventQueue();
      await r.idle;
      // One reference, then three frames, once.
      expect(vision.calls, 4);
      expect(event.annotations.isEmpty, isTrue);
    });

    test('on request it runs even when off, and says what it found', () async {
      const body = Box(0.3, 0.2, 0.7, 1);
      const other = Box(0.75, 0.2, 0.95, 1);
      log.addHistory([
        tagged(1, ['Rex']),
        tagged(2, ['Ana']),
      ]);
      config.update(
        (c) => c.copyWith(recognition: c.recognition.copyWith(enabled: false)),
      );
      final vision = FakeVision(
        {
          0: [
            seenAt(body, face: angleFor(0.9)),
            seenAt(other, face: 100 + angleFor(faceCos(0.6))),
          ],
        },
        {
          1: [seenAt(body, face: 0)],
          2: [seenAt(body, face: 100)],
        },
      );
      final r = recognizer(vision, FakeSampler(2));
      final event = ClipRequested(clip(), id: 'new');
      final result = await r.recognizeNow(event);
      expect(result.outcome, RecognitionOutcome.searched);
      expect(
        event.annotations.subjectSearch?.outcome,
        SubjectSearchOutcome.searched,
      );
      expect(result.tagged, ['Rex']);
      expect(result.asked, ['Ana']);
      expect(event.annotations.tags.single.source, TagSource.detected);
      expect(autoTagMessage(result), contains('Found Rex.'));
      expect(autoTagMessage(result), contains('"Is this Ana?"'));

      // Again: everyone known is on the clip now (Ana as a suggestion).
      final again = await r.recognizeNow(event);
      expect(again.outcome, RecognitionOutcome.allTagged);
      expect(
        event.annotations.subjectSearch?.outcome,
        SubjectSearchOutcome.allTagged,
      );
      expect(event.annotations.items, hasLength(2));
    });

    test('on request: nobody to look for, or nobody found', () async {
      final vision = FakeVision({}, {});
      final r = recognizer(vision, FakeSampler(2));
      final a = ClipRequested(clip(), id: 'a');
      final noOne = await r.recognizeNow(a);
      expect(noOne.outcome, RecognitionOutcome.noReferences);
      // Searched, as far as there's anyone to look for: noted, so it reads
      // as searched, not as never searched.
      expect(
        a.annotations.subjectSearch?.outcome,
        SubjectSearchOutcome.noReferences,
      );
      expect(autoTagMessage(noOne), contains('name someone'));

      log.addHistory([
        tagged(1, ['Rex']),
      ]);
      // Rex's tag points at nobody: still no one to look for.
      expect(
        (await r.recognizeNow(ClipRequested(clip(), id: 'b'))).outcome,
        RecognitionOutcome.noReferences,
      );

      vision.references[2] = [seenAt(const Box(0.3, 0.2, 0.7, 1), face: 0)];
      log.addHistory([
        tagged(2, ['Rex']),
      ]);
      final c = ClipRequested(clip(), id: 'c');
      final none = await r.recognizeNow(c);
      expect(none.outcome, RecognitionOutcome.searched);
      // Searched, no one found: noted, and no tags.
      expect(
        c.annotations.subjectSearch?.outcome,
        SubjectSearchOutcome.searched,
      );
      expect(c.annotations.tags, isEmpty);
      expect(autoTagMessage(none), 'No subjects recognized.');
    });

    test('a failed run on request leaves the queue working', () async {
      log.addHistory([
        tagged(1, ['Rex']),
      ]);
      var loads = 0;
      final vision = FakeVision({}, {
        1: [seenAt(const Box(0.3, 0.2, 0.7, 1), face: 0)],
      });
      final r = SubjectRecognizer(
        bus: bus,
        log: log,
        config: config,
        runtime: FakeRuntime(),
        sampler: FakeSampler(1),
        loadVision: () async {
          if (loads++ == 0) throw StateError('no models');
          return vision;
        },
        decode: (jpeg) async {
          final width = 1000 + jpeg.first;
          return RgbaImage(width, 1, Uint8List(width * 4));
        },
      );
      await expectLater(
        r.recognizeNow(ClipRequested(clip(), id: 'a')),
        throwsStateError,
      );
      final result = await r.recognizeNow(ClipRequested(clip(), id: 'b'));
      expect(result.outcome, RecognitionOutcome.searched);
    });

    test('only the kinds known are embedded, five a frame at most', () async {
      log.addHistory([
        tagged(1, ['Rex']),
      ]);
      final vision = FakeVision({}, {
        1: [seenAt(const Box(0.3, 0.2, 0.7, 1), face: 0)],
      });
      await recognizer(
        vision,
        FakeSampler(1),
      ).recognize(ClipRequested(clip(), id: 'a'));
      expect(vision.kinds, {SeenKind.person});
      expect(vision.maxSeen, SubjectRecognizer.maxSeenPerFrame);

      // A dog known: pets are looked at too (a cat may be taken for one).
      log.addHistory([
        tagged(2, ['Fido']),
      ]);
      vision.references[2] = [
        seenAt(const Box(0.3, 0.2, 0.7, 1), kind: SeenKind.dog),
      ];
      await recognizer(
        vision,
        FakeSampler(1),
      ).recognize(ClipRequested(clip(), id: 'b'));
      expect(vision.kinds, SeenKind.values.toSet());
    });

    /// A new clip, already fully recorded, as the camera publishes it.
    ClipRequested recorded(String id) => ClipRequested(
      VideoClip(
        cameraId: 'cam',
        cameraLabel: 'Back camera',
        before: const Duration(seconds: 15),
        after: const Duration(seconds: 15),
        capture: ClipCapture(
          past: Future.value(),
          full: Future.value(
            ClipMedia(
              url: 'blob:$id',
              start: Duration.zero,
              end: const Duration(seconds: 30),
            ),
          ),
        ),
      ),
      id: id,
    );

    test('only the latest new clips wait their turn', () async {
      const body = Box(0.3, 0.2, 0.7, 1);
      log.addHistory([
        tagged(1, ['Rex']),
      ]);
      final vision = _GatedVision(
        {
          0: [seenAt(body, face: angleFor(0.9))],
        },
        {
          1: [seenAt(body, face: 0)],
        },
      );
      final sampler = FakeSampler(1);
      final r = recognizer(vision, sampler);
      final clips = [for (var i = 0; i < 6; i++) recorded('c$i')];
      clips.forEach(bus.publish);
      await pumpEventQueue();
      // c0 is being searched; c1 to c5 wait, but only the latest three.
      expect(sampler.samples, 1);
      vision.gate.complete();
      await pumpEventQueue();
      await r.idle;
      expect(sampler.samples, 1 + r.maxPending);
      expect(
        [for (final c in clips) c.annotations.tags.length],
        [1, 0, 0, 1, 1, 1],
      );
      // Asked for, a clip isn't dropped however many wait.
      final asked = await r.recognizeNow(recorded('asked'));
      expect(asked.outcome, RecognitionOutcome.searched);
    });

    test('low on memory: Auto is put off, the models freed', () async {
      log.addHistory([
        tagged(1, ['Rex']),
      ]);
      final vision = FakeVision({}, {
        1: [seenAt(const Box(0.3, 0.2, 0.7, 1), face: 0)],
      });
      final memory = FakeMemory();
      final r = SubjectRecognizer(
        bus: bus,
        log: log,
        config: config,
        runtime: FakeRuntime(),
        sampler: FakeSampler(2),
        loadVision: () async => vision,
        decode: (jpeg) async => RgbaImage(1001, 1, Uint8List(1001 * 4)),
        memory: memory,
      );
      final first = await r.recognizeNow(ClipRequested(clip(), id: 'a'));
      expect(first.outcome, RecognitionOutcome.searched);
      expect(vision.releases, 0);

      memory.tight = 1 << 30;
      final b = ClipRequested(clip(), id: 'b');
      final put = await r.recognizeNow(b);
      expect(put.outcome, RecognitionOutcome.deferred);
      // Not run: nothing noted.
      expect(b.annotations.subjectSearch, isNull);
      expect(autoTagMessage(put), contains('low on memory'));
      await pumpEventQueue();
      expect(vision.releases, greaterThan(0));
      expect(vision.frameCalls, 2, reason: 'only the first clip');
    });

    test('low on memory: a new clip waits until there is room', () async {
      const body = Box(0.3, 0.2, 0.7, 1);
      log.addHistory([
        tagged(1, ['Rex']),
      ]);
      final vision = FakeVision(
        {
          0: [seenAt(body, face: angleFor(0.9))],
        },
        {
          1: [seenAt(body, face: 0)],
        },
      );
      SubjectRecognizer withMemory(FakeMemory memory, int retries) =>
          SubjectRecognizer(
            bus: bus,
            log: log,
            config: config,
            runtime: FakeRuntime(),
            sampler: FakeSampler(1),
            loadVision: () async => vision,
            decode: (jpeg) async => RgbaImage(1001, 1, Uint8List(1001 * 4)),
            memory: memory,
            memoryRetryAfter: const Duration(milliseconds: 1),
            memoryRetries: retries,
          );

      // Tight for three reads, then not: searched after waiting.
      final waits = FakeMemory()..tight = 3;
      final r = withMemory(waits, 10);
      final clip1 = recorded('waits');
      bus.publish(clip1);
      await pumpEventQueue();
      await r.idle;
      expect(waits.reads, greaterThanOrEqualTo(4));
      expect(clip1.annotations.tags.single.name, 'Rex');
      r.dispose();

      // Always tight: given up on after the retries.
      final full = FakeMemory()..tight = 1 << 30;
      final r2 = withMemory(full, 2);
      final clip2 = recorded('gives up');
      bus.publish(clip2);
      await pumpEventQueue();
      await r2.idle;
      expect(full.reads, 3 + 1, reason: 'three tries, then after the run');
      expect(clip2.annotations.isEmpty, isTrue);
      r2.dispose();
    });

    test('low on memory: a waiting new clip doesn\'t hold up Auto', () async {
      const body = Box(0.3, 0.2, 0.7, 1);
      log.addHistory([
        tagged(1, ['Rex']),
      ]);
      final vision = FakeVision(
        {
          0: [seenAt(body, face: angleFor(0.9))],
        },
        {
          1: [seenAt(body, face: 0)],
        },
      );
      // Tight for the new clip's first read only; it then waits an hour
      // out of the queue.
      final memory = FakeMemory()..tight = 1;
      final r = SubjectRecognizer(
        bus: bus,
        log: log,
        config: config,
        runtime: FakeRuntime(),
        sampler: FakeSampler(1),
        loadVision: () async => vision,
        decode: (jpeg) async => RgbaImage(1001, 1, Uint8List(1001 * 4)),
        memory: memory,
        memoryRetryAfter: const Duration(hours: 1),
      );
      final waiting = recorded('waiting');
      bus.publish(waiting);
      await pumpEventQueue();
      expect(memory.reads, 1);

      final asked = recorded('asked');
      final result = await r
          .recognizeNow(asked)
          .timeout(const Duration(seconds: 5));
      expect(result.outcome, RecognitionOutcome.searched);
      expect(asked.annotations.tags.single.name, 'Rex');
      expect(waiting.annotations.isEmpty, isTrue, reason: 'still waiting');
      r.dispose();
      await r.idle;
    });

    test('Auto goes ahead of new clips waiting their turn', () async {
      log.addHistory([
        tagged(1, ['Rex']),
      ]);
      final vision = FakeVision({}, {
        1: [seenAt(const Box(0.3, 0.2, 0.7, 1), face: 0)],
      });
      final order = <String>[];
      final gate = Completer<void>();
      final r = SubjectRecognizer(
        bus: bus,
        log: log,
        config: config,
        runtime: FakeRuntime(),
        sampler: FakeSampler(
          1,
          onSample: (media) async {
            order.add(media.liveUrl!);
            // The first clip holds the queue until Auto is asked.
            if (order.length == 1) await gate.future;
          },
        ),
        loadVision: () async => vision,
        decode: (jpeg) async => RgbaImage(1001, 1, Uint8List(1001 * 4)),
      );
      for (final id in ['new1', 'new2', 'new3']) {
        bus.publish(recorded(id));
      }
      await pumpEventQueue();
      expect(order, ['blob:new1']);
      final asked = r.recognizeNow(recorded('asked'));
      gate.complete();
      await asked;
      await r.idle;
      expect(order.first, 'blob:new1', reason: 'already running');
      expect(order[1], 'blob:asked');
      r.dispose();
    });

    test('memory is tight under the threshold plus what recognition needs', () {
      const mb = 1 << 20;
      MemoryStatus status(int available, {bool low = false}) => MemoryStatus(
        lowMemory: low,
        availableBytes: available * mb,
        thresholdBytes: 100 * mb,
      );
      expect(status(400).tight, isFalse);
      expect(status(150).tight, isTrue);
      expect(status(400, low: true).tight, isTrue);
      final read = MemoryStatus.fromMap({
        'lowMemory': false,
        'availMem': 300 * mb,
        'threshold': 100 * mb,
        'totalMem': 3000 * mb,
        'lowRamDevice': true,
      })!;
      expect(read.availableBytes, 300 * mb);
      expect(read.lowRamDevice, isTrue);
      expect(read.tight, isFalse);
      expect(MemoryStatus.fromMap(null), isNull);
    });

    group('with cloud recognition', () {
      const body = Box(0.3, 0.2, 0.7, 1);

      SubjectRecognizer withCloud(
        FakeVision vision,
        FakeSampler sampler,
        _FakeCloud? cloud, {
        _FakeDescriber? describer,
      }) => SubjectRecognizer(
        bus: bus,
        log: log,
        config: config,
        runtime: FakeRuntime(),
        sampler: sampler,
        loadVision: () async => vision,
        cloud: cloud,
        describer: describer,
        decode: (jpeg) async {
          final width = 1000 + jpeg.first;
          return RgbaImage(width, 1, Uint8List(width * 4));
        },
      );

      test(
        'the cloud, surer than the device, tags where it saw them',
        () async {
          log.addHistory([
            tagged(1, ['Rex']),
          ]);
          final vision = FakeVision(
            {
              // Rex's look, far from his reference: unsure on the device.
              1: [seenAt(body, look: 80)],
            },
            {
              1: [seenAt(body, look: 0)],
            },
          );
          final cloud = _FakeCloud({
            '0': const [CloudMatch('Rex', 0.97)],
          });
          final event = ClipRequested(clip(), id: 'new');
          final result = await withCloud(
            vision,
            FakeSampler(3),
            cloud,
          ).recognize(event);

          expect(cloud.asked.single.keys, ['0']);
          final (kind, pixels) = cloud.asked.single['0']!;
          expect(kind, 'person');
          expect(pixels, hasLength(CloudCrop.side * CloudCrop.side * 3));
          final rex = event.annotations.tags.single;
          expect(rex.name, 'Rex');
          expect(rex.source, TagSource.detected);
          expect(rex.confidence, closeTo(0.97, 1e-9));
          expect(rex.x, closeTo(body.cx, 1e-9));
          expect(event.annotations.frames[rex.frameId]!.ms, 2000);
          expect(
            rex.labeledAt,
            isNull,
            reason: 'recognition\'s tag, not a label',
          );
          expect(result.tagged, ['Rex']);
        },
      );

      test('asks about someone only the cloud knows, when unsure', () async {
        log.addHistory([
          tagged(1, ['Rex']),
        ]);
        final vision = FakeVision(
          {
            0: [seenAt(body, look: 90)],
          },
          {
            1: [seenAt(body, look: 0)],
          },
        );
        final cloud = _FakeCloud({
          '0': const [CloudMatch('Ana', 0.7), CloudMatch('Rex', 0.1)],
        });
        final event = ClipRequested(clip(), id: 'new');
        final result = await withCloud(
          vision,
          FakeSampler(2),
          cloud,
        ).recognize(event);
        expect(result.asked, ['Ana']);
        final ana = event.annotations.items.single;
        expect(ana.source, TagSource.suggested);
        expect(ana.confidence, closeTo(0.7, 1e-9));
        await Future<void>.delayed(Duration.zero);
        expect(
          published.whereType<SubjectSuggestion>().single.subjectName,
          'Ana',
        );
      });

      test(
        'sends a new clip\'s 2 surest crops to identify, Auto\'s 4',
        () async {
          log.addHistory([
            tagged(1, ['Rex']),
          ]);
          Seen at(double x, double score) => Seen(
            Detection(Box(x, 0.2, x + 0.1, 1), score, SeenKind.person),
            lookVector: direction(90),
          );
          // Surer on each frame: the last frames' are the ones sent.
          final vision = FakeVision(
            {
              for (var i = 0; i < 6; i++)
                i: [at(0, 0.1 * i + 0.1), at(0.2, 0.1 * i + 0.15), at(0.4, 0)],
            },
            {
              1: [seenAt(body, look: 0)],
            },
          );
          final cloud = _FakeCloud({});
          await withCloud(
            vision,
            FakeSampler(6),
            cloud,
          ).recognize(ClipRequested(clip(), id: 'new'));
          expect(SubjectRecognizer.maxIdentifyCrops, 2);
          expect(cloud.asked.single.keys.toSet(), {
            '10',
            '11',
          }, reason: 'the last frame\'s two, 2 a frame');

          final asked = _FakeCloud({});
          await withCloud(
            vision,
            FakeSampler(6),
            asked,
          ).recognize(ClipRequested(clip(), id: 'auto'), onRequest: true);
          expect(asked.asked.single.keys.toSet(), {
            '8',
            '9',
            '10',
            '11',
          }, reason: 'Auto, asked for, sends up to 4');
        },
      );

      test('not asked when nobody is seen on the clip', () async {
        log.addHistory([
          tagged(1, ['Rex']),
        ]);
        final vision = FakeVision(const {}, {
          1: [seenAt(body, look: 0)],
        });
        final cloud = _FakeCloud({});
        await withCloud(
          vision,
          FakeSampler(3),
          cloud,
        ).recognize(ClipRequested(clip(), id: 'new'));
        expect(cloud.asked, isEmpty);
      });

      test('not asked when the cloud isn\'t available', () async {
        log.addHistory([
          tagged(1, ['Rex']),
        ]);
        final vision = FakeVision(
          {
            0: [seenAt(body, look: 80)],
          },
          {
            1: [seenAt(body, look: 0)],
          },
        );
        final cloud = _FakeCloud({}, available: false);
        final sampler = FakeSampler(2);
        await withCloud(
          vision,
          sampler,
          cloud,
        ).recognize(ClipRequested(clip(), id: 'new'));
        expect(cloud.asked, isEmpty);
      });

      group('breeds and coats', () {
        const left = Box(0, 0.2, 0.4, 1);
        const right = Box(0.5, 0.2, 0.9, 1);
        Set<String> labels(ClipRequested e) => {
          for (final o in e.annotations.objects ?? const <ObjectTag>[]) o.label,
        };

        test('join the object tags, with no subject known', () async {
          final vision = FakeVision(
            const {},
            const {},
            objects: {
              0: {'cat': 0.9},
              1: {'cat': 0.9},
            },
            pets: {
              0: [const Detection(left, 0.9, SeenKind.cat)],
              1: [
                const Detection(left, 0.9, SeenKind.cat),
                const Detection(right, 0.8, SeenKind.dog),
              ],
            },
          );
          final describer = _FakeDescriber({
            '0': const [
              CloudPetLabel('Persian', 'breed', 0.8),
              CloudPetLabel('black cat', 'coat', 0.9),
            ],
            '1': const [CloudPetLabel('black cat', 'coat', 0.95)],
            '2': const [CloudPetLabel('Beagle', 'breed', 0.85)],
          });
          final event = ClipRequested(clip(), id: 'new');
          final r = withCloud(
            vision,
            FakeSampler(2),
            null,
            describer: describer,
          );
          final result = await r.recognize(event);
          await r.described;
          expect(result.objects, ['cat'], reason: 'the device\'s own');
          final asked = describer.asked.single;
          expect(asked.keys, ['0', '1', '2']);
          expect(
            [for (final (species, _) in asked.values) species],
            ['cat', 'cat', 'dog'],
          );
          expect(
            asked['0']!.$2,
            hasLength(CloudCrop.side * CloudCrop.side * 3),
          );
          expect(labels(event), {'cat', 'Persian', 'black cat', 'Beagle'});
          final black = event.annotations.objects!.firstWhere(
            (o) => o.label == 'black cat',
          );
          expect(black.score, 0.95, reason: 'its surest crop');
          expect(black.ms, 2000, reason: 'where it was surest (frame 1)');
        });

        test(
          'neither the subjects nor the breeds wait for the other',
          () async {
            log.addHistory([
              tagged(1, ['Rex']),
            ]);
            final vision = FakeVision(
              {
                0: [seenAt(body, look: 0, kind: SeenKind.dog)],
              },
              {
                1: [seenAt(body, look: 0, kind: SeenKind.dog)],
              },
              objects: {
                0: {'dog': 0.9},
              },
              pets: {
                0: [const Detection(body, 0.9, SeenKind.dog)],
              },
            );
            // The breeds answer late: the subjects are done first.
            var describeGate = Completer<void>();
            var describer = _FakeDescriber({
              '0': const [CloudPetLabel('Beagle', 'breed', 0.9)],
            }, gate: describeGate);
            var event = ClipRequested(clip(), id: 'new');
            var r = withCloud(
              vision,
              FakeSampler(1),
              _FakeCloud({
                '0': const [CloudMatch('Rex', 0.97)],
              }),
              describer: describer,
            );
            final result = await r.recognize(event);
            expect(result.tagged, ['Rex']);
            expect(labels(event), {'dog'});
            describeGate.complete();
            await r.described;
            expect(labels(event), {'dog', 'Beagle'});
            expect(event.annotations.tags.single.name, 'Rex');

            // The subjects answer late: the breeds are in first.
            final identifyGate = Completer<void>();
            describer = _FakeDescriber({
              '0': const [CloudPetLabel('Beagle', 'breed', 0.9)],
            });
            event = ClipRequested(clip(), id: 'new-2');
            r = withCloud(
              vision,
              FakeSampler(1),
              _FakeCloud({
                '0': const [CloudMatch('Rex', 0.97)],
              }, gate: identifyGate),
              describer: describer,
            );
            final searching = r.recognize(event);
            await pumpEventQueue();
            await r.described;
            expect(labels(event), {'dog', 'Beagle'});
            expect(event.annotations.tags, isEmpty);
            identifyGate.complete();
            await searching;
            expect(event.annotations.tags.single.name, 'Rex');
            expect(labels(event), {'dog', 'Beagle'}, reason: 'kept');
          },
        );

        test('asked for (recognizeNow), it waits for the breeds and coats: '
            'their labels in the result, or that the cloud failed', () async {
          final vision = FakeVision(
            const {},
            const {},
            objects: {
              0: {'cat': 0.9},
            },
            pets: {
              0: [const Detection(body, 0.9, SeenKind.cat)],
            },
          );
          final gate = Completer<void>();
          final describer = _FakeDescriber({
            '0': const [CloudPetLabel('black cat', 'coat', 0.9)],
          }, gate: gate);
          final event = ClipRequested(clip(), id: 'asked');
          final r = withCloud(
            vision,
            FakeSampler(1),
            null,
            describer: describer,
          );
          var done = false;
          final asking = r.recognizeNow(event).whenComplete(() => done = true);
          await pumpEventQueue();
          expect(done, isFalse, reason: 'the server is still answering');
          gate.complete();
          final result = await asking;
          expect(result.objects, ['cat', 'black cat']);
          expect(result.cloudFailed, isFalse);

          final failing = withCloud(
            vision,
            FakeSampler(1),
            null,
            describer: _FakeDescriber(const {}, fail: true),
          );
          final failed = await failing.recognizeNow(
            ClipRequested(clip(), id: 'asked-2'),
          );
          expect(failed.cloudFailed, isTrue);
          expect(failed.objects, ['cat']);
          expect(autoTagMessage(failed), contains("Cloud recognition didn't"));
        });

        test('not asked unless premium, or with object tags off', () async {
          final vision = FakeVision(
            const {},
            const {},
            objects: {
              0: {'cat': 0.9},
            },
            pets: {
              0: [const Detection(left, 0.9, SeenKind.cat)],
            },
          );
          final notPremium = _FakeDescriber({}, available: false);
          await withCloud(
            vision,
            FakeSampler(1),
            null,
            describer: notPremium,
          ).recognize(ClipRequested(clip(), id: 'a'));
          expect(notPremium.asked, isEmpty);
          config.update(
            (c) =>
                c.copyWith(recognition: c.recognition.copyWith(objects: false)),
          );
          final premium = _FakeDescriber({});
          await withCloud(
            vision,
            FakeSampler(1),
            null,
            describer: premium,
          ).recognize(ClipRequested(clip(), id: 'b'));
          expect(premium.asked, isEmpty);
        });

        test('a new clip\'s 4 surest pets, Auto\'s 8, and a failure changes '
            'nothing', () async {
          final vision = FakeVision(
            const {},
            const {},
            pets: {
              for (var i = 0; i < 6; i++)
                i: [
                  const Detection(left, 0.9, SeenKind.cat),
                  const Detection(right, 0.8, SeenKind.cat),
                  const Detection(right, 0.7, SeenKind.dog),
                ],
            },
          );
          final describer = _FakeDescriber({});
          final event = ClipRequested(clip(), id: 'new');
          final r = withCloud(
            vision,
            FakeSampler(6),
            null,
            describer: describer,
          );
          await r.recognize(event);
          await r.described;
          expect(describer.asked.single, hasLength(4));
          expect([
            for (final (species, _) in describer.asked.single.values) species,
          ], everyElement('cat'));
          expect(event.annotations.objects, isEmpty);
          await r.recognize(ClipRequested(clip(), id: 'auto'), onRequest: true);
          await r.described;
          expect(describer.asked.last, hasLength(8));
        });
      });

      test(
        'a label\'s crop for training: whom it points at, and its sort',
        () async {
          final old = tagged(1, ['Kitty']);
          final vision = FakeVision(const {}, {
            1: [seenAt(body, kind: SeenKind.cat)],
            2: [seenAt(const Box(0, 0, 0.1, 0.1))],
          });
          final r = withCloud(vision, FakeSampler(1), _FakeCloud({}));
          final crop = await r.cloudCrop(old, old.annotations.tags.single);
          expect(crop!.$1, 'pet');
          expect(crop.$2, hasLength(CloudCrop.side * CloudCrop.side * 3));
          // Nobody where the label points.
          final empty = tagged(2, ['Kitty']);
          expect(
            await r.cloudCrop(empty, empty.annotations.tags.single),
            isNull,
          );
        },
      );
    });
  });

  testWidgets("the player's Auto tags who it recognizes", (tester) async {
    final bus = AppEventBus();
    final log = EventLog(bus.stream);
    final a = ClipAnnotations();
    final frame = TagFrame(
      id: 'ref-1',
      sealed: sealed(Uint8List.fromList([1])),
      ms: 0,
    );
    a.add('Rex', 0.5, 0.5, frame: frame);
    log.addHistory([ClipRequested(clip(), annotations: a, id: 'old')]);
    const body = Box(0.3, 0.2, 0.7, 1);
    final recognizer = SubjectRecognizer(
      bus: bus,
      log: log,
      config: ConfigController(),
      runtime: FakeRuntime(),
      sampler: FakeSampler(1),
      loadVision: () async => FakeVision(
        {
          0: [seenAt(body, face: angleFor(0.9))],
        },
        {
          1: [seenAt(body, face: 0)],
        },
        objects: {
          0: {'cat': 0.9},
        },
      ),
      decode: (jpeg) async => RgbaImage(1001, 1, Uint8List(1001 * 4)),
    );
    final event = ClipRequested(clip(), id: 'new');
    await tester.pumpWidget(
      SubjectRecognizerScope(
        recognizer: recognizer,
        child: MaterialApp(
          home: Scaffold(body: ClipPlayerDialog(event: event)),
        ),
      ),
    );
    final auto = find.byKey(const Key('auto-tag'));
    expect(auto, findsOneWidget);
    await tester.tap(auto);
    for (var i = 0; i < 20; i++) {
      // Recognition yields to the app between frames.
      await tester.pump(const Duration(milliseconds: 1));
    }
    expect(find.text('Found Rex. Tags: cat.'), findsOneWidget);
    expect(find.textContaining('Rex · 100 %'), findsOneWidget);
    expect(event.annotations.tags.single.source, TagSource.detected);
    expect(event.annotations.objects!.single.label, 'cat');
  });

  testWidgets("the clip's card shows its first subject's frame, named where "
      'they were tagged; without one, the clip\'s thumbnail', (tester) async {
    final event = ClipRequested(clip(), id: 'c');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ClipEventCard(event: event)),
      ),
    );
    expect(find.byKey(const Key('clip-card-subject-frame')), findsNothing);
    final later = testFrame(onePixelPng, 9000);
    final earlier = testFrame(onePixelPng, 2000);
    event.annotations
      ..add('Bo', 0.6, 0.6, frame: later)
      ..add('Suerte', 0.3, 0.7, frame: earlier)
      // A suggestion isn't a subject yet.
      ..add(
        'Ana',
        0.5,
        0.5,
        frame: testFrame(onePixelPng, 100),
        source: TagSource.suggested,
      );
    await tester.pump();
    expect(find.byKey(const Key('clip-card-subject-frame')), findsOneWidget);
    final thumb = find.byKey(const Key('clip-card-thumbnail'));
    // The first seen (2 s), not the first tagged, nor the suggestion.
    expect(
      find.descendant(of: thumb, matching: find.text('Suerte')),
      findsOneWidget,
    );
    expect(find.descendant(of: thumb, matching: find.text('Bo')), findsNothing);
    expect(
      find.descendant(of: thumb, matching: find.text('Ana')),
      findsNothing,
    );
    final suerte = event.annotations.tags.firstWhere((t) => t.name == 'Suerte');
    expect(
      find.byKey(Key('marker-${suerte.id}')),
      findsOneWidget,
      reason: 'a dot where she was tagged',
    );
  });

  testWidgets("the clip's card shows its object tags", (tester) async {
    final event = ClipRequested(clip(), id: 'c');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ClipEventCard(event: event)),
      ),
    );
    expect(find.byKey(const Key('clip-objects')), findsNothing);
    event.annotations.setObjects(const [
      ObjectTag(label: 'human', ms: 0, score: 0.9),
      ObjectTag(label: 'bicycle', ms: 500, score: 0.7),
    ]);
    await tester.pump();
    expect(find.byKey(const Key('clip-object-human')), findsOneWidget);
    expect(find.byKey(const Key('clip-object-bicycle')), findsOneWidget);
    expect(find.text('bicycle'), findsOneWidget);
  });

  testWidgets("a card's labels open the player paused where they were seen", (
    tester,
  ) async {
    final event = ClipRequested(clip(), id: 'c');
    final a = event.annotations;
    a.add('Rex', 0.5, 0.5, frame: testFrame(onePixelPng, 4000));
    a.add('rex', 0.2, 0.2, frame: testFrame(onePixelPng, 1500));
    a.add('Ana', 0.1, 0.1);
    a.setObjects(const [ObjectTag(label: 'bicycle', ms: 2500, score: 0.7)]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ClipEventCard(event: event)),
      ),
    );
    Future<Duration?> openedAt(String key) async {
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      final player = tester.widget<ClipPlayerDialog>(
        find.byType(ClipPlayerDialog),
      );
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      return player.startAt;
    }

    // An object tag: where it was first seen.
    expect(
      await openedAt('clip-object-bicycle'),
      const Duration(seconds: 2, milliseconds: 500),
    );
    // A subject: their earliest tagged frame.
    expect(
      await openedAt('event-subject-rex'),
      const Duration(milliseconds: 1500),
    );
    // A tag without a frame: from the start, playing.
    expect(await openedAt('event-subject-ana'), isNull);
    expect(find.byTooltip('Show at 0:02.5'), findsOneWidget);
  });

  test('the player opens inside the clip window', () {
    final media = ClipMedia(
      url: 'blob:x',
      start: const Duration(seconds: 2),
      end: const Duration(seconds: 10),
    );
    expect(startPosition(media, null), const Duration(seconds: 2));
    expect(startPosition(media, Duration.zero), const Duration(seconds: 2));
    expect(
      startPosition(media, const Duration(seconds: 5)),
      const Duration(seconds: 5),
    );
    expect(
      startPosition(media, const Duration(seconds: 30)),
      const Duration(seconds: 10),
    );
  });

  for (final width in [320.0]) {
    testWidgets('the player shows Subjects and Tags apart at $width dp', (
      tester,
    ) async {
      tester.view
        ..physicalSize = Size(width, 1400)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final event = ClipRequested(clip(), id: 'c');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ClipPlayerDialog(event: event)),
        ),
      );
      expect(find.text('Subjects'), findsOneWidget);
      expect(find.text('Tags'), findsOneWidget);
      expect(find.text('Name subject'), findsOneWidget);
      expect(find.textContaining('No subjects yet'), findsOneWidget);
      expect(find.textContaining('No tags yet'), findsOneWidget);
      // Tags come after the subjects, under a divider.
      final subjects = tester.getTopLeft(
        find.byKey(const Key('subjects-heading')),
      );
      final tags = tester.getTopLeft(find.byKey(const Key('tags-heading')));
      expect(tags.dy, greaterThan(subjects.dy));

      event.annotations.setObjects(const [
        ObjectTag(label: 'bottle', ms: 0, score: 0.9),
      ]);
      await tester.pump();
      expect(find.byKey(const Key('player-object-bottle')), findsOneWidget);
      expect(find.byKey(const Key('tags-empty')), findsNothing);
      await tester.tap(find.byKey(const Key('player-object-remove-bottle')));
      await tester.pump();
      expect(event.annotations.objects, isEmpty);
      expect(find.text('No tags: nothing was seen on this clip.'), findsOne);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Auto is off where recognition cannot run', (tester) async {
    // The player in a dialog on a 320 dp phone: the buttons must fit.
    tester.view
      ..physicalSize = const Size(240, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bus = AppEventBus();
    final recognizer = SubjectRecognizer(
      bus: bus,
      log: EventLog(bus.stream),
      config: ConfigController(),
      runtime: FakeRuntime()..supported = false,
      sampler: FakeSampler(1),
    );
    await tester.pumpWidget(
      SubjectRecognizerScope(
        recognizer: recognizer,
        child: MaterialApp(
          home: Scaffold(
            body: ClipPlayerDialog(event: ClipRequested(clip(), id: 'c')),
          ),
        ),
      ),
    );
    final button = tester.widget<ButtonStyleButton>(
      find.byKey(const Key('auto-tag')),
    );
    expect(button.onPressed, isNull);
    expect(find.byTooltip('Not available on this device yet'), findsOneWidget);
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('a suggestion card on a 320 dp phone at ${scale}x text: the '
        'question on its own line under the picture, on one line', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final a = ClipAnnotations();
      final s = a.add(
        'Suerte',
        0.5,
        0.5,
        frame: testFrame(onePixelPng, 2000),
        source: TagSource.suggested,
        confidence: 0.89,
      )!;
      final event = ClipRequested(clip(), annotations: a, id: 'c1');
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(320, 900),
              textScaler: TextScaler.linear(scale),
            ),
            child: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Builder(
                  builder: SubjectSuggestion(
                    clipEventId: 'c1',
                    annotationId: s.id,
                    subjectName: 'Suerte',
                    confidence: 0.89,
                    clip: event,
                  ).buildCard,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'nothing overflows');
      final frame = tester.getRect(find.byKey(const Key('suggestion-frame')));
      final question = tester.getRect(
        find.byKey(const Key('suggestion-question')),
      );
      expect(question.top, greaterThanOrEqualTo(frame.bottom));
      final title = find.text('Is this Suerte?');
      final card = tester.getRect(find.byType(Card));
      // The line to itself: most of the card's width.
      expect(tester.getSize(title).width, greaterThan(card.width * 0.6));
      if (scale == 1) {
        // On one line.
        final style = tester.widget<Text>(title).style!;
        expect(tester.getSize(title).height, lessThan(style.fontSize! * 2));
      }
      expect(find.byKey(const Key('suggestion-yes')), findsOneWidget);
    });
  }

  testWidgets('a suggestion asks, and Yes makes it a tag', (tester) async {
    final a = ClipAnnotations();
    final frame = testFrame(onePixelPng, 2000);
    final s = a.add(
      'Ana',
      0.5,
      0.5,
      frame: frame,
      source: TagSource.suggested,
      confidence: 0.62,
    )!;
    final event = ClipRequested(clip(), annotations: a, id: 'c1');
    SubjectSuggestion suggestion() => SubjectSuggestion(
      clipEventId: 'c1',
      annotationId: s.id,
      subjectName: 'Ana',
      confidence: 0.62,
      clip: event,
    );
    Future<void> show(SubjectSuggestion sug) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Builder(builder: sug.buildCard)),
      ),
    );
    await show(suggestion());
    expect(find.text('Is this Ana?'), findsOneWidget);
    expect(find.textContaining('62 % sure · Back camera · '), findsOneWidget);
    expect(find.byKey(const Key('suggestion-frame')), findsOneWidget);
    await tester.tap(find.byKey(const Key('suggestion-yes')));
    await tester.pump();
    expect(a.byId(s.id)!.source, TagSource.confirmed);
    // Answered: the answer in the question's place, nothing asked again.
    expect(find.text('Tagged as Ana'), findsOneWidget);
    expect(find.text('Is this Ana?'), findsNothing);
    expect(find.byKey(const Key('suggestion-yes')), findsNothing);

    // No removes it.
    final t = a.add('Bo', 0.2, 0.2, frame: frame, source: TagSource.suggested)!;
    await show(
      SubjectSuggestion(
        clipEventId: 'c1',
        annotationId: t.id,
        subjectName: 'Bo',
        confidence: 0.55,
        clip: event,
      ),
    );
    await tester.tap(find.byKey(const Key('suggestion-no')));
    await tester.pump();
    expect(a.byId(t.id), isNull);
    expect(find.text('Not Bo'), findsOneWidget);
    expect(find.text('Is this Bo?'), findsNothing);
  });
}

VideoClip clip() => VideoClip.restored(
  id: 'clip-${AppEvent.newId()}',
  cameraId: 'cam',
  cameraLabel: 'Back camera',
  before: const Duration(seconds: 15),
  after: const Duration(seconds: 15),
  past: null,
  full: ClipMedia(
    url: 'blob:clip',
    start: Duration.zero,
    end: const Duration(seconds: 30),
  ),
);

/// Cloud recognition without HTTP: answers [answer] (crop ID to matches)
/// and records what it was asked.
class _FakeCloud extends CloudIdentifier {
  _FakeCloud(this.answer, {this.available = true, this.gate})
    : super(
        auth: FakeAuthService.signedIn(),
        roles: RolesService(auth: FakeAuthService(), client: FakeRolesClient()),
        config: ConfigController(),
        client: _UnusedClient(),
      );

  final Map<String, List<CloudMatch>> answer;

  @override
  final bool available;

  /// Answers once it completes, if given.
  final Completer<void>? gate;

  final asked = <Map<String, (String, Uint8List)>>[];

  @override
  Future<Map<String, List<CloudMatch>>?> identify(
    Map<String, (String, Uint8List)> crops,
  ) async {
    asked.add(crops);
    await gate?.future;
    return answer;
  }
}

/// Cloud recognition's breeds and coats without HTTP: answers [answer]
/// (crop ID to labels), once [gate] completes if given, and records what
/// it was asked.
class _FakeDescriber extends CloudDescriber {
  _FakeDescriber(
    this.answer, {
    this.available = true,
    this.gate,
    this.fail = false,
  }) : super(
         auth: FakeAuthService.signedIn(),
         roles: RolesService(
           auth: FakeAuthService(),
           client: FakeRolesClient(),
         ),
         client: _UnusedClient(),
       );

  final Map<String, List<CloudPetLabel>> answer;

  @override
  final bool available;

  final Completer<void>? gate;

  /// Answers nothing, as when the API fails.
  final bool fail;

  final asked = <Map<String, (String, Uint8List)>>[];

  @override
  Future<Map<String, List<CloudPetLabel>>?> describe(
    Map<String, (String, Uint8List)> crops,
  ) async {
    asked.add(crops);
    await gate?.future;
    return fail ? null : answer;
  }
}

class _UnusedClient implements CloudRecognitionClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
