import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../annotations.dart';
import '../cameras/camera_source.dart';
import '../clips.dart';
import '../config.dart';
import '../events.dart';
import '../subjects.dart';
import 'frames.dart';
import 'image.dart';
import 'matching.dart';
import 'memory.dart';
import 'runtime.dart';
import 'suggestion.dart';
import 'vision.dart';
import 'vision_platform_native.dart'
    if (dart.library.js_interop) 'vision_platform_web.dart'
    as platform;

/// How a recognition run went.
enum RecognitionOutcome {
  /// This platform can't run the models.
  unsupported,

  /// Off in Settings (only for new clips; asking on a clip runs anyway).
  off,

  /// Nobody to look for: no subject has a vouched tag showing someone.
  noReferences,

  /// Everyone recognition knows is already on the clip.
  allTagged,

  /// The clip was searched for subjects.
  searched,

  /// Not searched: memory was too low, or newer clips were waiting.
  deferred,
}

/// What a recognition run found: its [outcome] for subjects, the subjects
/// it [tagged], those it only [asked] about (a [SubjectSuggestion] each),
/// as named, and the [objects] it tagged, by label.
@immutable
class RecognitionResult {
  const RecognitionResult(
    this.outcome, {
    this.tagged = const [],
    this.asked = const [],
    this.objects = const [],
  });

  final RecognitionOutcome outcome;
  final List<String> tagged;
  final List<String> asked;
  final List<String> objects;
}

/// Searches every new clip, once its full recording (before + after) is
/// saved, in two
/// segments fed by the same frames and detector:
///
/// - **subjects**, who has an identity (Julio, Fido): people and pets
///   matched against those tagged before;
/// - **object tags**, what was there, for search: `human`, `cat`,
///   `bicycle`, `bottle`… ([ClipAnnotations.objects]), each label once per
///   clip, from the first frame it's seen on, if seen on [objectFrames]
///   frames (or once, surely). Off with [RecognitionConfig.objects]; a
///   clip already searched isn't again.
///
/// Each subject's references are the frames of tags someone made or
/// confirmed ([TagSource.vouched]); recognized tags never become
/// references, so a mistake doesn't spread. The clip is sampled
/// [every] so long, and each subject's confidence is pooled over it (the
/// mean of their [framesPooled] best frames). From
/// [RecognitionConfig.autoTag] they get a [TagSource.detected] tag on
/// their best frame; below that (but at least
/// [RecognitionConfig.askFloor]) a [TagSource.suggested] entry there
/// instead, and a [SubjectSuggestion] event asks about it.
/// Subjects already on the clip are skipped, so none is tagged twice. Only
/// detections that could match someone (people if a person is known, pets
/// if a pet is) are embedded, at most [maxSeenPerFrame] a frame. Clips
/// are done one at a time, each queued once it's fully recorded, so one
/// still recording doesn't hold up the others; only the latest
/// [maxPending] new clips wait, older ones are skipped. While the device
/// is low on memory ([MemoryStatus.tight]) a new clip waits
/// [memoryRetryAfter] at a time (at most [memoryRetries] times), the
/// models' memory freed meanwhile. [recognizeNow] runs it on any clip, on
/// request (the player's Auto); a new clip already searched that way isn't
/// searched again.
class SubjectRecognizer {
  SubjectRecognizer({
    required AppEventBus bus,
    required this.log,
    required this.config,
    TfliteRuntime? runtime,
    ClipFrameSampler? sampler,
    Future<Vision> Function()? loadVision,
    Future<RgbaImage?> Function(Uint8List jpeg)? decode,
    MemoryMonitor? memory,
    this.every = defaultEvery,
    this.maxPending = defaultMaxPending,
    this.memoryRetryAfter = defaultMemoryRetryAfter,
    this.memoryRetries = defaultMemoryRetries,
  }) : _bus = bus,
       _runtime = runtime ?? TfliteRuntime(),
       _sampler = sampler ?? ClipFrameSampler(),
       _memory = memory ?? MemoryMonitor(),
       _decode =
           decode ?? ((jpeg) => RgbaImage.decode(jpeg, maxWidth: frameWidth)) {
    _loadVision = loadVision ?? () => platform.loadPlatformVision(_runtime);
    _subscription = bus.stream.listen(_onEvent);
  }

  /// How often a clip is sampled: the recorder's keyframe interval.
  static const Duration defaultEvery = Duration(seconds: 1);

  /// How wide frames (and reference frames) are at most.
  static const int frameWidth = ClipFrameSampler.defaultMaxWidth;

