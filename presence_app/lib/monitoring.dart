import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'config.dart';
import 'events.dart';
import 'subjects.dart';

/// The Monitoring tab: what happened and who was seen, on one screen.
///
/// On a wide screen, the map of every subject's events sits top left with
/// all events under it, and the subjects list runs down the right. On a
/// phone they stack: the map, a strip of subject cards, then the events.
/// Tapping a dot on the map scrolls the events to its event.
class MonitoringView extends StatelessWidget {
  const MonitoringView({
    super.key,
    required this.log,
    required this.config,
    this.tiles,
    this.onOpenEvent,
    this.focus,
    this.deviceId,
    this.thisDeviceOnly,
  });

  /// Below this width the screen stacks instead of using two columns.
  static const double twoColumnWidth = 720;

  /// The subjects column's width on wide screens.
  static const double subjectsWidth = 340;

  final EventLog log;
  final ConfigController config;

  /// The map's tiles; defaults to OpenStreetMap.
  final Widget? tiles;

  /// Opens an event: scrolls the events to it (a dot tapped on a map).
  final ValueChanged<AppEvent>? onOpenEvent;

  /// The event the timeline scrolls to and outlines.
  final ValueListenable<String?>? focus;

  /// This device's ID, for the timeline's "Only this device" checkbox.
  final String? deviceId;
  final ValueNotifier<bool>? thisDeviceOnly;

  @override
  Widget build(BuildContext context) {
    final map = SubjectsMap(
      log: log,
      config: config,
      tiles: tiles,
      onOpenEvent: onOpenEvent,
    );
    final events = KeyedSubtree(
      key: const Key('events-page'),
      child: EventTimeline(
        log: log,
        focus: focus,
        deviceId: deviceId,
        thisDeviceOnly: thisDeviceOnly,
      ),
    );
    SubjectList subjects(Axis direction) => SubjectList(
      key: const Key('subjects-page'),
      log: log,
      config: config,
      tiles: tiles,
      onOpenEvent: onOpenEvent,
      direction: direction,
    );
    return LayoutBuilder(
      key: const Key('monitoring-page'),
      builder: (context, box) {
        if (box.maxWidth >= twoColumnWidth) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Column(
                  children: [
                    Expanded(flex: 2, child: map),
                    Expanded(flex: 3, child: events),
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              SizedBox(width: subjectsWidth, child: subjects(Axis.vertical)),
            ],
          );
        }
        return Column(
          children: [
            SizedBox(height: box.maxHeight * 0.3, child: map),
            SizedBox(height: 136, child: subjects(Axis.horizontal)),
            const Divider(height: 1),
            Expanded(child: events),
          ],
        );
      },
    );
  }
}
