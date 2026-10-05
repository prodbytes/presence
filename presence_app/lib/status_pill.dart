import 'package:flutter/material.dart';

/// A small rounded status chip over the camera: something [leading] (a dot
/// or an icon) and a short [label], or only [leading] without one.
/// [semantics] spells it out for the tooltip and screen readers.
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.leading,
    this.label,
    required this.semantics,
    this.labelColor,
  });

  final Widget leading;
  final String? label;
  final String semantics;

  /// The label's color; the surface's text color by default.
  final Color? labelColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Tooltip(
      message: semantics,
      child: Semantics(
        label: semantics,
        liveRegion: true,
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 8,
            children: [
              leading,
              if (label case final label?)
                Flexible(
                  child: ExcludeSemantics(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: labelColor ?? scheme.onSurface,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
