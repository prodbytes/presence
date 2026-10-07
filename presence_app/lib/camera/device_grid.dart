/// The All grid's pieces: each other device's latest image
/// ([latestByDevice]), the grid's shape ([gridColumns]) and its cells.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../clips.dart' show ClipRequested;
import '../events.dart';

/// Another device's latest event, and its latest image, for the grid.
class DeviceLatest {
  const DeviceLatest({required this.deviceId, required this.time, this.clip});

  final String deviceId;

  /// When the device's image was taken, or (without one) its latest event.
  final DateTime time;

  /// The device's newest clip with a thumbnail, if it has one.
  final ClipRequested? clip;

  Uint8List? get image => clip?.clip.thumbnail;
}

/// Each other device in [events] (newest first, as in [EventLog]) with its
/// newest clip thumbnail, sorted by device ID so cells don't move. Events of
/// [thisDevice], without a device, or (when [profileId] is set) of another
/// profile are left out: the rest are the profile's devices, synced from
/// its cloud folder.
List<DeviceLatest> latestByDevice(
  Iterable<AppEvent> events, {
  String? thisDevice,
  String? profileId,
}) {
  final latest = <String, DeviceLatest>{};
  for (final event in events) {
    final device = event.deviceId;
    if (device == null || device == thisDevice) continue;
    if (profileId != null && event.profileId != profileId) continue;
    final known = latest[device];
    if (known?.clip != null) continue;
    final clip = event is ClipRequested && event.clip.thumbnail != null
        ? event
        : null;
    if (known == null || clip != null) {
      latest[device] = DeviceLatest(
        deviceId: device,
        time: clip != null ? event.time : known?.time ?? event.time,
        clip: clip,
      );
    }
  }
  return latest.values.toList()
    ..sort((a, b) => a.deviceId.compareTo(b.deviceId));
}

/// How many columns fit [count] cells in [size] with the biggest 16:9
/// pictures.
int gridColumns(int count, Size size) {
  var best = 1;
  var bestScale = 0.0;
  for (var columns = 1; columns <= count; columns++) {
    final rows = (count / columns).ceil();
    final scale = min(size.width / columns / 16, size.height / rows / 9);
    if (scale > bestScale) {
      best = columns;
      bestScale = scale;
    }
  }
  return best;
}

/// "just now", "5 min ago", "3 h ago", "2 d ago".
String describeAge(Duration age) {
  if (age.inMinutes < 1) return 'just now';
  if (age.inHours < 1) return '${age.inMinutes} min ago';
  if (age.inDays < 1) return '${age.inHours} h ago';
  return '${age.inDays} d ago';
}

/// A grid cell: its picture, with a label at the bottom left.
class DeviceGridCell extends StatelessWidget {
  const DeviceGridCell({
    super.key,
    required this.label,
    required this.child,
    this.onTap,
    this.refreshing = false,
    this.refreshingKey,
    this.onDelete,
    this.deleteTooltip,
    this.deleteKey,
    this.presence,
  });

  /// Deletes the device shown: a small button, top left.
  final VoidCallback? onDelete;
  final String? deleteTooltip;
  final Key? deleteKey;

  /// The device's presence dot, before the label.
  final Widget? presence;

  /// Null: no label (the camera alone, full screen).
  final String? label;
  final Widget child;
  final VoidCallback? onTap;

  /// A fresh grab was asked for and hasn't come: a small spinner, top
  /// right.
  final bool refreshing;
  final Key? refreshingKey;

  /// The smallest cell that shows the delete button: room for it (top
  /// left) beside the spinner (top right) and above the label. A smaller
  /// cell leaves it out; the account sheet's device list still deletes.
  static const Size deleteRoom = Size(96, 84);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => _build(
      context,
      roomy:
          constraints.maxWidth >= deleteRoom.width &&
          constraints.maxHeight >= deleteRoom.height,
    ),
  );

  Widget _build(BuildContext context, {required bool roomy}) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          child,
          if (onTap != null)
            Material(
              type: MaterialType.transparency,
              child: InkWell(onTap: onTap),
            ),
          if (onDelete case final onDelete? when roomy)
            Positioned(
              top: 2,
              left: 2,
              child: IconButton(
                key: deleteKey,
                tooltip: deleteTooltip,
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                style: IconButton.styleFrom(
                  backgroundColor: scheme.surfaceContainerHigh.withValues(
                    alpha: 0.85,
                  ),
                ),
                icon: const Icon(Icons.delete_outline),
                onPressed: onDelete,
              ),
            ),
          if (refreshing)
            Positioned(
              top: 6,
              right: 6,
              child: Tooltip(
                key: refreshingKey,
                message: 'Asked for a fresh grab',
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh.withValues(alpha: 0.85),
                    shape: BoxShape.circle,
                  ),
                  child: const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            ),
          if (label case final label?)
            Positioned(
              left: 6,
              right: 6,
              bottom: 6,
              child: Align(
                alignment: Alignment.bottomLeft,
                // The label lets taps through to the cell; the presence
                // dot takes them, for its tooltip.
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 4,
                    children: [
                      ?presence,
                      Flexible(
                        child: IgnorePointer(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Another device's latest image, whole, or an icon when it has none.
class DeviceImage extends StatelessWidget {
  const DeviceImage({super.key, required this.latest});

  final DeviceLatest latest;

  @override
  Widget build(BuildContext context) {
    final image = latest.image;
    if (image == null) {
      return Icon(
        Icons.videocam_off_outlined,
        size: 32,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      );
    }
    return Image.memory(
      image,
      key: Key('device-image-${latest.deviceId}'),
      fit: BoxFit.contain,
      gaplessPlayback: true,
    );
  }
}
