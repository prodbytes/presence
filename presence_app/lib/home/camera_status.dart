import 'dart:async';

import 'package:flutter/material.dart';

import '../battery.dart';
import '../battery_pills.dart';
import '../auth/roles_service.dart';
import '../camera_feeds.dart';
import '../cloud/cloud_sync.dart';
import '../dot.dart';
import '../status_pill.dart';
import '../system_health.dart';
import '../theme.dart';
import '../time_format.dart';

/// Whether an automatic clip can be taken now: ready, or counting down the
/// cooldown after the latest clip (red while its "after" part is still
/// being saved). The Clip button works either way.
class ReadinessIndicator extends StatefulWidget {
  const ReadinessIndicator({super.key, required this.rig});

  final CameraRig rig;

  @override
  State<ReadinessIndicator> createState() => _ReadinessIndicatorState();
}

class _ReadinessIndicatorState extends State<ReadinessIndicator> {
  late final Timer _ticker;

  @override
  void initState() {
    super.initState();
    // Readiness moves with time: refresh the countdowns.
    _ticker = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final readiness = widget.rig.readiness;
    final seconds = (readiness.remaining.inMilliseconds / 1000).ceil();
    // Minutes and seconds for the cooldown ("4:59"), seconds below
    // a minute ("45 s").
    final countdown = seconds >= 60
        ? formatMinutesSeconds(seconds)
        : '$seconds s';
    // Only the dot, and the countdown while there is one: the tooltip and
    // screen readers spell the state out.
    final (
      Widget leading,
      String? label,
      String semantics,
    ) = switch (readiness.state) {
      ClipReadinessState.ready => (
        Dot(color: Gruvbox.green),
        null,
        'Ready to clip',
      ),
      ClipReadinessState.cooldown => (
        // Red while the latest clip is still saving, then amber.
        Dot(color: readiness.recording ? Gruvbox.red : Gruvbox.yellow),
        countdown,
        readiness.recording
            ? 'Clip saving; next automatic clip in $countdown'
            : 'Next automatic clip in $countdown',
      ),
      ClipReadinessState.unavailable => (
        Dot(color: scheme.outline),
        null,
        'Camera not ready',
      ),
      ClipReadinessState.paused => (
        Dot(color: scheme.outline),
        null,
        'Camera off: nothing is recorded',
      ),
    };
    return StatusPill(
      key: const Key('readiness'),
      leading: leading,
      label: label,
      semantics: semantics,
    );
  }
}

/// The status pills over the camera, bottom left, across from Flip and
/// Clip: a failed health check ([HealthWarningPill]), the battery, its temperature
/// (Android), the readiness and, beside it, a clip that just started
/// ([message]). In a row, level with the
/// buttons and clear of them, on wide screens. On phones they stack,
/// starting just above the buttons' row, so however wide they are they
/// never run into Flip and Clip; the readiness and the message share the
/// lowest line. A label that doesn't fit is cut short.
class CameraStatus extends StatelessWidget {
  const CameraStatus({
    super.key,
    required this.rig,
    required this.battery,
    required this.roles,
    this.sync,
    this.full = true,
    this.onHealthTap,
    this.message,
  });

  final CameraRig rig;
  final BatteryController battery;

  /// With access: the health warning, battery and readiness too. Signed
  /// out, only [message].
  final bool full;

  /// The health checks', for [HealthWarningPill].
  final RolesService roles;
  final CloudSync? sync;

  /// Where tapping the health warning goes.
  final VoidCallback? onHealthTap;

  /// The pill saying a clip just started, if one did.
  final Widget? message;

  /// Room kept on the right for the view button, Flip and Clip when the
  /// pills are in a row.
  static const double buttonsRoom = 16 + 56 + 12 + 56 + 12 + 120;

  /// Narrower than this, the pills stack.
  static const double stackBelow = 600;

  /// The floating buttons' height, and the gap above them.
  static const double buttonRow = 56 + 8;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final stacked = MediaQuery.sizeOf(context).width < stackBelow;
    return Positioned(
      // 16 from the edges, like the floating buttons; in a row, centered
      // on them (the pills are 40 high, the buttons 56).
      left: 16 + padding.left,
      right: (stacked ? 16 : buttonsRoom) + padding.right,
      bottom: 16 + padding.bottom + (stacked ? buttonRow : (56 - 40) / 2),
      // At the start of the room given; the pills keep their own width.
      child: Align(
        alignment: AlignmentDirectional.bottomStart,
        child: ListenableBuilder(
          listenable: Listenable.merge([rig, battery, roles, ?sync]),
          builder: (context, _) {
            final reading = full ? battery.reading : null;
            final readiness = full && (rig.active != null || rig.paused)
                ? ReadinessIndicator(rig: rig)
                : null;
            final failed = full
                ? HealthWarningPill.failedChecks(roles, sync)
                : const <String>[];
            final batteryPills = [
              if (failed.isNotEmpty)
                HealthWarningPill(failed: failed, onTap: onHealthTap),
              if (reading != null) BatteryPill(battery: battery),
              if (reading?.celsius != null)
                BatteryTemperaturePill(battery: battery),
            ];
            // The readiness, and the message beside it, cut short if need be.
            final last = [
              ?readiness,
              if (message case final m?) Flexible(child: m),
            ];
            return stacked
                ? Column(
                    key: const Key('camera-status'),
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 8,
                    children: [
                      ...batteryPills,
                      if (last.isNotEmpty)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          spacing: 8,
                          children: last,
                        ),
                    ],
                  )
                : Row(
                    key: const Key('camera-status'),
                    mainAxisSize: MainAxisSize.min,
                    spacing: 8,
                    children: [...batteryPills, ...last],
                  );
          },
        ),
      ),
    );
  }
}
