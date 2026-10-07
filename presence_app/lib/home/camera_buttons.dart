import 'package:flutter/material.dart';

import '../camera_feeds.dart';

/// The Camera tab's floating buttons, bottom right: the view button (One,
/// All, None), Flip and Clip. Each is hidden, not disabled, when it can't
/// act.
class CameraButtons extends StatelessWidget {
  const CameraButtons({
    super.key,
    required this.rig,
    required this.showAll,
    required this.onNextViewMode,
    required this.onClip,
  });

  final CameraRig rig;

  /// The All grid is asked for: with the camera on, the view is All.
  final bool showAll;
  final VoidCallback onNextViewMode;
  final VoidCallback onClip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: rig,
      builder: (context, _) {
        final viewMode = CameraViewMode.of(
          paused: rig.paused,
          showAll: showAll,
        );
        return Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            // Shows what's on screen (One, All, None); a tap moves on to the
            // next. Highlighted for All, and for None, the camera off. Icon
            // only: the tooltip and screen readers name it.
            FloatingActionButton(
              key: const Key('show-all'),
              heroTag: 'show-all',
              tooltip: switch (viewMode) {
                CameraViewMode.one => 'Show all devices',
                CameraViewMode.all => 'Turn the camera off',
                CameraViewMode.none => 'Turn the camera on',
              },
              backgroundColor: switch (viewMode) {
                CameraViewMode.one => scheme.surfaceContainerHigh,
                CameraViewMode.all => scheme.secondaryContainer,
                CameraViewMode.none => scheme.errorContainer,
              },
              foregroundColor: switch (viewMode) {
                CameraViewMode.one => scheme.onSurface,
                CameraViewMode.all => scheme.onSecondaryContainer,
                CameraViewMode.none => scheme.onErrorContainer,
              },
              onPressed: onNextViewMode,
              child: Icon(switch (viewMode) {
                CameraViewMode.one => Icons.crop_square,
                CameraViewMode.all => Icons.grid_view,
                CameraViewMode.none => Icons.videocam_off,
              }),
            ),
            if (rig.devices.length > 1 && !rig.paused)
              FloatingActionButton(
                heroTag: 'flip-camera',
                tooltip: 'Flip camera',
                // Secondary action: quieter than Clip.
                backgroundColor: scheme.surfaceContainerHigh,
                foregroundColor: scheme.onSurface,
                onPressed: rig.canFlip ? rig.flip : null,
                child: const Icon(Icons.cameraswitch),
              ),
            if (rig.canClip)
              FloatingActionButton.extended(
                heroTag: 'clip',
                tooltip: 'Clip',
                icon: const Icon(Icons.camera),
                label: const Text('Clip'),
                onPressed: onClip,
              ),
          ],
        );
      },
    );
  }
}

/// What the Camera tab shows, chosen with its view button.
enum CameraViewMode {
  /// This device's camera, full screen.
  one,

  /// This device's camera in a grid with every other device's image.
  all,

  /// Nothing: the camera is off ([CameraRig.paused]).
  none;

  /// What shows with the camera [paused] or not and the All grid asked for
  /// ([showAll]).
  static CameraViewMode of({required bool paused, required bool showAll}) =>
      paused
      ? CameraViewMode.none
      : showAll
      ? CameraViewMode.all
      : CameraViewMode.one;
}
