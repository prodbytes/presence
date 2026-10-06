import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'config.dart';
import 'events.dart';
import 'subjects.dart';

/// The Monitoring tab: where subjects were seen and what happened.
///
/// Two columns on a wide screen: the map of every subject's events on the
/// left, all events on the right, each clip's card showing its subjects in
/// their colors. On a phone the map sits above the events. One compact row
/// at the top: the events search ([EventSearch], an icon until tapped), its
/// matching / all events count ([EventCount]) and, while the events show
/// only one device's (picked by tapping an event's device,
/// [EventDeviceTag]), a chip to show every device again
/// ([DeviceFilterChip]). The small "Show system events" toggle
/// ([ShowSystemEvents]) sits at the bottom right. Tapping a dot on the map
/// scrolls the events to its event; tapping a subject's name opens the
/// subject.
class MonitoringView extends StatefulWidget {
  const MonitoringView({
    super.key,
    required this.log,
    required this.config,
    this.tiles,
    this.onOpenEvent,
    this.focus,
    this.deviceId,
    this.profileId,
    this.onlyDevice,
    this.showSystemEvents,
    this.search,
  });

  /// Below this width the map goes above the events instead of beside.
  static const double twoColumnWidth = 720;

  /// The map's share of the height when it's above the events.
  static const double stackedMapShare = 0.35;

  /// The events column beside the map: [eventsShare] of the width, kept
  /// between [minEventsWidth] and [maxEventsWidth]; the map takes the rest.
  static const double eventsShare = 0.4;
  static const double minEventsWidth = 360;
  static const double maxEventsWidth = 520;

  /// The page's widest; wider screens center it.
  static const double maxWidth = 1600;

  final EventLog log;
  final ConfigController config;

  /// The map's tiles; defaults to OpenStreetMap.
  final Widget? tiles;

  /// Opens an event: scrolls the events to it (a dot tapped on a map).
  final ValueChanged<AppEvent>? onOpenEvent;

  /// The event the timeline scrolls to and outlines.
  final ValueListenable<String?>? focus;

  /// This device's ID: events without one (not saved yet) are its.
  final String? deviceId;

  /// The signed-in account's profile (null signed out): the events count counts
  /// only its own ([EventCount]).
  final String? profileId;

  /// The one device whose events show ([EventTimeline.onlyDevice]).
  final ValueNotifier<String?>? onlyDevice;

  /// The "Show system events" toggle ([EventTimeline.showSystemEvents]).
  final ValueNotifier<bool>? showSystemEvents;

  /// The events search field's text ([EventTimeline.search]).
  final ValueNotifier<String>? search;

  @override
  State<MonitoringView> createState() => _MonitoringViewState();
}

class _MonitoringViewState extends State<MonitoringView> {
  ValueNotifier<String?>? _ownFilter;
  ValueNotifier<String?> get _filter =>
      widget.onlyDevice ?? (_ownFilter ??= ValueNotifier(null));

  ValueNotifier<bool>? _ownSystem;
  ValueNotifier<bool> get _system =>
      widget.showSystemEvents ?? (_ownSystem ??= ValueNotifier(true));

  ValueNotifier<String>? _ownSearch;
  ValueNotifier<String> get _search =>
      widget.search ?? (_ownSearch ??= ValueNotifier(''));

  @override
  void dispose() {
    _ownFilter?.dispose();
    _ownSystem?.dispose();
    _ownSearch?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final map = SubjectsMap(
      log: widget.log,
      config: widget.config,
      tiles: widget.tiles,
      onOpenEvent: widget.onOpenEvent,
      deviceId: widget.deviceId,
      onlyDevice: _filter,
    );
    Widget events(EdgeInsets padding) => KeyedSubtree(
      key: const Key('events-page'),
      child: EventTimeline(
        log: widget.log,
        focus: widget.focus,
        deviceId: widget.deviceId,
        onlyDevice: _filter,
        showSystemEvents: _system,
        search: _search,
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
                  // the count and the device filter, if any. The open
                  // field gives up room on a narrow phone.
                  SizedBox(
                    height: 40,
                    child: Row(
                      key: const Key('monitoring-filters'),
                      children: [
                        Flexible(child: EventSearch(value: _search)),
                        const SizedBox(width: 8),
                        EventCount(
                          log: widget.log,
                          profileId: widget.profileId,
                          deviceId: widget.deviceId,
                          onlyDevice: _filter,
                          showSystemEvents: _system,
                          search: _search,
                        ),
                        const SizedBox(width: 8),
                        Flexible(child: DeviceFilterChip(value: _filter)),
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
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SizedBox(
                                height:
                                    box.maxHeight *
                                    MonitoringView.stackedMapShare,
                                child: framedMap,
                              ),
                              Expanded(
                                child: events(EdgeInsets.only(top: gap)),
                              ),
                            ],
                          ),
                  ),
                  // Small and out of the way, at the bottom right.
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: ShowSystemEvents(value: _system),
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
