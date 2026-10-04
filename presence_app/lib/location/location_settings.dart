import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../theme.dart';
import 'device_location.dart';
import 'map_parts.dart';

/// The Settings screen's **Location** section: a map centered on this
/// device with a pin in the middle, and to its right the position and where
/// it came from. That column is plain screen, so a drag there scrolls the
/// list, as the map takes drags for itself.
/// Moving the map moves the pin, and sets the device's location by hand;
/// **My location** asks the device again.
class LocationSettings extends StatefulWidget {
  const LocationSettings({
    super.key,
    required this.location,
    this.tiles,
    this.onMapHeld,
  });

  final LocationController location;

  /// The map's tiles; defaults to OpenStreetMap. Tests pass a blank layer,
  /// so they don't reach the network.
  final Widget? tiles;

  /// Told true when a finger (or the mouse) goes down on the map and false
  /// when it's lifted, so the screen around it holds still: a drag on the
  /// map moves the map, not the list or the tabs.
  final ValueChanged<bool>? onMapHeld;

  /// How tall the map is: 40 % of the screen, between [minMapHeight] and
  /// [maxMapHeight], so on a phone there's room around it to scroll the
  /// list (a drag on the map moves the map).
  static double mapHeightFor(Size screen) =>
      (screen.height * 0.4).clamp(minMapHeight, maxMapHeight);
  static const double minMapHeight = 200;
  static const double maxMapHeight = 320;

  /// The position's column, right of the map: [sideShare] of the width,
  /// between [minSideWidth] and [maxSideWidth].
  static double sideWidthFor(double width) =>
      (width * sideShare).clamp(minSideWidth, maxSideWidth);
  static const double sideShare = 0.36;
  static const double minSideWidth = 120;
  static const double maxSideWidth = 320;

  /// How close the map zooms in on the device's own position.
  static const double deviceZoom = 17;

  /// How far out and in the map goes.
  static const double minZoom = 2;
  static const double maxZoom = 19;

  @override
  State<LocationSettings> createState() => _LocationSettingsState();
}

class _LocationSettingsState extends State<LocationSettings> {
  final _map = MapController();
  Timer? _commit;
  bool _ready = false;

  /// Pointers down on the map.
  int _held = 0;

  /// The device position the map last moved to, so it moves once per
  /// reading.
  DeviceLocation? _followed;

  LocationController get _location => widget.location;

  @override
  void initState() {
    super.initState();
    _followed = _location.location;
    _location.addListener(_onLocation);
  }

