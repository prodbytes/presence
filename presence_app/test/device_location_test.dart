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

    test('damaged records read as no location', () {
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
          rolesClient: FakeRolesClient(),
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

    testWidgets('Settings is full width', (tester) async {
      await launch(tester, FakeLocator(), size: const Size(1280, 800));
      await openLocation(tester);
      final map = tester.getRect(find.byKey(const Key('location-map')));
      expect(map.left, 16);
      expect(map.right, 1280 - 16);
    });

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
      testWidgets('battery and readiness sit bottom left, clear of Flip and '
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
        final readiness = tester.getRect(find.byKey(const Key('readiness')));
        final clip = tester.getRect(find.byTooltip('Clip'));
        final flip = tester.getRect(find.byTooltip('Flip camera'));
        expect(status.left, 16);
        expect(status.overlaps(clip), isFalse);
        expect(status.overlaps(flip), isFalse);
        if (size.width < 600) {
          // Stacked just above the buttons' row, the readiness lowest.
          expect(status.bottom, lessThanOrEqualTo(clip.top));
          final battery = tester.getRect(find.byKey(const Key('battery')));
          expect(battery.bottom, lessThan(readiness.top));
        } else {
          // In a row, level with the buttons.
          expect(readiness.bottom, closeTo(clip.bottom, 8));
          expect(status.right, lessThan(flip.left));
        }
        expect(tester.takeException(), isNull);
      });
    }

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
