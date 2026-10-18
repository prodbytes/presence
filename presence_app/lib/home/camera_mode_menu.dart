import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

/// The Camera tab's mode menu, in the app bar's title over the camera: the
/// mode's icon and name with a drop-down arrow ("This camera ▾" at launch);
/// a tap drops a menu of the four modes ([CameraMode]), each with what it
/// does, the current one checked, and picking one switches to it
/// ([onSelected]).
class CameraModeMenu extends StatelessWidget {
  const CameraModeMenu({
    super.key,
    required this.mode,
    required this.onSelected,
  });

  final CameraMode mode;
  final ValueChanged<CameraMode> onSelected;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    // Over the camera, under the app bar's dark scrim: white in either
    // theme.
    const color = Colors.white;
    return PopupMenuButton<CameraMode>(
      key: const Key('camera-mode'),
      tooltip: l.cameraModeMenu,
      initialValue: mode,
      onSelected: (picked) {
        if (picked != mode) onSelected(picked);
      },
      position: PopupMenuPosition.under,
      itemBuilder: (context) => [
        for (final item in CameraMode.values)
          PopupMenuItem(
            key: Key('camera-mode-${item.name}'),
            value: item,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(item.icon),
              title: Text(item.labelIn(l)),
              subtitle: Text(item.hintIn(l)),
              trailing: item == mode ? const Icon(Icons.check) : null,
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            Icon(mode.icon, color: color, size: 20),
            // Shrinks rather than overflow (longer languages, phones).
            Flexible(
              child: Text(
                mode.labelIn(l),
                key: const Key('camera-mode-label'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color),
              ),
            ),
            Icon(Icons.arrow_drop_down, color: color),
          ],
        ),
      ),
    );
  }
}

/// The Camera tab's mode, picked from its menu ([CameraModeMenu]).
enum CameraMode {
  /// This device's camera, full screen.
  normal(Icons.crop_square),

  /// This device's camera in a grid with every other device's image.
  all(Icons.grid_view),

  /// The screen dark (off, where the platform can) while capturing and
  /// syncing go on.
  unattended(Icons.brightness_2_outlined),

  /// The camera off ([CameraRig.paused]); events still sync, as in the
  /// other modes.
  stopped(Icons.stop_circle_outlined);

  const CameraMode(this.icon);

  final IconData icon;

  /// The mode's name in the language shown.
  String labelIn(AppLocalizations l) => switch (this) {
    normal => l.cameraModeNormal,
    all => l.cameraModeAll,
    unattended => l.cameraModeUnattended,
    stopped => l.cameraModeStopped,
  };

  /// What the mode does, under its name in the menu.
  String hintIn(AppLocalizations l) => switch (this) {
    normal => l.cameraModeNormalHint,
    all => l.cameraModeAllHint,
    unattended => l.cameraModeUnattendedHint,
    stopped => l.cameraModeStoppedHint,
  };

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
