import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Where a [DeviceLocation] came from.
enum LocationSource {
  /// The device's own positioning (GPS, Wi-Fi, the browser's geolocation).
  device,

  /// Set by hand, by moving the map or pasting a position in Settings.
  /// It's kept until the user asks for the device's position again. A
  /// pinned position ([DeviceLocation.pinned]) is one of these too.
  map,
}

/// Whether [latitude] and [longitude] are a position on Earth: finite,
/// latitude -90 to 90, longitude -180 to 180.
bool validCoordinates(double latitude, double longitude) =>
    latitude.isFinite &&
    longitude.isFinite &&
    latitude.abs() <= 90 &&
    longitude.abs() <= 180;

/// Where this device is: a point on the map, how sure the device was, and
/// how it was found. Every event records the location in force when it's
/// published (`AppEvent.location`).
@immutable
class DeviceLocation {
  const DeviceLocation({
    required this.latitude,
    required this.longitude,
    required this.source,
    required this.time,
    this.accuracy,
    this.pinned = false,
  }) : assert(!pinned || source == LocationSource.map);

  final double latitude;
  final double longitude;

  /// The radius, in meters, the device says it's within. Only for
  /// [LocationSource.device].
  final double? accuracy;

  final LocationSource source;

  /// When it was found, or set on the map (or pinned).
  final DateTime time;

  /// Pinned in Settings: fixed for this device until unpinned. Every event
  /// uses it, and the device's own positioning isn't asked. Always a
  /// [LocationSource.map] location; in JSON, `pinned: true` (absent
  /// otherwise, so earlier readers see an ordinary map location).
  final bool pinned;

  Map<String, Object?> toJson() => {
    'lat': latitude,
    'lng': longitude,
    'accuracy': accuracy,
    'source': source.name,
    if (pinned) 'pinned': true,
    'time': time.millisecondsSinceEpoch,
  };

  /// Reads [toJson]'s form; null for anything else (no location, or a
  /// damaged record).
  static DeviceLocation? fromJson(Object? json) {
    if (json is! Map) return null;
    final lat = json['lat'];
    final lng = json['lng'];
    final source = LocationSource.values.asNameMap()[json['source']];
    final time = json['time'];
    if (lat is! num ||
        lng is! num ||
        source == null ||
        time is! int ||
        !validCoordinates(lat.toDouble(), lng.toDouble())) {
      return null;
    }
    final accuracy = json['accuracy'];
    return DeviceLocation(
      latitude: lat.toDouble(),
      longitude: lng.toDouble(),
      accuracy: accuracy is num ? accuracy.toDouble() : null,
      source: source,
      time: DateTime.fromMillisecondsSinceEpoch(time),
      pinned: json['pinned'] == true && source == LocationSource.map,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DeviceLocation &&
      other.latitude == latitude &&
      other.longitude == longitude &&
      other.accuracy == accuracy &&
      other.source == source &&
      other.time == time &&
      other.pinned == pinned;

  @override
  int get hashCode =>
      Object.hash(latitude, longitude, accuracy, source, time, pinned);
}

/// Why the device's position couldn't be read.
class LocationUnavailable implements Exception {
  const LocationUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reads the device's position.
abstract interface class Locator {
  /// The device's position, as precise as it can give. Throws
  /// [LocationUnavailable] when it can't (permission denied, location off).
  Future<({double latitude, double longitude, double? accuracy})> locate();
}

/// The device's positioning through `geolocator`: GPS on phones, the
/// Geolocation API in browsers. Asks for permission the first time.
class DeviceLocator implements Locator {
  @override
  Future<({double latitude, double longitude, double? accuracy})>
  locate() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const LocationUnavailable('Location is turned off');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw const LocationUnavailable('Location permission was denied');
    }
    final position = await Geolocator.getCurrentPosition(
      // As close as the device can get.
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        timeLimit: Duration(seconds: 30),
      ),
    );
    return (
      latitude: position.latitude,
      longitude: position.longitude,
      // Zero means unknown.
      accuracy: position.accuracy > 0 ? position.accuracy : null,
    );
  }
}

