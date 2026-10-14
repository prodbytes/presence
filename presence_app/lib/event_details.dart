import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'cloud/live_sync.dart';
import 'device_events.dart';
import 'device_presence.dart';
import 'events.dart';
import 'identity/device_os.dart';
import 'l10n/l10n.dart';
import 'location/device_location.dart';
import 'location/map_parts.dart';
import 'theme.dart';

/// Deletes one event on every device of the signed-in profile
/// (`Persistence.deleteEvent`); true when it was deleted.
typedef DeleteEvent = Future<bool> Function(AppEvent event);

/// Deletes [events] on every device of the signed-in profile at once
/// (`Persistence.deleteEvents`); how many it deleted.
typedef DeleteEvents = Future<int> Function(List<AppEvent> events);

/// What the end of an event's details (the clip player) needs from the
/// app: who is signed in ([profileId]), this device, live sync (for the
/// recording device's presence dot), the event log (its latest event), the
/// map's tiles, and how to delete an event ([deleteEvent]) or the events
/// shown ([deleteEvents]). The events list's delete buttons use it too.
class EventDetailsScope extends InheritedWidget {
  const EventDetailsScope({
    super.key,
    required super.child,
    this.profileId,
    this.thisDevice,
    this.live,
    this.log,
    this.tiles,
    this.deleteEvent,
    this.deleteEvents,
    this.now,
  });

  /// The signed-in profile; null signed out and in DEV: then no delete
  /// button and no presence dot.
  final String? profileId;
  final String? thisDevice;
  final LiveSync? live;
  final EventLog? log;

  /// Replaces the map's tiles (tests); OpenStreetMap's otherwise.
  final Widget? tiles;
  final DeleteEvent? deleteEvent;
  final DeleteEvents? deleteEvents;
  final DateTime Function()? now;

  /// Whether [event] can be deleted here: signed in with its profile.
  bool canDelete(AppEvent event) =>
      deleteEvent != null && profileId != null && event.profileId == profileId;

  static EventDetailsScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<EventDetailsScope>();

  @override
  bool updateShouldNotify(EventDetailsScope old) =>
      profileId != old.profileId ||
      thisDevice != old.thisDevice ||
      live != old.live ||
      log != old.log ||
      tiles != old.tiles ||
      deleteEvent != old.deleteEvent ||
      deleteEvents != old.deleteEvents ||
      now != old.now;
}

/// The end of an event's details: where it was ([EventMap]), the device
/// that recorded it ([EventDevice]), and, signed in with the event's
/// profile, a button that deletes it on every device. [onDeleted] runs
/// once it's deleted (the player closes).
class EventDetailsFooter extends StatelessWidget {
  const EventDetailsFooter({
    super.key,
    required this.event,
    required this.onDeleted,
  });

  final AppEvent event;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context) {
    final scope = EventDetailsScope.maybeOf(context);
    final delete = scope?.deleteEvent;
    final canDelete = scope?.canDelete(event) ?? false;
    final l = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        _Heading(
          key: const Key('event-map-heading'),
          icon: Icons.place_outlined,
          title: l.eventWhere,
        ),
        EventMap(location: event.location, tiles: scope?.tiles),
        _Heading(
          key: const Key('event-device-heading'),
          icon: Icons.devices_other,
          title: l.eventDevice,
        ),
        EventDevice(event: event, scope: scope),
        if (canDelete) ...[
          const SizedBox(height: 4),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              key: const Key('delete-event'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
                side: BorderSide(color: Theme.of(context).colorScheme.error),
              ),
              icon: const Icon(Icons.delete_outline),
              label: Text(l.eventDelete),
              onPressed: () => deleteEventAfterConfirming(
                context,
                event: event,
                delete: delete!,
                onDeleted: onDeleted,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// A heading at the end of the details, like the player's Subjects and
/// Tags ones.
class _Heading extends StatelessWidget {
  const _Heading({super.key, required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Row(
        spacing: 6,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          Text(title, style: theme.textTheme.titleSmall),
        ],
      ),
    );
  }
}

/// A small map of where the event was ([location], the device's when it
/// was published), with a pin, and under it the position and how it was
/// found; "No location for this event" without one. The map doesn't move
/// (no gestures), so dragging over it scrolls the details.
class EventMap extends StatelessWidget {
  const EventMap({super.key, required this.location, this.tiles});

  final DeviceLocation? location;

  /// Replaces the tiles (tests); OpenStreetMap's otherwise.
  final Widget? tiles;

  static const double height = 140;
  static const double zoom = 15;

  /// How [location] was found, in words: in the language of [l], English
  /// without.
  static String sourceOf(
    DeviceLocation location, [
    AppLocalizations? language,
  ]) {
    final l = language ?? lookupAppLocalizations(const Locale('en'));
    if (location.pinned) return l.eventLocationPinned;
    return switch (location.source) {
      LocationSource.device => [
        l.eventLocationDevice,
        if (location.accuracy case final accuracy?) '±${accuracy.round()} m',
      ].join(' · '),
      LocationSource.map => l.eventLocationMap,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final at = location;
    if (at == null) {
      return Text(
        context.l10n.eventNoLocation,
        key: const Key('event-no-location'),
        style: TextStyle(color: scheme.onSurfaceVariant),
      );
    }
    final point = LatLng(at.latitude, at.longitude);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            key: const Key('event-map'),
            height: height,
            child: FlutterMap(
              options: MapOptions(
                initialCenter: point,
                initialZoom: zoom,
                backgroundColor: Gruvbox.bg0,
                // Still: a drag over it scrolls the details instead.
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.none,
                ),
              ),
              children: [
                tiles ?? openStreetMapTiles(),
                MarkerLayer(
                  markers: [
                    Marker(
                      key: const Key('event-map-marker'),
                      point: point,
                      width: 32,
                      height: 32,
                      alignment: Alignment.topCenter,
                      child: Icon(
                        at.pinned ? Icons.push_pin : Icons.place,
                        size: 32,
                        color: scheme.primary,
                      ),
                    ),
                  ],
                ),
                const MapAttribution(),
              ],
            ),
          ),
        ),
        Text(
          '${at.latitude.toStringAsFixed(5)}, '
          '${at.longitude.toStringAsFixed(5)} · '
          '${sourceOf(at, context.l10n)}',
          key: const Key('event-location-text'),
          style: small,
        ),
      ],
    );
  }
}

