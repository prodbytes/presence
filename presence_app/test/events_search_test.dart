import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/annotations.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/monitoring.dart';

import 'fakes.dart';

import 'sealed.dart';

/// A clip from [camera], with [names] tagged and [suggested] only
/// suggested.
ClipRequested clipOf(
  String camera, {
  List<String> names = const [],
  List<String> suggested = const [],
  required int minute,
}) {
  final annotations = ClipAnnotations();
  final frame = testFrame(onePixelPng, 1200);
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
    EventFilters? filters,
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
            filters: filters,
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

  Finder opener() => find.byKey(const Key('event-search-open'));
  Finder system() => find.byKey(const Key('show-system-events'));

  /// Types [text] in the search, opening it first if it's folded.
  Future<void> type(WidgetTester tester, String text) async {
    if (field().evaluate().isEmpty) {
      await tester.tap(opener());
      await tester.pumpAndSettle();
    }
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

  testWidgets('the search is an icon top left until tapped, then a field '
      'to type in, folding back when left empty', (tester) async {
    await show(tester);
    expect(field(), findsNothing);
    final icon = tester.getRect(opener());
    final page = tester.getRect(find.byKey(const Key('monitoring-page')));
    expect(icon.left, closeTo(page.left + 16, 0.5));
    expect(icon.height, greaterThanOrEqualTo(40));
    expect(find.byTooltip('Search events'), findsOneWidget);
    // The count sits beside it.
    final counts = tester.getRect(find.byKey(const Key('event-count')));
    expect(counts.left, greaterThan(icon.right));
    expect(counts.center.dy, closeTo(icon.center.dy, 1));

    // Tapped, it opens focused, so the user can type straight away.
    await tester.tap(opener());
    await tester.pumpAndSettle();
    expect(opener(), findsNothing);
    final editable = tester.widget<EditableText>(
      find.descendant(of: field(), matching: find.byType(EditableText)),
    );
    expect(editable.focusNode.hasFocus, isTrue);
    await tester.enterText(field(), 'rex');
    await tester.pumpAndSettle();
    expect(titles(tester), ['Clip requested']);

    // With text it stays open when it loses focus.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(field(), findsOneWidget);
    expect(count(tester), '1 / 4');

    // Emptied and unfocused, it folds back into the icon.
    await tester.enterText(field(), '');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(field(), findsNothing);
    expect(opener(), findsOneWidget);
    expect(titles(tester), hasLength(4));
  });

  testWidgets('a search kept from before shows open', (tester) async {
    final filters = EventFilters(search: 'door');
    addTearDown(filters.dispose);
    tester.view.physicalSize = const Size(390, 844);
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
            filters: filters,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field()).controller!.text, 'door');
    expect(count(tester), '2 / 4');
    // Cleared elsewhere (an event it hid was opened), it folds back.
    filters.search.value = '';
    await tester.pumpAndSettle();
    expect(field(), findsNothing);
    expect(opener(), findsOneWidget);
  });

  testWidgets('the count is the events shown out of all', (tester) async {
    await show(tester);
    expect(count(tester), '4 / 4');
    expect(find.byTooltip('4 of 4 events shown'), findsOneWidget);

    await type(tester, 'door');
    expect(count(tester), '2 / 4');
    await type(tester, 'milo');
    expect(count(tester), '0 / 4');

    // The filters count too.
    await type(tester, '');
    await tester.tap(system());
    await tester.pumpAndSettle();
    expect(count(tester), '2 / 4');

    // New events join both numbers.
    bus.add(AppEvent(icon: Icons.circle, title: 'Just now'));
    await tester.pumpAndSettle();
    expect(count(tester), '2 / 5');
    await tester.tap(system());
    await tester.pumpAndSettle();
    expect(count(tester), '5 / 5');
  });

  testWidgets('typing filters the events; the x clears and folds it', (
    tester,
  ) async {
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
    expect(field(), findsNothing);
    expect(opener(), findsOneWidget);
    expect(titles(tester), hasLength(4));
  });

  testWidgets('works together with Show system events', (tester) async {
    await show(tester);
    await tester.tap(system());
    await tester.pumpAndSettle();
    expect(titles(tester), ['Clip requested', 'Clip requested']);

    // Door opened is a system event: hidden even though it matches.
    await type(tester, 'door');
    expect(titles(tester), ['Clip requested']);
    expect(inEvents(find.text('Front door')), findsWidgets);

    await type(tester, 'kitchen');
    expect(find.text('No events match "kitchen"'), findsOneWidget);

    await tester.tap(system());
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
    // The timeline shows what's counted: not the other profile's event.
    expect(titles(tester), hasLength(5));
    expect(find.byKey(const Key('event-device-theirs')), findsNothing);
    expect(find.byKey(const Key('event-device-signed-out')), findsOneWidget);

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
    expect(titles(tester), hasLength(5));
  });

  testWidgets('the system events toggle is a small icon in the top row, '
      'with the other filters', (tester) async {
    await show(tester, width: 390);
    final toggle = tester.getRect(system());
    final row = tester.getRect(find.byKey(const Key('monitoring-filters')));
    final events = tester.getRect(find.byKey(const Key('events-page')));
    expect(
      find.descendant(
        of: find.byKey(const Key('monitoring-filters')),
        matching: system(),
      ),
      findsOneWidget,
    );
    expect(toggle.center.dy, closeTo(row.center.dy, 1));
    expect(toggle.bottom, lessThanOrEqualTo(events.top));
    expect(toggle.height, lessThanOrEqualTo(48));
    expect(toggle.height, greaterThanOrEqualTo(40));
    // No label; its tooltip names it, and says what a tap does.
    expect(find.text('Show system events'), findsNothing);
    expect(find.byTooltip('Show system events'), findsNothing);
    expect(find.byTooltip('Hide system events'), findsOneWidget);
    expect(tester.widget<IconButton>(system()).isSelected, isTrue);

    await tester.tap(system());
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(system()).isSelected, isFalse);
    expect(find.byTooltip('Show system events'), findsOneWidget);
    expect(titles(tester), ['Clip requested', 'Clip requested']);
  });

  for (final width in [320.0, 390.0]) {
    testWidgets('fits a ${width.toInt()} dp phone, one row on top', (
      tester,
    ) async {
      await show(tester, width: width);
      expect(tester.takeException(), isNull);
      final row = tester.getRect(find.byKey(const Key('monitoring-filters')));
      expect(row.height, lessThanOrEqualTo(48));
      final icon = tester.getRect(opener());
      expect(icon.left, closeTo(12, 0.5));

      // A tapped device searches for it: the field opens with its ID.
      await tester.tap(find.byKey(const Key('event-device-door')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.widget<TextField>(field()).controller!.text, 'this_device');
      expect(tester.getRect(field()).right, lessThanOrEqualTo(width - 12));

      // Open, with a long search, the field shares the row.
      await type(tester, 'a long search that is wider than the field');
      expect(tester.takeException(), isNull);
      final search = tester.getRect(field());
      expect(search.left, closeTo(12, 0.5));
      final counts = tester.getRect(find.byKey(const Key('event-count')));
      expect(counts.left, greaterThan(search.right));
      expect(counts.center.dy, closeTo(search.center.dy, 1));
      expect(
        tester.getRect(find.byKey(const Key('event-search-clear'))).right,
        lessThanOrEqualTo(search.right),
      );
      expect(tester.getRect(system()).right, lessThanOrEqualTo(width - 12));
    });
  }

  group('opening an event (EventFilters.focus)', () {
    // As on the home screen, outside DEV: system events hidden, and the
    // filters kept while the Monitoring tab comes and goes.
    late EventFilters filters;
    setUp(() => filters = EventFilters(showSystemEvents: false));
    tearDown(() => filters.dispose());

    /// Another tab: the Monitoring tab's widgets are gone.
    Future<void> away(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: Text('Settings')));
      await tester.pumpAndSettle();
    }

    testWidgets('shows it once: back on the tab later, the search and '
        'filters set since are kept', (tester) async {
      await show(tester, filters: filters);
      expect(titles(tester), ['Clip requested', 'Clip requested']);

      // Opened from a subject's map: a system event, so they show.
      filters.focus('door');
      await tester.pumpAndSettle();
      expect(filters.showSystemEvents.value, isTrue);
      expect(find.byKey(const Key('event-highlight')), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Then a search that hides it, system events off.
      await type(tester, 'rex');
      await tester.tap(system());
      await tester.pumpAndSettle();
      expect(titles(tester), ['Clip requested']);

      // Settings, and back: as it was left.
      await away(tester);
      await show(tester, filters: filters);
      expect(tester.takeException(), isNull);
      expect(filters.search.value, 'rex');
      expect(filters.showSystemEvents.value, isFalse);
      expect(tester.widget<TextField>(field()).controller!.text, 'rex');
      expect(titles(tester), ['Clip requested']);
      expect(find.byKey(const Key('event-highlight')), findsNothing);
    });

    testWidgets('asked for before the tab is built, it shows once it is, '
        'after the first frame', (tester) async {
      filters.search.value = 'milo';
      filters.focus('door');
      await show(tester, filters: filters);
      // No "setState() called during build": the filters change after it.
      expect(tester.takeException(), isNull);
      expect(filters.search.value, '');
      expect(filters.showSystemEvents.value, isTrue);
      expect(find.byKey(const Key('event-highlight')), findsOneWidget);

      await type(tester, 'milo');
      await away(tester);
      await show(tester, filters: filters);
      expect(filters.search.value, 'milo');
      expect(find.byKey(const Key('event-highlight')), findsNothing);
    });

    testWidgets('asked for again, even the same event, it shows again', (
      tester,
    ) async {
      await show(tester, filters: filters);
      filters.focus('door');
      await tester.pumpAndSettle();
      await tester.pump(EventTimeline.highlightFor);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('event-highlight')), findsNothing);
      await type(tester, 'rex');
      filters.focus('door');
      await tester.pumpAndSettle();
      expect(filters.search.value, '');
      expect(find.byKey(const Key('event-highlight')), findsOneWidget);
      await tester.pump(EventTimeline.highlightFor);
    });
  });
}
