/// The Camera tab's view ([CameraFeedsView]): the open camera, or the All
/// grid of every device. The rig and its parts live under `lib/camera/`;
/// this library exports them all, so `camera_feeds.dart` is the one import.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;

import 'camera/camera_rig.dart';
import 'camera/device_grid.dart';
import 'cameras/cameras.dart';
import 'clips.dart';
import 'events.dart';
import 'cloud/live_sync.dart';
import 'device_presence.dart';
import 'theme.dart';

export 'camera/auto_clip_policy.dart';
export 'camera/camera_rig.dart';
export 'camera/capture_all.dart';
export 'camera/device_grid.dart';

/// The open camera, full screen and without overlays; or, with [showAll],
/// in the top-left cell of a grid whose other cells hold the latest image
/// of each of the profile's other devices ([latestByDevice]).
class CameraFeedsView extends StatefulWidget {
  const CameraFeedsView({
    super.key,
    required this.rig,
    this.log,
    this.deviceId,
    this.profileId,
    this.showAll = false,
    this.refreshingSince,
    this.onDeleteDevice,
    this.live,
    this.active = true,
  });

  /// Asks to delete another device (the delete button on its cell in the
  /// grid, top left): its events are hidden on every device, and its cell
  /// goes. None: no delete buttons.
  final ValueChanged<String>? onDeleteDevice;

  final CameraRig rig;

  /// The events the other devices' images come from (for [showAll]).
  final EventLog? log;

  /// This device's ID: its own events aren't another device's.
  final String? deviceId;

  /// Only this profile's events count, when set (signed in).
  final String? profileId;

  /// The grid of every device instead of the camera alone.
  final bool showAll;

  /// When this device asked the others for a fresh grab
  /// ([CameraRig.askAll]), while it waits for them: a cell whose image is
  /// older shows a small spinner until a newer one arrives. Null: none.
  final DateTime? refreshingSince;

  /// Live sync, for each device's presence dot in the grid
  /// ([DevicePresence]); the grid pings the devices ([LiveSync.ping]) when
  /// it shows and every 30 s while it does and [active].
  final LiveSync? live;

  /// Whether the page is on screen (the Camera tab): the grid pings only
  /// then.
  final bool active;

  /// Room kept clear under the grid for the status pills, Flip and Clip.
  static const double bottomInset = 88;

  @override
  State<CameraFeedsView> createState() => _CameraFeedsViewState();
}

