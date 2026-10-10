import 'package:flutter/material.dart';

import '../camera_feeds.dart';
import 'clip_button.dart';

/// The Camera tab's floating buttons, bottom right: the mode button (One,
/// All, Unattended where the platform can turn the screen off, Stopped),
/// Flip and Clip. Flip is hidden when it can't act; Clip
/// ([ClipButton]) always shows, colored by whether a clip can be taken,
/// and disabled when none can.
class CameraButtons extends StatelessWidget {
  const CameraButtons({
    super.key,
    required this.rig,
    required this.showAll,
    required this.onNextViewMode,
    required this.onClip,
    this.unattended = false,
    this.canUnattend = false,
  });

  final CameraRig rig;

  /// The All grid is asked for: with the camera on, the view is All.
  final bool showAll;
  final VoidCallback onNextViewMode;
  final VoidCallback onClip;

  /// The mode is Unattended: the screen off, capture going on.
  final bool unattended;

  /// The platform can turn the screen off, so the cycle has Unattended.
  final bool canUnattend;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final padding = MediaQuery.paddingOf(context);
    // The screen less the 16 dp margins on both sides.
    final room = MediaQuery.sizeOf(context).width - padding.horizontal - 2 * 16;
    return ListenableBuilder(
      listenable: rig,
      builder: (context, _) {
        final viewMode = CameraViewMode.of(
          paused: rig.paused,
          unattended: unattended,
          showAll: showAll,
        );
        final flips = rig.devices.length > 1 && !rig.paused;
        return Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            // Shows the mode (One, All, Unattended, Stopped); a tap moves
            // on to the next. Highlighted for All and Unattended, and for
            // Stopped, the camera off. Icon only: the tooltip and screen
            // readers name it.
            FloatingActionButton(
              key: const Key('show-all'),
              heroTag: 'show-all',
              tooltip: switch (viewMode) {
                CameraViewMode.one => 'Show all devices',
                CameraViewMode.all when canUnattend =>
                  'Turn the screen off (capture goes on)',
                CameraViewMode.all ||
                CameraViewMode.unattended => 'Turn the camera off',
                CameraViewMode.stopped => 'Turn the camera on',
              },
              backgroundColor: switch (viewMode) {
                CameraViewMode.one => scheme.surfaceContainerHigh,
                CameraViewMode.all => scheme.secondaryContainer,
                CameraViewMode.unattended => scheme.tertiaryContainer,
                CameraViewMode.stopped => scheme.errorContainer,
              },
              foregroundColor: switch (viewMode) {
                CameraViewMode.one => scheme.onSurface,
                CameraViewMode.all => scheme.onSecondaryContainer,
                CameraViewMode.unattended => scheme.onTertiaryContainer,
                CameraViewMode.stopped => scheme.onErrorContainer,
              },
              onPressed: onNextViewMode,
              child: Icon(switch (viewMode) {
                CameraViewMode.one => Icons.crop_square,
                CameraViewMode.all => Icons.grid_view,
                CameraViewMode.unattended => Icons.brightness_2_outlined,
                CameraViewMode.stopped => Icons.videocam_off,
              }),
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

/// What the Camera tab shows and does, chosen with its mode button.
enum CameraViewMode {
  /// This device's camera, full screen.
  one,

  /// This device's camera in a grid with every other device's image.
  all,

  /// The screen off (`ScreenOff`) while capture, clips and the
  /// network go on.
  unattended,

  /// Nothing: the camera is off ([CameraRig.paused]).
  stopped;

  /// The mode with the camera [paused] or not, the screen off asked for
  /// ([unattended]) and the All grid asked for ([showAll]).
  static CameraViewMode of({
    required bool paused,
    bool unattended = false,
    required bool showAll,
  }) => paused
      ? CameraViewMode.stopped
      : unattended
      ? CameraViewMode.unattended
      : showAll
      ? CameraViewMode.all
      : CameraViewMode.one;
}
