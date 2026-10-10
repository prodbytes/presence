import 'package:flutter/material.dart';

import '../battery.dart';
import '../battery_pills.dart';
import '../auth/roles_service.dart';
import '../camera_feeds.dart';
import '../cloud/cloud_sync.dart';
import '../system_health.dart';
import 'clip_button.dart';

/// The status pills over the camera, top left, just under the app bar: a
/// failed health check ([HealthWarningPill]), the battery, its temperature
/// (Android) and a clip that just started ([message]); the Clip button
/// itself shows whether a clip can be taken ([ClipButton]). Up there they
/// never sit over the view button, Flip or Clip at the bottom. They're one
/// row that wraps onto the next line where they don't fit; only a message
/// wider than the screen is cut short.
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

  /// The gap between the app bar and the pills.
  static const double gap = 8;

  /// The room one row of pills takes under the app bar: the gap, a 40 dp
  /// pill and the gap under it. The All grid starts below it
  /// ([CameraFeedsView.topInset]).
  static const double rowHeight = gap + 40 + gap;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return Positioned(
      // 16 from the sides, like the floating buttons; under the app bar
      // (the body runs behind it, so its height is in the top padding).
      left: 16 + padding.left,
      right: 16 + padding.right,
      top: padding.top + gap,
      // At the start of the room given; the pills keep their own width.
      child: Align(
        alignment: AlignmentDirectional.topStart,
        child: LayoutBuilder(
          builder: (context, box) => ListenableBuilder(
            listenable: Listenable.merge([rig, battery, roles, ?sync]),
            builder: (context, _) {
              final reading = full ? battery.reading : null;
              final failed = full
                  ? HealthWarningPill.failedChecks(roles, sync)
                  : const <String>[];
              return Wrap(
                key: const Key('camera-status'),
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (failed.isNotEmpty)
                    HealthWarningPill(failed: failed, onTap: onHealthTap),
                  if (reading != null) BatteryPill(battery: battery),
                  if (reading?.celsius != null)
                    BatteryTemperaturePill(battery: battery),
                  // The message, cut short only if wider than the screen.
                  if (message case final m?)
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: box.maxWidth),
                      child: m,
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
