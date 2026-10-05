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

  Finder dropdown() => find.byKey(const Key('device-filter'));

  /// A line of the open dropdown (its key is on an inner button too).
  Finder item(String key) => find.byWidgetPredicate(
    (w) => w is CheckboxMenuButton && w.key == Key(key),
  );
  Finder line(String device) => item('device-filter-$device');
  Finder allLine() => item('device-filter-all');

  /// The events count beside the search: (shown, all).
  (int, int) counts(WidgetTester tester) {
    final text = tester.widget<Text>(find.byKey(const Key('event-count')));
    final [shown, all] = text.data!.split(' / ').map(int.parse).toList();
    return (shown, all);
  }

  bool? checked(WidgetTester tester, Finder item) =>
      tester.widget<CheckboxMenuButton>(item).value;

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// The id of the device that's not [there] among the dropdown's lines.
  String here(WidgetTester tester) {
    final key =
        tester
                .widgetList<CheckboxMenuButton>(find.byType(CheckboxMenuButton))
                .first
                .key!
            as ValueKey<String>;
    return key.value.substring('device-filter-'.length);
  }

  testWidgets('a dropdown checks every device, this device first in bold, '
      'until unchecked', (tester) async {
    await launch(tester);

    expect(find.text('Only this device'), findsNothing);
    expect(find.text('All devices'), findsOneWidget);
    final (shown, all) = counts(tester);
    expect(shown, all);

    await tap(tester, dropdown());
    final mine = here(tester);
    expect(mine, isNot(there));
    final bold = tester.widget<Text>(
      find.descendant(of: line(mine), matching: find.text('This device')),
    );
    expect(bold.style?.fontWeight, FontWeight.bold);
    expect(
      find.descendant(of: line(there), matching: find.text(there)),
      findsOneWidget,
    );
    expect(checked(tester, line(mine)), isTrue);
    expect(checked(tester, line(there)), isTrue);
    expect(checked(tester, allLine()), isTrue);

    // Unchecking the other device hides its events; the menu stays open.
    await tap(tester, line(there));
    expect(checked(tester, line(there)), isFalse);
    expect(checked(tester, allLine()), isNull);
    expect(find.text('Door opened here'), findsOneWidget);
    expect(find.text('Door opened there'), findsNothing);
    // Events published since launch are this device's too.
    expect(find.text('Application started'), findsWidgets);
    // The count leaves the other device's event out of the shown, not all.
    expect(counts(tester), (all - 1, all));

    // Unchecking this device too hides every event.
    await tap(tester, line(mine));
    expect(checked(tester, allLine()), isFalse);
    expect(find.text('Door opened here'), findsNothing);
    expect(counts(tester), (0, all));

    // All devices checks them all again, and again unchecks them all.
    await tap(tester, allLine());
    expect(checked(tester, line(mine)), isTrue);
    expect(checked(tester, line(there)), isTrue);
    expect(find.text('Door opened there'), findsOneWidget);
    await tap(tester, allLine());
    expect(checked(tester, line(mine)), isFalse);
    expect(checked(tester, line(there)), isFalse);
    await tap(tester, line(mine));

    // The choice stays while switching tabs.
    await tester.tapAt(const Offset(5, 795));
    await tester.pumpAndSettle();
    expect(find.text('1 of 2 devices'), findsOneWidget);
    await tap(tester, find.byTooltip('Settings'));
    await tap(tester, find.byTooltip('Monitoring'));
    expect(find.text('1 of 2 devices'), findsOneWidget);
    expect(find.text('Door opened here'), findsOneWidget);
    expect(find.text('Door opened there'), findsNothing);
  });

  testWidgets("a new event shows while filtered, before it's saved", (
    tester,
  ) async {
    await launch(tester);
    await tap(tester, dropdown());
    await tap(tester, line(there));
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
