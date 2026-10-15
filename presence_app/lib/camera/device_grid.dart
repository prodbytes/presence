/// The All grid's pieces: each other device's latest image
/// ([latestByDevice]), their order ([byActivity]), the grid's shape
/// ([gridColumns]) and its cells.
library;

import '../crypto/sealed_image.dart';

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../clips.dart' show ClipRequested;
import '../device_events.dart';
import '../device_presence.dart';
import '../events.dart';
import '../l10n/l10n.dart';

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

/// [devices] most recently active first, for the All grid: those live now
/// (answered a ping within [DevicePresence.liveWithin], green) first, then
/// the others by when they were last heard from over live sync
/// ([seenOf]) or posted an event ([lastEvents]), whichever is later,
/// newest first. Live devices all answer the same ping round within a
/// second or so, so among them their latest event decides, and the cells
/// don't swap places at every round. Ties by device ID.
List<DeviceLatest> byActivity(
  List<DeviceLatest> devices, {
  DateTime? Function(String deviceId)? seenOf,
  required Map<String, DateTime> lastEvents,
  required DateTime now,
  required bool liveAvailable,
  Duration within = DevicePresence.liveWithin,
}) {
  (bool, DateTime) rank(DeviceLatest d) {
    final answered = seenOf?.call(d.deviceId);
    final event = lastEvents[d.deviceId] ?? d.time;
    final live =
        DevicePresence.of(
          answeredAt: answered,
          lastEvent: event,
          now: now,
          liveAvailable: liveAvailable,
          within: within,
        ).level ==
        PresenceLevel.live;
    if (live) return (true, event);
    final heard = liveAvailable ? answered : null;
    return (false, heard != null && heard.isAfter(event) ? heard : event);
  }

  final ranks = {for (final d in devices) d.deviceId: rank(d)};
  return [...devices]..sort((a, b) {
    final (aLive, aTime) = ranks[a.deviceId]!;
    final (bLive, bTime) = ranks[b.deviceId]!;
    if (aLive != bLive) return aLive ? -1 : 1;
    final byTime = bTime.compareTo(aTime);
    return byTime != 0 ? byTime : a.deviceId.compareTo(b.deviceId);
  });
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

/// "just now", "5 min ago", "3 h ago", "2 d ago"; in [l], English by
/// default.
String describeAge(Duration age, [AppLocalizations? l]) {
  l ??= lookupAppLocalizations(const Locale('en'));
  if (age.inMinutes < 1) return l.cameraAgeJustNow;
  if (age.inHours < 1) return l.cameraAgeMinutes(age.inMinutes);
  if (age.inDays < 1) return l.cameraAgeHours(age.inHours);
  return l.cameraAgeDays(age.inDays);
}

/// A grid cell: its picture, with a label at the bottom left (the device
/// ID, its [detail] under it).
class DeviceGridCell extends StatelessWidget {
  const DeviceGridCell({
    super.key,
    required this.label,
    required this.child,
    this.onTap,
    this.refreshing = false,
    this.refreshingKey,
    this.presence,
    this.device,
    this.detail,
  });

  /// A second line under the label (how old the picture is, or "live"),
  /// so the label stays short.
  final String? detail;

  /// The device shown: its label, tapped, shows its events
  /// ([DeviceEventsLink]).
  final String? device;

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

  /// The label's text: tapped, it shows the [device]'s events; otherwise
  /// it lets taps through to the cell.
  Widget _label(String label) {
    final text = Builder(
      builder: (context) {
        final style = Theme.of(context).textTheme.labelSmall;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
            if (detail case final detail?)
              Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        );
      },
    );
    final device = this.device;
    if (device == null) return IgnorePointer(child: text);
    return DeviceEventsLink(
      key: Key('device-label-$device'),
      device: device,
      builder: (context, onTap) => onTap == null
          ? IgnorePointer(child: text)
          : InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onTap,
              child: text,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
          if (refreshing)
            Positioned(
              top: 6,
              right: 6,
              child: Tooltip(
                key: refreshingKey,
                message: context.l10n.cameraAskedFreshGrab,
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
                      Flexible(child: _label(label)),
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
    return SealedImage(
      image,
      key: Key('device-image-${latest.deviceId}'),
      fit: BoxFit.contain,
    );
  }
}
