import 'package:flutter/foundation.dart';

import 'events.dart';

/// A person or pet someone named on a frame of a clip, at the spot they
/// clicked.
@immutable
class Annotation {
  const Annotation({
    required this.id,
    required this.name,
    required this.x,
    required this.y,
    this.frameId,
    this.frameMs,
  });

  final String id;
  final String name;

  /// Where on the frame, from 0 (left/top) to 1 (right/bottom), relative to
  /// the video frame itself.
  final double x;
  final double y;

  /// The frame this was clicked on (its image is in
  /// [ClipAnnotations.frames]), and its time in the clip's recording.
  final String? frameId;
  final int? frameMs;

  Annotation copyWith({String? name}) => Annotation(
    id: id,
    name: name ?? this.name,
    x: x,
    y: y,
    frameId: frameId,
    frameMs: frameMs,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'x': x,
    'y': y,
    'frameId': ?frameId,
    'frameMs': ?frameMs,
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
    return Annotation(
      id: id,
      name: name,
      x: x.toDouble().clamp(0, 1),
      y: y.toDouble().clamp(0, 1),
      frameId: frameId is String ? frameId : null,
      frameMs: frameMs is num ? frameMs.toInt() : null,
    );
  }
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
/// `annotations`, the frame images as `frames` (id -> JPEG). Listeners hear
/// every change.
class ClipAnnotations extends ChangeNotifier {
  ClipAnnotations([
    Iterable<Annotation> items = const [],
    Map<String, TagFrame> frames = const {},
  ]) : _items = List.of(items),
       _frames = Map.of(frames);

  /// Rebuilds the list from an event record's `annotations` and `frames`.
  factory ClipAnnotations.fromJson(Object? annotations, [Object? frames]) {
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
    return ClipAnnotations(items, restored);
  }

  final List<Annotation> _items;
  final Map<String, TagFrame> _frames;

  List<Annotation> get items => List.unmodifiable(_items);

  bool get isEmpty => _items.isEmpty;

  /// The frames tags were clicked on, by id.
  Map<String, TagFrame> get frames => Map.unmodifiable(_frames);

  /// The tags clicked on [frameId].
  List<Annotation> on(String frameId) =>
      _items.where((a) => a.frameId == frameId).toList();

  /// A grabbed frame (its JPEG, at [ms] in the recording) ready for tags to
  /// be clicked on it. It's kept once its first tag is added.
  TagFrame newFrame(Uint8List jpeg, int ms) =>
      TagFrame(id: AppEvent.newId(), jpeg: jpeg, ms: ms);

  /// Adds [name] at ([x], [y]) on [frame]; blank names are ignored.
  Annotation? add(String name, double x, double y, {TagFrame? frame}) {
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
