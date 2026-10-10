import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:presence_app/annotations.dart';

import 'fakes.dart';

import 'sealed.dart';

void main() {
  test('adds as many names as needed, renames and removes them', () {
    final list = ClipAnnotations();
    var changes = 0;
    list.addListener(() => changes++);

    final rex = list.add('  Rex ', 0.25, 0.5)!;
    final ana = list.add('Ana', 0.8, 0.3)!;
    expect(list.add('   ', 0.1, 0.1), isNull);
    expect(list.items.map((a) => a.name), ['Rex', 'Ana']);
    expect((rex.x, rex.y), (0.25, 0.5));

    list.rename(ana.id, 'Ana Maria');
    list.remove(rex.id);
    expect(list.items.single.name, 'Ana Maria');
    expect(changes, 4);
  });

  test('positions are kept within the player', () {
    final a = ClipAnnotations().add('Cat', -0.2, 1.4)!;
    expect((a.x, a.y), (0.0, 1.0));
  });

  test('round-trips through JSON, skipping malformed entries', () {
    final list = ClipAnnotations()
      ..add('Rex', 0.25, 0.5)
      ..add('Ana', 0.8, 0.3);
    final restored = ClipAnnotations.fromJson([
      ...list.toJson(),
      {'name': 'no id'},
      'garbage',
    ]);
    expect(restored.items.map((a) => (a.name, a.x, a.y)), [
      ('Rex', 0.25, 0.5),
      ('Ana', 0.8, 0.3),
    ]);
    expect(ClipAnnotations.fromJson(null).isEmpty, isTrue);
  });

  test('tags keep their frame; a frame goes when its last tag does', () {
    final list = ClipAnnotations();
    final frame = testFrame(Uint8List.fromList([1, 2, 3]), 7400);
    expect(list.frames, isEmpty); // kept once a tag uses it

    final rex = list.add('Rex', 0.2, 0.3, frame: frame)!;
    final ana = list.add('Ana', 0.6, 0.4, frame: frame)!;
    expect((rex.frameId, rex.frameMs), (frame.id, 7400));
    expect(list.on(frame.id).map((a) => a.name), ['Rex', 'Ana']);
    // Recorded as held: sealed.
    final recorded = list.framesToRecord();
    expect(recorded.keys, [frame.id]);
    expect(recorded[frame.id], frame.sealed);
    expect(opened(recorded[frame.id]!), [1, 2, 3]);

    // Round-trips through the event record (tags + frame images).
    final back = ClipAnnotations.fromJson(list.toJson(), list.framesToRecord());
    expect(back.items.map((a) => (a.name, a.frameId, a.frameMs)), [
      ('Rex', frame.id, 7400),
      ('Ana', frame.id, 7400),
    ]);
    expect(back.frames[frame.id]!.ms, 7400);
    expect(opened(back.frames[frame.id]!.sealed), [1, 2, 3]);

    list.remove(rex.id);
    expect(list.frames.keys, [frame.id]);
    list.remove(ana.id);
    expect(list.frames, isEmpty);
    expect(list.framesToRecord(), isEmpty);
  });

  test('replaceWith takes on another version of the clip', () {
    final here = ClipAnnotations();
    final frame = testFrame(onePixelPng, 100);
    here
      ..add('Rex', 0.1, 0.1, frame: frame)
      ..add('Ana', 0.2, 0.2, frame: frame);
    final there = ClipAnnotations.fromJson(
      [here.toJson()[1]],
      here.framesToRecord(),
      [
        {'label': 'cat', 'ms': 0, 'score': 0.9},
      ],
    );
    var notified = 0;
    here.addListener(() => notified++);
    here.replaceWith(there);
    expect(notified, 1);
    expect(here.tags.map((a) => a.name), ['Ana']);
    expect(here.frames.keys, [frame.id]);
    expect(here.objects!.single.label, 'cat');

    here.replaceWith(ClipAnnotations());
    expect(here.isEmpty, isTrue);
    expect(here.frames, isEmpty);
    expect(here.objects, isNull);
  });
}