  /// The most detections a frame is searched for subjects on, best first.
  static const int maxSeenPerFrame = 5;

  /// How many of a subject's best frames are pooled into their confidence
  /// over the clip.
  static const int framesPooled = 3;

  /// On how many frames an object must be seen to be tagged, unless it's
  /// seen once at [sureObject] or more.
  static const int objectFrames = 2;
  static const double sureObject = 0.7;

  static const int defaultMaxPending = 3;
  static const Duration defaultMemoryRetryAfter = Duration(seconds: 30);
  static const int defaultMemoryRetries = 10;

  /// The most references kept per subject (from their latest tags).
  static const int referencesPerSubject = 10;

  /// How far a tag may be from a detection's center (in fractions of the
  /// frame) and still pick it, when none contains it.
  static const double maxTagDistance = 0.15;

  final AppEventBus _bus;
  final EventLog log;
  final ConfigController config;
  final Duration every;

  /// The most new clips waiting their turn.
  final int maxPending;
  final Duration memoryRetryAfter;
  final int memoryRetries;
  final TfliteRuntime _runtime;
  final ClipFrameSampler _sampler;
  final MemoryMonitor _memory;
  final Future<RgbaImage?> Function(Uint8List jpeg) _decode;
  late final Future<Vision> Function() _loadVision;
  late final StreamSubscription<AppEvent> _subscription;

  Future<Vision>? _vision;
  final _pending = <_Job>[];
  bool _running = false;
  Completer<void>? _drained;
  bool _disposed = false;

  /// Each reference tag's detection and embeddings, by tag ID (null: no
  /// one found where it was clicked).
  final _references = <String, Seen?>{};

  /// The clips searched in full, by event ID.
  final _searched = <String>{};

  /// Whether recognition can run on this platform.
  bool get supported => _runtime.supported && _sampler.supported;

  /// Completes once every clip queued so far is done (for tests).
  Future<void> get idle => !_running && _pending.isEmpty
      ? Future.value()
      : (_drained ??= Completer<void>()).future;

  void _onEvent(AppEvent event) {
    if (event is! ClipRequested || event.clip.capture == null) return;
    // Wait for the "after" part outside the queue.
    _full(event.clip)
        .then<void>((media) async {
          if (media == null || _disposed) return;
          await _enqueue(event, onRequest: false);
        })
        .catchError(
          (Object e, StackTrace stack) => debugPrint(
            'Presence: recognition failed on ${event.id}: $e\n$stack',
          ),
        );
  }

  /// Runs recognition on [event]'s clip now, after any clip already being
  /// searched, even with recognition off in Settings: someone asked.
  /// Throws if the models can't load.
  Future<RecognitionResult> recognizeNow(ClipRequested event) =>
      _enqueue(event, onRequest: true);

  Future<RecognitionResult> _enqueue(
    ClipRequested event, {
    required bool onRequest,
  }) {
    final job = _Job(event, onRequest: onRequest);
    _pending.add(job);
    // Clips come faster than they're searched: keep the latest new ones.
    final waiting = [
      for (final j in _pending)
        if (!j.onRequest) j,
    ];
    for (final old in waiting.take(math.max(0, waiting.length - maxPending))) {
      _pending.remove(old);
      debugPrint(
        'Presence: recognition skipped ${old.event.id}: newer clips waiting',
      );
      old.done.complete(const RecognitionResult(RecognitionOutcome.deferred));
    }
    _pump();
    return job.done.future;
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    while (_pending.isNotEmpty) {
      final job = _pending.removeAt(0);
      try {
        job.done.complete(await recognize(job.event, onRequest: job.onRequest));
      } catch (e, stack) {
        job.done.completeError(e, stack);
      }
      // Free the models now if memory got low, not after the idle delay.
      if ((await _memory.status())?.tight ?? false) _release();
    }
    _running = false;
    _drained?.complete();
    _drained = null;
  }

  /// Frees the models' memory; they load again when next needed.
  void _release() => _vision?.then((v) => v.release(), onError: (_) {});

  /// Whether there's memory enough to run the models; if not, and
  /// [wait], once there is (after up to [memoryRetries] waits).
  Future<bool> _roomToRun({required bool wait}) async {
    for (var attempt = 0; ; attempt++) {
      final status = await _memory.status();
      if (status == null || !status.tight) return true;
      _release();
      if (!wait || attempt >= memoryRetries || _disposed) {
        debugPrint('Presence: recognition put off, low on memory: $status');
        return false;
      }
      await Future<void>.delayed(memoryRetryAfter);
    }
  }

