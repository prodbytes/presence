import 'dart:math';

import 'animal_words.dart';
import 'device_id.dart';

/// A profile's ID: two different adjectives and an animal, joined by
/// underscores, such as `automatic_paranoid_axolotl`. Like a [DeviceId], the
/// app makes one at its first start and keeps it in storage (see
/// `EventStore.profileId`), owned by nobody. The first sign-in claims it
/// (`GET /api/auth?profile=<id>`), and the profile the auth API answers
/// with is kept from then on.
///
/// The adjectives are the device ID's; with 1031 animals there are about
/// 1.1 billion IDs. The auth API's `ProfileId` uses the same words.
abstract final class ProfileId {
  static final List<String> animals = List.unmodifiable(
    animalWords.split(RegExp(r'\s+')).where((w) => w.isNotEmpty),
  );

  /// What an ID looks like: `adjective_adjective_animal`, lowercase.
  static final RegExp pattern = DeviceId.pattern;

  /// A new random ID, from a cryptographically secure generator unless
  /// [random] is given.
  static String generate([Random? random]) {
    final r = random ?? Random.secure();
    final adjectives = DeviceId.adjectives;
    final first = r.nextInt(adjectives.length);
    // Two different adjectives: pick the second from the others.
    var second = r.nextInt(adjectives.length - 1);
    if (second >= first) second++;
    final animal = animals[r.nextInt(animals.length)];
    return '${adjectives[first]}_${adjectives[second]}_$animal';
  }
}