/// This device's location: the pinned one, or the one set on the map, if
/// there is one, otherwise the device's own position, read at launch.
/// Saved, so a location set by hand survives restarts.
class LocationController extends ChangeNotifier {
  LocationController({
    required this._locator,
    required this._load,
    required this._save,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Locator _locator;
  final Future<Map<String, Object?>?> Function() _load;
  final Future<void> Function(Map<String, Object?> json) _save;
  final DateTime Function() _now;
  bool _disposed = false;

  /// The location in force, or null while it's unknown.
  DeviceLocation? get location => _location;
  DeviceLocation? _location;

  /// Reading the device's position.
  bool get locating => _locating;
  bool _locating = false;

  /// Why the last reading failed, until the next one succeeds.
  String? get error => _error;
  String? _error;

  /// The location in force is pinned: fixed until [unpin], and the device
  /// isn't asked where it is.
  bool get pinned => _location?.pinned ?? false;

  /// Restores the saved location. Unless it was set on the map (or
  /// pinned), then asks the device where it is now.
  Future<void> init() async {
    try {
      final saved = DeviceLocation.fromJson(await _load());
      // Set by hand meanwhile: keep that.
      if (saved != null && _location == null && !_disposed) {
        _location = saved;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Presence: could not load the location: $e');
    }
    if (_location?.source != LocationSource.map) await locate();
  }

  /// Asks the device where it is, and uses that from now on (replacing a
  /// location set on the map). Does nothing while [pinned]: unpin first.
  Future<void> locate() async {
    if (_locating || _disposed || pinned) return;
    _locating = true;
    notifyListeners();
    final edits = _mapEdits;
    try {
      final at = await _locator.locate();
      _error = null;
      // Moved on the map (or pinned) while the device was answering: that
      // wins.
      if (edits != _mapEdits || pinned) return;
      _set(
        DeviceLocation(
          latitude: at.latitude,
          longitude: at.longitude,
          accuracy: at.accuracy,
          source: LocationSource.device,
          time: _now(),
        ),
      );
    } on LocationUnavailable catch (e) {
      _error = e.message;
    } catch (e) {
      // No plugin (tests, unsupported platforms), a timeout, …
      debugPrint('Presence: could not read the location: $e');
      _error = 'Location unavailable';
    } finally {
      _locating = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Sets the location by hand (the map was moved). It's kept until
  /// [locate] is called again. Ignored while [pinned] (use [pin] to move
  /// the pin), or for a position off the Earth.
  void setOnMap(double latitude, double longitude) {
    if (pinned || !validCoordinates(latitude, longitude)) return;
    _mapEdits++;
    _set(
      DeviceLocation(
        latitude: latitude,
        longitude: longitude,
        source: LocationSource.map,
        time: _now(),
      ),
    );
  }

  /// Pins this device's position: at [latitude], [longitude], or where the
  /// location in force is. From then on every event uses it, the device's
  /// own positioning isn't asked (so no permission prompt), and moving the
  /// map doesn't change it; until [unpin]. Saved, so it survives restarts,
  /// and synced with this device's settings. Throws an [ArgumentError] for
  /// a position off the Earth (latitude -90 to 90, longitude -180 to 180),
  /// and a [StateError] with neither a position nor a location in force.
  void pin([double? latitude, double? longitude]) {
    final lat = latitude ?? _location?.latitude;
    final lng = longitude ?? _location?.longitude;
    if (lat == null || lng == null) {
      throw StateError('No position to pin');
    }
    if (!validCoordinates(lat, lng)) {
      throw ArgumentError('Not a position: $lat, $lng');
    }
    _mapEdits++;
    _set(
      DeviceLocation(
        latitude: lat,
        longitude: lng,
        source: LocationSource.map,
        pinned: true,
        time: _now(),
      ),
    );
  }

  /// Unpins: back to the automatic location. The pinned point stands, as a
  /// reading, until the device answers where it is.
  Future<void> unpin() async {
    final at = _location;
    if (at == null || !at.pinned || _disposed) return;
    _mapEdits++;
    _set(_asReading(at));
    await locate();
  }

  /// Takes on the location set on the map (or pinned) in this device's
  /// settings from the cloud ([onMap]), already saved; or, with none set
  /// there, asks the device where it is instead of keeping one set here.
  void applyRemote(DeviceLocation? onMap) {
    if (_disposed) return;
    if (onMap != null) {
      _mapEdits++;
      _location = onMap;
      notifyListeners();
    } else if (_location case final at? when at.source == LocationSource.map) {
      // Saved as a reading already (by the settings sync).
      _location = _asReading(at);
      notifyListeners();
      locate().ignore();
    }
  }

  /// [at]'s point as a reading of the device: no longer set by hand.
  static DeviceLocation _asReading(DeviceLocation at) => DeviceLocation(
    latitude: at.latitude,
    longitude: at.longitude,
    source: LocationSource.device,
    time: at.time,
  );

  /// Counts [setOnMap] calls, so a slow [locate] doesn't undo one.
  int _mapEdits = 0;

  void _set(DeviceLocation location) {
    if (_disposed) return;
    _location = location;
    notifyListeners();
    _save(location.toJson()).catchError(
      (Object e) => debugPrint('Presence: could not save the location: $e'),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
