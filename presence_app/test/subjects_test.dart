import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';
import 'package:latlong2/latlong.dart';

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
  double lng = 2.29,
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
      longitude: lng,
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
    expect(const PresenceConfig().subjects.mapEvents, 100);
    final config = const PresenceConfig().copyWith(
      subjects: const SubjectsConfig().copyWith(mapEvents: 35),
    );
    expect(PresenceConfig.fromJson(config.toJson()), config);
    expect(const SubjectsConfig().copyWith(mapEvents: 1000).mapEvents, 500);
    expect(const SubjectsConfig().copyWith(mapEvents: 0).mapEvents, 10);
    // A value stored before the default changed is kept.
    expect(
      PresenceConfig.fromJson({
        'version': 1,
        'subjects': {'mapEvents': 20},
      }).subjects.mapEvents,
      20,
    );
    // Configs stored before the setting existed get the default.
    expect(
      PresenceConfig.fromJson({'version': 1}).subjects,
      const SubjectsConfig(),
    );
  });

  test('framing points around the newest centers the fit on it', () {
    const newest = LatLng(48.1, 2.29);
    final framed = framedAround(newest, const [
      LatLng(48.4, 2.29),
      LatLng(49.2, 3.5),
    ]);
    final projection = const Epsg3857().projection;
    final xs = [for (final p in framed) projection.projectXY(p).$1];
    final ys = [for (final p in framed) projection.projectXY(p).$2];
    final (cx, cy) = projection.projectXY(newest);
    double mid(List<double> v) =>
        (v.reduce((a, b) => a < b ? a : b) +
            v.reduce((a, b) => a > b ? a : b)) /
        2;
    expect(mid(xs), closeTo(cx, 1e-6));
    expect(mid(ys), closeTo(cy, 1e-6));
    expect(framed, containsAll(const [LatLng(48.4, 2.29), LatLng(49.2, 3.5)]));
    // Past the date line, the mirror stops at it.
    final wrapped = framedAround(const LatLng(0, 179), const [LatLng(0, 170)]);
    expect(wrapped.last.longitude, 180);
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
      // Fewer than the default 100, to see the rest left out.
      config.update(
        (c) => c.copyWith(subjects: const SubjectsConfig(mapEvents: 20)),
      );
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
      // The latest 20 of 26.
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

    MapCamera cameraOf(WidgetTester tester) => MapCamera.of(
      tester.element(find.byType(MarkerLayer, skipOffstage: false)),
    );

    testWidgets('the map opens on the newest event close up, with the ones '
        'nearby, and has zoom buttons', (tester) async {
      log.addHistory([
        clipWith(['Rex'], minutesAgo: 1, lat: 48.1),
        // About 90 m north: nearby.
        clipWith(['Ana'], minutesAgo: 2, lat: 48.1008),
        // About 30 km north: left out of the fit.
        clipWith(['Rex'], minutesAgo: 3, lat: 48.4),
      ]);
      await show(tester);
      await tester.pumpAndSettle();

      final map = tester.getRect(find.byKey(const Key('subjects-map')));
      Offset dot(String id) => tester.getCenter(find.byKey(Key(id)));
      final newest = dot('subjects-dot-rex-event-1');
      // The newest in the middle, at street level.
      expect(newest.dx, closeTo(map.center.dx, 1));
      expect(newest.dy, closeTo(map.center.dy, 1));
      final zoom = cameraOf(tester).zoom;
      expect(zoom, inInclusiveRange(16, 17));
      // The nearby one in view, the far one not.
      final near = dot('subjects-dot-ana-event-2');
      expect(map.deflate(40).contains(near), isTrue, reason: '$near in $map');
      expect(
        cameraOf(tester).visibleBounds.contains(const LatLng(48.4, 2.29)),
        isFalse,
      );

      // Zoom in spreads the dots (around the center), zoom out brings
      // them back.
      final zoomIn = find.byKey(const Key('sightings-zoom-in'));
      final zoomOut = find.byKey(const Key('sightings-zoom-out'));
      expect(zoomIn, findsOneWidget);
      final apart = (near - newest).distance;
      await tester.tap(zoomIn);
      await tester.pumpAndSettle();
      expect(
        (dot('subjects-dot-ana-event-2') - dot('subjects-dot-rex-event-1'))
            .distance,
        closeTo(apart * 2, 2),
      );
      await tester.tap(zoomOut);
      await tester.pumpAndSettle();
      expect(
        (dot('subjects-dot-ana-event-2') - dot('subjects-dot-rex-event-1'))
            .distance,
        closeTo(apart, 2),
      );
    });

    testWidgets('a lone newest event is shown at zoom 17', (tester) async {
      log.addHistory([
        clipWith(['Rex'], minutesAgo: 1, lat: 48.1),
        clipWith(['Rex'], minutesAgo: 2, lat: 49.2),
      ]);
      await show(tester);
      await tester.pumpAndSettle();
      final camera = cameraOf(tester);
      expect(camera.zoom, 17);
      expect(camera.center.latitude, closeTo(48.1, 1e-6));
    });

    testWidgets('the map follows the newest event as events load and arrive, '
        'until it is moved', (tester) async {
      await show(tester);
      await tester.pumpAndSettle();
      // Nothing yet: the whole world.
      expect(cameraOf(tester).zoom, 2);

      // The events load: the newest close up.
      log.addHistory([
        clipWith(['Rex'], minutesAgo: 5, lat: 48.1),
        clipWith(['Rex'], minutesAgo: 6, lat: 48.3),
      ]);
      await tester.pumpAndSettle();
      expect(cameraOf(tester).center.latitude, closeTo(48.1, 1e-6));
      expect(cameraOf(tester).zoom, 17);

      // A newer one arrives: the map moves to it.
      bus.add(clipWith(['Ana'], minutesAgo: 4, lat: 48.2));
      await tester.pumpAndSettle();
      expect(cameraOf(tester).center.latitude, closeTo(48.2, 1e-6));

      // Moved by hand, it stays put when the next one arrives.
      final map = tester.getRect(find.byKey(const Key('subjects-map')));
      await tester.dragFrom(map.center, const Offset(-120, 80));
      await tester.pumpAndSettle();
      final moved = cameraOf(tester).center;
      expect(moved.latitude, isNot(closeTo(48.2, 1e-6)));
      bus.add(clipWith(['Rex'], minutesAgo: 3, lat: 48.25));
      await tester.pumpAndSettle();
      expect(log.events.first.id, 'event-3');
      expect(cameraOf(tester).center, moved);
      expect(cameraOf(tester).zoom, 17);

      // A resize (rotation, keyboard, window) doesn't snap it back either.
      tester.view.physicalSize = const Size(1280, 600);
      await tester.pumpAndSettle();
      expect(cameraOf(tester).center, moved);
      expect(cameraOf(tester).zoom, 17);
    });

    testWidgets('a dot on the far side of the world is no trouble', (
      tester,
    ) async {
      log.addHistory([
        clipWith(['Rex'], minutesAgo: 1, lat: 0),
        // Nearly antipodal: Vincenty's formula doesn't converge there.
        clipWith(['Ana'], minutesAgo: 2, lat: 0, lng: -177.6),
      ]);
      await show(tester);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(cameraOf(tester).center.longitude, closeTo(2.29, 1e-6));
      expect(cameraOf(tester).zoom, 17);
    });

    testWidgets('without located events, the whole world, zoomed out', (
      tester,
    ) async {
      log.addHistory([
        clipWith(['Rex'], minutesAgo: 1),
      ]);
      await show(tester);
      await tester.pumpAndSettle();
      final out = tester.widget<IconButton>(
        find.byKey(const Key('sightings-zoom-out')),
      );
      expect(out.onPressed, isNull, reason: 'already as far out as it goes');
    });

    testWidgets("the map shows every device until an event's device is "
        'tapped (searched for), with the events', (tester) async {
      log.addHistory([
        // Close together: both in view at street level.
        clipWith(['Rex'], minutesAgo: 1, lat: 48.1)..deviceId = 'here',
        clipWith(['Ana'], minutesAgo: 2, lat: 48.1005)..deviceId = 'there',
      ]);
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
              deviceId: 'here',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final here = find.byKey(const Key('event-device-event-1'));
      final search = find.byKey(const Key('event-search'));
      final rex = find.byKey(const Key('subjects-dot-rex-event-1'));
      final ana = find.byKey(const Key('subjects-dot-ana-event-2'));
      final events = find.byKey(const Key('events-page'));
      Finder card(String name) =>
          find.descendant(of: events, matching: find.text(name));

      expect(search, findsNothing);
      expect(rex, findsOneWidget);
      expect(ana, findsOneWidget);
      expect(card('Ana'), findsOneWidget);

      await tester.tap(here);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(search).controller!.text, 'here');
      expect(rex, findsOneWidget);
      expect(ana, findsNothing);
      expect(find.byKey(const Key('subjects-label-ana')), findsNothing);
      expect(card('Rex'), findsOneWidget);
      expect(card('Ana'), findsNothing);

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(search, findsNothing);
      expect(ana, findsOneWidget);
      expect(card('Ana'), findsOneWidget);
    });

    testWidgets('on top, a map of every subject, each in its color, and a '
        'matching square on each row', (tester) async {
      log.addHistory([
        // Close together: all in view at street level.
        clipWith(['Rex'], minutesAgo: 1, lat: 48.1),
        clipWith(['Rex', 'Ana'], minutesAgo: 2, lat: 48.1005),
        clipWith(['Ana'], minutesAgo: 3, lat: 48.101),
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
          ('subjects-label-ana', 48.1005),
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

    testWidgets('the setting is last on the Settings screen', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsView(config: config, logTabDefault: false),
          ),
        ),
      );
      final slider = find.byKey(const Key('subject-events-slider'));
      await tester.scrollUntilVisible(slider, 100);
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      expect(find.text('How many events to load at once'), findsOneWidget);
      expect(find.text('100'), findsOneWidget);
      // Below every other setting, the Advanced section's too.
      expect(
        tester.getTopLeft(slider).dy,
        greaterThan(
          tester.getTopLeft(find.byKey(const Key('show-log-switch'))).dy,
        ),
      );
      await tester.drag(
        find.descendant(of: slider, matching: find.byType(Slider)),
        const Offset(500, 0),
      );
      expect(config.subjects.mapEvents, 500);
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

    // Opened once: a search that hides it, then Settings and back, keeps
    // the search and the toggle, and doesn't open the event again.
    await tester.tap(find.byKey(const Key('event-search-open')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('event-search')), 'nobody');
    // Submitted: the keyboard goes, so nothing keeps the tab alive.
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    bool systemShown() => tester
        .widget<IconButton>(find.byKey(const Key('show-system-events')))
        .isSelected!;
    final system = systemShown();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Monitoring'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('event-search')))
          .controller!
          .text,
      'nobody',
    );
    expect(find.text('No events match "nobody"'), findsOneWidget);
    expect(systemShown(), system);
    expect(highlight, findsNothing);
  });
}

class _NoLocation implements Locator {
  @override
  Future<({double latitude, double longitude, double? accuracy})> locate() =>
      Future.error(const LocationUnavailable('Location is off'));
}
