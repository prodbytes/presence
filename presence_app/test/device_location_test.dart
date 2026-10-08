import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';

import 'package:battery_plus/battery_plus.dart';
import 'package:presence_app/battery.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/location/device_location.dart';
import 'package:presence_app/location/location_settings.dart';
import 'package:presence_app/main.dart';
import 'package:presence_app/storage/event_store.dart';

import 'fakes.dart';

/// Answers with [position], or throws [failure]. [gate], when set, holds
/// the answer until it completes.
class FakeLocator implements Locator {
  FakeLocator({this.position = paris, this.failure});

  static const paris = (latitude: 48.8584, longitude: 2.2945, accuracy: 5.0);

  ({double latitude, double longitude, double? accuracy}) position;
  Exception? failure;
  Completer<void>? gate;
  int calls = 0;

  @override
  Future<({double latitude, double longitude, double? accuracy})>
  locate() async {
    calls++;
    await gate?.future;
    if (failure case final failure?) throw failure;
    return position;
  }
}

/// Answers with [reading]; [changed] stands for charging starting or
/// stopping.
class FakeBattery implements BatteryReader {
  FakeBattery(this.reading);

  BatteryReading? reading;
  final changed = StreamController<void>.broadcast();

  @override
  Future<BatteryReading?> read() async => reading;

  @override
  Stream<void> get changes => changed.stream;
}