  /// Recognizes the subjects and objects on [event]'s clip (once it's
  /// recorded). New clips are only searched as Settings say; [onRequest]
  /// runs anyway.
  @visibleForTesting
  Future<RecognitionResult> recognize(
    ClipRequested event, {
    bool onRequest = false,
  }) async {
    if (!supported) {
      return const RecognitionResult(RecognitionOutcome.unsupported);
    }
    final settings = config.recognition;
    // A new clip already searched for subjects (with Auto) isn't again.
    final subjectsOn =
        onRequest || (settings.enabled && !_searched.contains(event.id));
    final objectsOn =
        (onRequest || settings.objects) && event.annotations.objects == null;
    if (!subjectsOn && !objectsOn) {
      return const RecognitionResult(RecognitionOutcome.off);
    }
    final references = subjectsOn && _hasReferences(event);
    if (!references && !objectsOn) {
      return const RecognitionResult(RecognitionOutcome.noReferences);
    }
    final media = await _full(event.clip);
    if (media == null || _disposed) {
      return const RecognitionResult(RecognitionOutcome.searched);
    }
    // Asked for, it's now or not at all; a new clip can wait.
    if (!await _roomToRun(wait: !onRequest)) {
      return const RecognitionResult(RecognitionOutcome.deferred);
    }
    if (_disposed) return const RecognitionResult(RecognitionOutcome.searched);
    final Vision vision;
    try {
      vision = await (_vision ??= _loadVision());
    } catch (_) {
      // Try loading again on the next clip.
      _vision = null;
      rethrow;
    }
    final gallery = references
        ? await _gallery(vision, event)
        : const <GalleryEntry>[];
    if (_disposed) return const RecognitionResult(RecognitionOutcome.searched);

    final faces = gallery.any((g) => g.face != null);
    // Only who could be someone known: no pets embedded if no pet is.
    final kinds = {
      for (final k in SeenKind.values)
        if (gallery.any((g) => g.kind.sameAs(k))) k,
    };
    final found = {
      for (final a in event.annotations.items) Subject.idOf(a.name),
    };
    final everyone = {for (final g in gallery) g.subjectId};
    final outcome = !subjectsOn
        ? RecognitionOutcome.off
        : gallery.isEmpty
        ? RecognitionOutcome.noReferences
        : everyone.every(found.contains)
        ? RecognitionOutcome.allTagged
        : RecognitionOutcome.searched;
    if (outcome == RecognitionOutcome.allTagged) _searched.add(event.id);
    var lookForSubjects = outcome == RecognitionOutcome.searched;
    if (!lookForSubjects && !objectsOn) return RecognitionResult(outcome);

    final tagged = <String>[];
    // Each subject's per-frame confidences, and their best frame so far.
    final sightings = <String, _Sightings>{};
    // Objects, by label: the first frame each was seen on.
    final objects = <String, _ObjectSightings>{};
    final started = DateTime.now();
    var frames = 0;
    await for (final frame in _sampler.sample(
      media,
      every: every,
      maxWidth: frameWidth,
    )) {
      if (_disposed) return RecognitionResult(outcome, tagged: tagged);
      frames++;
      final analysis = await vision.analyse(
        frame.image,
        faces: faces,
        subjects: lookForSubjects,
        kinds: kinds,
        maxSeen: maxSeenPerFrame,
      );
      if (objectsOn) {
        for (final MapEntry(key: label, value: score)
            in analysis.objects.entries) {
          (objects[label] ??= _ObjectSightings(
            frame.position.inMilliseconds,
          )).add(score);
        }
      }
      if (lookForSubjects) {
        final matches = matchFrame(analysis.seen, gallery, skip: found);
        TagFrame? tagFrame;
        for (final match in matches) {
          final s = sightings[match.subjectId] ??= _Sightings();
          s.add(match);
          if (match.confidence <= (s.best?.confidence ?? -1)) continue;
          // A frame's JPEG only if someone's best on it.
          tagFrame ??= await _tagFrame(event, frame);
          if (tagFrame == null) break;
          s
            ..best = match
            ..frame = tagFrame;
        }
        // Everyone left surely seen on enough frames: nothing more to learn.
        if (everyone
            .difference(found)
            .every((id) => sightings[id]?.sure(settings.autoTag) ?? false)) {
          lookForSubjects = false;
        }
      }
      // The whole clip for objects; for subjects, until everyone's sure.
      if (!lookForSubjects && !objectsOn) break;
      // Let the app draw between frames.
      await Future<void>.delayed(Duration.zero);
    }
    if (outcome == RecognitionOutcome.searched) _searched.add(event.id);
    // Subjects only good enough to ask about.
    final asks = <(Match, TagFrame, double)>[];
    for (final MapEntry(key: id, value: s) in sightings.entries) {
      final match = s.best;
      final tagFrame = s.frame;
      if (match == null || tagFrame == null) continue;
      final confidence = s.confidence;
      if (confidence < RecognitionConfig.askFloor) continue;
      if (confidence >= settings.autoTag) {
        final (x, y) = match.seen.spot;
        event.annotations.add(
          match.entry.name,
          x,
          y,
          frame: tagFrame,
          source: TagSource.detected,
          confidence: confidence,
        );
        found.add(id);
        tagged.add(match.entry.name);
      } else {
        asks.add((match, tagFrame, confidence));
      }
    }
    for (final (match, tagFrame, confidence) in asks) {
      final (x, y) = match.seen.spot;
      final suggestion = event.annotations.add(
        match.entry.name,
        x,
        y,
        frame: tagFrame,
        source: TagSource.suggested,
        confidence: confidence,
      );
      if (suggestion == null) continue;
      _bus.publish(
        SubjectSuggestion(
          clipEventId: event.id,
          annotationId: suggestion.id,
          subjectName: match.entry.name,
          confidence: confidence,
          clip: event,
          cameraId: event.cameraId,
        ),
      );
    }
    final kept = [
      for (final MapEntry(key: label, value: o) in objects.entries)
        if (o.kept(frames: frames))
          ObjectTag(label: label, ms: o.ms, score: o.score),
    ];
    if (objectsOn) event.annotations.setObjects(kept);
    debugPrint(
      'Presence: recognized ${tagged.length} subject(s), asked about '
      '${asks.length}, saw ${kept.length} kind(s) of object, on $frames '
      'frame(s) of ${event.id} in '
      '${DateTime.now().difference(started).inMilliseconds} ms',
    );
    return RecognitionResult(
      outcome,
      tagged: tagged,
      asked: [for (final (match, _, _) in asks) match.entry.name],
      objects: [for (final o in kept) o.label],
    );
  }

