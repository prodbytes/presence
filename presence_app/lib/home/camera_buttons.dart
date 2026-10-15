import 'package:flutter/material.dart';

import '../camera_feeds.dart';
import '../l10n/l10n.dart';
import 'camera_mode_menu.dart';
import 'clip_button.dart';

/// The Camera tab's floating buttons, bottom right: Flip and Clip. Flip is
/// hidden when it can't act; Clip ([ClipButton]) always shows, colored by
/// whether a clip can be taken, and disabled when none can. The mode is
/// picked in the app bar ([CameraModeMenu]).
class CameraButtons extends StatelessWidget {
  const CameraButtons({super.key, required this.rig, required this.onClip});

  final CameraRig rig;
  final VoidCallback onClip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l = context.l10n;
    final padding = MediaQuery.paddingOf(context);
    // The screen less the 16 dp margins on both sides.
    final room = MediaQuery.sizeOf(context).width - padding.horizontal - 2 * 16;
    return ListenableBuilder(
      listenable: rig,
      builder: (context, _) {
        final flips = rig.devices.length > 1 && !rig.paused;
        return Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 12,
          children: [
            if (flips)
              FloatingActionButton(
                heroTag: 'flip-camera',
                tooltip: l.cameraFlip,
                // Secondary action: quieter than Clip.
                backgroundColor: scheme.surfaceContainerHigh,
                foregroundColor: scheme.onSurface,
                onPressed: rig.canFlip ? rig.flip : null,
                child: const Icon(Icons.cameraswitch),
              ),
            ClipButton(
              rig: rig,
              onPressed: onClip,
              maxWidth: room - (flips ? 56 + 12 : 0),
            ),
          ],
        );
      },
    );
  }
}
