import 'package:flutter/material.dart';

import 'cloud/event_copies.dart';
import 'events.dart';

/// Gives the event cards and the event details who holds each event
/// ([EventCopies]); they rebuild as it changes.
class EventCopiesScope extends InheritedNotifier<EventCopies> {
  const EventCopiesScope({
    super.key,
    required EventCopies copies,
    required super.child,
  }) : super(notifier: copies);

  static EventCopies? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<EventCopiesScope>()?.notifier;
}

/// How many copies of [event] there are, small and quiet: an icon and
/// "3 copies", or "Not synced" when it's held nowhere but here, with the
/// holders in its tooltip and screen-reader label ("This device, Cloud,
/// pixel_ab12"; with live sync off, that other devices' copies are
/// unknown). Nothing without an [EventCopiesScope].
class EventCopiesBadge extends StatelessWidget {
  const EventCopiesBadge({super.key, required this.event});

  final AppEvent event;

  @override
  Widget build(BuildContext context) {
    final copies = EventCopiesScope.maybeOf(context);
    // A deleted event (its device was deleted) has no copies to show.
    if (copies == null || event.deletedAt != null) {
      return const SizedBox.shrink();
    }
    final summary = copies.summaryOf(event.id, origin: event.deviceId);
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    final style = theme.textTheme.labelSmall?.copyWith(color: color);
    return Tooltip(
      message: summary.tooltip,
      child: Semantics(
        label: '${summary.label}. ${summary.tooltip}',
        excludeSemantics: true,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 32),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  !summary.synced
                      ? Icons.cloud_off_outlined
                      : summary.count > 1
                      ? Icons.file_copy_outlined
                      : Icons.insert_drive_file_outlined,
                  size: 14,
                  color: color,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    summary.label,
                    key: Key('event-copies-text-${event.id}'),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: style,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
