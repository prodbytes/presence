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

  Future<void> show(
    WidgetTester tester, {
    double width = 1280,
    String? profileId,
  }) async {
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
            profileId: profileId,
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

  /// The "shown / all" count beside the field.
  String count(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('event-count'))).data!;

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
    // Object tags, once recognition has them.
    expect(eventMatches(door, 'cat'), isFalse);
    expect(eventMatches(rex, 'bicycle'), isFalse);
    (rex as ClipRequested).annotations.setObjects(const [
      ObjectTag(label: 'bicycle', ms: 0, score: 0.8),
    ]);
    expect(eventMatches(rex, 'BICYCLE'), isTrue);
  });

  testWidgets('object tags found later show up in the search', (tester) async {
    await show(tester);
    await type(tester, 'bicycle');
    expect(titles(tester), isEmpty);
    // Recognition tags the front door clip with a bicycle after the search.
    final clip = log.events.firstWhere((e) => e.id == 'event-2');
    (clip as ClipRequested).annotations.setObjects(const [
      ObjectTag(label: 'bicycle', ms: 1500, score: 0.7),
    ]);
    await tester.pumpAndSettle();
    expect(titles(tester), ['Clip requested']);
    expect(
      inEvents(find.byKey(const Key('clip-object-bicycle'))),
      findsOneWidget,
    );
    expect(count(tester), '1 / 4');
  });

  testWidgets('the field sits top left, on the chips row', (tester) async {
    await show(tester);
    final search = tester.getRect(field());
    final chip = tester.getRect(find.byKey(const Key('device-filter')));
    final page = tester.getRect(find.byKey(const Key('monitoring-page')));
    expect(search.left, closeTo(page.left + 16, 0.5));
    expect(search.right, lessThan(chip.left));
    expect(search.center.dy, closeTo(chip.center.dy, 1));
    // The count sits between the field and the chips.
    final counts = tester.getRect(find.byKey(const Key('event-count')));
    expect(counts.left, greaterThan(search.right));
    expect(counts.right, lessThan(chip.left));
    expect(counts.center.dy, closeTo(search.center.dy, 1));
  });

  testWidgets('the count is the events shown out of all', (tester) async {
    await show(tester);
    expect(count(tester), '4 / 4');
    expect(find.byTooltip('4 of 4 events shown'), findsOneWidget);

    await type(tester, 'door');
    expect(count(tester), '2 / 4');
    await type(tester, 'milo');
    expect(count(tester), '0 / 4');

    // The chips count too.
    await type(tester, '');
    await tester.tap(find.byKey(const Key('show-system-events')));
    await tester.pumpAndSettle();
    expect(count(tester), '2 / 4');

    // New events join both numbers.
    bus.add(AppEvent(icon: Icons.circle, title: 'Just now'));
    await tester.pumpAndSettle();
    expect(count(tester), '2 / 5');
    await tester.tap(find.byKey(const Key('show-system-events')));
    await tester.pumpAndSettle();
    expect(count(tester), '5 / 5');
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

  testWidgets("all is this profile's events, growing as the cloud's arrive", (
    tester,
  ) async {
    AppEvent stored(
      String id,
      String? owner, {
      String device = 'this_device',
    }) =>
        AppEvent(
            icon: Icons.notifications_none,
            title: 'Door opened',
            time: DateTime(2026, 10, 1, 11),
            id: id,
          )
          ..profileId = owner
          ..deviceId = device;
    // Another profile's event, and a signed-out one (no profile) that the
    // next sign-in gives its profile.
    log.addHistory([
      stored('theirs', 'someone-else'),
      stored('signed-out', null),
    ]);
    await show(tester, profileId: 'me');
    expect(count(tester), '5 / 5');

    // Sync brings down events from the cloud: this profile's, from this
    // device and another one.
    log.addHistory([
      stored('cloud-here', 'me'),
      stored('cloud-there', 'me', device: 'other_device'),
    ]);
    await tester.pumpAndSettle();
    // Every device shows by default: both match.
    expect(count(tester), '7 / 7');

    await type(tester, 'door');
    expect(count(tester), '5 / 7');
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
    // The count stays on the field's row.
    final counts = tester.getRect(find.byKey(const Key('event-count')));
    expect(counts.right, lessThanOrEqualTo(320 - 12));
    expect(counts.center.dy, closeTo(search.center.dy, 1));

    await type(tester, 'a long search that is wider than the field');
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('event-search-clear')), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const Key('event-search-clear'))).right,
      lessThanOrEqualTo(search.right),
    );
  });
}
