import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/annotations.dart';
import 'package:presence_app/cameras/camera_source.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/event_flags.dart';
import 'package:presence_app/events.dart';

import 'fakes.dart';

/// A clip that saw [objects] (first at 1 s, then a second apart), with
/// [names] tagged by someone and [suggested] waiting for an answer.
ClipRequested clipWith(
  List<String> objects, {
  List<String> names = const [],
  List<String> suggested = const [],
  bool playable = true,
}) {
  final annotations = ClipAnnotations(const [], const {}, [
    for (final (i, o) in objects.indexed)
      ObjectTag(label: o, ms: 1000 * (i + 1), score: 0.8),
  ]);
  for (final name in names) {
    annotations.add(name, 0.5, 0.5);
  }
  for (final name in suggested) {
    annotations.add(name, 0.5, 0.5, source: TagSource.suggested);
  }
  return ClipRequested(
    VideoClip.restored(
      id: 'clip-${AppEvent.newId()}',
      cameraId: 'cam',
      cameraLabel: 'Back camera',
      before: const Duration(seconds: 15),
      after: const Duration(seconds: 15),
      past: null,
      full: playable
          ? ClipMedia(
              url: 'blob:clip',
              start: Duration.zero,
              end: const Duration(seconds: 30),
            )
          : null,
    ),
    annotations: annotations,
  );
}

void main() {
  group('the unidentified flag', () {
    test('an unknown person is flagged', () {
      final event = clipWith(['human', 'bicycle']);
      expect(event.flags, [EventFlag.unidentified]);
      expect(unidentifiedOf(event.annotations)!.label, 'Unidentified subject');
      expect(unidentifiedOf(event.annotations)!.ms, 1000);
    });

    test('an unknown cat or dog is flagged', () {
      expect(clipWith(['cat']).flags, [EventFlag.unidentified]);
      final dog = clipWith(['car', 'dog']);
      expect(dog.flags, [EventFlag.unidentified]);
      expect(unidentifiedOf(dog.annotations)!.label, 'Unidentified subject');
      // Where the dog was first seen, not the car.
      expect(unidentifiedOf(dog.annotations)!.ms, 2000);
    });

    test('other animals and objects are not flagged', () {
      expect(
        clipWith(['bird', 'horse', 'cow', 'bear', 'bicycle']).flags,
        isEmpty,
      );
      // Not searched yet, or nothing seen.
      expect(clipWith([]).flags, isEmpty);
      final unsearched = ClipRequested(
        VideoClip.restored(
          id: 'c',
          cameraId: 'cam',
          cameraLabel: 'Back camera',
          before: const Duration(seconds: 15),
          after: const Duration(seconds: 15),
          past: null,
          full: null,
        ),
      );
      expect(unsearched.flags, isEmpty);
    });

    test('everyone identified is not flagged', () {
      expect(clipWith(['human'], names: ['Ana']).flags, isEmpty);
      expect(clipWith(['human', 'dog'], names: ['Ana', 'Rex']).flags, isEmpty);
      // Recognized tags identify too.
      final recognized = clipWith(['dog']);
      recognized.annotations.add(
        'Rex',
        0.5,
        0.5,
        source: TagSource.detected,
        confidence: 0.9,
      );
      expect(recognized.flags, isEmpty);
    });

    test('a person and a pet need a name each', () {
      final both = clipWith(['dog', 'human']);
      expect(unidentifiedOf(both.annotations)!.label, 'Unidentified subject');
      both.annotations.add('Ana', 0.5, 0.5);
      expect(both.flags, [EventFlag.unidentified]);
      expect(unidentifiedOf(both.annotations)!.label, 'Unidentified subject');
      // The same subject twice is still one.
      both.annotations.add(' ana ', 0.4, 0.4);
      expect(both.flags, [EventFlag.unidentified]);
      both.annotations.add('Rex', 0.2, 0.2);
      expect(both.flags, isEmpty);
    });

    test('a suggestion identifies only once confirmed', () {
      final event = clipWith(['human'], suggested: ['Bo']);
      expect(event.flags, [EventFlag.unidentified]);
      event.annotations.confirm(event.annotations.items.single.id);
      expect(event.flags, isEmpty);
    });

    test('tagging clears it, and removing the tag brings it back', () {
      final event = clipWith(['human']);
      expect(event.flags, [EventFlag.unidentified]);
      event.annotations.add('Ana', 0.5, 0.5);
      expect(event.flags, isEmpty);
      event.annotations.removeName('Ana');
      expect(event.flags, [EventFlag.unidentified]);
    });

    test('the search finds flagged events', () {
      expect(eventMatches(clipWith(['cat']), 'unidentified'), isTrue);
      expect(
        eventMatches(clipWith(['cat'], names: ['Tom']), 'unidentified'),
        isFalse,
      );
    });
  });

  group("the card's flag", () {
    Future<void> pumpCard(WidgetTester tester, ClipRequested event) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: ClipEventCard(event: event)),
            ),
          ),
        );

    final flag = find.byKey(const Key('event-flag-unidentified'));

    testWidgets('shows on an unidentified event, and goes once tagged', (
      tester,
    ) async {
      final event = clipWith(['human']);
      await pumpCard(tester, event);
      expect(flag, findsOneWidget);
      expect(find.text('Unidentified subject · Identify'), findsOneWidget);
      expect(find.byTooltip('Unidentified subject — identify'), findsOneWidget);
      final icon = tester.widget<Icon>(
        find.descendant(of: flag, matching: find.byIcon(Icons.flag)),
      );
      expect(icon.color, EventFlag.unidentified.color);
      expect(
        find.bySemanticsLabel('Unidentified subject — identify'),
        findsOneWidget,
      );

      event.annotations.add('Ana', 0.5, 0.5);
      await tester.pump();
      expect(flag, findsNothing);
    });

    testWidgets('not on an event with nobody to identify', (tester) async {
      await pumpCard(tester, clipWith(['bird', 'bicycle']));
      expect(flag, findsNothing);
    });

    testWidgets('Identify opens the player where they were seen, to tag them', (
      tester,
    ) async {
      final event = clipWith(['car', 'dog']);
      await pumpCard(tester, event);
      await tester.tap(flag);
      await tester.pumpAndSettle();
      final player = tester.widget<ClipPlayerDialog>(
        find.byType(ClipPlayerDialog),
      );
      expect(player.startAt, const Duration(seconds: 2));
      expect(player.identify, isTrue);
      expect(find.byKey(const Key('identify-hint')), findsOneWidget);
      expect(find.byKey(const Key('tag-frame')), findsOneWidget);

      // Naming them in the player (as under "Tag this frame") clears it.
      final a = event.annotations;
      a.add('Rex', 0.5, 0.5, frame: a.newFrame(onePixelPng, 2000));
      await tester.pump();
      expect(find.byKey(const Key('identify-hint')), findsNothing);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(flag, findsNothing);
    });

    testWidgets('a clip that cannot play shows the flag without Identify', (
      tester,
    ) async {
      await pumpCard(tester, clipWith(['human'], playable: false));
      expect(flag, findsOneWidget);
      expect(find.text('Unidentified subject'), findsOneWidget);
    });

    testWidgets('fits a 320 dp phone', (tester) async {
      tester.view
        ..physicalSize = const Size(320, 900)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpCard(tester, clipWith(['human', 'dog', 'bicycle', 'car']));
      expect(flag, findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('fits a wide screen', (tester) async {
      tester.view
        ..physicalSize = const Size(1400, 900)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpCard(tester, clipWith(['human']));
      expect(flag, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
