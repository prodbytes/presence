import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';

import 'package:presence_app/annotations.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/location/device_location.dart';
import 'package:presence_app/main.dart';
import 'package:presence_app/monitoring.dart';
import 'package:presence_app/settings.dart';
import 'package:presence_app/subjects.dart';

import 'fakes.dart';

/// A stored clip from [minutesAgo] minutes before noon, at [lat], with
/// [names] tagged on one frame.
ClipRequested clipWith(
  List<String> names, {
  required int minutesAgo,
  double? lat,
  String id = '',
}) {
  final annotations = ClipAnnotations();
  final frame = annotations.newFrame(onePixelPng, 1200);
  for (final name in names) {
    annotations.add(name, 0.5, 0.5, frame: frame);
  }
  final event = ClipRequested(
    VideoClip.restored(
      id: 'clip-$minutesAgo',
      cameraId: 'cam',
      cameraLabel: 'Back camera',
      before: const Duration(seconds: 15),
      after: const Duration(seconds: 15),
      past: null,
      full: null,
    ),
    annotations: annotations,
    time: DateTime(2026, 10, 1, 12).subtract(Duration(minutes: minutesAgo)),
    id: id.isEmpty ? 'event-$minutesAgo' : id,
  );
  if (lat != null) {
    event.location = DeviceLocation(
      latitude: lat,
      longitude: 2.29,
      source: LocationSource.map,
      time: event.time,
    );
  }
  return event;
}