  /// The full recording, once it's done; null if there's none.
  Future<ClipMedia?> _full(VideoClip clip) async {
    if (!clip.fullDone) {
      final done = Completer<void>();
      void check() {
        if (clip.fullDone && !done.isCompleted) done.complete();
      }

      clip.addListener(check);
      await done.future;
      clip.removeListener(check);
    }
    return clip.full;
  }

  Future<TagFrame?> _tagFrame(ClipRequested event, SampledFrame frame) async {
    final jpeg = await frame.jpeg();
    if (jpeg == null) return null;
    return event.annotations.newFrame(jpeg, frame.position.inMilliseconds);
  }

  /// The vouched tags with frames, on clips other than [event]'s.
  Iterable<(ClipRequested, Annotation)> _vouched(ClipRequested event) sync* {
    final clips =
        log.events
            .whereType<ClipRequested>()
            .where((e) => e.id != event.id)
            .toList()
          ..sort((a, b) => b.time.compareTo(a.time));
    for (final clip in clips) {
      for (final tag in clip.annotations.items) {
        if (tag.source.vouched &&
            tag.frameId != null &&
            Subject.idOf(tag.name).isNotEmpty) {
          yield (clip, tag);
        }
      }
    }
  }

  bool _hasReferences(ClipRequested event) => _vouched(event).isNotEmpty;

  /// Every subject's references: their latest [referencesPerSubject]
  /// vouched tags whose frame shows someone where they were clicked, named
  /// as on their latest tag.
  Future<List<GalleryEntry>> _gallery(
    Vision vision,
    ClipRequested event,
  ) async {
    final names = <String, String>{};
    final counts = <String, int>{};
    final gallery = <GalleryEntry>[];
    for (final (clip, tag) in _vouched(event)) {
      final id = Subject.idOf(tag.name);
      final name = names.putIfAbsent(id, () => tag.name.trim());
      if ((counts[id] ?? 0) >= referencesPerSubject) continue;
      final seen = await _reference(vision, clip, tag);
      final look = seen?.lookVector;
      if (seen == null || look == null) continue;
      counts[id] = (counts[id] ?? 0) + 1;
      gallery.add(
        GalleryEntry(
          subjectId: id,
          name: name,
          kind: seen.detection.kind,
          look: look,
          face: seen.faceVector,
        ),
      );
    }
    return gallery;
  }

