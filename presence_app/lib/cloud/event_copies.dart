import 'package:flutter/foundation.dart';

import '../storage/event_store.dart';
import 'live_sync.dart';

/// Who holds a copy of one event, as this device knows it: this device
/// ([self]: the event and all its media are stored here), the [cloud] (the
/// event and its media are in the bucket), and the profile's other
/// [devices] that said they've stored one (a `copied` ack over live sync),
/// with when they said so (ms since the epoch, by their clock). [acked]:
/// this device has told the others it holds one.
@immutable
class EventHolders {
  const EventHolders({
    this.self = false,
    this.cloud = false,
    this.acked = false,
    this.devices = const {},
  });

  final bool self;
  final bool cloud;
  final bool acked;
  final Map<String, int> devices;

  EventHolders copyWith({
    bool? self,
    bool? cloud,
    bool? acked,
    Map<String, int>? devices,
  }) => EventHolders(
    self: self ?? this.self,
    cloud: cloud ?? this.cloud,
    acked: acked ?? this.acked,
    devices: devices ?? this.devices,
  );

  Map<String, Object?> toJson() => {
    if (self) 's': true,
    if (cloud) 'c': true,
    if (acked) 'a': true,
    if (devices.isNotEmpty) 'd': devices,
  };

  /// The holders in [json] (as [toJson] wrote it); unsafe device IDs and
  /// anything malformed are left out.
  static EventHolders fromJson(Object? json) {
    if (json is! Map) return const EventHolders();
    final devices = <String, int>{};
    if (json['d'] case final Map d) {
      for (final MapEntry(:key, :value) in d.entries) {
        if (LiveSync.isSafeId(key) && value is int) devices[key] = value;
        if (devices.length >= EventCopies.maxDevicesPerEvent) break;
      }
    }
    return EventHolders(
      self: json['s'] == true,
      cloud: json['c'] == true,
      acked: json['a'] == true,
      devices: devices,
    );
  }
}

/// What the copies badge says about one event ([EventCopies.summaryOf]):
/// how many holders, who they are ("This device", "Cloud", device IDs),
/// the short [label] and the [tooltip].
@immutable
class CopiesSummary {
  const CopiesSummary({
    required this.holders,
    required this.cloud,
    required this.liveOn,
  });

  /// The holders, this device first, then the cloud, then other devices.
  final List<String> holders;

  /// Whether the cloud is among them.
  final bool cloud;

  /// Whether live sync is on here (otherwise other devices' copies are
  /// only partly known).
  final bool liveOn;

  int get count => holders.length;

  /// "3 copies", "1 copy", or "1 copy — not uploaded yet" for an event
  /// held only here.
  String get label {
    if (count == 0) return 'No copy known';
    if (count == 1 && !cloud && holders.first == EventCopies.thisDevice) {
      return '1 copy — not uploaded yet';
    }
    return count == 1 ? '1 copy' : '$count copies';
  }

  /// The holders by name, and why the count may be short.
  String get tooltip {
    final who = holders.isEmpty ? 'No copy known' : holders.join(', ');
    return liveOn
        ? who
        : "$who\nLive sync is off: other devices' copies are unknown";
  }
}

/// Which holders have a copy of each event ([EventHolders]): kept up to
/// date by cloud sync (this device and the cloud) and by other devices'
/// `copied` acks over live sync, saved in the `settings` store (record
/// `copies`) so it survives a restart, and bounded to the [maxTracked]
/// most recently changed events.
class EventCopies extends ChangeNotifier {
  EventCopies({this._store, this.maxTracked = 2000}) {
    _loaded = _load();
  }

  final Future<EventStore>? _store;

  /// The most events tracked; the least recently changed go first.
  final int maxTracked;

  /// The most other devices remembered per event.
  static const int maxDevicesPerEvent = 32;

  /// The settings-store record that holds them.
  static const String settingsKey = 'copies';

  /// How this device shows among the holders.
  static const String thisDevice = 'This device';

  /// How the cloud shows among the holders.
  static const String cloudHolder = 'Cloud';

  /// By event ID, least recently changed first.
  final _holders = <String, EventHolders>{};

  late final Future<void> _loaded;

  /// The save under way, if any; [_dirty]: changed since it started, so
  /// it's saved once more after it (a burst of changes is a few saves).
  Future<void>? _saving;
  bool _dirty = false;
  bool _disposed = false;

  /// Completes once the saved holders are loaded.
  Future<void> get loaded => _loaded;

  /// This device's ID, once known: an event recorded here is held here.
  String? get deviceId => _deviceId;
  String? _deviceId;
  set deviceId(String? value) {
    if (value == _deviceId) return;
    _deviceId = value;
    notifyListeners();
  }

  /// Whether live sync is on here (set by cloud sync). Off, other devices'
  /// copies aren't heard of.
  bool get liveOn => _liveOn;
  bool _liveOn = false;
  set liveOn(bool value) {
    if (value == _liveOn) return;
    _liveOn = value;
    notifyListeners();
  }

