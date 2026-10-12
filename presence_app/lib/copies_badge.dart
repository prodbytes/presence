import 'package:flutter/material.dart';

import 'annotations.dart';
import 'clips/clip_model.dart';
import 'clips/clip_player_dialog.dart' show autoTagMessage;
import 'cloud/event_copies.dart';
import 'events.dart';
import 'l10n/l10n.dart';
import 'recognition/recognizer.dart';

/// Gives the event cards and the event details who holds each event
/// ([EventCopies]), and what tapping their cloud and copies indicators
/// does ([actions], cloud sync's); they rebuild as it changes.
class EventCopiesScope extends InheritedNotifier<EventCopies> {
  const EventCopiesScope({
    super.key,
    required EventCopies copies,
    this.actions,
    required super.child,
  }) : super(notifier: copies);

  /// What the cloud and copies indicators do when tapped; without them
  /// (no cloud sync), they aren't tappable.
  final EventCopyActions? actions;

  static EventCopies? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<EventCopiesScope>()?.notifier;

  static EventCopyActions? actionsOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<EventCopiesScope>()?.actions;

  @override
  bool updateShouldNotify(EventCopiesScope oldWidget) =>
      super.updateShouldNotify(oldWidget) || actions != oldWidget.actions;
}

/// An event's indicators, top right of its card and in its details: the
/// devices holding a copy ([EventCopiesBadge]), whether the cloud holds one
/// ([EventCloudBadge]) and, for a clip, how far recognition ran
/// ([EventRecognitionBadge]). Nothing without an [EventCopiesScope] but the
/// recognition indicator. Each does something when tapped: recognition
/// runs again, the event goes to the cloud or is deleted from it, the
/// other devices are asked to take a copy.
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
/// means, and that for screen readers. With [onTap], a button: a spinner
/// stands in for the icon while what it started runs.
class _Indicator extends StatefulWidget {
  const _Indicator({
    required this.icon,
    required this.color,
    required this.tooltip,
    this.text,
    this.textKey,
    this.onTap,
  });

  final IconData icon;
  final Color color;
  final String tooltip;
  final String? text;
  final Key? textKey;
  final Future<void> Function()? onTap;

  /// The icon's size, in logical pixels.
  static const double iconSize = 20;

  @override
  State<_Indicator> createState() => _IndicatorState();
}

class _IndicatorState extends State<_Indicator> {
  bool _busy = false;

  Future<void> _tap() async {
    final onTap = widget.onTap;
    if (onTap == null || _busy) return;
    setState(() => _busy = true);
    try {
      await onTap();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium
        ?.copyWith(color: widget.color);
    final tappable = widget.onTap != null;
    Widget body = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 40, minWidth: 32),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_busy)
              SizedBox.square(
                dimension: _Indicator.iconSize,
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: widget.color,
                  ),
                ),
              )
            else
              Icon(widget.icon, size: _Indicator.iconSize, color: widget.color),
            if (widget.text case final text?) ...[
              const SizedBox(width: 4),
              Text(text, key: widget.textKey, style: style),
            ],
          ],
        ),
      ),
    );
    if (tappable) {
      body = InkWell(
        customBorder: const StadiumBorder(),
        onTap: _busy ? null : _tap,
        child: body,
      );
    }
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        label: widget.tooltip,
        button: tappable,
        excludeSemantics: true,
        onTap: tappable && !_busy ? _tap : null,
        child: body,
      ),
    );
  }
}

/// Says [message] at the bottom of the screen, if there's a [messenger].
void _say(ScaffoldMessengerState? messenger, String message) => messenger
  ?..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(message)));

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
    final actions = EventCopiesScope.actionsOf(context);
    return _Indicator(
      icon: devices > 1
          ? Icons.file_copy_outlined
          : Icons.insert_drive_file_outlined,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      text: '$devices',
      textKey: Key('event-copies-text-${event.id}'),
      tooltip: [
        l.eventCopiesOnDevices(devices),
        tooltipOf(summary, l),
        if (actions != null) l.eventCopiesTapToShare,
      ].join('\n'),
      onTap: actions == null
          ? null
          : () async {
              final messenger = ScaffoldMessenger.maybeOf(context);
              final shared = await actions.shareCopies(event.id);
              _say(
                messenger,
                shared ? l.eventCopiesSharing : l.eventCopiesShareFailed,
              );
            },
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
    final actions = EventCopiesScope.actionsOf(context);
    final cloud = summary.cloud;
    return _Indicator(
      icon: icon,
      color: color,
      tooltip: actions == null
          ? tooltip
          : '$tooltip\n${cloud ? l.eventCloudTapToDelete : l.eventCloudTapToPut}',
      onTap: actions == null
          ? null
          : () => cloud
                ? _delete(context, actions, onlyCopy: !here)
                : _put(context, actions),
    );
  }

  Future<void> _put(BuildContext context, EventCopyActions actions) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final put = await actions.putInCloud(event.id);
    _say(messenger, put ? l.eventCloudPutting : l.eventCloudPutFailed);
  }

  /// Asks first: deleting from the cloud can lose the event, if no device
  /// holds a full copy ([onlyCopy]: this one doesn't).
  Future<void> _delete(
    BuildContext context,
    EventCopyActions actions, {
    required bool onlyCopy,
  }) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.eventCloudDeleteTitle),
        content: Text(
          onlyCopy
              ? '${l.eventCloudDeleteBody}\n\n${l.eventCloudDeleteOnlyCopy}'
              : l.eventCloudDeleteBody,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.eventCancel),
          ),
          TextButton(
            key: const Key('event-cloud-delete-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.eventCloudDelete),
          ),
        ],
      ),
    );
    if (sure != true) return;
    final deleted = await actions.deleteFromCloud(event.id);
    _say(messenger, deleted ? l.eventCloudDeleted : l.eventCloudDeleteFailed);
  }
}

/// How far recognition ran on [clip]: its search for people and pets
/// ([ClipAnnotations.subjectSearch]) and for object tags
/// ([ClipAnnotations.objects]), each not done, or done, found or not. In
/// the theme's primary color when both ran to the end (even with nothing
/// found), plain when one did, disabled when neither; the tooltip says
/// each, so "searched, nothing found" never reads as "not searched".
/// Tapped, recognition runs on the clip again, object tags included
/// ([SubjectRecognizer.recognizeNow]).
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
      final recognizer = SubjectRecognizerScope.maybeOf(context);
      final canRun = recognizer != null && recognizer.supported;
      return _Indicator(
        icon: icon,
        color: color,
        tooltip: [
          state,
          ...linesOf(a, l),
          if (canRun) l.eventRecognitionTapToRerun,
        ].join('\n'),
        onTap: canRun ? () => _rerun(context, recognizer) : null,
      );
    },
  );

  /// Runs recognition on the clip again, and says how it went.
  Future<void> _rerun(
    BuildContext context,
    SubjectRecognizer recognizer,
  ) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    _say(messenger, l.eventRecognitionRerunning);
    String message;
    try {
      message = autoTagMessage(
        await recognizer.recognizeNow(clip, again: true),
        l,
      );
    } catch (e) {
      debugPrint('Presence: recognition failed again on ${clip.id}: $e');
      message = l.clipAutoFailed;
    }
    _say(messenger, message);
  }
}