class _CameraFeedsViewState extends State<CameraFeedsView> {
  /// Refreshes the images' ages while the grid shows.
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _tick();
  }

  @override
  void didUpdateWidget(CameraFeedsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _tick();
  }

  /// Whether the grid pinged since it last showed.
  bool _pinging = false;

  void _tick() {
    if (widget.showAll) {
      _ticker ??= Timer.periodic(const Duration(seconds: 30), (_) {
        if (widget.active) widget.live?.ping().ignore();
        setState(() {});
      });
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
    // Shown (or back on screen): ask who's there now.
    final pinging = widget.showAll && widget.active;
    if (pinging && !_pinging) widget.live?.ping().ignore();
    _pinging = pinging;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rig = widget.rig;
    final log = widget.log;
    return ColoredBox(
      color: Gruvbox.bg0Hard,
      child: ListenableBuilder(
        listenable: Listenable.merge([rig, ?log, ?widget.live]),
        builder: (context, _) {
          final all = widget.showAll;
          final live = widget.live;
          final available = liveAvailable(live);
          final lastEvents = all
              ? lastEventByDevice(
                  log?.events ?? const [],
                  profileId: widget.profileId,
                )
              : const <String, DateTime>{};
          final others = all
              ? latestByDevice(
                  log?.events ?? const [],
                  thisDevice: widget.deviceId,
                  profileId: widget.profileId,
                )
              : const <DeviceLatest>[];
          final padding = MediaQuery.paddingOf(context);
          // The same tree with or without the grid, so switching doesn't
          // rebuild the camera's preview.
          return Padding(
            // The grid stays clear of the app bar above and the buttons
            // below; the camera alone fills the screen.
            padding: all
                ? EdgeInsets.only(
                    top: padding.top + kToolbarHeight,
                    bottom: padding.bottom + CameraFeedsView.bottomInset,
                  )
                : EdgeInsets.zero,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = constraints.biggest;
                final columns = gridColumns(others.length + 1, size);
                final rows = ((others.length + 1) / columns).ceil();
                final cell = Size(size.width / columns, size.height / rows);
                Rect rectOf(int i) =>
                    Offset(
                      (i % columns) * cell.width,
                      (i ~/ columns) * cell.height,
                    ) &
                    cell;
                final now = DateTime.now();
                return Stack(
                  children: [
                    // This device, live: top left in the grid.
                    Positioned.fromRect(
                      rect: all ? rectOf(0).deflate(1) : Offset.zero & size,
                      child: DeviceGridCell(
                        label: all
                            ? '${widget.deviceId ?? 'This device'} · live'
                            : null,
                        presence: all
                            ? PresenceDot(
                                key: const Key('presence-this-device'),
                                presence: DevicePresence.of(
                                  now: now,
                                  liveAvailable: available,
                                  thisDevice: true,
                                  connected:
                                      live?.state == LiveSyncState.connected,
                                ),
                              )
                            : null,
                        child: _camera(context),
                      ),
                    ),
                    for (final (i, latest) in others.indexed)
                      Positioned.fromRect(
                        key: ValueKey(latest.deviceId),
                        rect: rectOf(i + 1).deflate(1),
                        child: DeviceGridCell(
                          label:
                              '${latest.deviceId} · '
                              '${describeAge(now.difference(latest.time))}',
                          onTap: switch (latest.clip) {
                            final clip? when clip.clip.playable =>
                              () => showClipPlayer(context, clip),
                            _ => null,
                          },
                          refreshing: switch (widget.refreshingSince) {
                            final since? => latest.time.isBefore(since),
                            null => false,
                          },
                          refreshingKey: Key('refreshing-${latest.deviceId}'),
                          onDelete: switch (widget.onDeleteDevice) {
                            final delete? => () => delete(latest.deviceId),
                            null => null,
                          },
                          deleteTooltip: 'Delete ${latest.deviceId}',
                          deleteKey: Key('device-delete-${latest.deviceId}'),
                          presence: PresenceDot(
                            key: Key('presence-${latest.deviceId}'),
                            presence: DevicePresence.of(
                              answeredAt: live?.seenOf(latest.deviceId),
                              lastEvent: lastEvents[latest.deviceId],
                              now: now,
                              liveAvailable: available,
                            ),
                          ),
                          child: DeviceImage(latest: latest),
                        ),
                      ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }

  /// The open camera's preview, or why there isn't one.
  Widget _camera(BuildContext context) {
    final rig = widget.rig;
    if (rig.paused) {
      return FeedMessage(
        key: const Key('camera-paused'),
        icon: Icons.videocam_off_outlined,
        message: 'Camera off\nNothing is recorded until you turn it on.',
        action: TextButton(
          onPressed: () => rig.setPaused(false),
          child: const Text('Turn on'),
        ),
      );
    }
    final active = rig.active;
    if (active != null) {
      return SizedBox.expand(
        key: ObjectKey(active),
        child: active.buildPreview(context),
      );
    }
    final error = rig.error;
    if (error != null) {
      return FeedMessage(
        icon: Icons.error_outline,
        message: 'Could not open the camera\n${describeCameraError(error)}',
        action: TextButton(onPressed: rig.retry, child: const Text('Retry')),
      );
    }
    if (rig.busy) {
      return const Center(child: CircularProgressIndicator());
    }
    return FeedMessage(
      icon: Icons.videocam_off_outlined,
      message: 'No camera found',
      action: TextButton(onPressed: rig.load, child: const Text('Retry')),
    );
  }
}

class FeedMessage extends StatelessWidget {
  const FeedMessage({
    super.key,
    required this.icon,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: color),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: color),
            ),
            if (action != null) ...[const SizedBox(height: 8), action!],
          ],
        ),
      ),
    );
  }
}

/// A sentence for the user about why the camera didn't open. Backends
/// throw [CameraUnavailable] with one; native plugin errors carry their own
/// message. Anything else (a bug, an unexpected browser error) gets a
/// generic sentence, and the details go to the log instead of the screen.
String describeCameraError(Object error) {
  switch (error) {
    case CameraUnavailable(:final message):
      return message;
    case PlatformException(:final message?) when message.trim().isNotEmpty:
      return message;
  }
  debugPrint('Presence: could not open the camera: $error');
  return 'Something went wrong while starting the camera.';
}
