import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The battery's charge, in percent, whether it's charging, and its
/// temperature in °C where the platform reports it (Android only; null
/// elsewhere).
typedef BatteryReading = ({int level, BatteryState state, double? celsius});

/// Reads this device's battery. Null when there's no reading: the browser
/// has no Battery Status API (Firefox, Safari), or the platform has none.
abstract class BatteryReader {
  Future<BatteryReading?> read();

  /// Fires when charging starts or stops.
  Stream<void> get changes;
}

/// [BatteryReader] through `battery_plus`: the platform's battery on
/// Android and iOS, `navigator.getBattery()` on the web.
class DeviceBattery implements BatteryReader {
  final _battery = Battery();

  /// The app's own Android channel (`MainActivity`): the battery's
  /// temperature, which `battery_plus` doesn't give.
  static const _device = MethodChannel('presence/device');

  @override
  Future<BatteryReading?> read() async {
    try {
      final state = await _battery.batteryState;
      // On the web, "unknown" means the browser has no Battery Status API;
      // the level it gives then is a meaningless 0.
      if (kIsWeb && state == BatteryState.unknown) return null;
      return (
        level: await _battery.batteryLevel,
        state: state,
        celsius: await _temperature(),
      );
    } catch (e) {
      debugPrint('Presence: no battery reading: $e');
      return null;
    }
  }

  /// Android only: iOS has no public API for it (only a thermal state, not
  /// degrees) and neither do browsers.
  static Future<double?> _temperature() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      return await _device.invokeMethod<double>('batteryTemperature');
    } catch (e) {
      debugPrint('Presence: no battery temperature: $e');
      return null;
    }
  }

  @override
  Stream<void> get changes => _battery.onBatteryStateChanged.handleError(
    (Object e) => debugPrint('Presence: no battery changes: $e'),
  );
}

/// The latest [BatteryReading], read when created, when charging starts or
/// stops, and every [interval] (the level changes without an event).
/// Listeners hear each new reading.
class BatteryController extends ChangeNotifier {
  BatteryController(
    this._reader, {
    this.interval = const Duration(minutes: 1),
  }) {
    _read();
    _changes = _reader.changes.listen((_) => _read(), onError: (_) {});
    _timer = Timer.periodic(interval, (_) => _read());
  }

  final BatteryReader _reader;
  final Duration interval;
  late final StreamSubscription<void> _changes;
  late final Timer _timer;
  bool _disposed = false;

  /// False until the first read finishes.
  bool get ready => _ready;
  bool _ready = false;

  /// Null once read when there's no battery reading.
  BatteryReading? get reading => _reading;
  BatteryReading? _reading;

  Future<void> _read() async {
    final reading = await _reader.read();
    if (_disposed) return;
    _ready = true;
    _reading = reading;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _changes.cancel();
    _timer.cancel();
    super.dispose();
  }
}
