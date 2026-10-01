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

  testWidgets('wide: the map on the left, the events on the right', (
    tester,
  ) async {
    await show(tester, const Size(1500, 900));
    final map = rectOf(tester, 'subjects-map');
    final events = rectOf(tester, 'events-page');

    // Padded from the edges, a gap between, both from the same top.
    expect(map.left, greaterThanOrEqualTo(16));
    expect(events.left, greaterThanOrEqualTo(map.right + 16));
    expect(events.right, lessThanOrEqualTo(1500 - 16));
    expect(map.top, closeTo(events.top, 2));
    expect(map.top, greaterThanOrEqualTo(16));
    // The events column: two fifths of the width, at most 520 dp.
    expect(events.width, MonitoringView.maxEventsWidth);
    expect(find.byKey(const Key('subjects-page')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('very wide: the page stops growing and is centered', (
    tester,
  ) async {
    await show(tester, const Size(2400, 900));
    final page = rectOf(tester, 'monitoring-page');
    final map = rectOf(tester, 'subjects-map');
    final events = rectOf(tester, 'events-page');
    expect(page.width, 2400);
    expect(events.right - map.left, lessThanOrEqualTo(MonitoringView.maxWidth));
    expect(map.left, closeTo(2400 - events.right, 2));
  });

  testWidgets('a clip card fits the events column, its thumbnail 16:9', (
    tester,
  ) async {
    await show(tester, const Size(1500, 900));
    final events = rectOf(tester, 'events-page');
    final thumbnail = rectOf(tester, 'clip-card-thumbnail');
    expect(thumbnail.left, greaterThanOrEqualTo(events.left));
    expect(thumbnail.right, lessThanOrEqualTo(events.right));
    expect(thumbnail.height, closeTo(thumbnail.width * 9 / 16, 0.5));
  });

  testWidgets('narrow: the map above the events; cards stacked too', (
    tester,
  ) async {
    await show(tester, const Size(400, 800));
    final map = rectOf(tester, 'subjects-map');
    final events = rectOf(tester, 'events-page');
    expect(events.top, greaterThanOrEqualTo(map.bottom));
    expect(map.left, greaterThanOrEqualTo(12));
    expect(map.right, lessThanOrEqualTo(400 - 12));

    final thumbnail = rectOf(tester, 'clip-card-thumbnail');
    final title = tester.getRect(find.text('Clip requested'));
    expect(title.top, greaterThanOrEqualTo(thumbnail.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('each clip card shows its subjects in their colors', (
    tester,
  ) async {
    await show(tester, const Size(1500, 900));
    expect(find.byKey(const Key('event-subject-rex')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('event-subject-rex')),
        matching: find.text('Rex'),
      ),
      findsOneWidget,
    );
  });
}
