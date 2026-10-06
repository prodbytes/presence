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
    this.liveRegion = false,
    this.onTap,
  });

  final Widget leading;
  final String? label;
  final String semantics;

  /// Screen readers announce it whenever [semantics] changes: for news
  /// that comes by itself (a message, a failed health check). Off for
  /// pills that change all the time (a countdown, the battery), which
  /// would be read out again and again.
  final bool liveRegion;

  /// Called when it's tapped; it's then a button to screen readers too.
  final VoidCallback? onTap;

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
        liveRegion: liveRegion,
        button: onTap != null,
        onTap: onTap,
        child: _tappable(
          Container(
            height: 40,
            // Without a label, a 40 dp circle around [leading].
            constraints: const BoxConstraints(minWidth: 40),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
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
      ),
    );
  }

  Widget _tappable(Widget pill) {
    final tap = onTap;
    if (tap == null) return pill;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Its semantics are the pill's own, above.
        excludeFromSemantics: true,
        onTap: tap,
        child: pill,
      ),
    );
  }
}
