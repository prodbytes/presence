import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:presence_app/identity/device_id.dart';

void main() {
  test('IDs are adjective_adjective_thing, with two different adjectives', () {
    final random = Random(1);
    for (var i = 0; i < 2000; i++) {
      final id = DeviceId.generate(random);
      expect(id, matches(DeviceId.pattern));
      final [first, second, thing] = id.split('_');
      expect(first, isNot(second));
      expect(DeviceId.adjectives, contains(first));
      expect(DeviceId.adjectives, contains(second));
      expect(DeviceId.things, contains(thing));
    }
  });

  test('the dictionary is big enough not to collide', () {
    // Each word once, lowercase letters only (so IDs match the pattern).
    for (final words in [DeviceId.adjectives, DeviceId.things]) {
      expect(words.toSet(), hasLength(words.length));
      expect(words, everyElement(matches(RegExp(r'^[a-z]+$'))));
    }
    expect(DeviceId.adjectives.length, greaterThan(1000));
    expect(DeviceId.things.length, greaterThan(1000));
    // Over a billion IDs: two of 5,000 devices match with about 1% odds.
    expect(DeviceId.combinations, greaterThan(1000000000));
    final ids = {for (var i = 0; i < 5000; i++) DeviceId.generate()};
    expect(ids.length, greaterThan(4990));
  });
}
