import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'config.dart';
import 'events.dart';
import 'subjects.dart';

/// The Monitoring tab: what happened and who was seen, on one screen.
///
/// Two rows. The first is split in two columns: the map of every subject's
/// events on the left, the subjects on the right. The second row is all
/// events, one card per row, centered. Tapping a dot on the map
/// scrolls the events to its event.
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

  /// The share of the height the first row (map and subjects) takes.
  static const double topShare = 0.45;

  /// The subjects column's widest; narrower screens give it [subjectsShare]
  /// of the width.
  static const double subjectsWidth = 340;
  static const double subjectsShare = 0.45;

  /// The event cards' widest, centered in the second row, so a clip's
  /// 16:9 thumbnail stays shorter than the row.
  static const double eventsWidth = 640;

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
  Widget build(BuildContext context) => LayoutBuilder(
    key: const Key('monitoring-page'),
    builder: (context, box) {
      final subjectsColumn = (box.maxWidth * subjectsShare).clamp(
        0.0,
        subjectsWidth,
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: box.maxHeight * topShare,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: SubjectsMap(
                    log: log,
                    config: config,
                    tiles: tiles,
                    onOpenEvent: onOpenEvent,
                  ),
                ),
                const VerticalDivider(width: 1),
                SizedBox(
                  width: subjectsColumn,
                  child: SubjectList(
                    key: const Key('subjects-page'),
                    log: log,
                    config: config,
                    tiles: tiles,
                    onOpenEvent: onOpenEvent,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: KeyedSubtree(
              key: const Key('events-page'),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: eventsWidth),
                  child: EventTimeline(
                    log: log,
                    focus: focus,
                    deviceId: deviceId,
                    thisDeviceOnly: thisDeviceOnly,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}
