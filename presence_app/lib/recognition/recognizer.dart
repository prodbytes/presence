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
import 'runtime.dart';
import 'suggestion.dart';
import 'vision.dart';

/// What recognition needs from the models: everyone on a picture, with
/// their embeddings. [VisionModels] is the real one.
abstract interface class Vision {
  Future<List<Seen>> analyse(RgbaImage image, {bool faces = true});
}

class _ModelsVision implements Vision {
  _ModelsVision(this._models);

  final VisionModels _models;

  @override
  Future<List<Seen>> analyse(RgbaImage image, {bool faces = true}) =>
      _models.analyse(image, faces: faces);
}

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

  /// The clip was searched.
  searched,
}

/// What a recognition run found: the subjects it [tagged], and those it
/// only [asked] about (a [SubjectSuggestion] each), as named.
@immutable
class RecognitionResult {
  const RecognitionResult(
    this.outcome, {
    this.tagged = const [],
    this.asked = const [],
  });

  final RecognitionOutcome outcome;
  final List<String> tagged;
  final List<String> asked;
}

/// Finds the subjects on every new clip, once its full recording (before +
/// after) is saved.
///
/// Each subject's references are the frames of tags someone made or
/// confirmed ([TagSource.vouched]); recognized tags never become
/// references, so a mistake doesn't spread. The clip is sampled
/// [every] so long; the first frame a subject is
/// recognized on at [RecognitionConfig.autoTag] or more gets a
/// [TagSource.detected] tag. A subject only reaching
/// [RecognitionConfig.ask] gets a [TagSource.suggested] entry instead, on
/// the first frame it did, and a [SubjectSuggestion] event asks about it.
/// Subjects already on the clip are skipped, so none is tagged twice. Clips
/// are done one at a time, each queued once it's fully recorded, so one
/// still recording doesn't hold up the others. [recognizeNow] runs it on
/// any clip, on request (the player's Auto); a new clip already searched
/// that way isn't searched again.
class SubjectRecognizer {
  SubjectRecognizer({
    required AppEventBus bus,
    required this.log,
    required this.config,
    TfliteRuntime? runtime,
    ClipFrameSampler? sampler,
    Future<Vision> Function()? loadVision,
    Future<RgbaImage?> Function(Uint8List jpeg)? decode,
    this.every = defaultEvery,
  }) : _bus = bus,
       _runtime = runtime ?? TfliteRuntime(),
       _sampler = sampler ?? ClipFrameSampler(),
       _decode = decode ?? ((jpeg) => RgbaImage.decode(jpeg, maxWidth: 960)) {
    _loadVision =
        loadVision ??
        () async => _ModelsVision(await VisionModels.load(_runtime));
    _subscription = bus.stream.listen(_onEvent);
  }

  /// How often a clip is sampled.
  static const Duration defaultEvery = Duration(milliseconds: 500);

  /// The most references kept per subject (from their latest tags).
  static const int referencesPerSubject = 10;

  /// How far a tag may be from a detection's center (in fractions of the
  /// frame) and still pick it, when none contains it.
  static const double maxTagDistance = 0.15;

  final AppEventBus _bus;
  final EventLog log;
  final ConfigController config;
  final Duration every;
  final TfliteRuntime _runtime;
  final ClipFrameSampler _sampler;
  final Future<RgbaImage?> Function(Uint8List jpeg) _decode;
  late final Future<Vision> Function() _loadVision;
  late final StreamSubscription<AppEvent> _subscription;

  Future<Vision>? _vision;
  Future<void> _queue = Future.value();
  bool _disposed = false;

  /// Each reference tag's detection and embeddings, by tag ID (null: no
  /// one found where it was clicked).
  final _references = <String, Seen?>{};

  /// The clips searched in full, by event ID.
  final _searched = <String>{};

  /// Whether recognition can run on this platform.
  bool get supported => _runtime.supported && _sampler.supported;