void main() {
  group('LocationController', () {
    Map<String, Object?>? saved;
    setUp(() => saved = null);

    LocationController controller(FakeLocator locator) => LocationController(
      locator: locator,
      load: () async => saved,
      save: (json) async => saved = json,
      now: () => DateTime(2026, 10, 1, 12),
    );

    test('reads the device position at launch and saves it', () async {
      final locator = FakeLocator();
      final location = controller(locator);
      await location.init();

      expect(location.location?.latitude, 48.8584);
      expect(location.location?.accuracy, 5.0);
      expect(location.location?.source, LocationSource.device);
      expect(DeviceLocation.fromJson(saved), location.location);
    });

    test('a location set on the map survives a restart', () async {
      final first = controller(FakeLocator());
      await first.init();
      first.setOnMap(40.7, -74.0);

      final locator = FakeLocator();
      final second = controller(locator);
      await second.init();
      expect(locator.calls, 0, reason: "the map's location wins");
      expect(second.location?.latitude, 40.7);
      expect(second.location?.source, LocationSource.map);

      // Until the device is asked again.
      await second.locate();
      expect(second.location?.source, LocationSource.device);
      expect(second.location?.latitude, 48.8584);
    });

    test('a saved device position is read again at launch', () async {
      saved = DeviceLocation(
        latitude: 1,
        longitude: 1,
        source: LocationSource.device,
        time: DateTime(2026),
      ).toJson();
      final locator = FakeLocator();
      final location = controller(locator);
      await location.init();
      expect(locator.calls, 1);
      expect(location.location?.latitude, 48.8584);
    });

    test('moving the map while the device answers keeps the map', () async {
      final locator = FakeLocator()..gate = Completer();
      final location = controller(locator);
      final reading = location.init();
      await Future<void>.delayed(Duration.zero);
      location.setOnMap(10, 20);
      locator.gate!.complete();
      await reading;
      expect(location.location?.source, LocationSource.map);
      expect(location.location?.longitude, 20);
    });

    test('a denied permission leaves the location unknown', () async {
      final location = controller(
        FakeLocator(failure: const LocationUnavailable('Permission denied')),
      );
      await location.init();
      expect(location.location, isNull);
      expect(location.error, 'Permission denied');
    });

    test('a pinned position survives a restart, and the device is never '
        'asked', () async {
      final first = controller(FakeLocator());
      await first.init();
      first.pin();
      expect(first.pinned, isTrue);
      expect(first.location?.latitude, 48.8584);
      expect(saved?['pinned'], isTrue);
      expect(saved?['source'], 'map');

      final locator = FakeLocator(
        position: (latitude: 1, longitude: 1, accuracy: 3.0),
      );
      final second = controller(locator);
      await second.init();
      expect(second.pinned, isTrue);
      expect(second.location?.latitude, 48.8584);
      // Neither My location nor a map move changes it.
      await second.locate();
      second.setOnMap(10, 10);
      expect(locator.calls, 0);
      expect(second.location?.latitude, 48.8584);

      // Pinning elsewhere moves the pin.
      second.pin(38.72, -9.14);
      expect(second.location?.latitude, 38.72);
      expect(second.pinned, isTrue);

      // Unpinned: the device is asked again.
      await second.unpin();
      expect(locator.calls, 1);
      expect(second.pinned, isFalse);
      expect(second.location?.source, LocationSource.device);
      expect(second.location?.latitude, 1);
      expect(saved?.containsKey('pinned'), isFalse);
    });

    test('a reading under way when pinning is dropped', () async {
      final locator = FakeLocator()..gate = Completer();
      final location = controller(locator);
      final reading = location.init();
      await Future<void>.delayed(Duration.zero);
      location.pin(10, 20);
      locator.gate!.complete();
      await reading;
      expect(location.pinned, isTrue);
      expect(location.location?.longitude, 20);
    });

    test('positions off the Earth are not pinned', () async {
      final location = controller(FakeLocator());
      expect(location.pin, throwsStateError, reason: 'nothing to pin yet');
      for (final (lat, lng) in [
        (91.0, 0.0),
        (-90.5, 0.0),
        (0.0, 180.1),
        (0.0, -181.0),
        (double.nan, 0.0),
      ]) {
        expect(() => location.pin(lat, lng), throwsArgumentError);
      }
      expect(location.location, isNull);
      expect(saved, isNull);
      // The edges are fine.
      location.pin(-90, 180);
      expect(location.pinned, isTrue);
    });

    test('damaged records read as no location', () {
      expect(
        DeviceLocation.fromJson({
          'lat': 95,
          'lng': 2,
          'source': 'map',
          'time': 0,
        }),
        isNull,
      );
      // Only a position set by hand is pinned.
      expect(
        DeviceLocation.fromJson({
          'lat': 1,
          'lng': 2,
          'source': 'device',
          'pinned': true,
          'time': 0,
        })?.pinned,
        isFalse,
      );
      expect(DeviceLocation.fromJson(null), isNull);
      expect(DeviceLocation.fromJson({'lat': 'x'}), isNull);
      expect(
        DeviceLocation.fromJson({
          'lat': 1,
          'lng': 2,
          'source': 'satellite',
          'time': 0,
        }),
        isNull,
      );
    });
  });

  group('The Settings map', () {
    Map<String, Object?>? saved;
    setUp(() => saved = null);

    /// Shows the map alone, before the location is known: [init] is left
    /// to the test.
    Future<LocationController> show(
      WidgetTester tester,
      FakeLocator locator,
    ) async {
      final location = LocationController(
        locator: locator,
        load: () async => saved,
        save: (json) async => saved = json,
      );
      addTearDown(location.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LocationSettings(location: location, tiles: const SizedBox()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return location;
    }

    MapCamera camera(WidgetTester tester) => tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!
        .camera;

    testWidgets('opens on the world, then moves to the detected place', (
      tester,
    ) async {
      final location = await show(tester, FakeLocator());
      expect(camera(tester).zoom, LocationSettings.minZoom);

      await tester.runAsync(location.init);
      await tester.pumpAndSettle();
      expect(camera(tester).center.latitude, closeTo(48.8584, 1e-6));
      expect(camera(tester).center.longitude, closeTo(2.2945, 1e-6));
      expect(camera(tester).zoom, LocationSettings.deviceZoom);
    });

    testWidgets('moves to a saved location once it loads', (tester) async {
      saved = DeviceLocation(
        latitude: 40.7,
        longitude: -74,
        source: LocationSource.map,
        time: DateTime(2026),
      ).toJson();
      final location = await show(tester, FakeLocator());
      await tester.runAsync(location.init);
      await tester.pumpAndSettle();
      expect(camera(tester).center.latitude, closeTo(40.7, 1e-6));
      expect(camera(tester).center.longitude, closeTo(-74, 1e-6));
    });

    testWidgets('a reading after the user moved the map leaves it there', (
      tester,
    ) async {
      final locator = FakeLocator()..gate = Completer();
      final location = await show(tester, locator);
      final reading = location.init();
      await tester.pump();

      await tester.drag(
        find.byKey(const Key('location-map')),
        const Offset(-150, 100),
      );
      await tester.pump();
      final moved = camera(tester).center;
      // The device answers before the move is committed.
      locator.gate!.complete();
      await tester.runAsync(() => reading);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(camera(tester).center, moved);
      expect(location.location?.source, LocationSource.map);
      expect(location.location?.latitude, closeTo(moved.latitude, 1e-6));

      // My location follows the device again.
      await tester.tap(find.byTooltip('My location'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(camera(tester).center.latitude, closeTo(48.8584, 1e-6));
    });

    testWidgets('a pasted position sets the location and moves the map', (
      tester,
    ) async {
      final location = await show(tester, FakeLocator());
      await tester.runAsync(location.init);
      await tester.pumpAndSettle();
      // Moved by hand first: a pasted position still moves the map.
      await tester.drag(
        find.byKey(const Key('location-map')),
        const Offset(-150, 100),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      final field = find.byKey(const Key('location-paste'));
      await tester.enterText(field, 'somewhere nice');
      await tester.tap(find.byKey(const Key('location-paste-set')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Not a position'), findsOneWidget);
      final before = location.location;

      await tester.enterText(field, '95, 10');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('Latitude must be between -90 and 90'), findsOneWidget);
      expect(location.location, before);

      await tester.enterText(field, '38°43\'20.3"N 9°08\'21.5"W');
      await tester.tap(find.byKey(const Key('location-paste-set')));
      await tester.pumpAndSettle();
      expect(find.textContaining('must be between'), findsNothing);
      expect(location.location?.source, LocationSource.map);
      expect(location.location?.latitude, closeTo(38.722306, 1e-6));
      expect(location.location?.longitude, closeTo(-9.139306, 1e-6));
      expect(camera(tester).center.latitude, closeTo(38.722306, 1e-6));
      expect(camera(tester).center.longitude, closeTo(-9.139306, 1e-6));
      expect(find.text('Set on the map'), findsOneWidget);
      // Taken: the box is empty again, and the position saved.
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(saved?['lat'], closeTo(38.722306, 1e-6));
    });
  });

  group('Pinning in Settings', () {
    Map<String, Object?>? saved;
    setUp(() => saved = null);

    Future<(LocationController, FakeLocator)> show(
      WidgetTester tester, {
      double width = 320,
    }) async {
      tester.view.physicalSize = Size(width, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final locator = FakeLocator();
      final location = LocationController(
        locator: locator,
        load: () async => saved,
        save: (json) async => saved = json,
      );
      addTearDown(location.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: LocationSettings(
                location: location,
                tiles: const SizedBox(),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(location.init);
      await tester.pumpAndSettle();
      return (location, locator);
    }

    MapCamera camera(WidgetTester tester) => tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!
        .camera;

    testWidgets('pins the detected position, shows it, and unpins', (
      tester,
    ) async {
      final (location, locator) = await show(tester);
      expect(find.byKey(const Key('pinned-marker')), findsNothing);
      await tester.tap(find.byKey(const Key('location-pin')));
      await tester.pumpAndSettle();
      expect(location.pinned, isTrue);
      expect(location.location?.latitude, 48.8584);
      expect(saved?['pinned'], isTrue);
      // Shown as pinned: icon, label, status, a marker instead of the
      // center pin, and Unpin.
      expect(find.byKey(const Key('pinned-icon')), findsOneWidget);
      expect(find.textContaining('Pinned:'), findsOneWidget);
      expect(find.text('48.858400, 2.294500'), findsOneWidget);
      expect(find.text('Pinned · used for every event'), findsOneWidget);
      expect(find.byKey(const Key('pinned-marker')), findsOneWidget);
      expect(find.byKey(const Key('device-pin')), findsNothing);
      expect(find.byKey(const Key('location-unpin')), findsOneWidget);
      expect(find.byKey(const Key('location-pin')), findsNothing);
      // My location is off while pinned.
      expect(find.byTooltip('Unpin to use my location'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Moving the map only looks around.
      await tester.drag(
        find.byKey(const Key('location-map')),
        const Offset(-100, 80),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(camera(tester).center.latitude, isNot(closeTo(48.8584, 1e-6)));
      expect(location.location?.latitude, 48.8584);
      expect(location.pinned, isTrue);

      // Unpin: back to the device's position, and the map follows it.
      final calls = locator.calls;
      locator.position = (latitude: 40.7, longitude: -74.0, accuracy: 8.0);
      await tester.tap(find.byKey(const Key('location-unpin')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(locator.calls, calls + 1);
      expect(location.pinned, isFalse);
      expect(find.text("This device's location · ±8 m"), findsOneWidget);
      expect(find.byKey(const Key('device-pin')), findsOneWidget);
      expect(camera(tester).center.latitude, closeTo(40.7, 1e-6));
      expect(saved?.containsKey('pinned'), isFalse);
    });

    testWidgets('pins a pasted position, and a paste moves the pin', (
      tester,
    ) async {
      final (location, _) = await show(tester);
      final field = find.byKey(const Key('location-paste'));
      await tester.enterText(field, '38.7223, -9.1393');
      await tester.tap(find.byKey(const Key('location-paste-set')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('location-pin')));
      await tester.pumpAndSettle();
      expect(location.pinned, isTrue);
      expect(location.location?.latitude, 38.7223);

      // Pinned, an out-of-range position is refused and the pin stays.
      await tester.enterText(field, '10, 190');
      await tester.tap(find.byKey(const Key('location-paste-set')));
      await tester.pumpAndSettle();
      expect(
        find.text('Longitude must be between -180 and 180'),
        findsOneWidget,
      );
      expect(location.location?.longitude, -9.1393);

      // A good one moves the pin.
      await tester.enterText(field, '51.5, -0.12');
      await tester.tap(find.byKey(const Key('location-paste-set')));
      await tester.pumpAndSettle();
      expect(location.pinned, isTrue);
      expect(location.location?.latitude, 51.5);
      expect(camera(tester).center.latitude, closeTo(51.5, 1e-6));
      expect(saved?['lat'], 51.5);
    });

    testWidgets('pins where the map was just moved to', (tester) async {
      final (location, _) = await show(tester);
      await tester.drag(
        find.byKey(const Key('location-map')),
        const Offset(-100, 80),
      );
      await tester.pump();
      final center = camera(tester).center;
      // Before the move is committed.
      await tester.tap(find.byKey(const Key('location-pin')));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(location.pinned, isTrue);
      expect(location.location?.latitude, closeTo(center.latitude, 1e-6));
    });
  });

  group('Location and battery', () {
    late IdbFactory storage;
    setUp(() => storage = newIdbFactoryMemory());

    Future<T> run<T>(WidgetTester tester, Future<T> future) async {
      var done = false;
      late T result;
      Object? error;
      future.then(
        (v) {
          result = v;
          done = true;
        },
        onError: (Object e) {
          error = e;
          done = true;
        },
      );
      for (var i = 0; i < 50 && !done; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      if (error != null) throw error!;
      expect(done, isTrue, reason: 'storage call timed out');
      return result;
    }

    Future<void> launch(
      WidgetTester tester,
      FakeLocator locator, {
      BatteryReader? battery,
      Size size = const Size(400, 800),
      List<FakeCameraSource> cameras = const [],
      FakeRolesClient? rolesClient,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        PresenceApp(
          consentGiven: true,
          key: UniqueKey(),
          cameras: cameras.isEmpty ? noCameras : openFakes(cameras),
          storage: storage,
          auth: FakeAuthService.signedIn(),
          rolesClient: rolesClient ?? FakeRolesClient(),
          locator: locator,
          battery: battery ?? FakeBattery(null),
          // No network in tests.
          mapTiles: const SizedBox(),
        ),
      );
      await tester.pumpAndSettle();
      await settleStorage(tester);
      await tester.pumpAndSettle();
    }

    Future<List<Map<String, Object?>>> storedEvents(WidgetTester tester) async {
      final store = await run(tester, EventStore.open(storage));
      final events = await run(tester, store.allEvents());
      store.close();
      return events;
    }

    void publish(WidgetTester tester, String title) =>
        AppEventBusScope.of(tester.element(find.byType(Scaffold).first))
            .publish(AppEvent(icon: Icons.circle, title: title));

    /// Opens Settings and scrolls the whole location map into view.
    Future<void> openLocation(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await scrollSettingsTo(tester, find.byKey(const Key('location-map')));
    }

    testWidgets('the location is a section of Settings; no Device tab', (
      tester,
    ) async {
      await launch(tester, FakeLocator());
      expect(find.byTooltip('Device'), findsNothing);

      // The first section, above Camera.
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Location')).dy,
        lessThan(tester.getTopLeft(find.text('Camera')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Location')).dy,
        lessThan(tester.getTopLeft(find.byKey(const Key('location-map'))).dy),
      );

      await openLocation(tester);
      expect(find.byKey(const Key('device-pin')), findsOneWidget);
      expect(find.text('Position (latitude, longitude)'), findsOneWidget);
      expect(find.text('48.858400, 2.294500'), findsOneWidget);
      expect(find.text("This device's location · ±5 m"), findsOneWidget);
      expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
      // The device ID is already at the bottom of Settings, once.
      expect(find.text('Device ID'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    for (final size in [const Size(360, 740), const Size(1280, 800)]) {
      testWidgets('the position sits right of the map, and a drag there '
          'scrolls the list, at ${size.width.toInt()} wide', (tester) async {
        await launch(tester, FakeLocator(), size: size);
        await openLocation(tester);
        // Full width: the map on the left, the position on the right.
        final section = tester.getRect(
          find.byKey(const Key('location-settings')),
        );
        expect(section.left, 16);
        expect(section.right, size.width - 16);
        final map = tester.getRect(find.byKey(const Key('location-map')));
        final side = tester.getRect(find.byKey(const Key('location-position')));
        expect(map.left, 16);
        expect(side.left, map.right + 16);
        expect(side.right, size.width - 16);
        expect(
          tester.getRect(find.byKey(const Key('device-coordinates'))).left,
          greaterThanOrEqualTo(side.left),
        );
        expect(tester.takeException(), isNull);

        // A drag up beside the map scrolls Settings: the map moves too.
        await tester.dragFrom(
          Offset(side.center.dx, map.center.dy),
          const Offset(0, -150),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.byKey(const Key('location-map'))).top,
          lessThan(map.top),
        );
      });
    }

    testWidgets('the zoom buttons zoom in and out', (tester) async {
      await launch(tester, FakeLocator());
      await openLocation(tester);

      double zoom() => tester
          .widget<FlutterMap>(find.byType(FlutterMap))
          .mapController!
          .camera
          .zoom;
      final start = zoom();
      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pumpAndSettle();
      expect(zoom(), start + 1);
      await tester.tap(find.byTooltip('Zoom out'));
      await tester.tap(find.byTooltip('Zoom out'));
      await tester.pumpAndSettle();
      expect(zoom(), start - 1);
      // Zooming keeps the center, so the device's own location stays.
      await tester.pump(const Duration(seconds: 1));
      expect(find.text("This device's location · ±5 m"), findsOneWidget);
      expect(find.text('48.858400, 2.294500'), findsOneWidget);

      // At the closest zoom, Zoom in turns off.
      for (var i = 0; i < 25; i++) {
        await tester.tap(find.byTooltip('Zoom in'));
      }
      await tester.pumpAndSettle();
      expect(zoom(), LocationSettings.maxZoom);
      expect(
        tester.widget<IconButton>(find.byKey(const Key('zoom-in'))).onPressed,
        isNull,
      );
    });

    testWidgets('moving the map sets the location, on every event after', (
      tester,
    ) async {
      final locator = FakeLocator();
      await launch(tester, locator);
      publish(tester, 'Before');
      await settleStorage(tester);

      await openLocation(tester);
      final map = find.byKey(const Key('location-map'));
      final before = tester.getRect(map);
      await tester.drag(map, const Offset(-150, 100));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Set on the map'), findsOneWidget);
      // The drag moved the map: neither the list nor the tabs moved.
      expect(tester.getRect(map), before);
      expect(find.byKey(const Key('settings-page')), findsOneWidget);
      expect(find.byKey(const Key('camera-page')), findsNothing);

      publish(tester, 'After');
      await settleStorage(tester);
      final stored = {
        for (final e in await storedEvents(tester)) e['title']: e['location'],
      };
      final first = DeviceLocation.fromJson(stored['Before'])!;
      final after = DeviceLocation.fromJson(stored['After'])!;
      expect(first.source, LocationSource.device);
      expect(first.latitude, 48.8584);
      expect(after.source, LocationSource.map);
      // Dragged left and down: the center moved east and north.
      expect(after.latitude, greaterThan(first.latitude));
      expect(after.longitude, greaterThan(first.longitude));

      // A restart keeps the location set by hand, without asking the
      // device.
      await tester.pumpWidget(const SizedBox());
      await settleStorage(tester);
      final again = FakeLocator();
      await launch(tester, again);
      expect(again.calls, 0);
      await openLocation(tester);
      expect(find.text('Set on the map'), findsOneWidget);

      // My location asks the device again.
      await tester.tap(find.byTooltip('My location'));
      await tester.pumpAndSettle();
      expect(again.calls, 1);
      expect(find.text('48.858400, 2.294500'), findsOneWidget);
    });

    testWidgets('while pinned, every event carries the pinned position, '
        'also after a restart, without asking the device', (tester) async {
      await launch(tester, FakeLocator(), size: const Size(320, 640));
      await openLocation(tester);
      await scrollSettingsTo(tester, find.byKey(const Key('location-pin')));
      await tester.tap(find.byKey(const Key('location-pin')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      publish(tester, 'Pinned');
      await settleStorage(tester);

      await tester.pumpWidget(const SizedBox());
      await settleStorage(tester);
      final again = FakeLocator(
        position: (latitude: 1, longitude: 1, accuracy: 3.0),
      );
      await launch(tester, again);
      expect(again.calls, 0, reason: 'no position asked while pinned');
      publish(tester, 'Pinned after restart');
      await settleStorage(tester);
      final stored = {
        for (final e in await storedEvents(tester)) e['title']: e['location'],
      };
      for (final title in ['Pinned', 'Pinned after restart']) {
        final at = DeviceLocation.fromJson(stored[title])!;
        expect(at.pinned, isTrue, reason: title);
        expect(at.source, LocationSource.map);
        expect(at.latitude, 48.8584);
        expect((stored[title]! as Map)['pinned'], isTrue);
      }
      await openLocation(tester);
      expect(find.text('Pinned · used for every event'), findsOneWidget);
    });

    testWidgets('the battery shows over the camera, and follows it', (
      tester,
    ) async {
      final battery = FakeBattery((
        level: 82,
        state: BatteryState.charging,
        celsius: null,
      ));
      await launch(tester, FakeLocator(), battery: battery);
      final pill = find.byKey(const Key('battery'));
      expect(find.descendant(of: pill, matching: find.text('82 %')), findsOne);
      expect(find.byIcon(Icons.battery_charging_full), findsOneWidget);
      expect(find.byTooltip('Battery 82 %, charging'), findsOneWidget);

      // Unplugged: an event reads it again.
      battery.reading = (
        level: 81,
        state: BatteryState.discharging,
        celsius: null,
      );
      battery.changed.add(null);
      await tester.pump();
      await tester.pump();
      expect(find.text('81 %'), findsOneWidget);
      expect(find.byIcon(Icons.battery_6_bar), findsOneWidget);

      // The level drops without an event: read again every minute.
      battery.reading = (
        level: 9,
        state: BatteryState.discharging,
        celsius: null,
      );
      await tester.pump(const Duration(minutes: 1));
      expect(find.text('9 %'), findsOneWidget);
      final icon = tester.widget<Icon>(find.byIcon(Icons.battery_alert));
      expect(
        icon.color,
        Theme.of(tester.element(find.byWidget(icon))).colorScheme.error,
      );

      battery.reading = (level: 100, state: BatteryState.full, celsius: null);
      battery.changed.add(null);
      await tester.pump();
      await tester.pump();
      expect(find.byTooltip('Battery 100 %, full'), findsOneWidget);

      // Only over the camera.
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(pill, findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets("the battery's temperature shows where it's reported", (
      tester,
    ) async {
      final battery = FakeBattery((
        level: 60,
        state: BatteryState.discharging,
        celsius: 31.46,
      ));
      await launch(tester, FakeLocator(), battery: battery);
      expect(find.text('31.5 °C'), findsOneWidget);
      final scheme = Theme.of(tester.element(find.text('31.5 °C'))).colorScheme;
      Color? colorOf(String text) =>
          tester.widget<Text>(find.text(text)).style?.color;
      expect(colorOf('31.5 °C'), scheme.onSurface);

      // Hot: in the error color.
      battery.reading = (level: 60, state: BatteryState.charging, celsius: 46);
      battery.changed.add(null);
      await tester.pump();
      await tester.pump();
      expect(colorOf('46.0 °C'), scheme.error);

      // Not reported (iOS, web): no pill.
      battery.reading = (
        level: 60,
        state: BatteryState.charging,
        celsius: null,
      );
      battery.changed.add(null);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('battery-temperature')), findsNothing);
      expect(find.text('60 %'), findsOneWidget);
    });

    testWidgets('without a battery reading, no battery pill', (tester) async {
      await launch(tester, FakeLocator(), battery: FakeBattery(null));
      expect(find.byKey(const Key('battery')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    for (final size in [const Size(320, 640), const Size(1280, 800)]) {
      testWidgets('the battery sits bottom left, clear of Flip and '
          'Clip, at ${size.width.toInt()} wide', (tester) async {
        await launch(
          tester,
          FakeLocator(),
          size: size,
          cameras: [FakeCameraSource('Back'), FakeCameraSource('Front')],
          battery: FakeBattery((
            level: 100,
            state: BatteryState.connectedNotCharging,
            celsius: 31.5,
          )),
        );
        final status = tester.getRect(find.byKey(const Key('camera-status')));
        final clip = tester.getRect(find.byKey(const Key('clip')));
        final flip = tester.getRect(find.byTooltip('Flip camera'));
        expect(status.left, 16);
        expect(status.overlaps(clip), isFalse);
        expect(status.overlaps(flip), isFalse);
        if (size.width < 600) {
          // Stacked just above the buttons' row.
          expect(status.bottom, lessThanOrEqualTo(clip.top));
        } else {
          // In a row, level with the buttons.
          expect(status.center.dy, closeTo(clip.center.dy, 1));
          expect(status.right, lessThan(flip.left));
        }
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('a failed health check: a warning icon pill, which opens '
        'the details', (tester) async {
      final client = FakeRolesClient()
        ..anonymousError = Exception('unreachable');
      await launch(tester, FakeLocator(), rolesClient: client);
      final pill = find.byKey(const Key('health-warning'));
      expect(pill, findsOneWidget);
      // Only the icon: no label.
      expect(
        find.descendant(of: pill, matching: find.byType(Text)),
        findsNothing,
      );
      expect(
        find.descendant(
          of: pill,
          matching: find.byIcon(Icons.warning_amber_rounded),
        ),
        findsOneWidget,
      );
      final tooltip = tester
          .widget<Tooltip>(
            find.descendant(of: pill, matching: find.byType(Tooltip)),
          )
          .message!;
      expect(tooltip, contains('Auth API: unreachable'));

      // For an admin, tapping it opens the Log tab's health panel.
      await tester.tap(pill);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('health-panel')), findsOneWidget);
      expect(pill, findsNothing, reason: 'over the camera only');

      // Answering again: no warning.
      client.anonymousError = null;
      await tester.tap(find.byTooltip('Camera'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(minutes: 5));
      await tester.pumpAndSettle();
      expect(pill, findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('every health check passing: no warning pill', (tester) async {
      await launch(tester, FakeLocator());
      expect(find.byKey(const Key('health-warning')), findsNothing);
    });

    testWidgets('without permission, the map asks to be moved', (tester) async {
      await launch(
        tester,
        FakeLocator(
          failure: const LocationUnavailable('Location permission was denied'),
        ),
      );
      await openLocation(tester);
      expect(
        find.text('Location permission was denied. Move the map to set it.'),
        findsOneWidget,
      );
      publish(tester, 'Nowhere');
      await settleStorage(tester);
      final stored = await storedEvents(tester);
      expect(
        stored.firstWhere((e) => e['title'] == 'Nowhere')['location'],
        isNull,
      );
    });
  });
}
