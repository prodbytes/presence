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
import 'l10n/l10n.dart';
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
    this.live,
    this.active = true,
  });

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

  /// Room kept clear under the grid for the view button, Flip and Clip.
  static const double bottomInset = 88;

  /// Room kept clear above the grid, under the app bar, for a row of status
  /// pills (`CameraStatus.rowHeight`), so they don't cover the top cells.
  static const double topInset = 8 + 40 + 8;

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
                  // Only the devices that show (a free profile's first two).
                  log?.eventsOf(widget.profileId) ?? const [],
                  profileId: widget.profileId,
                )
              : const <String, DateTime>{};
          final now = DateTime.now();
          final others = all
              ? byActivity(
                  latestByDevice(
                    log?.eventsOf(widget.profileId) ?? const [],
                    thisDevice: widget.deviceId,
                    profileId: widget.profileId,
                  ),
                  seenOf: live?.seenOf,
                  lastEvents: lastEvents,
                  now: now,
                  liveAvailable: available,
                )
              : const <DeviceLatest>[];
          final padding = MediaQuery.paddingOf(context);
          // The same tree with or without the grid, so switching doesn't
          // rebuild the camera's preview.
          return Padding(
            // The grid stays clear of the app bar (in the top padding: the
            // body runs behind it) and the status pills above and the
            // buttons below; the camera alone fills the screen.
            padding: all
                ? EdgeInsets.only(
                    top: padding.top + CameraFeedsView.topInset,
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
                return Stack(
                  children: [
                    // This device, live: top left in the grid.
                    Positioned.fromRect(
                      rect: all ? rectOf(0).deflate(1) : Offset.zero & size,
                      child: DeviceGridCell(
                        label: all
                            ? context.l10n.cameraLiveLabel(
                                widget.deviceId ??
                                    context.l10n.cameraThisDevice,
                              )
                            : null,
                        device: all ? widget.deviceId : null,
                        presence: all
                            ? PresenceDot(
                                key: const Key('presence-this-device'),
                                presence: DevicePresence.of(
                                  l: context.l10n,
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
                      // A device whose place changes slides there, as the
                      // tabs do.
                      AnimatedPositioned.fromRect(
                        key: ValueKey(latest.deviceId),
                        duration: kTabScrollDuration,
                        curve: Curves.ease,
                        rect: rectOf(i + 1).deflate(1),
                        child: DeviceGridCell(
                          label:
                              '${latest.deviceId} · '
                              '${describeAge(now.difference(latest.time), context.l10n)}',
                          device: latest.deviceId,
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
                          presence: PresenceDot(
                            key: Key('presence-${latest.deviceId}'),
                            presence: DevicePresence.of(
                              l: context.l10n,
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
    final l = context.l10n;
    if (rig.paused) {
      return FeedMessage(
        key: const Key('camera-paused'),
        icon: Icons.videocam_off_outlined,
        message: l.cameraOffMessage,
        action: TextButton(
          onPressed: () => rig.setPaused(false),
          child: Text(l.cameraTurnOn),
        ),
      );
    }
    final active = rig.active;
    if (active != null) {
      return SizedBox.expand(
        key: ObjectKey(active),
        // Night mode's pill is with the status pills, top left
        // (CameraStatus).
        child: active.buildPreview(context),
      );
    }
    final error = rig.error;
    if (error != null) {
      return FeedMessage(
        icon: Icons.error_outline,
        message: l.cameraCouldNotOpen(describeCameraError(error, l)),
        action: TextButton(onPressed: rig.retry, child: Text(l.cameraRetry)),
      );
    }
    if (rig.busy) {
      return const Center(child: CircularProgressIndicator());
    }
    return FeedMessage(
      icon: Icons.videocam_off_outlined,
      message: l.cameraNotFound,
      action: TextButton(onPressed: rig.load, child: Text(l.cameraRetry)),
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
/// The backends' own sentences are worded in [l] (English by default);
/// native plugin messages stay as the platform wrote them.
String describeCameraError(Object error, [AppLocalizations? l]) {
  l ??= lookupAppLocalizations(const Locale('en'));
  switch (error) {
    case CameraUnavailable(:final message):
      return _cameraSentence(message, l);
    case PlatformException(:final message?) when message.trim().isNotEmpty:
      return message;
  }
  debugPrint('Presence: could not open the camera: $error');
  return l.cameraErrorGeneric;
}

/// A backend's sentence ([CameraUnavailable.message], in English) in [l];
/// one it doesn't know stays as it is.
String _cameraSentence(String message, AppLocalizations l) {
  final en = lookupAppLocalizations(const Locale('en'));
  final known = <String Function(AppLocalizations)>[
    (l) => l.cameraErrorGeneric,
    (l) => l.cameraErrorDenied,
    (l) => l.cameraErrorInsecure,
    (l) => l.cameraErrorBlocked,
    (l) => l.cameraErrorNoneFound,
    (l) => l.cameraErrorInUse,
    (l) => l.cameraErrorStopped,
  ];
  for (final sentence in known) {
    if (sentence(en) == message) return sentence(l);
  }
  return message;
}
