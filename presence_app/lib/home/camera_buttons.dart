import 'package:flutter/material.dart';

import '../camera_feeds.dart';
import 'clip_button.dart';

/// The Camera tab's floating buttons, bottom right: the mode button
/// (Normal, All, Unattended, Stopped: [CameraMode]), Flip and Clip. Flip is
/// hidden when it can't act; Clip ([ClipButton]) always shows, colored by
/// whether a clip can be taken, and disabled when none can.
class CameraButtons extends StatelessWidget {
  const CameraButtons({
    super.key,
    required this.rig,
    required this.unattended,
    required this.showAll,
    required this.onNextMode,
    required this.onClip,
  });

  final CameraRig rig;

  /// With the camera's pause (Stopped), what the button shows
  /// ([CameraMode.of]); a tap moves on to the next ([onNextMode]).
  final bool unattended;
  final bool showAll;
  final VoidCallback onNextMode;
  final VoidCallback onClip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final padding = MediaQuery.paddingOf(context);
    // The screen less the 16 dp margins on both sides.
    final room = MediaQuery.sizeOf(context).width - padding.horizontal - 2 * 16;
    return ListenableBuilder(
      listenable: rig,
      builder: (context, _) {
        final mode = CameraMode.of(
          paused: rig.paused,
          unattended: unattended,
          showAll: showAll,
        );
        final flips = rig.devices.length > 1 && !rig.paused;
        final (background, foreground) = switch (mode) {
          CameraMode.normal => (scheme.surfaceContainerHigh, scheme.onSurface),
          CameraMode.all => (
            scheme.secondaryContainer,
            scheme.onSecondaryContainer,
          ),
          CameraMode.unattended => (
            scheme.tertiaryContainer,
            scheme.onTertiaryContainer,
          ),
          CameraMode.stopped => (
            scheme.errorContainer,
            scheme.onErrorContainer,
          ),
        };
        return Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            // Shows the mode; a tap moves on to the next. Icon only: the
            // tooltip and screen readers say what the tap does.
            FloatingActionButton(
              key: const Key('camera-mode'),
              heroTag: 'camera-mode',
              tooltip: mode.next.action,
              backgroundColor: background,
              foregroundColor: foreground,
              onPressed: onNextMode,
              child: Icon(mode.icon, semanticLabel: mode.label),
            ),
            if (flips)
              FloatingActionButton(
                heroTag: 'flip-camera',
                tooltip: 'Flip camera',
                // Secondary action: quieter than Clip.
                backgroundColor: scheme.surfaceContainerHigh,
                foregroundColor: scheme.onSurface,
                onPressed: rig.canFlip ? rig.flip : null,
                child: const Icon(Icons.cameraswitch),
              ),
            ClipButton(
              rig: rig,
              onPressed: onClip,
              maxWidth: room - (56 + 12) - (flips ? 56 + 12 : 0),
            ),
          ],
        );
      },
    );
  }
}

/// The Camera tab's mode, chosen with its mode button, which goes Normal →
/// All → Unattended → Stopped → Normal.
enum CameraMode {
  /// This device's camera, full screen.
  normal('Normal', Icons.crop_square, 'Back to normal: this camera'),

  /// This device's camera in a grid with every other device's image.
  all('All', Icons.grid_view, 'Show all devices'),

  /// The screen dark (off, where the platform can) while capturing and
  /// syncing go on.
  unattended(
    'Unattended',
    Icons.brightness_2_outlined,
    'Go unattended: screen off, still capturing',
  ),

  /// Nothing at all: the camera off ([CameraRig.paused]) and no syncing
  /// ([CloudSync.halted]).
  stopped(
    'Stopped',
    Icons.stop_circle_outlined,
    'Stop: no capturing or syncing',
  );

  const CameraMode(this.label, this.icon, this.action);

  final String label;
  final IconData icon;

  /// What switching to this mode does, for the button's tooltip.
  final String action;

  CameraMode get next => values[(index + 1) % values.length];

  /// The mode with the camera [paused] (Stopped) or not, [unattended] or
  /// the All grid asked for ([showAll]).
  static CameraMode of({
    required bool paused,
    required bool unattended,
    required bool showAll,
  }) => paused
      ? stopped
      : unattended
      ? CameraMode.unattended
      : showAll
      ? all
      : normal;
}
