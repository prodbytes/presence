import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../theme.dart';
import 'device_location.dart';
import 'map_parts.dart';

/// The Device screen: a map centered on this device, with a pin in the
/// middle. Moving the map moves the pin, and sets the device's location by
/// hand; **My location** asks the device again.
class DeviceView extends StatefulWidget {
  const DeviceView({
    super.key,
    required this.location,
    this.deviceId,
    this.tiles,
  });

  final LocationController location;

  /// This device's ID, once it's loaded.
  final String? deviceId;

  /// The map's tiles; defaults to OpenStreetMap. Tests pass a blank layer,
  /// so they don't reach the network.
  final Widget? tiles;

  /// How close the map zooms in on the device's own position.
  static const double deviceZoom = 17;

  /// How far out and in the map goes.
  static const double minZoom = 2;
  static const double maxZoom = 19;

  @override
  State<DeviceView> createState() => _DeviceViewState();
}

class _DeviceViewState extends State<DeviceView> {
  final _map = MapController();
  Timer? _commit;
  bool _ready = false;

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
  void didUpdateWidget(DeviceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.location != widget.location) {
      oldWidget.location.removeListener(_onLocation);
      widget.location.addListener(_onLocation);
    }
  }

  @override
  void dispose() {
    _commit?.cancel();
    _location.removeListener(_onLocation);
    _map.dispose();
    super.dispose();
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
      math.max(_map.camera.zoom, DeviceView.deviceZoom),
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
      (camera.zoom + by).clamp(DeviceView.minZoom, DeviceView.maxZoom),
    );
    setState(() {});
  }

  /// The map's zoom, once it's ready.
  double get _zoomLevel => _ready ? _map.camera.zoom : DeviceView.minZoom;

  /// Longitudes past the date line, back into -180..180.
  static double _wrap(double longitude) => (longitude + 180) % 360 - 180;

  @override
  Widget build(BuildContext context) {
    final location = _location.location;
    return Stack(
      key: const Key('device-page'),
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: location == null
                ? const LatLng(20, 0)
                : LatLng(location.latitude, location.longitude),
            initialZoom: location == null ? 2 : DeviceView.deviceZoom,
            minZoom: DeviceView.minZoom,
            maxZoom: DeviceView.maxZoom,
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
          top: 12,
          left: 12,
          right: 12,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: _LocationCard(
                deviceId: widget.deviceId,
                location: _location,
              ),
            ),
          ),
        ),
        Positioned(
          right: 16,
          bottom: 40,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              // Zoom in and out, for those without pinch or a wheel.
              _ZoomButtons(
                onZoomIn: _ready && _zoomLevel < DeviceView.maxZoom
                    ? () => _zoom(1)
                    : null,
                onZoomOut: _ready && _zoomLevel > DeviceView.minZoom
                    ? () => _zoom(-1)
                    : null,
              ),
              FloatingActionButton(
                heroTag: 'my-location',
                tooltip: 'My location',
                onPressed: _location.locating ? null : _location.locate,
                child: _location.locating
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.my_location),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The device's ID, where it is and how that was found.
class _LocationCard extends StatelessWidget {
  const _LocationCard({required this.deviceId, required this.location});

  final String? deviceId;
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
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.92),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (deviceId case final deviceId?)
              _Field(
                label: 'Device ID',
                child: SelectableText(
                  deviceId,
                  key: const Key('device-page-id'),
                  style: theme.textTheme.titleSmall,
                ),
              ),
            if (at != null)
              _Field(
                label: 'Position (latitude, longitude)',
                child: SelectableText(
                  '${at.latitude.toStringAsFixed(6)}, '
                  '${at.longitude.toStringAsFixed(6)}',
                  key: const Key('device-coordinates'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            Text(
              status,
              key: const Key('device-location-status'),
              style: small,
            ),
            // A failed "My location" keeps the location in force; say why.
            if (at != null && error != null)
              Text(error, style: small?.copyWith(color: scheme.error)),
          ],
        ),
      ),
    );
  }
}

/// A value in the location card, with a small label saying what it is.
class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// Zoom in (+) over zoom out (−), as one small control.
class _ZoomButtons extends StatelessWidget {
  const _ZoomButtons({required this.onZoomIn, required this.onZoomOut});

  final VoidCallback? onZoomIn;
  final VoidCallback? onZoomOut;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      elevation: 3,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: const Key('zoom-in'),
            tooltip: 'Zoom in',
            icon: const Icon(Icons.add),
            onPressed: onZoomIn,
          ),
          const SizedBox(width: 32, child: Divider(height: 1)),
          IconButton(
            key: const Key('zoom-out'),
            tooltip: 'Zoom out',
            icon: const Icon(Icons.remove),
            onPressed: onZoomOut,
          ),
        ],
      ),
    );
  }
}
