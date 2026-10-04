import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

/// OpenStreetMap's tiles (no API key), for the app's maps.
Widget openStreetMapTiles() => TileLayer(
  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  userAgentPackageName: 'com.nu01.presence',
);

/// The tiles' credit, small in the bottom-left corner. OpenStreetMap's
/// tiles require it.
class MapAttribution extends StatelessWidget {
  const MapAttribution({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.bottomLeft,
      child: Container(
        margin: const EdgeInsets.all(4),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          '© OpenStreetMap contributors',
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Zoom in (+) over zoom out (−), as one small control, for the app's
/// maps. A null callback disables its button.
class MapZoomButtons extends StatelessWidget {
  const MapZoomButtons({
    super.key,
    required this.onZoomIn,
    required this.onZoomOut,
    this.keyPrefix = '',
  });

  /// Before the buttons' keys (`zoom-in`, `zoom-out`), to tell maps apart.
  final String keyPrefix;

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
            key: Key('${keyPrefix}zoom-in'),
            tooltip: 'Zoom in',
            icon: const Icon(Icons.add),
            onPressed: onZoomIn,
          ),
          const SizedBox(width: 32, child: Divider(height: 1)),
          IconButton(
            key: Key('${keyPrefix}zoom-out'),
            tooltip: 'Zoom out',
            icon: const Icon(Icons.remove),
            onPressed: onZoomOut,
          ),
        ],
      ),
    );
  }
}