/// The device that recorded the event: its operating system's icon
/// ([DeviceOs.iconOf]), its ID (selectable; tapped, it shows the device's
/// events: [DeviceEventsLink]), "this device" for this one,
/// and its operating system's name; signed in, its presence dot
/// ([DevicePresence]) before the ID.
class EventDevice extends StatelessWidget {
  const EventDevice({super.key, required this.event, this.scope});

  final AppEvent event;
  final EventDetailsScope? scope;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final thisDevice = scope?.thisDevice;
    // Not saved yet: recorded here.
    final device = event.deviceId ?? thisDevice;
    if (device == null) {
      return Text(context.l10n.eventDeviceUnknown, style: muted);
    }
    final os = event.os;
    final profile = scope?.profileId;
    final live = scope?.live;
    return Row(
      key: const Key('event-device'),
      spacing: 8,
      children: [
        Tooltip(
          message: os ?? context.l10n.eventOsUnknown,
          child: Icon(
            DeviceOs.iconOf(os),
            key: const Key('event-device-icon'),
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (profile != null)
                    PresencePinger(
                      live: live,
                      builder: (context) => PresenceDot(
                        key: const Key('event-device-presence'),
                        presence: DevicePresence.of(
                          l: context.l10n,
                          answeredAt: live?.seenOf(device),
                          lastEvent: lastEventByDevice(
                            scope?.log?.events ?? const [],
                            profileId: profile,
                          )[device],
                          now: (scope?.now ?? DateTime.now)(),
                          liveAvailable: liveAvailable(live),
                          thisDevice: device == thisDevice,
                          connected: live?.state == LiveSyncState.connected,
                        ),
                      ),
                    ),
                  DeviceEventsLink(
                    device: device,
                    builder: (context, onTap) => SelectableText(
                      device,
                      key: const Key('event-device-id'),
                      onTap: onTap,
                      // bodySmall: a long ID fits a small phone.
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: onTap == null ? null : theme.colorScheme.primary,
                      ),
                    ),
                  ),
                  if (device == thisDevice)
                    Text(context.l10n.eventThisDevice, style: muted),
                ],
              ),
              if (os != null)
                Text(
                  os,
                  key: const Key('event-device-os-name'),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Asks whether to delete [event] ([DeleteEventDialog]), and if so,
/// deletes it with [delete], runs [onDeleted] (the player closes) and says
/// so in a snack bar.
Future<void> deleteEventAfterConfirming(
  BuildContext context, {
  required AppEvent event,
  required DeleteEvent delete,
  required VoidCallback onDeleted,
}) async {
  // Found now: the player asking is gone once it's deleted.
  final messenger = ScaffoldMessenger.maybeOf(context);
  final l = context.l10n;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => const DeleteEventDialog(),
  );
  if (confirmed != true) return;
  try {
    final deleted = await delete(event);
    if (deleted) onDeleted();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          deleted ? l.eventDeletedEverywhere : l.eventAlreadyDeleted,
        ),
      ),
    );
  } catch (e) {
    debugPrint('Presence: could not delete event ${event.id}: $e');
    messenger?.showSnackBar(SnackBar(content: Text(l.eventDeleteFailed)));
  }
}

/// Asks whether to delete [events] (the events list's Delete all: those
/// shown, [DeleteEventDialog] with their count), and if so, deletes them
/// with [delete] and says how many in a snack bar.
Future<void> deleteEventsAfterConfirming(
  BuildContext context, {
  required List<AppEvent> events,
  required DeleteEvents delete,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final l = context.l10n;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => DeleteEventDialog(count: events.length),
  );
  if (confirmed != true) return;
  try {
    final deleted = await delete(events);
    messenger?.showSnackBar(
      SnackBar(content: Text(l.eventsDeletedEverywhere(deleted))),
    );
  } catch (e) {
    debugPrint('Presence: could not delete ${events.length} events: $e');
    messenger?.showSnackBar(SnackBar(content: Text(l.eventsDeleteFailed)));
  }
}

/// "Delete this event? It will be hidden on every device.", with Cancel
/// and Delete; with [count], the same about that many events (Delete
/// all). Pops true for Delete.
class DeleteEventDialog extends StatelessWidget {
  const DeleteEventDialog({super.key, this.count});

  /// How many events Delete all deletes; null, one event.
  final int? count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l = context.l10n;
    return AlertDialog(
      key: const Key('delete-event-dialog'),
      icon: const Icon(Icons.delete_outline),
      title: Text(
        count == null ? l.eventDeleteTitle : l.eventsDeleteAllTitle(count!),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Text(
              count == null ? l.eventDeleteMessage : l.eventsDeleteAllMessage,
              key: const Key('delete-event-message'),
            ),
            Text(
              count == null ? l.eventDeleteClipNote : l.eventsDeleteAllClipNote,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('delete-event-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l.eventCancel),
        ),
        FilledButton(
          key: const Key('delete-event-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l.eventDeleteConfirm),
        ),
      ],
    );
  }
}
