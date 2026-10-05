import 'package:flutter/foundation.dart';

import 'events.dart';

/// Where a tag came from.
enum TagSource {
  /// Someone clicked the spot and named them.
  manual,

  /// Recognized on the clip, sure enough to tag on its own.
  detected,

  /// Recognized, but not sure enough: waiting for someone to confirm it
  /// (a `SubjectSuggestion` event asks). Not a tag until then.
  suggested,

  /// A suggestion someone confirmed.
  confirmed;

  /// Whether a person vouched for it, so recognition can learn from it.
  bool get vouched => this == manual || this == confirmed;
}

/// A person or pet named on a frame of a clip, at a spot on it: clicked by
/// someone, or found by recognition ([source]).
@immutable
class Annotation {
  const Annotation({
    required this.id,
    required this.name,
    required this.x,
    required this.y,
    this.frameId,
    this.frameMs,
    this.source = TagSource.manual,
    this.confidence,
  });

  final String id;
  final String name;

  final TagSource source;

  /// How sure recognition was, from 0 to 1 (recognized tags only).
  final double? confidence;

  /// Where on the frame, from 0 (left/top) to 1 (right/bottom), relative to
  /// the video frame itself.
  final double x;
  final double y;

  /// The frame this was clicked on (its image is in
  /// [ClipAnnotations.frames]), and its time in the clip's recording.
  final String? frameId;
  final int? frameMs;

  Annotation copyWith({String? name, TagSource? source}) => Annotation(
    id: id,
    name: name ?? this.name,
    x: x,
    y: y,
    frameId: frameId,
    frameMs: frameMs,
    source: source ?? this.source,
    confidence: confidence,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'x': x,
    'y': y,
    'frameId': ?frameId,
    'frameMs': ?frameMs,
    if (source != TagSource.manual) 'source': source.name,
    'confidence': ?confidence,
  };

  /// Null for a malformed entry (skipped rather than failing a restore).
  static Annotation? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    final x = json['x'];
    final y = json['y'];
    if (id is! String || name is! String || x is! num || y is! num) {
      return null;
    }
    final frameId = json['frameId'];
    final frameMs = json['frameMs'];
    final confidence = json['confidence'];
    return Annotation(
      id: id,
      name: name,
      x: x.toDouble().clamp(0, 1),
      y: y.toDouble().clamp(0, 1),
      frameId: frameId is String ? frameId : null,
      frameMs: frameMs is num ? frameMs.toInt() : null,
      // Older records, and unknown sources, are someone's clicks.
      source: TagSource.values.asNameMap()[json['source']] ?? TagSource.manual,
      confidence: confidence is num ? confidence.toDouble().clamp(0, 1) : null,
    );
  }
}

/// What recognition saw on a clip, for search ("clips with a cat"): a
/// [label] such as `human`, `cat` or `bicycle`, with no identity (that's
/// what subjects are for). Kept once per clip, from the first frame it was
/// seen on ([ms] into the recording), with that frame's [score].
@immutable
class ObjectTag {
  const ObjectTag({required this.label, required this.ms, required this.score});

  final String label;
  final int ms;
  final double score;

  Map<String, Object?> toJson() => {'label': label, 'ms': ms, 'score': score};