void main() {
  group('subjectsOf', () {
    test('one subject per name, most recently seen first', () {
      final subjects = subjectsOf([
        clipWith(['Rex'], minutesAgo: 30),
        clipWith(['Ana', ' rex ', 'REX'], minutesAgo: 10),
        AppEvent(icon: Icons.circle, title: 'Not a clip'),
        clipWith(['Ana'], minutesAgo: 20),
      ]);
      expect(subjects.map((s) => s.id), ['ana', 'rex']);
      final rex = subjects[1];
      // Tagged twice in one clip still counts once; newest event first.
      expect(rex.sightings.map((s) => s.event.id), ['event-10', 'event-30']);
      expect(rex.name, 'rex', reason: 'as written on the latest event');
      expect(rex.latest.frame?.jpeg, onePixelPng);
    });

    test('dots fade from the newest to the oldest', () {
      expect(SubjectScreen.opacityOf(0, 1), 1);
      expect(SubjectScreen.opacityOf(0, 20), 1);
      expect(SubjectScreen.opacityOf(19, 20), closeTo(0.15, 1e-9));
      expect(
        SubjectScreen.opacityOf(5, 20),
        greaterThan(SubjectScreen.opacityOf(6, 20)),
      );
    });
  });

  test("a subject's color depends only on its name", () {
    expect(Subject.colorOf('rex'), Subject.colorOf('rex'));
    final subjects = subjectsOf([
      clipWith(['Rex'], minutesAgo: 1),
      clipWith([' REX '], minutesAgo: 2),
    ]);
    expect(subjects.single.color, Subject.colorOf('rex'));
    // Spread over the palette.
    final names = ['ana', 'rex', 'bob', 'cat', 'dog', 'eve', 'max', 'zoe'];
    expect({for (final n in names) Subject.colorOf(n)}.length, greaterThan(3));
  });

  test('the number of events on a subject map is a stored setting', () {
    expect(const PresenceConfig().subjects.mapEvents, 20);
    final config = const PresenceConfig().copyWith(
      subjects: const SubjectsConfig().copyWith(mapEvents: 35),
    );
    expect(PresenceConfig.fromJson(config.toJson()), config);
    expect(const SubjectsConfig().copyWith(mapEvents: 1000).mapEvents, 100);
    expect(const SubjectsConfig().copyWith(mapEvents: 0).mapEvents, 5);
    // Configs stored before the setting existed get the default.
    expect(
      PresenceConfig.fromJson({'version': 1}).subjects,
      const SubjectsConfig(),
    );
  });

  group('screens', () {
    late StreamController<AppEvent> bus;
    late EventLog log;
    late ConfigController config;

    setUp(() {
      bus = StreamController<AppEvent>.broadcast();
      log = EventLog(bus.stream);
      config = ConfigController();
    });
    tearDown(() => bus.close());

    Future<void> show(WidgetTester tester) async {
      // Wide: the subjects list runs down the right.
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MonitoringView(
              log: log,
              config: config,
              tiles: const SizedBox(),
            ),
          ),
        ),
      );
    }

    double opacityOfDot(WidgetTester tester, String eventId) => tester
        .widget<Opacity>(
          find.descendant(
            of: find.byKey(Key('subject-dot-$eventId')),
            matching: find.byType(Opacity),
          ),
        )
        .opacity;

    testWidgets("each event shows its subjects, and updates", (tester) async {
      await show(tester);
      expect(find.byKey(const Key('event-subjects')), findsNothing);

      log.addHistory([
        clipWith(['Rex'], minutesAgo: 30),
        clipWith(['Ana', ' rex ', 'REX'], minutesAgo: 10),
      ]);
      await tester.pump();
      // Tagged twice on one clip, shown once; as written on that clip.
      expect(find.byKey(const Key('event-subject-rex')), findsNWidgets(2));
      expect(find.byKey(const Key('event-subject-ana')), findsOneWidget);
      expect(find.text('rex'), findsOneWidget);
      expect(find.text('Ana'), findsOneWidget);
      Color colorOf(Finder f) =>
          ((tester.widget<Container>(
                    find.descendant(of: f, matching: find.byType(Container)),
                  )).decoration!
                  as BoxDecoration)
              .color!;
      expect(
        colorOf(find.byKey(const Key('event-subject-color-ana'))),
        Subject.colorOf('ana'),
      );
      expect(
        colorOf(find.byKey(const Key('event-subject-color-rex')).first),
        Subject.colorOf('rex'),
      );

      expect(
        formatSeen(DateTime(2026, 9, 30, 8, 5), DateTime(2026, 10, 1)),
        '2026-09-30 08:05:00',
      );
      expect(
        formatSeen(DateTime(2026, 10, 1, 8), DateTime(2026, 10, 1)),
        '08:00:00',
      );

      // A tag added on an older clip shows at once.
      final older = log.events.last as ClipRequested;
      older.annotations.add('Ana', 0.1, 0.1);
      await tester.pump();
      expect(find.byKey(const Key('event-subject-ana')), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a subject opens on a map of its latest events, fading', (
      tester,
    ) async {
      log.addHistory([
        for (var i = 0; i < 25; i++)
          clipWith(['Rex'], minutesAgo: i, lat: 48 + i / 100),
        clipWith(['Rex'], minutesAgo: 99, id: 'no-location'),
      ]);
      await show(tester);
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('subjects-label-rex')),
          matching: find.byType(Text),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('subject-page')), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Rex'), findsOneWidget);
      expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
      // The latest 20 of 26, by default.
      expect(find.text('Latest 20 of 26 events'), findsOneWidget);
      expect(find.byKey(const Key('subject-dot-event-0')), findsOneWidget);
      expect(find.byKey(const Key('subject-dot-event-19')), findsOneWidget);
      expect(find.byKey(const Key('subject-dot-event-20')), findsNothing);
      expect(opacityOfDot(tester, 'event-0'), 1);
      expect(opacityOfDot(tester, 'event-19'), closeTo(0.15, 1e-9));
      expect(
        opacityOfDot(tester, 'event-5'),
        greaterThan(opacityOfDot(tester, 'event-6')),
      );

      // More events in Settings: the one without a location is listed,
      // with no dot.
      config.update(
        (c) => c.copyWith(subjects: const SubjectsConfig(mapEvents: 30)),
      );
      await tester.pumpAndSettle();
      expect(find.text('26 events'), findsOneWidget);
      final markers = tester.widget<MarkerLayer>(find.byType(MarkerLayer));
      expect(markers.markers, hasLength(25));
      expect(find.byKey(const Key('subject-dot-no-location')), findsNothing);
      await tester.dragUntilVisible(
        find.byKey(const Key('subject-event-no-location')),
        find.byKey(const Key('subject-events')),
        const Offset(0, -200),
      );
      expect(find.text('No location'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets("dots take the subject's color, faded by age", (tester) async {
      log.addHistory([
        for (var i = 1; i <= 3; i++)
          clipWith(['Rex'], minutesAgo: i, lat: 48 + i / 10),
      ]);
      await show(tester);
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('subjects-label-rex')),
          matching: find.byType(Text),
        ),
      );
      await tester.pumpAndSettle();

      Color colorOfDot(String eventId) {
        final box = tester.widget<Container>(
          find.descendant(
            of: find.byKey(Key('subject-dot-$eventId')),
            matching: find.byType(Container),
          ),
        );
        return (box.decoration! as BoxDecoration).color!;
      }

      final rex = Subject.colorOf('rex');
      for (final id in ['event-1', 'event-2', 'event-3']) {
        expect(colorOfDot(id), rex);
      }
      expect(opacityOfDot(tester, 'event-1'), 1);
      expect(opacityOfDot(tester, 'event-2'), closeTo(0.575, 1e-9));
      expect(opacityOfDot(tester, 'event-3'), closeTo(0.15, 1e-9));
    });

    testWidgets('on a phone: the map above the events', (tester) async {
      log.addHistory([
        clipWith(['Rex'], minutesAgo: 1, lat: 48.1),
        clipWith(['Ana', 'Rex'], minutesAgo: 2, lat: 48.2),
        AppEvent(icon: Icons.circle, title: 'Door opened'),
      ]);
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MonitoringView(
              log: log,
              config: config,
              tiles: const SizedBox(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final map = tester.getRect(find.byKey(const Key('subjects-map')));
      final events = tester.getRect(find.byKey(const Key('events-page')));
      expect(map.bottom, lessThanOrEqualTo(events.top));
      expect(map.width, closeTo(events.width, 2));
      expect(find.byKey(const Key('subjects-page')), findsNothing);
      expect(find.byKey(const Key('subjects-label-rex')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('on top, a map of every subject, each in its color, and a '
        'matching square on each row', (tester) async {
      log.addHistory([
        clipWith(['Rex'], minutesAgo: 1, lat: 48.1),
        clipWith(['Rex', 'Ana'], minutesAgo: 2, lat: 48.2),
        clipWith(['Ana'], minutesAgo: 3, lat: 48.3),
        clipWith(['Ana'], minutesAgo: 4),
      ]);
      AppEvent? opened;
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MonitoringView(
              log: log,
              config: config,
              tiles: const SizedBox(),
              onOpenEvent: (e) => opened = e,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Two columns: the map on the left, the events on the right, both
      // the full height; no subjects list.
      final map = tester.getRect(find.byKey(const Key('subjects-map')));
      final events = tester.getRect(find.byKey(const Key('events-page')));
      expect(map.right, lessThanOrEqualTo(events.left));
      expect(events.right, lessThanOrEqualTo(1280));
      expect(map.top, closeTo(events.top, 2));
      expect(find.byKey(const Key('subjects-page')), findsNothing);

      // Every located event of every subject; the clip with both gets a
      // dot for each.
      final markers = tester.widget<MarkerLayer>(find.byType(MarkerLayer));
      expect(
        markers.markers.where(
          (m) => (m.key! as ValueKey<String>).value.startsWith('subjects-dot-'),
        ),
        hasLength(4),
      );
      Color colorOf(Finder f) =>
          (tester
                      .widget<Container>(
                        find.descendant(
                          of: f,
                          matching: find.byType(Container),
                        ),
                      )
                      .decoration!
                  as BoxDecoration)
              .color!;
      final rex = Subject.colorOf('rex'), ana = Subject.colorOf('ana');
      expect(colorOf(find.byKey(const Key('subjects-dot-rex-event-1'))), rex);
      expect(colorOf(find.byKey(const Key('subjects-dot-rex-event-2'))), rex);
      expect(colorOf(find.byKey(const Key('subjects-dot-ana-event-2'))), ana);
      expect(colorOf(find.byKey(const Key('subjects-dot-ana-event-3'))), ana);
      // Faded per subject, by age: Rex's newest solid, his older one faint.
      double opacity(String key) => tester
          .widget<Opacity>(
            find.descendant(
              of: find.byKey(Key(key)),
              matching: find.byType(Opacity),
            ),
          )
          .opacity;
      expect(opacity('subjects-dot-rex-event-1'), 1);
      expect(opacity('subjects-dot-rex-event-2'), closeTo(0.15, 1e-9));

      // The events' squares are the same colors.
      expect(
        colorOf(find.byKey(const Key('event-subject-color-rex')).first),
        rex,
      );
      expect(
        colorOf(find.byKey(const Key('event-subject-color-ana')).first),
        ana,
      );

      // A name beside each subject's newest dot only, edged in its color.
      final labels = tester.widget<MarkerLayer>(find.byType(MarkerLayer));
      expect(
        [
          for (final m in labels.markers)
            if (m.key case ValueKey<String>(:final value)
                when value.startsWith('subjects-label-'))
              (value, m.point.latitude),
        ],
        unorderedEquals([
          ('subjects-label-rex', 48.1),
          ('subjects-label-ana', 48.2),
        ]),
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('subjects-label-rex')),
          matching: find.text('Rex'),
        ),
        findsOneWidget,
      );

      // A tapped dot opens its event.
      await tester.tap(find.byKey(const Key('subjects-dot-ana-event-3')));
      expect(opened?.id, 'event-3');
    });

    testWidgets('the setting is on the Settings screen', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SettingsView(config: config)),
        ),
      );
      final slider = find.byKey(const Key('subject-events-slider'));
      await tester.scrollUntilVisible(slider, 100);
      expect(find.text("Latest events on a subject's map"), findsOneWidget);
      expect(find.text('20'), findsOneWidget);
      await tester.drag(
        find.descendant(of: slider, matching: find.byType(Slider)),
        const Offset(500, 0),
      );
      expect(config.subjects.mapEvents, 100);
    });
  });

  testWidgets('the Monitoring tab sits between Camera and Settings', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      PresenceApp(
        cameras: noCameras,
        auth: FakeAuthService.signedIn(),
        rolesClient: FakeRolesClient(),
        storage: newIdbFactoryMemory(),
        consentGiven: true,
        locator: _NoLocation(),
        mapTiles: const SizedBox(),
        // The day of the test events, so none is too old to keep.
        now: () => DateTime(2026, 10, 1, 12),
      ),
    );
    await tester.pumpAndSettle();
    await settleStorage(tester);
    final camera = tester.getCenter(find.byTooltip('Camera'));
    final monitoring = tester.getCenter(find.byTooltip('Monitoring'));
    final settings = tester.getCenter(find.byTooltip('Settings'));
    expect(camera.dx, lessThan(monitoring.dx));
    expect(monitoring.dx, lessThan(settings.dx));
    expect(find.byTooltip('Events'), findsNothing);
    expect(find.byTooltip('Subjects'), findsNothing);
    expect(find.byTooltip('Device'), findsNothing);

    await tester.tap(find.byTooltip('Monitoring'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('subjects-map')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a dot opens its event in the Monitoring timeline', (
    tester,
  ) async {
    // Tall enough for a clip card under the search field and the chips,
    // which take three rows in the test font.
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      PresenceApp(
        cameras: noCameras,
        auth: FakeAuthService.signedIn(),
        rolesClient: FakeRolesClient(),
        storage: newIdbFactoryMemory(),
        consentGiven: true,
        locator: _NoLocation(),
        mapTiles: const SizedBox(),
        // The day of the test events, so none is too old to keep.
        now: () => DateTime(2026, 10, 1, 12),
      ),
    );
    await tester.pumpAndSettle();
    await settleStorage(tester);
    final bus = AppEventBusScope.of(
      tester.element(find.byType(Scaffold).first),
    );
    // Rex's older sighting ends up far down the timeline.
    bus.publish(clipWith(['Rex'], minutesAgo: 0, lat: 48.2, id: 'rex-old'));
    for (var i = 0; i < 30; i++) {
      bus.publish(AppEvent(icon: Icons.circle, title: 'Filler $i'));
    }
    bus.publish(clipWith(['Rex'], minutesAgo: 0, lat: 48.1, id: 'rex-new'));
    await tester.pumpAndSettle();
    await settleStorage(tester);

    await tester.tap(find.byTooltip('Monitoring'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('subjects-label-rex')),
        matching: find.byType(Text),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('subject-dot-rex-old')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('subject-page')), findsNothing);
    expect(find.byKey(const Key('events-page')), findsOneWidget);
    final highlight = find.byKey(const Key('event-highlight'));
    expect(highlight, findsOneWidget);
    final card = tester.getRect(highlight);
    expect(card.top, greaterThanOrEqualTo(0));
    expect(card.bottom, lessThanOrEqualTo(900));
    expect(find.text('Filler 29'), findsNothing, reason: 'scrolled to it');

    // The outline goes after a few seconds.
    await tester.pump(const Duration(seconds: 5));
    expect(highlight, findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _NoLocation implements Locator {
  @override
  Future<({double latitude, double longitude, double? accuracy})> locate() =>
      Future.error(const LocationUnavailable('Location is off'));
}
