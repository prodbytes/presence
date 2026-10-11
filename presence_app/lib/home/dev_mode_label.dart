import 'package:flutter/material.dart';

import '../app_version.dart';
import '../auth/roles_service.dart';
import '../l10n/l10n.dart';

/// Says, quietly, that the system runs in [ExecutionMode.dev]: nobody signs
/// in and everything is open. With a build version, it shows it too
/// ("dev 0.4.202610011728"), cut short with an ellipsis where there's no
/// room.
class DevModeLabel extends StatelessWidget {
  const DevModeLabel({super.key, this.version = AppVersion.version});

  /// The build's version ([AppVersion.version]); empty shows only "dev".
  final String version;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = version.isEmpty ? 'dev' : 'dev $version';
    return Tooltip(
      message: version.isEmpty
          ? context.l10n.devModeTooltip
          : context.l10n.devModeTooltipVersion(version),
      child: Container(
        key: const Key('dev-mode'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outline),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          // labelLarge (14 sp): readable next to the title.
          style: theme.textTheme.labelLarge?.copyWith(
            color: scheme.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}
