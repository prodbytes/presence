import 'dart:math';

import 'device_words.dart';

/// A device's ID: two different adjectives and a thing, joined by
/// underscores, such as `automatic_paranoid_gadget`. Generated once per
/// install and kept in storage (see `EventStore.deviceId`).
///
/// With 1053 adjectives and 1091 things there are about 1.2 billion IDs:
/// the chance that two of 5,000 devices share one is about 1%.
abstract final class DeviceId {
  static final List<String> adjectives = _words(adjectiveWords);
  static final List<String> things = _words(thingWords);

  /// How many different IDs [generate] can make.
  static int get combinations =>
      adjectives.length * (adjectives.length - 1) * things.length;

  /// What an ID looks like: `adjective_adjective_thing`, lowercase.
  static final RegExp pattern = RegExp(r'^[a-z]+_[a-z]+_[a-z]+$');

  /// A new random ID. [random] defaults to a cryptographically secure one,
  /// so IDs from devices started at the same moment don't follow each
  /// other.
  static String generate([Random? random]) {
    final r = random ?? Random.secure();
    final first = r.nextInt(adjectives.length);
    // Two different adjectives: pick the second from the others.
    var second = r.nextInt(adjectives.length - 1);
    if (second >= first) second++;
    final thing = things[r.nextInt(things.length)];
    return '${adjectives[first]}_${adjectives[second]}_$thing';
  }

  static List<String> _words(String text) =>
      List.unmodifiable(text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty));
}
