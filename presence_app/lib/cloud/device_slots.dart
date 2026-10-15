/// The plans a member can be on, and how many of a profile's devices show
/// their events on each. The auth API decides the limit
/// (`ProfileHandler.deviceLimit`); these say the same.
enum Plan {
  /// Live sync only: the first [DeviceSlots.freeLimit] devices show.
  free(DeviceSlots.freeLimit),

  /// Cloud backup: the first [DeviceSlots.premiumLimit] devices show.
  premium(DeviceSlots.premiumLimit),

  /// Premium with more devices: the first [DeviceSlots.proLimit] show.
  /// Admins have it too.
  pro(DeviceSlots.proLimit);

  const Plan(this.deviceLimit);

  /// How many of the profile's devices show their events.
  final int deviceLimit;

  /// The plan whose limit [limit] is (the auth API's `deviceLimit`): the
  /// largest whose limit it reaches.
  static Plan ofLimit(int limit) => limit >= DeviceSlots.proLimit
      ? pro
      : limit >= DeviceSlots.premiumLimit
      ? premium
      : free;

  /// The plan with more devices, to upgrade to; null for Pro.
  Plan? get next => switch (this) {
    free => premium,
    premium => pro,
    pro => null,
  };
}

/// A profile's devices as the auth API lists them (`POST
/// /api/auth/credentials`): in the order they first asked for credentials,
/// with how many of the first show their events ([Plan.deviceLimit]:
/// [freeLimit] for a free profile, [premiumLimit] for a premium one,
/// [proLimit] for a pro one or an admin's). The others still sync, but
/// their events are hidden: on the devices that show, the others' events;
/// on one that doesn't, every other device's.
class DeviceSlots {
  const DeviceSlots({required this.limit, required this.devices});

  /// How many devices show for a free profile.
  static const int freeLimit = 10;

  /// How many devices show for a premium profile.
  static const int premiumLimit = 25;

  /// How many devices show for a pro profile (or an admin's), and the most
  /// a profile lists.
  static const int proLimit = 50;

  /// Where to sign up for Premium.
  static final Uri signUp = Uri.parse('https://nu01.com');

  /// How many of [devices] show.
  final int limit;

  /// The profile's devices, in the order they came.
  final List<String> devices;

  /// The auth API's answer's `deviceLimit` and `devices`; null when it has
  /// neither (an older API).
  static DeviceSlots? fromJson(Map<String, Object?> json) {
    final limit = json['deviceLimit'];
    final devices = json['devices'];
    if (limit is! int || devices is! List) return null;
    return DeviceSlots(
      limit: limit,
      devices: List.unmodifiable(devices.whereType<String>()),
    );
  }

  /// The plan whose limit this is.
  Plan get plan => Plan.ofLimit(limit);

  /// The devices that show: the first [limit] of [devices].
  List<String> get shown => devices.take(limit).toList();

  /// Whether [device] is one of those that show.
  bool shows(String device) {
    final index = devices.indexOf(device);
    return index >= 0 && index < limit;
  }

  /// Whether every place is taken: a device not listed yet won't show.
  bool get full => devices.length >= limit;

  /// The devices whose events show on [thisDevice]: those that [shows],
  /// when it's one of them; otherwise only its own.
  Set<String> visibleFrom(String thisDevice) =>
      shows(thisDevice) ? shown.toSet() : {thisDevice};

  @override
  bool operator ==(Object other) =>
      other is DeviceSlots &&
      other.limit == limit &&
      _sameList(other.devices, devices);

  @override
  int get hashCode => Object.hash(limit, Object.hashAll(devices));

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() => 'DeviceSlots($limit of $devices)';
}

/// A cloud session that knows its profile's [DeviceSlots] (from the auth
/// API's credentials).
abstract interface class DeviceSlotsSession {
  DeviceSlots? get deviceSlots;
}

/// A backend that can take a device out of its profile's [DeviceSlots]
/// (when the device is deleted), so the next one takes its place.
abstract interface class DeviceRegistry {
  /// The profile's slots after; null when the auth API doesn't say.
  Future<DeviceSlots?> removeDevice(String idToken, String device);
}
