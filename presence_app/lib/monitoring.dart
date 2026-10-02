import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'config.dart';
import 'events.dart';
import 'subjects.dart';

/// The Monitoring tab: where subjects were seen and what happened.
///
/// Two columns on a wide screen: the map of every subject's events on the
/// left, all events on the right, each clip's card showing its subjects in
/// their colors. On a phone the map sits above the events. Once the device
/// ID is known, the "Only this device" chip sits at the top, next to the
/// "Show system events" chip, both after the events search field (top
/// left). Tapping a dot on the map scrolls the events to its event;
/// tapping a subject's name opens the subject.
class MonitoringView extends StatefulWidget {
  const MonitoringView({
    super.key,
    required this.log,
    required this.config,
    this.tiles,
    this.onOpenEvent,
    this.focus,
    this.deviceId,
    this.thisDeviceOnly,
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

  /// This device's ID, for the "Only this device" chip.
  final String? deviceId;
  final ValueNotifier<bool>? thisDeviceOnly;

  /// The "Show system events" chip ([EventTimeline.showSystemEvents]).
  final ValueNotifier<bool>? showSystemEvents;

  /// The events search field's text ([EventTimeline.search]).
  final ValueNotifier<String>? search;

  @override
  State<MonitoringView> createState() => _MonitoringViewState();
}

class _MonitoringViewState extends State<MonitoringView> {
  ValueNotifier<bool>? _ownFilter;
  ValueNotifier<bool> get _filter =>
      widget.thisDeviceOnly ?? (_ownFilter ??= ValueNotifier(true));

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
    );
    Widget events(EdgeInsets padding) => KeyedSubtree(
      key: const Key('events-page'),
      child: EventTimeline(
        log: widget.log,
        focus: widget.focus,
        deviceId: widget.deviceId,
        thisDeviceOnly: _filter,
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
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        EventSearch(value: _search),
                        // Until the device ID is known there's nothing to
                        // filter by.
                        if (widget.deviceId != null)
                          ThisDeviceOnly(value: _filter),
                        ShowSystemEvents(value: _system),
                      ],
                    ),
                  ),
                  SizedBox(height: gap),
                  Expanded(
                    child: wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: Padding(
                                  padding: EdgeInsets.only(bottom: gap),
                                  child: framedMap,
                                ),
                              ),
                              SizedBox(width: gap),
                              SizedBox(
                                width:
                                    (box.maxWidth * MonitoringView.eventsShare)
                                        .clamp(
                                          MonitoringView.minEventsWidth,
                                          MonitoringView.maxEventsWidth,
                                        ),
                                child: events(EdgeInsets.only(bottom: gap)),
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
                                child: events(
                                  EdgeInsets.only(top: gap, bottom: gap),
                                ),
                              ),
                            ],
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