  /// Null for a malformed entry.
  static ObjectTag? fromJson(Object? json) {
    if (json is! Map) return null;
    final label = json['label'];
    final ms = json['ms'];
    final score = json['score'];
    if (label is! String || label.isEmpty || ms is! num || score is! num) {
      return null;
    }
    return ObjectTag(
      label: label,
      ms: ms.toInt(),
      score: score.toDouble().clamp(0, 1),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ObjectTag &&
      other.label == label &&
      other.ms == ms &&
      other.score == score;

  @override
  int get hashCode => Object.hash(label, ms, score);
}

/// A frame grabbed from a clip for tagging: its JPEG and its time.
@immutable
class TagFrame {
  const TagFrame({required this.id, required this.jpeg, required this.ms});

  final String id;
  final Uint8List jpeg;
  final int ms;
}

/// The people and pets named in one clip, as many as needed, each on a
/// frame grabbed from the clip. Stored with the clip's event: the tags as
/// `annotations`, the frame images as `frames` (id -> JPEG). Its [objects]
/// (`objectTags`) sit beside them. Listeners hear every change.
class ClipAnnotations extends ChangeNotifier {
  ClipAnnotations([
    Iterable<Annotation> items = const [],
    Map<String, TagFrame> frames = const {},
    Iterable<ObjectTag>? objects,
  ]) : _items = List.of(items),
       _frames = Map.of(frames),
       _objects = objects == null ? null : List.of(objects);

  /// Rebuilds the list from an event record's `annotations`, `frames` and
  /// `objectTags`.
  factory ClipAnnotations.fromJson(
    Object? annotations, [
    Object? frames,
    Object? objectTags,
  ]) {
    final items = [
      if (annotations is List)
        for (final entry in annotations) ?Annotation.fromJson(entry),
    ];
    final times = {
      for (final a in items)
        if (a.frameId != null) a.frameId!: a.frameMs ?? 0,
    };
    final restored = <String, TagFrame>{};
    if (frames is Map) {
      for (final MapEntry(:key, :value) in frames.entries) {
        final jpeg = _bytes(value);
        if (key is String && jpeg != null) {
          restored[key] = TagFrame(id: key, jpeg: jpeg, ms: times[key] ?? 0);
        }
      }
    }
    return ClipAnnotations(
      items,
      restored,
      objectTags is List
          ? [for (final entry in objectTags) ?ObjectTag.fromJson(entry)]
          : null,
    );
  }

  final List<Annotation> _items;
  final Map<String, TagFrame> _frames;
  List<ObjectTag>? _objects;

  /// What recognition saw on the clip, by first sighting; null until the
  /// clip has been searched for objects (empty: searched, nothing seen).
  List<ObjectTag>? get objects =>
      _objects == null ? null : List.unmodifiable(_objects!);

  /// Sets what recognition saw, once the clip has been searched.
  void setObjects(Iterable<ObjectTag> objects) {
    _objects = List.of(objects);
    notifyListeners();
  }

  /// Every entry, suggestions included (as stored).
  List<Annotation> get items => List.unmodifiable(_items);

  /// The tags: every entry but suggestions waiting to be confirmed.
  List<Annotation> get tags => [
    for (final a in _items)
      if (a.source != TagSource.suggested) a,
  ];

  /// No entries at all, suggestions included.
  bool get isEmpty => _items.isEmpty;

  /// The frames entries are on, by id (suggestions' frames included).
  Map<String, TagFrame> get frames => Map.unmodifiable(_frames);

  /// The frames [tags] are on, by id.
  Map<String, TagFrame> get tagFrames => {
    for (final id in {for (final a in tags) ?a.frameId}) id: ?_frames[id],
  };

  /// The tags on [frameId] (not suggestions).
  List<Annotation> on(String frameId) =>
      tags.where((a) => a.frameId == frameId).toList();

  Annotation? byId(String id) {
    for (final a in _items) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// A grabbed frame (its JPEG, at [ms] in the recording) ready for tags to
  /// be clicked on it. It's kept once its first tag is added.
  TagFrame newFrame(Uint8List jpeg, int ms) =>
      TagFrame(id: AppEvent.newId(), jpeg: jpeg, ms: ms);

  /// Adds [name] at ([x], [y]) on [frame]; blank names are ignored.
  /// Recognition passes its [source] and [confidence].
  Annotation? add(
    String name,
    double x,
    double y, {
    TagFrame? frame,
    TagSource source = TagSource.manual,
    double? confidence,
  }) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    if (frame != null) _frames[frame.id] = frame;
    final annotation = Annotation(
      id: AppEvent.newId(),
      name: trimmed,
      x: x.clamp(0, 1),
      y: y.clamp(0, 1),
      frameId: frame?.id,
      frameMs: frame?.ms,
      source: source,
      confidence: confidence,
    );
    _items.add(annotation);
    notifyListeners();
    return annotation;
  }

  void rename(String id, String name) {
    final trimmed = name.trim();
    final i = _items.indexWhere((a) => a.id == id);
    if (i < 0 || trimmed.isEmpty || _items[i].name == trimmed) return;
    _items[i] = _items[i].copyWith(name: trimmed);
    notifyListeners();
  }

  /// Makes a suggestion a tag: someone confirmed it.
  void confirm(String id) {
    final i = _items.indexWhere((a) => a.id == id);
    if (i < 0 || _items[i].source != TagSource.suggested) return;
    _items[i] = _items[i].copyWith(source: TagSource.confirmed);
    notifyListeners();
  }

  /// Removes a tag, and its frame once no tag uses it.
  void remove(String id) {
    final i = _items.indexWhere((a) => a.id == id);
    if (i < 0) return;
    final frameId = _items.removeAt(i).frameId;
    if (frameId != null && _items.every((a) => a.frameId != frameId)) {
      _frames.remove(frameId);
    }
    notifyListeners();
  }

  /// Takes on [other]'s entries, the frames they use and its object tags:
  /// the same clip, as changed on another device.
  void replaceWith(ClipAnnotations other) {
    _items
      ..clear()
      ..addAll(other._items);
    _frames
      ..clear()
      ..addAll({
        for (final id in {for (final a in _items) ?a.frameId})
          id: ?other._frames[id],
      });
    _objects = other._objects == null ? null : List.of(other._objects!);
    notifyListeners();
  }

  List<Map<String, Object?>> toJson() => [for (final a in _items) a.toJson()];

  /// The frames tags use, as stored: id -> JPEG bytes.
  Map<String, Uint8List> framesToRecord() => {
    for (final id in {for (final a in _items) ?a.frameId})
      if (_frames[id] case final frame?) id: frame.jpeg,
  };

  static Uint8List? _bytes(Object? value) => value is Uint8List
      ? value
      : (value is List ? Uint8List.fromList(value.cast<int>()) : null);
}