  @override
  void didUpdateWidget(LocationSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.location != widget.location) {
      oldWidget.location.removeListener(_onLocation);
      widget.location.addListener(_onLocation);
    }
  }

  @override
  void dispose() {
    _commit?.cancel();
    if (_held > 0) widget.onMapHeld?.call(false);
    _location.removeListener(_onLocation);
    _map.dispose();
    super.dispose();
  }

  void _hold(int by) {
    final was = _held > 0;
    _held = math.max(0, _held + by);
    if (was != _held > 0) widget.onMapHeld?.call(_held > 0);
  }

  /// A new reading from the device recenters the map on it. A location set
  /// on the map is already where the map is.
  void _onLocation() {
    setState(() {});
    final location = _location.location;
    if (!_ready ||
        location == null ||
        location.source != LocationSource.device ||
        location == _followed) {
      return;
    }
    _followed = location;
    _map.move(
      LatLng(location.latitude, location.longitude),
      math.max(_map.camera.zoom, LocationSettings.deviceZoom),
    );
  }

  /// The user moved the map: once it settles, its center is the device's
  /// location. Moves made by the app (recentering) don't count.
  void _onMoved(MapCamera camera, bool hasGesture) {
    if (!hasGesture) return;
    _commit?.cancel();
    _commit = Timer(const Duration(milliseconds: 400), () {
      final center = camera.center;
      _location.setOnMap(center.latitude, _wrap(center.longitude));
    });
  }

  /// Zooms one step in ([by] 1) or out (-1), around the center, so the pin
  /// and the device's location stay put.
  void _zoom(double by) {
    if (!_ready) return;
    final camera = _map.camera;
    _map.move(
      camera.center,
      (camera.zoom + by).clamp(
        LocationSettings.minZoom,
        LocationSettings.maxZoom,
      ),
    );
    setState(() {});
  }

  /// The map's zoom, once it's ready.
  double get _zoomLevel => _ready ? _map.camera.zoom : LocationSettings.minZoom;

  /// Longitudes past the date line, back into -180..180.
  static double _wrap(double longitude) => (longitude + 180) % 360 - 180;

  @override
  Widget build(BuildContext context) {
    final location = _location.location;
    final map = Listener(
      onPointerDown: (_) => _hold(1),
      onPointerUp: (_) => _hold(-1),
      onPointerCancel: (_) => _hold(-1),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          key: const Key('location-map'),
          height: LocationSettings.mapHeightFor(MediaQuery.sizeOf(context)),
          child: Stack(
            children: [
              FlutterMap(
                mapController: _map,
                options: MapOptions(
                  initialCenter: location == null
                      ? const LatLng(20, 0)
                      : LatLng(location.latitude, location.longitude),
                  initialZoom: location == null
                      ? 2
                      : LocationSettings.deviceZoom,
                  minZoom: LocationSettings.minZoom,
                  maxZoom: LocationSettings.maxZoom,
                  backgroundColor: Gruvbox.bg0,
                  // North stays up: there's nothing to orient.
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                  ),
                  onMapReady: () => setState(() => _ready = true),
                  onPositionChanged: _onMoved,
                ),
                children: [
                  widget.tiles ?? openStreetMapTiles(),
                  const MapAttribution(),
                ],
              ),
              // The pin's tip marks the center of the map.
              const IgnorePointer(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: 40),
                    child: Icon(
                      Icons.place,
                      key: Key('device-pin'),
                      size: 40,
                      color: Gruvbox.red,
                      shadows: [Shadow(blurRadius: 4)],
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 12,
                bottom: 12,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 12,
                  children: [
                    // Zoom in and out, for those without pinch or a
                    // wheel.
                    MapZoomButtons(
                      onZoomIn: _ready && _zoomLevel < LocationSettings.maxZoom
                          ? () => _zoom(1)
                          : null,
                      onZoomOut: _ready && _zoomLevel > LocationSettings.minZoom
                          ? () => _zoom(-1)
                          : null,
                    ),
                    FloatingActionButton.small(
                      heroTag: 'my-location',
                      tooltip: 'My location',
                      onPressed: _location.locating ? null : _location.locate,
                      child: _location.locating
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.my_location),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, box) => Row(
        key: const Key('location-settings'),
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 16,
        children: [
          Expanded(child: map),
          SizedBox(
            key: const Key('location-position'),
            width: LocationSettings.sideWidthFor(box.maxWidth),
            child: _Position(location: _location),
          ),
        ],
      ),
    );
  }
}

/// Where this device is, and how that was found.
class _Position extends StatelessWidget {
  const _Position({required this.location});

  final LocationController location;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final at = location.location;
    final error = location.error;
    final String status;
    if (at == null) {
      status = location.locating
          ? 'Finding this device…'
          : '${error ?? 'Location unknown'}. Move the map to set it.';
    } else {
      status = switch (at.source) {
        LocationSource.device => [
          "This device's location",
          if (at.accuracy case final accuracy?) '±${accuracy.round()} m',
        ].join(' · '),
        LocationSource.map => 'Set on the map',
      };
    }
    final small = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (at != null) ...[
          Text(
            'Position (latitude, longitude)',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          SelectableText(
            '${at.latitude.toStringAsFixed(6)}, '
            '${at.longitude.toStringAsFixed(6)}',
            key: const Key('device-coordinates'),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
        Text(status, key: const Key('device-location-status'), style: small),
        // A failed "My location" keeps the location in force; say why.
        if (at != null && error != null)
          Text(error, style: small?.copyWith(color: scheme.error)),
      ],
    );
  }
}