  /// What's known of event [id]'s holders, if anything.
  EventHolders? of(String id) => _holders[id];

  /// The holders of event [id], recorded on device [origin] (which holds
  /// it: it recorded it).
  CopiesSummary summaryOf(String id, {String? origin}) {
    final known = _holders[id] ?? const EventHolders();
    final me = _deviceId;
    final mine = origin != null && origin == me;
    final others = <String>[
      if (origin != null && !mine) origin,
      for (final d in known.devices.keys.toList()..sort())
        if (d != me && d != origin) d,
    ];
    return CopiesSummary(
      holders: [
        if (known.self || mine) thisDevice,
        if (known.cloud) cloudHolder,
        ...others,
      ],
      cloud: known.cloud,
      liveOn: _liveOn,
    );
  }

  /// Records whether this device ([self]) and the cloud ([cloud]) hold
  /// event [id]. Returns whether that changed anything.
  bool setLocal(String id, {required bool self, required bool cloud}) {
    final known = _holders[id] ?? const EventHolders();
    if (known.self == self && known.cloud == cloud) return false;
    // No longer held here: the others must hear of it again once it is.
    _put(
      id,
      known.copyWith(self: self, cloud: cloud, acked: self && known.acked),
    );
    return true;
  }

  /// Device [deviceId] said at [at] that it holds event [id]. Returns
  /// whether it's news (a repeated ack isn't).
  bool addDevice(String id, String deviceId, int at) {
    if (!LiveSync.isSafeId(id) || !LiveSync.isSafeId(deviceId)) return false;
    final known = _holders[id] ?? const EventHolders();
    if (known.devices.containsKey(deviceId)) return false;
    final devices = {...known.devices, deviceId: at};
    if (devices.length > maxDevicesPerEvent) {
      // The oldest ack goes.
      final oldest = devices.entries.reduce(
        (a, b) => a.value <= b.value ? a : b,
      );
      devices.remove(oldest.key);
    }
    _put(id, known.copyWith(devices: devices));
    return true;
  }

  /// This device told the others it holds the events [ids].
  void markAcked(Iterable<String> ids) {
    for (final id in ids) {
      final known = _holders[id];
      if (known == null || known.acked || !known.self) continue;
      _put(id, known.copyWith(acked: true));
    }
  }

  /// Forgets device [deviceId] as a holder of every event (it was
  /// deleted, see `Persistence.deleteDevice`): it counts again only once
  /// it acks again.
  void forgetDevice(String deviceId) {
    var changed = false;
    for (final MapEntry(key: id, value: known) in Map.of(_holders).entries) {
      if (!known.devices.containsKey(deviceId)) continue;
      _holders[id] = known.copyWith(
        devices: {...known.devices}..remove(deviceId),
      );
      changed = true;
    }
    if (changed) _changed();
  }

  /// Forgets event [id] (deleted).
  void forget(String id) {
    if (_holders.remove(id) == null) return;
    _changed();
  }

  void _put(String id, EventHolders holders) {
    // Most recently changed last.
    _holders.remove(id);
    _holders[id] = holders;
    while (_holders.length > maxTracked) {
      _holders.remove(_holders.keys.first);
    }
    _changed();
  }

  void _changed() {
    if (_disposed) return;
    notifyListeners();
    _scheduleSave();
  }

  void _scheduleSave() {
    if (_store == null) return;
    _dirty = true;
    _saving ??= () async {
      try {
        while (_dirty) {
          _dirty = false;
          await _save();
        }
      } finally {
        _saving = null;
      }
    }();
  }

  Future<void> _load() async {
    final store = _store;
    if (store == null) return;
    try {
      final saved = await (await store).getSettings(settingsKey);
      final events = saved?['events'];
      if (_disposed || events is! Map) return;
      // What changed since the app started wins over what was saved.
      final fresh = Map.of(_holders);
      _holders.clear();
      for (final MapEntry(:key, :value) in events.entries) {
        if (key is String && LiveSync.isSafeId(key)) {
          _holders[key] = EventHolders.fromJson(value);
        }
      }
      for (final MapEntry(:key, :value) in fresh.entries) {
        _holders.remove(key);
        _holders[key] = value;
      }
      while (_holders.length > maxTracked) {
        _holders.remove(_holders.keys.first);
      }
      notifyListeners();
    } catch (e) {
      debugPrint('Presence: could not load event copies: $e');
    }
  }

  Future<void> _save() async {
    final store = _store;
    if (store == null) return;
    try {
      await _loaded;
      await (await store).putSettings(settingsKey, {
        'v': 1,
        'events': {
          for (final MapEntry(:key, :value) in _holders.entries)
            key: value.toJson(),
        },
      });
    } catch (e) {
      debugPrint('Presence: could not save event copies: $e');
    }
  }

  /// Completes once what changed so far is saved (for tests).
  @visibleForTesting
  Future<void> flush() async {
    for (var saving = _saving; saving != null; saving = _saving) {
      await saving;
    }
  }

  @override
  void dispose() {
    // A save under way finishes.
    _disposed = true;
    super.dispose();
  }
}
