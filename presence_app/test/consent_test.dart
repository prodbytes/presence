import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';

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
      expect(find.text('Faces are biometric data'), findsOneWidget);
      expect(find.byType(TabBar), findsNothing);
      expect(cameras.opened, isEmpty, reason: 'no camera before consent');

      // Both ticks are needed.
      FilledButton agree() =>
          tester.widget<FilledButton>(find.byKey(const Key('consent-agree')));
      expect(agree().onPressed, isNull);
      await tester.tap(find.byKey(const Key('consent-right-to-record')));
      await tester.pump();
      expect(agree().onPressed, isNull);
      await tester.ensureVisible(find.byKey(const Key('consent-biometrics')));
      await tester.tap(find.byKey(const Key('consent-biometrics')));
      await tester.pump();
      expect(agree().onPressed, isNotNull);

      await tester.ensureVisible(find.byKey(const Key('consent-agree')));
      await tester.tap(find.byKey(const Key('consent-agree')));
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('consent')), findsNothing);
      expect(find.byType(TabBar), findsOneWidget);
      expect(cameras.opened, hasLength(1));

      // Saved for this device, with a hash that checks out.
      final record = await stored(tester);
      expect(record, isNotNull);
      expect(
        DeviceConsent.isValid(record, record!['deviceId']! as String),
        isTrue,
      );
    });

    testWidgets('once given, it is never asked again on the device', (
      tester,
    ) async {
      await launch(tester);
      await tester.tap(find.byKey(const Key('consent-right-to-record')));
      await tester.ensureVisible(find.byKey(const Key('consent-biometrics')));
      await tester.tap(find.byKey(const Key('consent-biometrics')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('consent-agree')));
      await tester.tap(find.byKey(const Key('consent-agree')));
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 1));
      }

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      final cameras = await launch(tester);
      expect(find.byKey(const Key('consent')), findsNothing);
      expect(find.byType(TabBar), findsOneWidget);
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
