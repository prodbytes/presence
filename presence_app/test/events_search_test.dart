import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/annotations.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/monitoring.dart';

import 'fakes.dart';

/// A clip from [camera], with [names] tagged and [suggested] only
/// suggested.
ClipRequested clipOf(
  String camera, {
  List<String> names = const [],
  List<String> suggested = const [],
  required int minute,
}) {
  final annotations = ClipAnnotations();
  final frame = annotations.newFrame(onePixelPng, 1200);
  for (final name in names) {
    annotations.add(name, 0.5, 0.5, frame: frame);
  }
  for (final name in suggested) {
    annotations.add(
      name,
      0.5,
      0.5,
      frame: frame,
      source: TagSource.suggested,
      confidence: 0.6,
    );
  }
  return ClipRequested(
    VideoClip.restored(
      id: 'clip-$minute',
      cameraId: 'cam-$minute',
      cameraLabel: camera,
      before: const Duration(seconds: 15),
      after: const Duration(seconds: 15),
      past: null,
      full: null,
    ),
    annotations: annotations,
    time: DateTime(2026, 10, 1, 12, minute),
    id: 'event-$minute',
  );
}

void main() {
  late StreamController<AppEvent> bus;
  late EventLog log;

  setUp(() {
    bus = StreamController<AppEvent>.broadcast();
    log = EventLog(bus.stream)
      ..addHistory([
        clipOf('Back camera', names: ['Rex'], minute: 3),
        clipOf('Front door', suggested: ['Milo'], minute: 2),
        AppEvent(
          icon: Icons.notifications_none,
          title: 'Door opened',
          detail: 'Kitchen',
          time: DateTime(2026, 10, 1, 12, 1),
          id: 'door',
        ),
        AppEvent.appStarted(time: DateTime(2026, 10, 1, 12)),
      ]);
  });
  tearDown(() => bus.close());

  Future<void> show(WidgetTester tester, {double width = 1280}) async {
    // Tall, so every card is built.
    tester.view.physicalSize = Size(width, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MonitoringView(
            log: log,
            config: ConfigController(),
            tiles: const SizedBox(),
            deviceId: 'this_device',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder field() => find.byKey(const Key('event-search'));
  Finder inEvents(Finder f) =>
      find.descendant(of: find.byKey(const Key('events-page')), matching: f);

  /// The titles of the event cards shown, top to bottom.
  List<String> titles(WidgetTester tester) => [
    for (final title in [
      'Clip requested',
      'Door opened',
      'Application started',
    ])
      for (final _ in inEvents(find.text(title)).evaluate()) title,
  ];

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(field(), text);
    await tester.pumpAndSettle();
  }

  test('matches title, detail, camera and tags, ignoring case', () {
    final events = log.events;
    bool any(String q) => events.any((e) => eventMatches(e, q));
    final rex = events.firstWhere((e) => e.id == 'event-3');
    final milo = events.firstWhere((e) => e.id == 'event-2');
    final door = events.firstWhere((e) => e.id == 'door');

    expect(eventMatches(rex, 'rEx'), isTrue);
    expect(eventMatches(rex, '  back CAM '), isTrue);
    expect(eventMatches(door, 'kitchen'), isTrue);
    expect(eventMatches(door, 'opened'), isTrue);
    // A suggestion isn't a tag yet.
    expect(eventMatches(milo, 'milo'), isFalse);
    expect(eventMatches(milo, 'front door'), isTrue);
    expect(any('nobody'), isFalse);
    // Blank shows everything.
    expect(events.every((e) => eventMatches(e, '  ')), isTrue);
  });

  testWidgets('the field sits top left, on the chips row', (tester) async {
    await show(tester);
    final search = tester.getRect(field());
    final chip = tester.getRect(find.byKey(const Key('this-device-only')));
    final page = tester.getRect(find.byKey(const Key('monitoring-page')));
    expect(search.left, closeTo(page.left + 16, 0.5));
    expect(search.right, lessThan(chip.left));
    expect(search.center.dy, closeTo(chip.center.dy, 1));
  });

  testWidgets('typing filters the events; the x clears it', (tester) async {
    await show(tester);
    expect(titles(tester), [
      'Clip requested',
      'Clip requested',
      'Door opened',
      'Application started',
    ]);
    expect(find.byKey(const Key('event-search-clear')), findsNothing);

    await type(tester, 'REX');
    expect(titles(tester), ['Clip requested']);
    expect(inEvents(find.text('Back camera')), findsWidgets);

    await type(tester, 'door');
    // The Front door clip and the Door opened event.
    expect(titles(tester), ['Clip requested', 'Door opened']);

    await type(tester, 'milo');
    expect(titles(tester), isEmpty);
    expect(find.text('No events match "milo"'), findsOneWidget);

    await tester.tap(find.byKey(const Key('event-search-clear')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field()).controller!.text, isEmpty);
    expect(find.byKey(const Key('event-search-clear')), findsNothing);
    expect(titles(tester), hasLength(4));
  });

  testWidgets('works together with Show system events', (tester) async {
    await show(tester);
    await tester.tap(find.byKey(const Key('show-system-events')));
    await tester.pumpAndSettle();
    expect(titles(tester), ['Clip requested', 'Clip requested']);

    // Door opened is a system event: hidden even though it matches.
    await type(tester, 'door');
    expect(titles(tester), ['Clip requested']);
    expect(inEvents(find.text('Front door')), findsWidgets);

    await type(tester, 'kitchen');
    expect(find.text('No events match "kitchen"'), findsOneWidget);

    await tester.tap(find.byKey(const Key('show-system-events')));
    await tester.pumpAndSettle();
    expect(titles(tester), ['Door opened']);
  });

  testWidgets('fits a 320 dp phone, the chips wrapping below', (tester) async {
    await show(tester, width: 320);
    expect(tester.takeException(), isNull);
    final search = tester.getRect(field());
    final system = tester.getRect(find.byKey(const Key('show-system-events')));
    expect(search.left, closeTo(12, 0.5));
    expect(search.right, lessThanOrEqualTo(320 - 12));
    expect(system.right, lessThanOrEqualTo(320 - 12));
    expect(system.top, greaterThanOrEqualTo(search.bottom));

    await type(tester, 'a long search that is wider than the field');
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('event-search-clear')), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const Key('event-search-clear'))).right,
      lessThanOrEqualTo(search.right),
    );
  });
}
