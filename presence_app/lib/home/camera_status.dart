import 'package:flutter/material.dart';

import '../battery.dart';
import '../battery_pills.dart';
import '../auth/roles_service.dart';
import '../camera_feeds.dart';
import '../cloud/cloud_sync.dart';
import '../system_health.dart';
import 'clip_button.dart';

/// The status pills over the camera, bottom left, across from Flip and
/// Clip: a failed health check ([HealthWarningPill]), the battery, its
/// temperature (Android) and a clip that just started ([message]); the
/// Clip button itself shows whether a clip can be taken ([ClipButton]).
/// In a row, level with the buttons and clear of them, on wide screens.
/// On phones they stack, starting just above the buttons' row, so however
/// wide they are they never run into Flip and Clip; the message is the
/// lowest. A label that doesn't fit is cut short.
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

  /// With access: the health warning and battery too. Signed out, only
  /// [message].
  final bool full;

  /// The health checks', for [HealthWarningPill].
  final RolesService roles;
  final CloudSync? sync;

  /// Where tapping the health warning goes.
  final VoidCallback? onHealthTap;

  /// The pill saying a clip just started, if one did.
  final Widget? message;

  /// Room kept on the right for the view button, Flip and Clip (as wide
  /// as "Clip · 4:59") when the pills are in a row.
  static const double buttonsRoom = 16 + 56 + 12 + 56 + 12 + 170;

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
            // The message, cut short if need be.
            final last = [if (message case final m?) Flexible(child: m)];
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
