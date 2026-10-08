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

  /// The device tag above event [id]'s card.
  Finder tag(String id) => find.byKey(Key('event-device-$id'));

  /// The events search field, open with a device's ID once it's tapped.
  Finder field() => find.byKey(const Key('event-search'));
  String searched(WidgetTester tester) =>
      tester.widget<TextField>(field()).controller!.text;

  /// The events count beside the search: (shown, all).
  (int, int) counts(WidgetTester tester) {
    final text = tester.widget<Text>(find.byKey(const Key('event-count')));
    final [shown, all] = text.data!.split(' / ').map(int.parse).toList();
    return (shown, all);
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets("each event shows its device; tapping it searches for it: "
      "only that device's events show, until tapped again", (tester) async {
    await launch(tester);

    expect(find.text('All devices'), findsNothing);
    expect(field(), findsNothing);
    final (shown, all) = counts(tester);
    expect(shown, all);
    expect(
      find.descendant(of: tag('e2'), matching: find.text(there)),
      findsOneWidget,
    );
    final mine = tester.widget<EventDeviceTag>(tag('e1')).device;
    expect(mine, isNot(there));
    // This device's ID is in bold.
    final bold = tester.widget<Text>(
      find.descendant(of: tag('e1'), matching: find.text(mine)),
    );
    expect(bold.style?.fontWeight, FontWeight.bold);
    expect(find.byTooltip("Show this device's events"), findsWidgets);

    // Tapping the other device's tag searches for it: only its events.
    await tap(tester, tag('e2'));
    expect(searched(tester), there);
    expect(find.text('Door opened there'), findsOneWidget);
    expect(find.text('Door opened here'), findsNothing);
    expect(find.text('Application started'), findsNothing);
    expect(counts(tester), (1, all));
    expect(find.byTooltip("Show every device's events"), findsOneWidget);

    // The search stays while switching tabs.
    await tap(tester, find.byTooltip('Settings'));
    await tap(tester, find.byTooltip('Monitoring'));
    expect(searched(tester), there);
    expect(find.text('Door opened here'), findsNothing);

    // Tapped again, the search clears: every device's events.
    await tap(tester, tag('e2'));
    expect(find.text('Door opened here'), findsOneWidget);
    expect(find.text('Door opened there'), findsOneWidget);
    expect(counts(tester), (all, all));

    // This device's tag shows only its events, events published since
    // launch (no device ID yet) among them.
    await tap(tester, tag('e1'));
    expect(searched(tester), mine);
    expect(find.text('Door opened here'), findsOneWidget);
    expect(find.text('Door opened there'), findsNothing);
    expect(find.text('Application started'), findsWidgets);
    expect(counts(tester), (all - 1, all));
  });

  test('a search for a whole device ID narrows to its events, ignoring '
      'case; part of one matches events by their device too', () {
    AppEvent at(String id, String? device) =>
        AppEvent(icon: Icons.circle, title: 'Event $id')..deviceId = device;
    final events = [
      at('1', 'brave_quiet_lamp'),
      at('2', 'loud_shy_kettle'),
      at('3', null),
    ];
    expect(
      EventFilters.searchedDevice(events, ' BRAVE_quiet_lamp '),
      'brave_quiet_lamp',
    );
    expect(EventFilters.searchedDevice(events, 'brave'), isNull);
    expect(
      EventFilters.searchedDevice(events, 'here', deviceId: 'here'),
      'here',
      reason: 'events not saved yet are this device\'s',
    );
    expect(eventMatches(events[1], 'kettle'), isTrue);
    expect(eventMatches(events[2], 'here', deviceId: 'here'), isTrue);
    expect(eventMatches(events[0], 'kettle'), isFalse);
  });

  testWidgets("a new event shows while filtered, before it's saved", (
    tester,
  ) async {
    await launch(tester);
    await tap(tester, tag('e1'));
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
