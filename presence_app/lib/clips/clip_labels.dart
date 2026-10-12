import 'package:flutter/material.dart';

import '../annotations.dart';
import '../events.dart';
import '../l10n/l10n.dart';
import 'clip_model.dart';

/// The border of a label on a clip (a subject or a tag): the theme's main
/// color for one someone made or confirmed ([authored]), a shade of grey
/// for recognition's, the lighter the surer ([confidence], 0 to 1) — grey
/// even when recognition is 100 % sure.
Color labelBorderColor(
  ColorScheme scheme,
  double confidence, {
  bool authored = false,
}) => authored
    ? scheme.primary
    : Color.lerp(_unsureGrey, _sureGrey, confidence.clamp(0, 1))!;

const _unsureGrey = Color(0xFF5C5C5C);
const _sureGrey = Color(0xFFE0E0E0);

/// A clip's **Tags**: the things recognition saw on it (`human`, `cat`,
/// `bicycle`, `bottle`…), as small square chips edged in grey by their
/// score ([labelBorderColor]: they're all recognition's), by first sighting;
/// nothing until it's been searched, or if nothing was seen. In a timeline
/// ([EventSearchScope]) a click on one filters the events by it (again,
/// clears the filter) and it shows highlighted while it's the search, a
/// long press calling [onOpenAt]; elsewhere a click calls [onOpenAt] with
/// where it was first seen. Its x removes it from the clip.
class ClipObjectTags extends StatelessWidget {
  const ClipObjectTags({
    super.key,
    required this.annotations,
    this.onOpenAt,
    this.onFiltered,
    this.keyPrefix = 'clip-object',
  });

  final ClipAnnotations annotations;
  final void Function(Duration? at)? onOpenAt;

  /// Called once a click filtered the events (the player closes).
  final VoidCallback? onFiltered;

  /// Starts the chips' keys, so the player's and the card's differ.
  final String keyPrefix;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: annotations,
    builder: (context, _) {
      final objects = annotations.objects ?? const [];
      if (objects.isEmpty) return const SizedBox.shrink();
      final theme = Theme.of(context);
      final scheme = theme.colorScheme;
      final search = EventSearchScope.maybeOf(context);
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Wrap(
          key: Key('${keyPrefix}s'),
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final o in objects)
              if (search != null &&
                      EventSearchScope.isActive(search.value, o.label)
                      // Whether it's the search: highlighted.
                      case final active)
                Semantics(
                  key: Key('$keyPrefix-chip-${o.label}'),
                  selected: search == null ? null : active,
                  child: Container(
                    decoration: BoxDecoration(
                      color: active ? scheme.primaryContainer : null,
                      border: Border.all(
                        color: labelBorderColor(scheme, o.score),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        OpenAtLabel(
                          key: Key('$keyPrefix-${o.label}'),
                          ms: o.ms,
                          onOpenAt: onOpenAt,
                          filter: o.label,
                          onFiltered: onFiltered,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 2, 2, 2),
                            child: Text(
                              o.label,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: active
                                    ? scheme.onPrimaryContainer
                                    : scheme.onSurfaceVariant,
                                fontWeight: active ? FontWeight.bold : null,
                              ),
                            ),
                          ),
                        ),
                        RemoveLabelButton(
                          key: Key('$keyPrefix-remove-${o.label}'),
                          label: o.label,
                          kind: 'tag',
                          onRemove: () => annotations.removeObject(o.label),
                        ),
                      ],
                    ),
                  ),
                ),
          ],
        ),
      );
    },
  );
}

/// A label on a clip's card that, clicked, opens the player paused [ms] into
/// the recording (or, without [ms], playing from the start); just the label
/// when the clip can't be played ([onOpenAt] null).
///
/// With a [filter] (the tag or subject it shows) and in a timeline
/// ([EventSearchScope]), a click filters the events by it instead (again,
/// clears the filter), then calls [onFiltered]; a long press opens the
/// player.
class OpenAtLabel extends StatelessWidget {
  const OpenAtLabel({
    super.key,
    required this.ms,
    required this.onOpenAt,
    required this.child,
    this.filter,
    this.onFiltered,
    this.borderRadius,
  });

  final int? ms;
  final void Function(Duration? at)? onOpenAt;
  final Widget child;
  final BorderRadius? borderRadius;

  /// What a click searches the events for, in a timeline.
  final String? filter;
  final VoidCallback? onFiltered;

  @override
  Widget build(BuildContext context) {
    final open = onOpenAt;
    final at = ms == null ? null : Duration(milliseconds: ms!);
    final search = filter == null ? null : EventSearchScope.maybeOf(context);
    if (search != null) {
      final label = filter!;
      final active = EventSearchScope.isActive(search.value, label);
      return Tooltip(
        // Shown on hover; a long press opens the player.
        triggerMode: TooltipTriggerMode.manual,
        message: active
            ? context.l10n.clipShowEveryEvent
            : context.l10n.clipShowOnlyWith(label),
        child: InkWell(
          borderRadius: borderRadius,
          onTap: () {
            EventSearchScope.toggle(search, label);
            onFiltered?.call();
          },
          onLongPress: open == null ? null : () => open(at),
          child: child,
        ),
      );
    }
    if (open == null) return child;
    return Tooltip(
      message: at == null
          ? context.l10n.clipPlay
          : context.l10n.clipShowAt(formatClipTime(at.inMilliseconds)),
      child: InkWell(
        borderRadius: borderRadius,
        onTap: () => open(at),
        child: child,
      ),
    );
  }
}

/// The small x beside a label on a clip's card: removes the [kind]
/// (`subject` or `tag`) [label] from the clip ([onRemove]). Its tooltip
/// names the kind in the app's language.
class RemoveLabelButton extends StatelessWidget {
  const RemoveLabelButton({
    super.key,
    required this.label,
    required this.kind,
    required this.onRemove,
  });

  final String label;
  final String kind;
  final VoidCallback onRemove;

  String _message(AppLocalizations l) => kind == 'subject'
      ? l.clipRemoveSubjectFromEvent(label)
      : l.clipRemoveTagFromEvent(label);

  @override
  Widget build(BuildContext context) => Tooltip(
    message: _message(context.l10n),
    child: Semantics(
      button: true,
      label: _message(context.l10n),
      excludeSemantics: true,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onRemove,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            Icons.close,
            size: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ),
  );
}