  /// Who [tag] points at on its frame: the smallest detection containing
  /// the spot, or else the nearest within [maxTagDistance]. Kept per tag.
  Future<Seen?> _reference(
    Vision vision,
    ClipRequested clip,
    Annotation tag,
  ) async {
    if (_references.containsKey(tag.id)) return _references[tag.id];
    final frame = clip.annotations.frames[tag.frameId];
    final image = frame == null ? null : await _decode(frame.jpeg);
    final seen = image == null
        ? const <Seen>[]
        : (await vision.analyse(image, faces: true)).seen;
    return _references[tag.id] = pickTagged(seen, tag.x, tag.y);
  }

  /// The one of [seen] a tag at ([x], [y]) points at.
  @visibleForTesting
  static Seen? pickTagged(List<Seen> seen, double x, double y) {
    Seen? best;
    for (final s in seen) {
      if (!s.detection.box.contains(x, y)) continue;
      if (best == null || s.detection.box.area < best.detection.box.area) {
        best = s;
      }
    }
    if (best != null) return best;
    var nearest = maxTagDistance;
    for (final s in seen) {
      final box = s.detection.box;
      final d = math.sqrt(math.pow(box.cx - x, 2) + math.pow(box.cy - y, 2));
      if (d <= nearest) {
        nearest = d;
        best = s;
      }
    }
    return best;
  }

  void dispose() {
    _disposed = true;
    _subscription.cancel();
    _release();
  }
}

/// A clip waiting its turn.
class _Job {
  _Job(this.event, {required this.onRequest});

  final ClipRequested event;
  final bool onRequest;
  final done = Completer<RecognitionResult>();
}

/// Puts the app's [SubjectRecognizer] within reach of its screens (the
/// clip player's Auto button).
class SubjectRecognizerScope extends InheritedWidget {
  const SubjectRecognizerScope({
    super.key,
    required this.recognizer,
    required super.child,
  });

  final SubjectRecognizer recognizer;

  /// The recognizer above [context], if any.
  static SubjectRecognizer? maybeOf(BuildContext context) => context
      .getInheritedWidgetOfExactType<SubjectRecognizerScope>()
      ?.recognizer;

  @override
  bool updateShouldNotify(SubjectRecognizerScope oldWidget) =>
      recognizer != oldWidget.recognizer;
}

/// One subject's matches over a clip: their confidence on each frame they
/// were paired on, the surest [best] match and its [frame].
class _Sightings {
  final confidences = <double>[];
  Match? best;
  TagFrame? frame;

  /// Their surest match by face: aligned faces of different people score
  /// under the ask floor 99.9 % of the time (LFW), so one sure face is
  /// enough on its own.
  double byFace = 0;

  void add(Match match) {
    confidences.add(match.confidence);
    if (match.byFace && match.confidence > byFace) byFace = match.confidence;
  }

  /// How sure they were seen over the clip: their surest face, or the mean
  /// of their best [SubjectRecognizer.framesPooled] frames (fewer if they
  /// weren't on that many), so one lucky look of a stranger counts less
  /// than a subject seen again and again. On Market-1501 this tagged
  /// nearly as many right as the best frame alone (93 % against 96 %),
  /// with half the strangers taken for someone.
  double get confidence {
    final best = [...confidences]..sort((a, b) => b.compareTo(a));
    final top = best.take(SubjectRecognizer.framesPooled);
    final pooled = top.isEmpty ? 0.0 : top.reduce((a, b) => a + b) / top.length;
    return math.max(byFace, pooled);
  }

  /// Whether they're surely tagged whatever the rest of the clip shows: a
  /// face at [autoTag] or more, or as many frames as are pooled, each at
  /// [autoTag] or more.
  bool sure(double autoTag) =>
      byFace >= autoTag ||
      confidences.where((c) => c >= autoTag).length >=
          SubjectRecognizer.framesPooled;
}

/// One object label over a clip: where it was first seen ([ms]), its best
/// [score], and on how many frames.
class _ObjectSightings {
  _ObjectSightings(this.ms);

  final int ms;
  double score = 0;
  int frames = 0;

  void add(double frameScore) {
    frames++;
    if (frameScore > score) score = frameScore;
  }

  /// Whether it's tagged, on a clip of [frames] frames: seen on
  /// [SubjectRecognizer.objectFrames] frames or more, or once at
  /// [SubjectRecognizer.sureObject] or more, or on a clip of one frame. A
  /// label on one frame only, unsure, is more often a mistake than a thing
  /// seen for an instant.
  bool kept({required int frames}) =>
      this.frames >= SubjectRecognizer.objectFrames ||
      score >= SubjectRecognizer.sureObject ||
      frames == 1;
}
