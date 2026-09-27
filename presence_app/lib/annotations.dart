import 'package:flutter/foundation.dart';

import 'events.dart';

/// A person or pet someone named in a clip, at the spot they tapped.
@immutable
class Annotation {
  const Annotation({
    required this.id,
    required this.name,
    required this.x,
    required this.y,
  });

  final String id;
  final String name;

  /// Where on the player, from 0 (left/top) to 1 (right/bottom). Relative
  /// to the 16:9 player box the clip plays in (the video is letterboxed
  /// inside it), so a marker lands on the same spot on every screen.
  final double x;
  final double y;

  Annotation copyWith({String? name}) =>
      Annotation(id: id, name: name ?? this.name, x: x, y: y);

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'x': x, 'y': y};

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
    return Annotation(
      id: id,
      name: name,
      x: x.toDouble().clamp(0, 1),
      y: y.toDouble().clamp(0, 1),
    );
  }
}

/// The names people added to one clip, as many as needed. Stored with the
/// clip's event (its `annotations` field); listeners hear every change.
class ClipAnnotations extends ChangeNotifier {
  ClipAnnotations([Iterable<Annotation> items = const []])
    : _items = List.of(items);

  /// Rebuilds the list from an event record's `annotations` field.
  factory ClipAnnotations.fromJson(Object? json) => ClipAnnotations([
    if (json is List)
      for (final entry in json) ?Annotation.fromJson(entry),
  ]);

  final List<Annotation> _items;

  List<Annotation> get items => List.unmodifiable(_items);

  bool get isEmpty => _items.isEmpty;

  /// Adds [name] at ([x], [y]); blank names are ignored.
  Annotation? add(String name, double x, double y) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final annotation = Annotation(
      id: AppEvent.newId(),
      name: trimmed,
      x: x.clamp(0, 1),
      y: y.clamp(0, 1),
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

  void remove(String id) {
    final before = _items.length;
    _items.removeWhere((a) => a.id == id);
    if (_items.length != before) notifyListeners();
  }

  List<Map<String, Object?>> toJson() => [for (final a in _items) a.toJson()];
}
