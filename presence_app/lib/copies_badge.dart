import 'package:flutter/material.dart';

import 'annotations.dart';
import 'clips/clip_model.dart';
import 'cloud/event_copies.dart';
import 'events.dart';
import 'l10n/l10n.dart';

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

/// An event's indicators, top right of its card and in its details: the
/// devices holding a copy ([EventCopiesBadge]), whether the cloud holds one
/// ([EventCloudBadge]) and, for a clip, how far recognition ran
/// ([EventRecognitionBadge]). Nothing without an [EventCopiesScope] but the
/// recognition indicator.
class EventIndicators extends StatelessWidget {
  const EventIndicators({super.key, required this.event});

  final AppEvent event;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (event case final ClipRequested clip)
        EventRecognitionBadge(
          key: Key('event-recognition-${event.id}'),
          clip: clip,
        ),
      EventCloudBadge(key: Key('event-cloud-${event.id}'), event: event),
      EventCopiesBadge(key: Key('event-copies-${event.id}'), event: event),
    ],
  );
}

/// A small indicator: an icon, maybe a number, a tooltip saying what it
/// means, and that for screen readers.
class _Indicator extends StatelessWidget {
  const _Indicator({
    required this.icon,
    required this.color,
    required this.tooltip,
    this.text,
    this.textKey,
  });

  final IconData icon;
  final Color color;
  final String tooltip;
  final String? text;
  final Key? textKey;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall
        ?.copyWith(color: color);
    return Tooltip(
      message: tooltip,
      child: Semantics(
        label: tooltip,
        excludeSemantics: true,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 32, minWidth: 24),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: color),
                if (text case final text?) ...[
                  const SizedBox(width: 3),
                  Text(text, key: textKey, style: style),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The color of an indicator that's on (the theme's primary), or off (the
/// disabled one).
Color _on(BuildContext context) => Theme.of(context).colorScheme.primary;
Color _off(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.38);

/// How many devices hold a copy of [event]: an icon and the number, the
/// cloud not counted ([EventCloudBadge] shows it), with the holders in its
/// tooltip ("On 2 devices", then "This device, Cloud, pixel_ab12"; with
/// live sync off, that other devices' copies are unknown). Nothing without
/// an [EventCopiesScope], or for a deleted event.
class EventCopiesBadge extends StatelessWidget {
  const EventCopiesBadge({super.key, required this.event});

  final AppEvent event;

  /// [CopiesSummary.tooltip] in the language of [l]: this device and the
  /// cloud by their names in it, other devices by their IDs.
  static String tooltipOf(CopiesSummary summary, AppLocalizations l) {
    final who = summary.holders.isEmpty
        ? l.eventCopiesNone
        : [
            for (final h in summary.holders)
              switch (h) {
                EventCopies.thisDevice => l.eventCopiesThisDevice,
                EventCopies.cloudHolder => l.eventCopiesCloud,
                _ => h,
              },
          ].join(', ');
    return summary.liveOn ? who : '$who\n${l.eventCopiesLiveOff}';
  }

  @override
  Widget build(BuildContext context) {
    final copies = EventCopiesScope.maybeOf(context);
    // A deleted event (its device was deleted) has no copies to show.
    if (copies == null || event.deletedAt != null) {
      return const SizedBox.shrink();
    }
    final summary = copies.summaryOf(event.id, origin: event.deviceId);
    final l = context.l10n;
    final devices = summary.devices.length;
    return _Indicator(
      icon: devices > 1
          ? Icons.file_copy_outlined
          : Icons.insert_drive_file_outlined,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      text: '$devices',
      textKey: Key('event-copies-text-${event.id}'),
      tooltip: '${l.eventCopiesOnDevices(devices)}\n${tooltipOf(summary, l)}',
    );
  }
}

/// Whether the cloud holds a copy of [event], in three states: disabled
/// when it doesn't (not synced yet); the theme's primary color when it does
/// and this device holds one too (synced); its secondary color when only the
/// cloud does, this device not (archived, the goal). Nothing without an
/// [EventCopiesScope], or for a deleted event.
class EventCloudBadge extends StatelessWidget {
  const EventCloudBadge({super.key, required this.event});

  final AppEvent event;

  @override
  Widget build(BuildContext context) {
    final copies = EventCopiesScope.maybeOf(context);
    if (copies == null || event.deletedAt != null) {
      return const SizedBox.shrink();
    }
    final summary = copies.summaryOf(event.id, origin: event.deviceId);
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    // Archived (the goal): kept in the cloud, and no longer (or never, in
    // full) on this device.
    final here = summary.holders.contains(EventCopies.thisDevice);
    final (icon, color, tooltip) = !summary.cloud
        ? (Icons.cloud_off_outlined, _off(context), l.eventCloudNotSynced)
        : here
        ? (Icons.cloud_done, _on(context), l.eventCloudSynced)
        : (Icons.cloud_done, scheme.secondary, l.eventCloudArchived);
    return _Indicator(icon: icon, color: color, tooltip: tooltip);
  }
}

/// How far recognition ran on [clip]: its search for people and pets
/// ([ClipAnnotations.subjectSearch]) and for object tags
/// ([ClipAnnotations.objects]), each not done, or done, found or not. In
/// the theme's primary color when both ran to the end (even with nothing
/// found), plain when one did, disabled when neither; the tooltip says
/// each, so "searched, nothing found" never reads as "not searched".
class EventRecognitionBadge extends StatelessWidget {
  const EventRecognitionBadge({super.key, required this.clip});

  final ClipRequested clip;

  /// The tooltip's lines, in the language of [l].
  static List<String> linesOf(ClipAnnotations a, AppLocalizations l) {
    final named = {
      for (final t in a.items)
        if (t.source != TagSource.suggested) t.name,
    };
    final subjects = switch (a.subjectSearch?.outcome) {
      null => l.eventSubjectsNotSearched,
      SubjectSearchOutcome.noReferences =>
        named.isEmpty
            ? l.eventSubjectsNoReferences
            : l.eventSubjectsFound(named.join(', ')),
      SubjectSearchOutcome.allTagged => l.eventSubjectsAllTagged,
      SubjectSearchOutcome.searched =>
        named.isEmpty
            ? l.eventSubjectsNone
            : l.eventSubjectsFound(named.join(', ')),
    };
    final objects = a.objects;
    final tags = objects == null
        ? l.eventTagsNotSearched
        : objects.isEmpty
        ? l.eventTagsNone
        : l.eventTagsFound([for (final o in objects) o.label].join(', '));
    return [subjects, tags];
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: clip.annotations,
    builder: (context, _) {
      final a = clip.annotations;
      final l = context.l10n;
      final subjects = a.subjectSearch != null;
      final objects = a.objects != null;
      final (icon, color, state) = subjects && objects
          ? (Icons.manage_search, _on(context), l.eventRecognitionComplete)
          : subjects || objects
          ? (
              Icons.manage_search,
              Theme.of(context).colorScheme.onSurfaceVariant,
              l.eventRecognitionPartial,
            )
          : (Icons.search_off, _off(context), l.eventRecognitionNotRun);
      return _Indicator(
        icon: icon,
        color: color,
        tooltip: [state, ...linesOf(a, l)].join('\n'),
      );
    },
  );
}
