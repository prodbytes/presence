import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/annotations.dart';
import 'package:presence_app/cameras/camera_source.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/monitoring.dart';

import 'fakes.dart';

import 'sealed.dart';

/// A playable clip from [minute] past noon with [names] tagged on a frame
/// 1.2 s in, and [objects] seen 2.5 s in.
ClipRequested clipOf(
  int minute, {
  List<String> names = const [],
  List<String> objects = const [],
}) {
  final annotations = ClipAnnotations(const [], const {}, [
    for (final o in objects) ObjectTag(label: o, ms: 2500, score: 0.8),
  ]);
  final frame = testFrame(onePixelPng, 1200);
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
      full: ClipMedia(
        url: 'blob:clip-$minute',
        start: Duration.zero,
        end: const Duration(seconds: 30),
      ),
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
        clipOf(3, names: ['Rex'], objects: ['cat', 'bicycle']),
        clipOf(2, names: ['Ana'], objects: ['bicycle']),
        clipOf(1, names: ['Rex', 'Ana'], objects: ['cat']),
        AppEvent(
          icon: Icons.notifications_none,
          title: 'Door opened',
          time: DateTime(2026, 10, 1, 12),
          id: 'door',
        ),
      ]);
  });
  tearDown(() => bus.close());

  Future<void> show(WidgetTester tester, {double width = 1280}) async {
    // Tall, so every card is built.
    tester.view.physicalSize = Size(width, 4000);
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

  Finder inEvents(Finder f) =>
      find.descendant(of: find.byKey(const Key('events-page')), matching: f);

  /// The search field's text; null while it's folded into its icon.
  String? searched(WidgetTester tester) {
    final field = find.byKey(const Key('event-search'));
    if (field.evaluate().isEmpty) return null;
    return tester.widget<TextField>(field).controller!.text;
  }

  /// The IDs of the clips shown, top to bottom, and "door".
  List<String> shown() => [
    for (final id in ['event-3', 'event-2', 'event-1'])
      if (inEvents(find.byKey(Key('event-device-$id'))).evaluate().isNotEmpty)
        id,
    if (inEvents(find.text('Door opened')).evaluate().isNotEmpty) 'door',
  ];

  /// Whether each of the chips [key] shows highlighted (selected).
  List<bool> highlighted(WidgetTester tester, String key) => [
    for (final e in inEvents(find.byKey(Key(key))).evaluate())
      (e.widget as Semantics).properties.selected ?? false,
  ];

  /// Opens [eventId]'s player by tapping its card's thumbnail.
  Future<void> openFromThumbnail(WidgetTester tester, String eventId) async {
    final index = shown().indexOf(eventId);
    await tester.tap(
      inEvents(find.byKey(const Key('clip-card-thumbnail'))).at(index),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ClipPlayerDialog), findsOneWidget);
  }

  testWidgets('tapping a tag on a card searches for it and highlights it; '
      'tapping it again clears the search', (tester) async {
    await show(tester);
    expect(shown(), ['event-3', 'event-2', 'event-1', 'door']);
    expect(highlighted(tester, 'clip-object-chip-cat'), [false, false]);

    await tester.tap(inEvents(find.byKey(const Key('clip-object-cat'))).first);
    await tester.pumpAndSettle();
    expect(searched(tester), 'cat');
    expect(shown(), ['event-3', 'event-1']);
    // Highlighted on every card shown, and only that tag.
    expect(highlighted(tester, 'clip-object-chip-cat'), [true, true]);
    expect(highlighted(tester, 'clip-object-chip-bicycle'), [false]);
    // Tapping a tag doesn't open the player.
    expect(find.byType(ClipPlayerDialog), findsNothing);
    final box = tester.widget<Container>(
      find
          .descendant(
            of: inEvents(find.byKey(const Key('clip-object-chip-cat'))).first,
            matching: find.byType(Container),
          )
          .first,
    );
    final scheme = Theme.of(tester.element(find.byType(MonitoringView)))
        .colorScheme;
    expect((box.decoration! as BoxDecoration).color, scheme.primaryContainer);

    // Again: every event, nothing highlighted.
    await tester.tap(inEvents(find.byKey(const Key('clip-object-cat'))).last);
    await tester.pumpAndSettle();
    expect(searched(tester), anyOf(isNull, isEmpty));
    expect(shown(), ['event-3', 'event-2', 'event-1', 'door']);
    expect(highlighted(tester, 'clip-object-chip-cat'), [false, false]);
  });

  testWidgets('tapping a subject on a card searches for them; clearing the '
      'search drops the highlight', (tester) async {
    await show(tester);
    await tester.tap(
      inEvents(find.byKey(const Key('event-subject-ana'))).first,
    );
    await tester.pumpAndSettle();
    expect(searched(tester), 'Ana');
    expect(shown(), ['event-2', 'event-1']);
    expect(highlighted(tester, 'event-subject-chip-ana'), [true, true]);
    expect(highlighted(tester, 'event-subject-chip-rex'), [false]);

    // Another subject replaces it.
    await tester.tap(inEvents(find.byKey(const Key('event-subject-rex'))));
    await tester.pumpAndSettle();
    expect(searched(tester), 'Rex');
    expect(shown(), ['event-3', 'event-1']);
    expect(highlighted(tester, 'event-subject-chip-rex'), [true, true]);
    expect(highlighted(tester, 'event-subject-chip-ana'), [false]);

    // The search's x clears the filter and the highlight.
    await tester.tap(find.byKey(const Key('event-search-clear')));
    await tester.pumpAndSettle();
    expect(searched(tester), isNull);
    expect(shown(), ['event-3', 'event-2', 'event-1', 'door']);
    expect(highlighted(tester, 'event-subject-chip-rex'), [false, false]);
  });

  testWidgets('a long press on a card label still opens the player where it '
      'was seen; its x still removes it', (tester) async {
    await show(tester);
    await tester.longPress(
      inEvents(find.byKey(const Key('clip-object-bicycle'))).first,
    );
    await tester.pumpAndSettle();
    final player = tester.widget<ClipPlayerDialog>(
      find.byType(ClipPlayerDialog),
    );
    expect(player.startAt, const Duration(milliseconds: 2500));
    expect(searched(tester), isNull);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    await tester.longPress(
      inEvents(find.byKey(const Key('event-subject-rex'))).first,
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<ClipPlayerDialog>(find.byType(ClipPlayerDialog)).startAt,
      const Duration(milliseconds: 1200),
    );
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    await tester.tap(
      inEvents(find.byKey(const Key('clip-object-remove-bicycle'))).first,
    );
    await tester.pumpAndSettle();
    expect(searched(tester), isNull);
    expect(
      (log.events.first as ClipRequested).annotations.objects!.map(
        (o) => o.label,
      ),
      ['cat'],
    );
  });

  testWidgets('tapping a tag in the event detail closes it on the list '
      'filtered by it, highlighted; tapping it again clears it', (
    tester,
  ) async {
    await show(tester);
    await openFromThumbnail(tester, 'event-2');
    await tester.tap(find.byKey(const Key('player-object-bicycle')));
    await tester.pumpAndSettle();
    expect(find.byType(ClipPlayerDialog), findsNothing);
    expect(searched(tester), 'bicycle');
    expect(shown(), ['event-3', 'event-2']);
    expect(highlighted(tester, 'clip-object-chip-bicycle'), [true, true]);

    // In the detail too.
    await openFromThumbnail(tester, 'event-2');
    expect(
      (tester.widget<Semantics>(
        find.byKey(const Key('player-object-chip-bicycle')),
      )).properties.selected,
      isTrue,
    );
    await tester.tap(find.byKey(const Key('player-object-bicycle')));
    await tester.pumpAndSettle();
    expect(find.byType(ClipPlayerDialog), findsNothing);
    expect(searched(tester), anyOf(isNull, isEmpty));
    expect(shown(), ['event-3', 'event-2', 'event-1', 'door']);
    expect(highlighted(tester, 'clip-object-chip-bicycle'), [false, false]);
  });

  testWidgets('tapping a subject in the event detail filters by them; a long '
      'press renames them', (tester) async {
    await show(tester);
    await openFromThumbnail(tester, 'event-1');
    final clip = log.events.firstWhere((e) => e.id == 'event-1');
    final ana = (clip as ClipRequested).annotations.tags.firstWhere(
      (a) => a.name == 'Ana',
    );
    final chip = find.byKey(Key('annotation-${ana.id}'));
    expect(tester.widget<InputChip>(chip).selected, isFalse);

    // A long press renames, as a tap did before.
    await tester.longPress(chip);
    await tester.pumpAndSettle();
    expect(find.text('Rename subject'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(ClipPlayerDialog), findsOneWidget);
    expect(searched(tester), isNull);

    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(find.byType(ClipPlayerDialog), findsNothing);
    expect(searched(tester), 'Ana');
    expect(shown(), ['event-2', 'event-1']);
    expect(highlighted(tester, 'event-subject-chip-ana'), [true, true]);

    await openFromThumbnail(tester, 'event-1');
    expect(tester.widget<InputChip>(chip).selected, isTrue);
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(find.byType(ClipPlayerDialog), findsNothing);
    expect(shown(), ['event-3', 'event-2', 'event-1', 'door']);
    expect(highlighted(tester, 'event-subject-chip-ana'), [false, false]);
  });

  testWidgets('fits a 320 dp phone with a tag filtered', (tester) async {
    await show(tester, width: 320);
    await tester.tap(inEvents(find.byKey(const Key('clip-object-cat'))).first);
    await tester.pumpAndSettle();
    expect(searched(tester), 'cat');
    await tester.tap(
      inEvents(find.byKey(const Key('event-subject-rex'))).first,
    );
    await tester.pumpAndSettle();
    expect(searched(tester), 'Rex');
    expect(highlighted(tester, 'event-subject-chip-rex'), [true, true]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('outside a timeline a tapped label still opens the player', (
    tester,
  ) async {
    final event = log.events.first as ClipRequested;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ClipEventCard(event: event)),
      ),
    );
    await tester.tap(find.byKey(const Key('clip-object-cat')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ClipPlayerDialog>(find.byType(ClipPlayerDialog)).startAt,
      const Duration(milliseconds: 2500),
    );
  });
}
