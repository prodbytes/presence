import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';

import 'package:presence_app/events.dart';
import 'package:presence_app/main.dart';
import 'package:presence_app/storage/event_store.dart';

import 'fakes.dart';

void main() {
  const there = 'loud_shy_kettle';

  late IdbFactory storage;
  setUp(() => storage = newIdbFactoryMemory());

  /// Runs a storage call to completion under fake time.
  Future<T> run<T>(WidgetTester tester, Future<T> future) async {
    var done = false;
    late T result;
    future.then((v) {
      result = v;
      done = true;
    });
    for (var i = 0; i < 50 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(done, isTrue, reason: 'storage call timed out');
    return result;
  }

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      PresenceApp(
        // A new key forces a fresh app, like a page reload.
        key: UniqueKey(),
        consentGiven: true,
        cameras: noCameras,
        storage: storage,
        auth: FakeAuthService.signedIn(),
        rolesClient: FakeRolesClient(),
        mapTiles: const SizedBox(),
        locator: NoLocation(),
        // The day of the stored events, so none is too old to keep.
        now: () => DateTime(2026, 10, 1, 12),
      ),
    );
    await tester.pumpAndSettle();
    await settleStorage(tester);
    await tester.pumpAndSettle();
  }

  /// Opens the app with an event from this device and one from another,
  /// as after a cloud fetch, on the Events tab.
  Future<void> launch(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await open(tester);
    final store = await run(tester, EventStore.open(storage));
    final here = await run(tester, store.deviceId(() => 'unused'));
    for (final (title, device, minute) in [
      ('Door opened here', here, 1),
      ('Door opened there', there, 2),
    ]) {
      await run(
        tester,
        store.putEvent({
          'id': 'e$minute',
          'type': AppEvent.genericType,
          'title': title,
          'time': DateTime(2026, 10, 1, 9, minute).millisecondsSinceEpoch,
          'deviceId': device,
          'userId': AppEvent.anonymousUserId,
        }),
      );
    }
    store.close();
    await tester.pumpWidget(const SizedBox());
    await settleStorage(tester);
    await open(tester);
    await tester.tap(find.byTooltip('Monitoring'));
    await tester.pumpAndSettle();
    await revealSystemEvents(tester);
  }

  Finder checkbox() => find.byKey(const Key('this-device-only'));

  bool checked(WidgetTester tester) =>
      tester.widget<FilterChip>(checkbox()).selected;

  testWidgets('shows only this device until the checkbox is cleared', (
    tester,
  ) async {
    await launch(tester);

    expect(checkbox(), findsOneWidget);
    expect(checked(tester), isTrue);
    expect(find.text('Only this device'), findsOneWidget);
    expect(find.text('Door opened here'), findsOneWidget);
    expect(find.text('Door opened there'), findsNothing);
    // Events published since launch are this device's too.
    expect(find.text('Application started'), findsWidgets);

    await tester.tap(checkbox());
    await tester.pumpAndSettle();
    expect(checked(tester), isFalse);
    expect(find.text('Door opened here'), findsOneWidget);
    expect(find.text('Door opened there'), findsOneWidget);

    // The choice stays while switching tabs.
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Monitoring'));
    await tester.pumpAndSettle();
    expect(checked(tester), isFalse);
    expect(find.text('Door opened there'), findsOneWidget);

    await tester.tap(checkbox());
    await tester.pumpAndSettle();
    expect(find.text('Door opened there'), findsNothing);
  });

  testWidgets("a new event shows while filtered, before it's saved", (
    tester,
  ) async {
    await launch(tester);
    AppEventBusScope.of(tester.element(find.byType(Scaffold).first))
        .publish(AppEvent(icon: Icons.circle, title: 'Just now'));
    // The bus delivers in a microtask; the next frame shows it.
    await tester.pump();
    await tester.pump();
    expect(find.text('Just now'), findsOneWidget);
    await settleStorage(tester);
    await tester.pumpAndSettle();
    expect(find.text('Just now'), findsOneWidget);
  });
}