  /// Completes once every clip queued so far is done (for tests).
  Future<void> get idle => _queue;

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
    final run = _queue.then((_) => recognize(event, onRequest: onRequest));
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Recognizes the subjects on [event]'s clip (once it's recorded). New
  /// clips are only searched with recognition on; [onRequest] runs anyway.
  @visibleForTesting
  Future<RecognitionResult> recognize(
    ClipRequested event, {
    bool onRequest = false,
  }) async {
    if (!supported) {
      return const RecognitionResult(RecognitionOutcome.unsupported);
    }
    if (!onRequest && !config.recognition.enabled) {
      return const RecognitionResult(RecognitionOutcome.off);
    }
    if (!onRequest && _searched.contains(event.id)) {
      return const RecognitionResult(RecognitionOutcome.searched);
    }
    if (!_hasReferences(event)) {
      return const RecognitionResult(RecognitionOutcome.noReferences);
    }
    final media = await _full(event.clip);
    if (media == null || _disposed) {
      return const RecognitionResult(RecognitionOutcome.searched);
    }
    final Vision vision;
    try {
      vision = await (_vision ??= _loadVision());
    } catch (_) {
      // Try loading again on the next clip.
      _vision = null;
      rethrow;
    }
    final gallery = await _gallery(vision, event);
    if (_disposed) return const RecognitionResult(RecognitionOutcome.searched);
    if (gallery.isEmpty) {
      return const RecognitionResult(RecognitionOutcome.noReferences);
    }

    final settings = config.recognition;
    final faces = gallery.any((g) => g.face != null);
    final found = {
      for (final a in event.annotations.items) Subject.idOf(a.name),
    };
    final everyone = {for (final g in gallery) g.subjectId};
    if (everyone.every(found.contains)) {
      _searched.add(event.id);
      return const RecognitionResult(RecognitionOutcome.allTagged);
    }
    final tagged = <String>[];
    // Subjects only good enough to ask about: the first frame they were.
    final asks = <String, (Match, TagFrame)>{};
    final started = DateTime.now();
    var frames = 0;
    await for (final frame in _sampler.sample(media, every: every)) {
      if (_disposed) {
        return RecognitionResult(RecognitionOutcome.searched, tagged: tagged);
      }
      frames++;
      final seen = await vision.analyse(frame.image, faces: faces);
      final matches = matchFrame(
        seen,
        gallery,
        skip: found,
        minConfidence: settings.ask,
      );
      TagFrame? tagFrame;
      for (final match in matches) {
        final sure = match.confidence >= settings.autoTag;
        if (!sure && asks.containsKey(match.subjectId)) continue;
        tagFrame ??= await _tagFrame(event, frame);
        if (tagFrame == null) break;
        if (sure) {
          final (x, y) = match.seen.spot;
          event.annotations.add(
            match.entry.name,
            x,
            y,
            frame: tagFrame,
            source: TagSource.detected,
            confidence: match.confidence,
          );
          found.add(match.subjectId);
          tagged.add(match.entry.name);
          asks.remove(match.subjectId);
        } else {
          asks[match.subjectId] = (match, tagFrame);
        }
      }
      if (everyone.every(found.contains)) break;
      // Let the app draw between frames.
      await Future<void>.delayed(Duration.zero);
    }
    _searched.add(event.id);
    for (final (match, tagFrame) in asks.values) {
      final (x, y) = match.seen.spot;
      final suggestion = event.annotations.add(
        match.entry.name,
        x,
        y,
        frame: tagFrame,
        source: TagSource.suggested,
        confidence: match.confidence,
      );
      if (suggestion == null) continue;
      _bus.publish(
        SubjectSuggestion(
          clipEventId: event.id,
          annotationId: suggestion.id,
          subjectName: match.entry.name,
          confidence: match.confidence,
          clip: event,
          cameraId: event.cameraId,
        ),
      );
    }
    debugPrint(
      'Presence: recognized ${found.length} subject(s), asked about '
      '${asks.length}, on $frames frame(s) of ${event.id} in '
      '${DateTime.now().difference(started).inMilliseconds} ms',
    );
    return RecognitionResult(
      RecognitionOutcome.searched,
      tagged: tagged,
      asked: [for (final (match, _) in asks.values) match.entry.name],
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
        : await vision.analyse(image, faces: true);
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
  }
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
