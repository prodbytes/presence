import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';

import 'package:battery_plus/battery_plus.dart';
import 'package:presence_app/battery.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/location/device_location.dart';
import 'package:presence_app/location/device_view.dart';
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

  group('Device tab', () {
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
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        PresenceApp(
          consentGiven: true,
          key: UniqueKey(),
          cameras: noCameras,
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

    testWidgets('shows the device on the map, sits between Events and '
        'Settings', (tester) async {
      await launch(tester, FakeLocator());

      final events = tester.getCenter(find.byTooltip('Events'));
      final device = tester.getCenter(find.byTooltip('Device'));
      final settings = tester.getCenter(find.byTooltip('Settings'));
      expect(events.dx, lessThan(device.dx));
      expect(device.dx, lessThan(settings.dx));

      await tester.tap(find.byTooltip('Device'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('device-pin')), findsOneWidget);
      expect(find.text('48.858400, 2.294500'), findsOneWidget);
      expect(find.text("This device's location · ±5 m"), findsOneWidget);
      expect(find.byKey(const Key('device-page-id')), findsOneWidget);
      expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final size in [const Size(320, 640), const Size(1280, 800)]) {
      testWidgets('the info panel sits in the top-left corner at '
          '${size.width.toInt()} wide', (tester) async {
        await launch(tester, FakeLocator(), size: size);
        await tester.tap(find.byTooltip('Device'));
        await tester.pumpAndSettle();
        final card = tester.getRect(find.byKey(const Key('device-card')));
        final map = tester.getRect(find.byType(FlutterMap));
        expect(card.left, map.left + 12);
        expect(card.top, map.top + 12);
        expect(card.right, lessThanOrEqualTo(size.width - 12));
        // As wide as its content, not the screen.
        expect(card.width, lessThanOrEqualTo(560));
        if (size.width > 600) expect(card.width, lessThan(400));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('labels say what each value is; buttons zoom in and out', (
      tester,
    ) async {
      await launch(tester, FakeLocator());
      await tester.tap(find.byTooltip('Device'));
      await tester.pumpAndSettle();
      expect(find.text('Device ID'), findsOneWidget);
      expect(find.text('Position (latitude, longitude)'), findsOneWidget);

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
      expect(zoom(), DeviceView.maxZoom);
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

      await tester.tap(find.byTooltip('Device'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('device-page')),
        const Offset(-150, 100),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('Set on the map'), findsOneWidget);
      // Dragging the map doesn't flip to another tab.
      expect(find.byKey(const Key('device-pin')), findsOneWidget);

      publish(tester, 'After');
      await settleStorage(tester);
      final stored = {
        for (final e in await storedEvents(tester)) e['title']: e['location'],
      };
      final before = DeviceLocation.fromJson(stored['Before'])!;
      final after = DeviceLocation.fromJson(stored['After'])!;
      expect(before.source, LocationSource.device);
      expect(before.latitude, 48.8584);
      expect(after.source, LocationSource.map);
      // Dragged left and down: the center moved east and north.
      expect(after.latitude, greaterThan(before.latitude));
      expect(after.longitude, greaterThan(before.longitude));

      // A restart keeps the location set by hand, without asking the
      // device.
      await tester.pumpWidget(const SizedBox());
      await settleStorage(tester);
      final again = FakeLocator();
      await launch(tester, again);
      expect(again.calls, 0);
      await tester.tap(find.byTooltip('Device'));
      await tester.pumpAndSettle();
      expect(find.text('Set on the map'), findsOneWidget);

      // My location asks the device again.
      await tester.tap(find.byTooltip('My location'));
      await tester.pumpAndSettle();
      expect(again.calls, 1);
      expect(find.text('48.858400, 2.294500'), findsOneWidget);
    });

    testWidgets('shows the battery charge, and follows it', (tester) async {
      final battery = FakeBattery((level: 82, state: BatteryState.charging));
      await launch(tester, FakeLocator(), battery: battery);
      await tester.tap(find.byTooltip('Device'));
      await tester.pumpAndSettle();
      expect(find.text('Battery'), findsOneWidget);
      expect(find.text('82 % · Charging'), findsOneWidget);
      expect(find.byIcon(Icons.battery_charging_full), findsOneWidget);

      // Unplugged: an event reads it again.
      battery.reading = (level: 81, state: BatteryState.discharging);
      battery.changed.add(null);
      await tester.pump();
      await tester.pump();
      expect(find.text('81 % · On battery'), findsOneWidget);
      expect(find.byIcon(Icons.battery_6_bar), findsOneWidget);

      // The level drops without an event: read again every minute.
      battery.reading = (level: 9, state: BatteryState.discharging);
      await tester.pump(const Duration(minutes: 1));
      expect(find.text('9 % · On battery'), findsOneWidget);
      final icon = tester.widget<Icon>(find.byIcon(Icons.battery_alert));
      expect(
        icon.color,
        Theme.of(tester.element(find.byWidget(icon))).colorScheme.error,
      );

      battery.reading = (level: 100, state: BatteryState.full);
      battery.changed.add(null);
      await tester.pump();
      await tester.pump();
      expect(find.text('100 % · Full'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('says when there is no battery reading', (tester) async {
      await launch(tester, FakeLocator(), battery: FakeBattery(null));
      await tester.tap(find.byTooltip('Device'));
      await tester.pumpAndSettle();
      expect(find.text('Not available'), findsOneWidget);
      expect(find.byIcon(Icons.battery_unknown), findsOneWidget);
    });

    testWidgets('without permission, the map asks to be moved', (tester) async {
      await launch(
        tester,
        FakeLocator(
          failure: const LocationUnavailable('Location permission was denied'),
        ),
      );
      await tester.tap(find.byTooltip('Device'));
      await tester.pumpAndSettle();
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
