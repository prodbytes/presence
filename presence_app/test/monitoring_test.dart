import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/annotations.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/monitoring.dart';

import 'fakes.dart';

/// A clip with [names] tagged, and a thumbnail.
ClipRequested tagged(List<String> names, {int minutesAgo = 0}) {
  final annotations = ClipAnnotations();
  final frame = annotations.newFrame(onePixelPng, 1200);
  for (final name in names) {
    annotations.add(name, 0.5, 0.5, frame: frame);
  }
  return ClipRequested(
    VideoClip.restored(
      id: 'clip-$minutesAgo',
      cameraId: 'cam',
      cameraLabel: 'Back camera',
      before: const Duration(seconds: 15),
      after: const Duration(seconds: 15),
      past: null,
      full: null,
      thumbnail: onePixelPng,
    ),
    annotations: annotations,
    time: DateTime(2026, 10, 1, 12).subtract(Duration(minutes: minutesAgo)),
    id: 'event-$minutesAgo',
  );
}

void main() {
  late StreamController<AppEvent> bus;
  late EventLog log;

  setUp(() {
    bus = StreamController<AppEvent>.broadcast();
    log = EventLog(bus.stream)
      ..addHistory([
        tagged(['Rex'], minutesAgo: 1),
        AppEvent.appStarted(time: DateTime(2026, 10, 1, 11)),
      ]);
  });
  tearDown(() => bus.close());

  Future<void> show(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MonitoringView(
            log: log,
            config: ConfigController(),
            tiles: const SizedBox(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Rect rectOf(WidgetTester tester, String key) =>
      tester.getRect(find.byKey(Key(key)));

  testWidgets('wide: map and subjects on top, events full width below', (
    tester,
  ) async {
    await show(tester, const Size(1500, 900));
    final map = rectOf(tester, 'subjects-map');
    final subjects = rectOf(tester, 'subjects-page');
    final events = rectOf(tester, 'events-page');

    // The top row: the map on the left, the subjects on the right.
    expect(map.left, 0);
    expect(subjects.left, greaterThan(map.right - 1));
    expect(subjects.width, MonitoringView.subjectsWidth);
    expect(subjects.right, 1500);
    expect(map.top, subjects.top);
    // The events under both, across the whole width.
    expect(events.top, greaterThanOrEqualTo(map.bottom));
    expect(events.top, greaterThanOrEqualTo(subjects.bottom));
    expect(events.left, 0);
    expect(events.width, 1500);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a wide clip card puts its thumbnail beside the details', (
    tester,
  ) async {
    await show(tester, const Size(1500, 900));
    final thumbnail = rectOf(tester, 'clip-card-thumbnail');
    expect(thumbnail.width, ClipEventCard.sideThumbnailWidth);
    // 16:9, not stretched to the card's width.
    expect(thumbnail.height, closeTo(320 * 9 / 16, 0.5));
    final title = tester.getRect(find.text('Clip requested'));
    expect(title.left, greaterThan(thumbnail.right));
  });

  testWidgets('narrow: map, subjects and events stacked; cards stacked too', (
    tester,
  ) async {
    await show(tester, const Size(400, 800));
    final map = rectOf(tester, 'subjects-map');
    final subjects = rectOf(tester, 'subjects-page');
    final events = rectOf(tester, 'events-page');
    expect(subjects.top, greaterThanOrEqualTo(map.bottom));
    expect(events.top, greaterThanOrEqualTo(subjects.bottom));

    final thumbnail = rectOf(tester, 'clip-card-thumbnail');
    final title = tester.getRect(find.text('Clip requested'));
    expect(title.top, greaterThanOrEqualTo(thumbnail.bottom));
    expect(tester.takeException(), isNull);
  });
}
