import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';

import 'package:presence_app/consent/consent_screen.dart';
import 'package:presence_app/home/home_navigation_bar.dart';
import 'package:presence_app/consent/device_consent.dart';
import 'package:presence_app/main.dart';
import 'package:presence_app/storage/event_store.dart';

import 'fakes.dart';

void main() {
  group('DeviceConsent', () {
    final at = DateTime.utc(2026, 10, 1, 12);
    final record = DeviceConsent.record('automatic_paranoid_gadget', at);

    test('a record is valid for its own device and the current text', () {
      expect(record['version'], DeviceConsent.version);
      expect(record['acceptedAt'], at.millisecondsSinceEpoch);
      expect(
        DeviceConsent.isValid(record, 'automatic_paranoid_gadget'),
        isTrue,
      );
    });

    test('another device, another text, an edit or nothing: not valid', () {
      expect(DeviceConsent.isValid(record, 'brave_quiet_teapot'), isFalse);
      expect(DeviceConsent.isValid(null, 'automatic_paranoid_gadget'), isFalse);
      for (final edit in <String, Object?>{
        'version': DeviceConsent.version - 1,
        'acceptedAt': at.millisecondsSinceEpoch + 1,
        'deviceId': 'brave_quiet_teapot',
        'hash': 'f' * 64,
      }.entries) {
        expect(
          DeviceConsent.isValid({
            ...record,
            edit.key: edit.value,
          }, 'automatic_paranoid_gadget'),
          isFalse,
          reason: 'edited ${edit.key}',
        );
      }
    });
  });

  group('the consent screen', () {
    late IdbFactory storage;
    setUp(() => storage = newIdbFactoryMemory());

    Future<FakeCameraBackend> launch(WidgetTester tester) async {
      // Tall enough that the whole screen is built.
      tester.view.physicalSize = const Size(600, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final cameras = openFakes([FakeCameraSource('Front door')]);
      await tester.pumpWidget(
        PresenceApp(
          // A new key forces a fresh app, like a page reload.
          key: UniqueKey(),
          cameras: cameras,
          storage: storage,
          auth: FakeAuthService.signedIn(),
          rolesClient: FakeRolesClient(),
          mapTiles: const SizedBox(),
          locator: NoLocation(),
        ),
      );
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pumpAndSettle();
      return cameras;
    }

    Future<Map<String, Object?>?> stored(WidgetTester tester) async {
      Map<String, Object?>? result;
      var done = false;
      () async {
        final store = await EventStore.open(storage);
        result = await store.getSettings('consent');
        store.close();
        done = true;
      }();
      for (var i = 0; i < 50 && !done; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      return result;
    }

    testWidgets('a new device asks first, and records nothing until agreed', (
      tester,
    ) async {
      final cameras = await launch(tester);
      expect(find.byKey(const Key('consent')), findsOneWidget);
      // The two conditions, highlighted, and one button.
      expect(find.byKey(const Key('consent-right-to-record')), findsOneWidget);
      expect(find.text('I have the right to record here.'), findsOneWidget);
      expect(find.byKey(const Key('consent-biometrics')), findsOneWidget);
      expect(
        find.text('Faces are biometric data, and I am responsible.'),
        findsOneWidget,
      );
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byType(HomeNavigationBar), findsNothing);
      expect(cameras.opened, isEmpty, reason: 'no camera before consent');

      // One click agrees.
      await tester.tap(find.byKey(const Key('consent-agree')));
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('consent')), findsNothing);
      expect(find.byType(HomeNavigationBar), findsOneWidget);
      expect(cameras.opened, hasLength(1));

      // Saved for this device, with a hash that checks out.
      final record = await stored(tester);
      expect(record, isNotNull);
      expect(
        DeviceConsent.isValid(record, record!['deviceId']! as String),
        isTrue,
      );
    });

    testWidgets('on a small phone it scrolls, without overflow, to I agree', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var agreed = false;
      await tester.pumpWidget(
        MaterialApp(home: ConsentScreen(onAgree: () async => agreed = true)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.byKey(const Key('consent-agree')),
        200,
      );
      await tester.tap(find.byKey(const Key('consent-agree')));
      await tester.pump();
      expect(agreed, isTrue);
    });

    testWidgets('once given, it is never asked again on the device', (
      tester,
    ) async {
      await launch(tester);
      await tester.tap(find.byKey(const Key('consent-agree')));
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 1));
      }

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      final cameras = await launch(tester);
      expect(find.byKey(const Key('consent')), findsNothing);
      expect(find.byType(HomeNavigationBar), findsOneWidget);
      expect(cameras.opened, hasLength(1));
    });

    testWidgets('a consent saved for another device ID asks again', (
      tester,
    ) async {
      var done = false;
      () async {
        final store = await EventStore.open(storage);
        await store.putSettings(
          'consent',
          DeviceConsent.record('someone_elses_gadget', DateTime(2026)),
        );
        store.close();
        done = true;
      }();
      for (var i = 0; i < 50 && !done; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final cameras = await launch(tester);
      expect(find.byKey(const Key('consent')), findsOneWidget);
      expect(cameras.opened, isEmpty);
    });
  });
}
