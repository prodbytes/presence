import 'package:flutter_test/flutter_test.dart';
import 'package:presence_app/annotations.dart';

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
}
