import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/annotations.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/location/device_location.dart';
import 'package:presence_app/monitoring.dart';
import 'package:presence_app/subjects.dart';

import 'fakes.dart';

/// A located clip from [minute] past noon with [names] tagged on one frame
/// and [objects] seen on it.
ClipRequested clipOf(
  List<String> names, {
  required int minute,
  List<String> objects = const [],
}) {
  final annotations = ClipAnnotations(const [], const {}, [
    for (final o in objects) ObjectTag(label: o, ms: 1000, score: 0.8),
  ]);
  final frame = annotations.newFrame(onePixelPng, 1200);
  for (final name in names) {
    annotations.add(name, 0.5, 0.5, frame: frame);
  }
  return ClipRequested(
      VideoClip.restored(
        id: 'clip-$minute',
        cameraId: 'cam',
        cameraLabel: 'Back camera',
        before: const Duration(seconds: 15),
        after: const Duration(seconds: 15),
        past: null,
        full: null,
      ),
      annotations: annotations,
      time: DateTime(2026, 10, 1, 12, minute),
      id: 'event-$minute',
    )
    ..location = DeviceLocation(
      latitude: 48 + minute / 10,
      longitude: 2.29,
      source: LocationSource.map,
      time: DateTime(2026, 10, 1, 12, minute),
    );
}

void main() {
  group('ClipAnnotations', () {
    test('removeName drops every tag of the name, not suggestions', () {
      final annotations = ClipAnnotations();
      final one = annotations.newFrame(onePixelPng, 100);
      final two = annotations.newFrame(onePixelPng, 200);
      annotations
        ..add('Rex', 0.1, 0.1, frame: one)
        ..add(' rex ', 0.2, 0.2, frame: two)
        ..add('Ana', 0.3, 0.3, frame: one)
        ..add('Rex', 0.4, 0.4, frame: two, source: TagSource.suggested);
      var notified = 0;
      annotations.addListener(() => notified++);

      annotations.removeName('REX');
      expect(notified, 1);
      expect(annotations.tags.map((a) => a.name), ['Ana']);
      expect(annotations.items.map((a) => a.source), [
        TagSource.manual,
        TagSource.suggested,
      ]);
      // Both frames are still used: by Ana, and by the suggestion.
      expect(annotations.frames.keys, {one.id, two.id});

      annotations.removeName('Ana');
      expect(annotations.frames.keys, {two.id});
      annotations.removeName('Nobody');
      expect(notified, 2);
    });

    test('removeObject drops one object tag', () {
      final annotations = ClipAnnotations(const [], const {}, const [
        ObjectTag(label: 'cat', ms: 0, score: 0.9),
        ObjectTag(label: 'bicycle', ms: 10, score: 0.7),
      ]);
      var notified = 0;
      annotations.addListener(() => notified++);
      annotations.removeObject('cat');
      expect(annotations.objects!.map((o) => o.label), ['bicycle']);
      annotations.removeObject('cat');
      expect(notified, 1);
      annotations.removeObject('bicycle');
      // Searched, nothing left: stored as an empty list.
      expect(annotations.objects, isEmpty);
    });
  });

  group('the x on a clip card', () {
    late StreamController<AppEvent> bus;
    late EventLog log;

    setUp(() {
      bus = StreamController<AppEvent>.broadcast();
      log = EventLog(bus.stream)
        ..addHistory([
          clipOf(['Rex', 'Ana'], minute: 2, objects: ['cat', 'bicycle']),
          clipOf(['Rex'], minute: 1),
        ]);
    });
    tearDown(() => bus.close());

    Future<void> show(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1500, 1600);
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

    /// [key] on the card of `event-<minute>`.
    Finder onCard(String minute, String key) => find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is ClipEventCard && w.event.id == 'event-$minute',
      ),
      matching: find.byKey(Key(key)),
    );

    String count(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const Key('event-count'))).data!;

    ClipRequested event(String id) =>
        log.events.firstWhere((e) => e.id == id) as ClipRequested;

    testWidgets('removes a subject from that event, everywhere', (
      tester,
    ) async {
      await show(tester);
      expect(onCard('2', 'event-subject-remove-ana'), findsOneWidget);
      expect(find.byKey(const Key('subjects-label-ana')), findsOneWidget);
      expect(find.byKey(const Key('subjects-dot-rex-event-2')), findsOneWidget);
      await tester.tap(find.byKey(const Key('event-search-open')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('event-search')), 'rex');
      await tester.pumpAndSettle();
      expect(count(tester), '2 / 2');

      await tester.tap(onCard('2', 'event-subject-remove-rex'));
      await tester.pumpAndSettle();

      // Gone from that card, its map dot and the search; still on the other.
      expect(onCard('2', 'event-subject-rex'), findsNothing);
      expect(onCard('1', 'event-subject-rex'), findsOneWidget);
      expect(find.byKey(const Key('subjects-dot-rex-event-2')), findsNothing);
      expect(find.byKey(const Key('subjects-dot-rex-event-1')), findsOneWidget);
      expect(count(tester), '1 / 2');
      expect(event('event-2').toRecord()['annotations'], hasLength(1));
      final rex = subjectsOf(log.events).firstWhere((s) => s.id == 'rex');
      expect(rex.sightings.map((s) => s.event.id), ['event-1']);

      // Ana's only event: she's no subject any more.
      await tester.enterText(find.byKey(const Key('event-search')), '');
      await tester.pumpAndSettle();
      await tester.tap(onCard('2', 'event-subject-remove-ana'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('subjects-label-ana')), findsNothing);
      expect(subjectsOf(log.events).map((s) => s.id), ['rex']);
      expect(event('event-2').toRecord().containsKey('annotations'), isFalse);
      expect(event('event-2').toRecord().containsKey('frames'), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('removes an object tag from that event', (tester) async {
      await show(tester);
      await tester.tap(find.byKey(const Key('event-search-open')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('event-search')), 'cat');
      await tester.pumpAndSettle();
      expect(count(tester), '1 / 2');

      await tester.tap(onCard('2', 'clip-object-remove-cat'));
      await tester.pumpAndSettle();
      expect(count(tester), '0 / 2');
      expect(event('event-2').toRecord()['objectTags'], [
        {'label': 'bicycle', 'ms': 1000, 'score': 0.8},
      ]);

      await tester.enterText(find.byKey(const Key('event-search')), '');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('clip-object-cat')), findsNothing);
      expect(find.byKey(const Key('clip-object-bicycle')), findsOneWidget);
      expect(
        find.byTooltip('Remove tag bicycle from this event'),
        findsOneWidget,
      );
    });
  });
}
