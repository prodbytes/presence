import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'config.dart';
import 'events.dart';
import 'l10n/l10n.dart';
import 'subjects.dart';

/// The Monitoring tab: where subjects were seen and what happened.
///
/// Two columns on a wide screen: the map of every subject, each at its
/// latest located event ([SubjectsMap]), on the left, all events on the
/// right, each clip's card showing its subjects in their colors. On a phone the map sits above the events. One compact row
/// at the top: the events search ([EventSearch], an icon until tapped), its
/// matching / all events count ([EventCount]), with the small "Show
/// system events" toggle ([ShowSystemEvents]) in the same row. Tapping a
/// device's name (an event's, [EventDeviceTag], or elsewhere,
/// `ShowDeviceEvents`) searches for its ID: only its events show (the map
/// keeps every subject). Tapping a dot on the map
/// scrolls the events to its event; tapping a subject's name opens the
/// subject.
class MonitoringView extends StatefulWidget {
  const MonitoringView({
    super.key,
    required this.log,
    required this.config,
    this.tiles,
    this.onOpenEvent,
    this.deviceId,
    this.profileId,
    this.filters,
    this.onSync,
  });

  /// The Sync button's action ([SyncAllButton]): a full pass here and a
  /// request to the profile's other devices; whether the request went out.
  /// No button without it.
  final Future<bool> Function()? onSync;

  /// Below this width the map goes above the events instead of beside.
  static const double twoColumnWidth = 720;

  /// The map's share of the height when it's above the events
  /// ([stackedMapHeight]).
  static const double stackedMapShare = 0.3;
  static const double minStackedMapHeight = 160;

  /// The events column beside the map: [eventsShare] of the width, kept
  /// between [minEventsWidth] and [maxEventsWidth]; the map takes the rest.
  static const double eventsShare = 0.55;
  static const double minEventsWidth = 360;
  static const double maxEventsWidth = 880;

  /// The stacked map's height in [height] of room under the filters:
  /// [stackedMapShare] of it, at least [minStackedMapHeight] unless that's
  /// over half of it.
  static double stackedMapHeight(double height) => math.max(
    height * stackedMapShare,
    math.min(minStackedMapHeight, height / 2),
  );

  /// The page's widest; wider screens center it.
  static const double maxWidth = 1600;

  final EventLog log;
  final ConfigController config;

  /// The map's tiles; defaults to OpenStreetMap.
  final Widget? tiles;

  /// Opens an event: scrolls the events to it (a dot tapped on a map).
  final ValueChanged<AppEvent>? onOpenEvent;

  /// This device's ID: events without one (not saved yet) are its.
  final String? deviceId;

  /// The signed-in account's profile (null signed out): the map, the
  /// events and their count show only its own ([EventTimeline.ofProfile]).
  final String? profileId;

  /// The device picked, the "Show system events" toggle, the search and
  /// the event to open ([EventFilters]); defaults to an own one, showing
  /// every event.
  final EventFilters? filters;

  @override
  State<MonitoringView> createState() => _MonitoringViewState();
}

class _MonitoringViewState extends State<MonitoringView> {
  EventFilters? _ownFilters;
  EventFilters get _filters =>
      widget.filters ?? (_ownFilters ??= EventFilters());

  @override
  void dispose() {
    _ownFilters?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final map = SubjectsMap(
      log: widget.log,
      config: widget.config,
      tiles: widget.tiles,
      onOpenEvent: widget.onOpenEvent,
      profileId: widget.profileId,
    );
    Widget events(EdgeInsets padding) => KeyedSubtree(
      key: const Key('events-page'),
      child: EventTimeline(
        log: widget.log,
        filters: _filters,
        deviceId: widget.deviceId,
        profileId: widget.profileId,
        padding: padding,
      ),
    );
    return Center(
      key: const Key('monitoring-page'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: MonitoringView.maxWidth),
        child: LayoutBuilder(
          builder: (context, box) {
            final wide = box.maxWidth >= MonitoringView.twoColumnWidth;
            final gap = wide ? 16.0 : 12.0;
            final framedMap = Card.outlined(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: map,
            );
            return Padding(
              padding: EdgeInsets.fromLTRB(gap, gap, gap, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // One compact row: the search (an icon until tapped),
                  // the count and the system events toggle, and at the far
                  // right Delete all. The open field gives up room on a
                  // narrow phone.
                  SizedBox(
                    height: 40,
                    child: Row(
                      key: const Key('monitoring-filters'),
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              Flexible(
                                child: EventSearch(value: _filters.search),
                              ),
                              const SizedBox(width: 8),
                              EventCount(
                                log: widget.log,
                                filters: _filters,
                                profileId: widget.profileId,
                                deviceId: widget.deviceId,
                              ),
                              ShowSystemEvents(
                                value: _filters.showSystemEvents,
                              ),
                            ],
                          ),
                        ),
                        DeleteShownEvents(
                          log: widget.log,
                          filters: _filters,
                          profileId: widget.profileId,
                          deviceId: widget.deviceId,
                        ),
                        if (widget.onSync case final onSync?)
                          SyncAllButton(onSync: onSync),
                      ],
                    ),
                  ),
                  SizedBox(height: gap / 2),
                  Expanded(
                    child: wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: framedMap),
                              SizedBox(width: gap),
                              SizedBox(
                                width:
                                    (box.maxWidth * MonitoringView.eventsShare)
                                        .clamp(
                                          MonitoringView.minEventsWidth,
                                          MonitoringView.maxEventsWidth,
                                        ),
                                child: events(EdgeInsets.zero),
                              ),
                            ],
                          )
                        // Sized from the room under the filters, not the
                        // whole page, so a very short one doesn't overflow.
                        : LayoutBuilder(
                            builder: (context, room) => Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SizedBox(
                                  height: MonitoringView.stackedMapHeight(
                                    room.maxHeight,
                                  ),
                                  child: framedMap,
                                ),
                                Expanded(
                                  child: events(EdgeInsets.only(top: gap)),
                                ),
                              ],
                            ),
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Monitoring's Sync button: syncs this device with the cloud now (a full
/// pass) and asks the profile's other devices to do the same over live
/// sync, then says which it could do. Spins while asking.
class SyncAllButton extends StatefulWidget {
  const SyncAllButton({super.key, required this.onSync});

  /// Starts the sync; whether the other devices were asked.
  final Future<bool> Function() onSync;

  @override
  State<SyncAllButton> createState() => _SyncAllButtonState();
}

class _SyncAllButtonState extends State<SyncAllButton> {
  bool _busy = false;

  Future<void> _sync() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l = context.l10n;
    setState(() => _busy = true);
    bool asked;
    try {
      asked = await widget.onSync();
    } catch (_) {
      asked = false;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(asked ? l.monitoringSyncAsked : l.monitoringSyncHere),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('monitoring-sync'),
    tooltip: context.l10n.monitoringSyncTooltip,
    onPressed: _busy ? null : _sync,
    icon: _busy
        ? const SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.sync),
  );
}
