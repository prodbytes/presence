import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';

import 'package:presence_app/auth/account_sheet.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/device_events.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/main.dart';
import 'package:presence_app/storage/event_store.dart';

import 'event_details_test.dart' show clipEvent;
import 'fakes.dart';

/// A tapped device name, anywhere, shows the device's events: the
/// Monitoring tab, its search set to the device's ID ([ShowDeviceEvents]).
void main() {
  const phone = 'brave_phone';
  const profile = 'automatic_paranoid_axolotl';
  final noon = DateTime(2026, 10, 6, 12);

  /// Opens the app at [width] dp, signed in, with two events of [phone]
  /// synced before, on the Camera tab.
  Future<void> launch(
    WidgetTester tester, {
    double width = 320,
    FakeRolesClient? roles,
  }) async {
    tester.view.physicalSize = Size(width, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final storage = newIdbFactoryMemory();
    final seed = await tester.runAsync(() => EventStore.open(storage));
    for (final (i, title) in ['Phone motion', 'Phone door'].indexed) {
      await tester.runAsync(
        () => seed!.putEvent({
          'id': 'phone-$i',
          'type': AppEvent.genericType,
          'title': title,
          'time': noon
              .subtract(Duration(minutes: i + 1))
              .millisecondsSinceEpoch,
          'deviceId': phone,
          'userId': '1',
          'profileId': profile,
        }),
      );
    }
    seed!.close();
    await tester.pumpWidget(
      PresenceApp(
        consentGiven: true,
        cameras: openFakes([FakeCameraSource('Main')]),
        storage: storage,
        mediaIo: fakeMediaIo,
        now: () => noon,
        auth: FakeAuthService.signedIn(),
        rolesClient: roles ?? FakeRolesClient(),
        mapTiles: const SizedBox(),
        locator: NoLocation(),
      ),
    );
    await tester.pumpAndSettle();
    await settleStorage(tester);
    await tester.pumpAndSettle();
  }

  Finder field() => find.byKey(const Key('event-search'));

  /// On the Monitoring tab, the search open with [phone]'s ID, and only
  /// its events (system events too, once shown).
  Future<void> expectPhoneEvents(WidgetTester tester) async {
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('events-page')), findsOneWidget);
    expect(tester.widget<TextField>(field()).controller!.text, phone);
    await revealSystemEvents(tester);
    expect(find.text('Phone motion'), findsOneWidget);
    expect(find.text('Phone door'), findsOneWidget);
    expect(find.text('Application started'), findsNothing);
    final count = tester
        .widget<Text>(find.byKey(const Key('event-count')))
        .data!;
    expect(count, startsWith('2 / '));
    expect(tester.takeException(), isNull);
  }

  testWidgets("the account sheet's device ID: the sheet closes, Monitoring "
      "shows the device's events", (tester) async {
    await launch(tester);
    await tester.tap(find.byKey(const Key('account-button')));
    await tester.pumpAndSettle();
    final id = find.byKey(const Key('profile-device-id-$phone'));
    expect(tester.takeException(), isNull);
    expect(find.ancestor(of: id, matching: find.byType(Tooltip)), findsWidgets);
    expect(find.byTooltip("Show this device's events"), findsWidgets);
    // Still selectable to copy.
    expect(tester.widget(id), isA<SelectableText>());

    await tester.tap(id);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account-sheet')), findsNothing);
    await expectPhoneEvents(tester);
  });

  testWidgets("the All grid's label: Monitoring shows the device's events", (
    tester,
  ) async {
    await launch(tester);
    await tester.tap(find.byTooltip('Show all devices'));
    await tester.pumpAndSettle();
    final label = find.byKey(const Key('device-label-$phone'));
    expect(label, findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(label);
    await tester.pumpAndSettle();
    await expectPhoneEvents(tester);
  });

  testWidgets("the event details' device: the player closes, Monitoring "
      "shows the device's events", (tester) async {
    await launch(tester);
    await showEvents(tester);
    final clip = clipEvent(device: phone);
    showClipPlayer(tester.element(find.byKey(const Key('events-page'))), clip);
    await tester.pumpAndSettle();
    final id = find.byKey(const Key('event-device-id'));
    await tester.ensureVisible(id);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(id);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    await expectPhoneEvents(tester);
  });

  testWidgets("an event card's device: the search shows the device's events", (
    tester,
  ) async {
    await launch(tester);
    await showEvents(tester);
    await revealSystemEvents(tester);
    expect(find.text('Application started'), findsWidgets);

    await tester.tap(find.byKey(const Key('event-device-phone-0')));
    await tester.pumpAndSettle();
    await expectPhoneEvents(tester);
  });

  testWidgets('without access (no Monitoring tab), device IDs are not '
      'tappable', (tester) async {
    await launch(tester, roles: FakeRolesClient.none());
    await tester.tap(find.byKey(const Key('account-button')));
    await tester.pumpAndSettle();
    expect(find.byTooltip("Show this device's events"), findsNothing);
    final ids = find.byKey(const Key('profile-device-id-$phone'));
    expect(ids, findsOneWidget);
    for (final e in ids.evaluate()) {
      expect((e.widget as SelectableText).onTap, isNull);
    }
  });

  group('DeviceEventsLink', () {
    Future<void> show(WidgetTester tester, ValueChanged<String>? onShow) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ShowDeviceEvents(
                onShow: onShow,
                child: ProfileDevices(
                  profile: profile,
                  now: () => noon,
                  devices: [(id: phone, os: 'Android', lastEvent: noon)],
                ),
              ),
            ),
          ),
        );

    testWidgets('a button with a tooltip, showing the device tapped', (
      tester,
    ) async {
      final shown = <String>[];
      await show(tester, shown.add);
      expect(find.byTooltip("Show this device's events"), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byKey(const Key('profile-device-id-$phone')),
          matching: find.byWidgetPredicate(
            (w) => w is Semantics && (w.properties.button ?? false),
          ),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('profile-device-id-$phone')));
      expect(shown, [phone]);
    });

    testWidgets('unavailable: plain, selectable text', (tester) async {
      await show(tester, null);
      expect(find.byTooltip("Show this device's events"), findsNothing);
      final id = tester.widget<SelectableText>(
        find.byKey(const Key('profile-device-id-$phone')),
      );
      expect(id.onTap, isNull);
    });
  });
}
