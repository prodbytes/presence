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
import 'package:presence_app/events.dart';
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

/// A unit vector pointing [degrees] around a circle: two of them have a
/// cosine of cos(difference).
Float32List direction(double degrees) {
  final r = degrees * math.pi / 180;
  return Float32List.fromList([math.cos(r), math.sin(r)]);
}

/// The angle between two unit vectors with cosine [c].
double angleFor(double c) => math.acos(c) * 180 / math.pi;

Seen seenAt(
  Box box, {
  SeenKind kind = SeenKind.person,
  double? face,
  double look = 0,
}) => Seen(
  Detection(box, 0.9, kind),
  face: face == null
      ? null
      : Face(
          Box.centered(box.cx, box.top + 0.05, 0.04, 0.04),
          0.9,
          (box.cx - 0.01, box.top + 0.04),
          (box.cx + 0.01, box.top + 0.04),
        ),
  faceVector: face == null ? null : direction(face),
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
  FakeSampler(this.count);

  final int count;
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
  FakeVision(this.frames, this.references, {this.objects = const {}});

  final Map<int, List<Seen>> frames;

  /// For reference frames (decoded as 1000 + n wide).
  final Map<int, List<Seen>> references;
  final Map<int, Map<String, double>> objects;

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
  group('decoding', () {
    test('EfficientDet: a scored anchor becomes a box of its kind', () {
      final anchors = efficientDetAnchors;
      final n = anchors.length ~/ 4;
      expect(n, 19206);
      final scores = Float32List(n * cocoClasses);
      final boxes = Float32List(n * 4);
      // A dog on anchor 1000 exactly, and a weaker overlapping one.
      scores[1000 * cocoClasses + 17] = 0.9;
      scores[1009 * cocoClasses + 17] = 0.6;
      // A person on anchor 15000, shifted right by half its width.
      scores[15000 * cocoClasses] = 0.8;
      boxes[15000 * 4 + 1] = 0.5;
      // A car: not kept.
      scores[200 * cocoClasses + 2] = 0.99;
      final found = decodeDetections(scores, boxes);
      expect(found.map((d) => d.kind), [SeenKind.dog, SeenKind.person]);
      final dog = found.first;
      expect(dog.score, closeTo(0.9, 1e-6));
      expect(dog.box.cy, closeTo(anchors[1000 * 4], 1e-6));
      expect(dog.box.cx, closeTo(anchors[1000 * 4 + 1], 1e-6));
      final person = found.last;
      expect(
        person.box.cx,
        closeTo(anchors[15000 * 4 + 1] + 0.5 * anchors[15000 * 4 + 3], 1e-6),
      );
      expect(person.box.height, closeTo(anchors[15000 * 4 + 2], 1e-6));
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
  });

  group('matching', () {
    test('confidence: faces and looks on their own scales', () {
      expect(faceConfidence(0.2), 0);
      expect(faceConfidence(0.55), closeTo(0.5, 1e-9));
      expect(faceConfidence(0.70), closeTo(0.8, 1e-9));
      expect(faceConfidence(0.95), 1);
      expect(lookConfidence(0.45), 0);
      expect(lookConfidence(0.81), closeTo(0.8, 1e-9));
    });

    test('faces are compared when both show; looks otherwise', () {
      const box = Box(0, 0, 0.5, 1);
      final byFace = compare(
        seenAt(box, face: angleFor(0.7), look: 90),
        entry('ana', face: 0, look: 0),
      )!;
      expect(byFace.byFace, isTrue);
      expect(byFace.confidence, closeTo(0.8, 1e-6));
      final byLook = compare(
        seenAt(box, look: angleFor(0.81)),
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
        matchFrame(seen, [entry('bo', face: 90)], minConfidence: 0.7),
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
      expect(RecognitionConfig.askFloor, 0.3);
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
    });

    test('tags keep their source and confidence; suggestions are not tags', () {
      final a = ClipAnnotations();
      final frame = a.newFrame(onePixelPng, 1500);
      final manual = a.add('Ana', 0.1, 0.1, frame: frame)!;
      final detected = a.add(
        'Rex',
        0.5,
        0.5,
        frame: frame,
        source: TagSource.detected,
        confidence: 0.86,
      )!;
      final other = a.newFrame(onePixelPng, 2500);
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
      final frame = TagFrame(
        id: 'ref-$n',
        jpeg: Uint8List.fromList([n]),
        ms: 0,
      );
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

    test('tags the sure, asks about the unsure, on the first frame', () async {
      const body = Box(0.3, 0.2, 0.7, 1);
      const other = Box(0.75, 0.2, 0.95, 1);
      log.addHistory([
        tagged(1, ['Rex']),
        tagged(2, ['Ana']),
        tagged(3, ['Bo']),
      ]);
      final vision = FakeVision(
        {
          // Frame 0: nobody. Frame 1: Rex, surely (0.95 → 1.0).
          1: [seenAt(body, face: angleFor(0.85))],
          // Frame 2: Rex again, and someone a bit like Ana (0.6 → 0.6).
          2: [
            seenAt(body, face: angleFor(0.85)),
            seenAt(other, face: 100 + angleFor(0.6)),
          ],
          // Frame 3: the same one, a bit more like Ana: still unsure.
          3: [seenAt(other, face: 100 + angleFor(0.65))],
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
      expect(ana.confidence, closeTo(0.6, 1e-6));
      expect(event.annotations.frames[ana.frameId]!.ms, 3000);
      expect(ana.x, closeTo(other.cx, 1e-9));

      await Future<void>.delayed(Duration.zero);
      final suggestion = published.whereType<SubjectSuggestion>().single;
      expect(suggestion.subjectName, 'Ana');
      expect(suggestion.annotationId, ana.id);
      expect(suggestion.clip, same(event));
      // One JPEG per frame used, not per tag.
      expect(sampler.jpegs, 2);
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
              seenAt(left, face: angleFor(0.70)),
              // Bo at 40 %: under the old "ask" default (50 %), asked now.
              seenAt(middle, face: 120 - angleFor(0.50)),
              // Cy at 20 %: under the floor, a stranger; not asked.
              seenAt(right, face: 240 + angleFor(0.40)),
            ],
          },
          {
            // Far apart, so nobody is much like the others.
            1: [seenAt(middle, face: 0)],
            2: [seenAt(middle, face: 120)],
            3: [seenAt(middle, face: 240)],
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

    test('stops once everyone is found, and skips who is tagged', () async {
      const body = Box(0.3, 0.2, 0.7, 1);
      log.addHistory([
        tagged(1, ['Rex']),
        tagged(2, ['Ana']),
      ]);
      final vision = FakeVision(
        {
          0: [seenAt(body, face: angleFor(0.9))],
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
      // Two references, then the first frame only.
      expect(vision.calls, 3);
    });

    test('recognized tags never become references', () async {
      const body = Box(0.3, 0.2, 0.7, 1);
      final a = ClipAnnotations();
      final frame = TagFrame(id: 'f', jpeg: Uint8List.fromList([1]), ms: 0);
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
    });

    test('object tags: each label once, from its first frame', () async {
      // Nobody tagged before: only the object tags' segment runs.
      final vision = FakeVision(
        {},
        {},
        objects: {
          0: {'human': 0.7},
          1: {'cat': 0.6, 'human': 0.9},
          3: {'bicycle': 0.8, 'cat': 0.95},
        },
      );
      final r = recognizer(vision, FakeSampler(4));
      final event = ClipRequested(clip(), id: 'new');
      final result = await r.recognize(event);
      expect(result.outcome, RecognitionOutcome.noReferences);
      expect(result.objects, ['human', 'cat', 'bicycle']);
      expect(event.annotations.objects, const [
        ObjectTag(label: 'human', ms: 1000, score: 0.7),
        ObjectTag(label: 'cat', ms: 2000, score: 0.6),
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
    });

    test('object tags keep going once every subject is found', () async {
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
        objects: {
          2: {'dog': 0.8},
        },
      );
      final event = ClipRequested(clip(), id: 'new');
      final result = await recognizer(vision, FakeSampler(3)).recognize(event);
      expect(result.tagged, ['Rex']);
      expect(result.objects, ['dog']);
      // One reference, then subjects on the first frame only.
      expect(vision.calls, 2);
      expect(vision.frameCalls, 3);
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
            seenAt(other, face: 100 + angleFor(0.6)),
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
      expect(result.tagged, ['Rex']);
      expect(result.asked, ['Ana']);
      expect(event.annotations.tags.single.source, TagSource.detected);
      expect(autoTagMessage(result), contains('Found Rex.'));
      expect(autoTagMessage(result), contains('"Is this Ana?"'));

      // Again: everyone known is on the clip now (Ana as a suggestion).
      final again = await r.recognizeNow(event);
      expect(again.outcome, RecognitionOutcome.allTagged);
      expect(event.annotations.items, hasLength(2));
    });

    test('on request: nobody to look for, or nobody found', () async {
      final vision = FakeVision({}, {});
      final r = recognizer(vision, FakeSampler(2));
      final noOne = await r.recognizeNow(ClipRequested(clip(), id: 'a'));
      expect(noOne.outcome, RecognitionOutcome.noReferences);
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
      final none = await r.recognizeNow(ClipRequested(clip(), id: 'c'));
      expect(none.outcome, RecognitionOutcome.searched);
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

    test('only the kinds known are embedded, three a frame at most', () async {
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
      final put = await r.recognizeNow(ClipRequested(clip(), id: 'b'));
      expect(put.outcome, RecognitionOutcome.deferred);
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
  });

  testWidgets("the player's Auto tags who it recognizes", (tester) async {
    final bus = AppEventBus();
    final log = EventLog(bus.stream);
    final a = ClipAnnotations();
    final frame = TagFrame(id: 'ref-1', jpeg: Uint8List.fromList([1]), ms: 0);
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
    a.add('Rex', 0.5, 0.5, frame: a.newFrame(onePixelPng, 4000));
    a.add('rex', 0.2, 0.2, frame: a.newFrame(onePixelPng, 1500));
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

  for (final width in [320.0, 1000.0]) {
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

  testWidgets('a suggestion asks, and Yes makes it a tag', (tester) async {
    final a = ClipAnnotations();
    final frame = a.newFrame(onePixelPng, 2000);
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
    expect(find.textContaining('62 % sure · Back camera'), findsOneWidget);
    expect(find.byKey(const Key('suggestion-frame')), findsOneWidget);
    await tester.tap(find.byKey(const Key('suggestion-yes')));
    await tester.pump();
    expect(a.byId(s.id)!.source, TagSource.confirmed);
    expect(find.text('Tagged as Ana'), findsOneWidget);
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
