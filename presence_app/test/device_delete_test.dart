import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';

import 'package:presence_app/auth/account_sheet.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/camera_feeds.dart';
import 'package:presence_app/cloud/cloud_sync.dart';
import 'package:presence_app/cloud/live_sync.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/main.dart';
import 'package:presence_app/recognition/suggestion.dart';
import 'package:presence_app/storage/event_store.dart';
import 'package:presence_app/storage/media_store.dart';
import 'package:presence_app/storage/persistence.dart';

import 'account_sheet_test.dart' show eventOf;
import 'fakes.dart';
import 'live_sync_test.dart'
    show FakeBroker, eventsTopic, identity, messageOf, until;

void main() {
  test('the deleted state round-trips through the stored record', () {
    final event = AppEvent(
      icon: Icons.circle,
      title: 'Door',
      deviceId: 'brave_fox',
      profileId: '1',
    );
    expect(event.toRecord().containsKey('deletedAt'), isFalse);
    expect(AppEvent.isDeletedRecord(event.toRecord()), isFalse);

    final at = DateTime(2026, 10, 6, 9, 30);
    event.deletedAt = at;
    final record = event.toRecord();
    expect(record['deletedAt'], at.millisecondsSinceEpoch);
    expect(AppEvent.isDeletedRecord(record), isTrue);
    // And through JSON, as uploaded.
    final json = (jsonDecode(jsonEncode(record)) as Map)
        .cast<String, Object?>();
    expect(AppEvent.fromRecord(json)!.deletedAt, at);
    expect(AppEvent.deletedAtOf({'deletedAt': 'soon'}), isNull);
  });

  group('the account sheet', () {
    late FakeAuthService auth;
    late RolesService roles;
    late StreamController<AppEvent> bus;
    late EventLog log;
    late List<(String, bool)> shows;

    setUp(() async {
      auth = FakeAuthService.signedIn();
      roles = RolesService(
        auth: auth,
        client: FakeRolesClient(),
        oidcClient: true,
      );
      // The roles check (rbacr's roles and maintenance status) answers
      // before the sheet shows.
      await pumpEventQueue();
      bus = StreamController<AppEvent>();
      log = EventLog(bus.stream)
        ..addHistory([
          eventOf('brave_quiet_lamp'),
          eventOf('brave_quiet_lamp', minutesAgo: 1),
          eventOf('happy_tidy_gadget', minutesAgo: 2),
        ]);
      shows = [];
    });

    tearDown(() {
      log.dispose();
      bus.close();
      roles.dispose();
    });

    Future<void> show(WidgetTester tester, {double scale = 1}) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(320, 800),
              textScaler: TextScaler.linear(scale),
            ),
            child: Scaffold(
              body: AccountSheet(
                auth: auth,
                roles: roles,
                log: log,
                deviceId: 'happy_tidy_gadget',
                showDevice: (id, shown) {
                  shows.add((id, shown));
                  // As the app does: the log hides its events.
                  log.hiddenDevices = shown
                      ? ({...log.hiddenDevices}..remove(id))
                      : {...log.hiddenDevices, id};
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('every device has a hide button, this one too; none '
        'deletes', (tester) async {
      await show(tester);
      for (final device in ['brave_quiet_lamp', 'happy_tidy_gadget']) {
        expect(find.byKey(Key('profile-device-hide-$device')), findsOneWidget);
      }
      expect(find.byIcon(Icons.delete_outline), findsNothing);
    });

    testWidgets('hide hides its events, the device stays listed; show '
        'shows them again', (tester) async {
      await show(tester);
      List<String?> devices() => [
        for (final e in log.eventsOf('automatic_paranoid_axolotl')) e.deviceId,
      ];
      expect(devices(), contains('brave_quiet_lamp'));

      await tester.tap(
        find.byKey(const Key('profile-device-hide-brave_quiet_lamp')),
      );
      await tester.pumpAndSettle();
      expect(shows, [('brave_quiet_lamp', false)]);
      expect(devices(), isNot(contains('brave_quiet_lamp')));
      expect(find.text('2 devices'), findsOneWidget);
      expect(find.byTooltip("Show brave_quiet_lamp's events"), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('profile-device-show-brave_quiet_lamp')),
      );
      await tester.pumpAndSettle();
      expect(shows.last, ('brave_quiet_lamp', true));
      expect(devices(), contains('brave_quiet_lamp'));
      expect(
        find.byKey(const Key('profile-device-hide-brave_quiet_lamp')),
        findsOneWidget,
      );
    });

    testWidgets('without a showDevice, no eye buttons', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AccountSheet(
              auth: auth,
              roles: roles,
              log: log,
              deviceId: 'happy_tidy_gadget',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('profile-device-hide-brave_quiet_lamp')),
        findsNothing,
      );
    });
  });

  for (final keep in [true, false]) {
    testWidgets('in the app: deleting a device from the account sheet, '
        '${keep ? 'keeping its videos: it leaves the list, its events stay' : 'with its videos: its events go too'}'
        '; after a restart too', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final storage = newIdbFactoryMemory();
      final noon = DateTime(2026, 10, 6, 12);
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
            'deviceId': 'brave_phone',
            'userId': '1',
            'profileId': 'automatic_paranoid_axolotl',
          }),
        );
      }
      seed!.close();
      Widget app() => PresenceApp(
        consentGiven: true,
        cameras: openFakes(const []),
        storage: storage,
        mediaIo: fakeMediaIo,
        now: () => noon,
        auth: FakeAuthService.signedIn(),
        rolesClient: FakeRolesClient(),
        mapTiles: const SizedBox(),
        locator: NoLocation(),
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await settleStorage(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('account-button')));
      await tester.pumpAndSettle();
      // Beside its eye button.
      expect(
        find.byKey(const Key('profile-device-hide-brave_phone')),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(const Key('profile-device-delete-brave_phone')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('profile-device-delete-brave_phone')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('delete-device-message')))
            .data,
        'Delete brave_phone from your devices? It has 2 events.',
      );
      expect(tester.takeException(), isNull, reason: 'fits 320 dp');
      await tester.tap(
        find.byKey(Key(keep ? 'delete-device-keep' : 'delete-device-confirm')),
      );
      await tester.pump();
      await settleStorage(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('profile-device-brave_phone')), findsNothing);
      expect(
        find.text(
          keep
              ? 'Removed brave_phone from the list; its videos stay'
              : 'Deleted brave_phone: 2 events hidden',
        ),
        findsOneWidget,
      );

      Future<void> eventsShow() async {
        await showEvents(tester);
        await revealSystemEvents(tester);
        expect(find.text('Phone motion'), keep ? findsOneWidget : findsNothing);
      }

      await tester.tap(find.byTooltip('Events'));
      await tester.pumpAndSettle();
      await eventsShow();

      // Remembered: after a restart it's still off the list.
      await tester.pumpWidget(const SizedBox());
      await settleStorage(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await settleStorage(tester);
      await tester.pumpAndSettle();
      // Its events gone stay gone (kept ones may be past the screen, under
      // the restarts' own events).
      if (!keep) await eventsShow();
      await tester.tap(find.byKey(const Key('account-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('profile-device-brave_phone')), findsNothing);
    });
  }

  test('a device deleted keeping its videos is listed again once it has a '
      'newer event', () {
    final log = EventLog(const Stream.empty());
    final at = DateTime(2026, 10, 6, 12);
    log.removedDevices = {'brave_phone': at};
    expect(log.removedFromList('brave_phone', at), isTrue);
    expect(log.removedFromList('brave_phone', null), isTrue);
    expect(
      log.removedFromList('brave_phone', at.add(const Duration(seconds: 1))),
      isFalse,
    );
    expect(log.removedFromList('zesty_owl', at), isFalse);
    log.dispose();
  });

  testWidgets('in the app: hiding a device from the account sheet hides '
      'its events from the timeline and its count, after a restart too', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final storage = newIdbFactoryMemory();
    final noon = DateTime(2026, 10, 6, 12);
    // Another device's events, synced before.
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
          'deviceId': 'brave_phone',
          'userId': '1',
          'profileId': 'automatic_paranoid_axolotl',
        }),
      );
    }
    seed!.close();
    Widget app() => PresenceApp(
      consentGiven: true,
      cameras: openFakes(const []),
      storage: storage,
      mediaIo: fakeMediaIo,
      now: () => noon,
      auth: FakeAuthService.signedIn(),
      rolesClient: FakeRolesClient(),
      mapTiles: const SizedBox(),
      locator: NoLocation(),
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await settleStorage(tester);
    await tester.pumpAndSettle();
    await showEvents(tester);
    await revealSystemEvents(tester);
    expect(find.text('Phone motion'), findsOneWidget);
    String count() =>
        tester.widget<Text>(find.byKey(const Key('event-count'))).data!;
    final before = count();

    await tester.tap(find.byKey(const Key('account-button')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('profile-device-hide-brave_phone')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('profile-device-hide-brave_phone')));
    await tester.pump();
    await settleStorage(tester);
    await tester.pumpAndSettle();
    // Still listed, to show again.
    expect(
      find.byKey(const Key('profile-device-show-brave_phone')),
      findsOneWidget,
    );

    // The account is a tab: back to Monitoring.
    await tester.tap(find.byTooltip('Events'));
    await tester.pumpAndSettle();
    expect(find.text('Phone motion'), findsNothing);
    expect(find.text('Phone door'), findsNothing);
    final [shown, all] = before.split(' / ').map(int.parse).toList();
    expect(count(), '${shown - 2} / ${all - 2}');

    // Remembered: a restart keeps them hidden.
    await tester.pumpWidget(const SizedBox());
    await settleStorage(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await settleStorage(tester);
    await tester.pumpAndSettle();
    await showEvents(tester);
    await revealSystemEvents(tester);
    expect(find.text('Phone motion'), findsNothing);
  });

  group('with storage and cloud sync', () {
    late IdbFactory factory;
    late AppEventBus bus;
    late EventLog log;
    late Persistence persistence;
    late FakeCloudBackend backend;
    late FakeAuthService auth;
    late FakeBroker broker;
    late LiveSync live;
    late CloudSync sync;

    int now() => DateTime.now().millisecondsSinceEpoch;
    Uint8List json(Map<String, Object?> m) =>
        Uint8List.fromList(utf8.encode(jsonEncode(m)));
    Map<String, Object?> decode(Uint8List bytes) =>
        (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();

    Map<String, Object?> phoneEvent(String id, {int ago = 60000}) => {
      'id': id,
      'type': AppEvent.genericType,
      'title': 'From the phone $id',
      'time': now() - ago,
      'deviceId': 'brave_phone',
      'userId': '1',
      'profileId': '1',
    };

    /// Puts [event] in the bucket, as another device uploads it.
    void inCloud(Map<String, Object?> event) =>
        backend.uploads['$identity/${CloudSync.eventKey(event)}'] = (
          bytes: json(event),
          contentType: 'application/json',
        );

    Map<String, Object?> cloudCopy(Map<String, Object?> event) => decode(
      backend.uploads['$identity/${CloudSync.eventKey(event)}']!.bytes,
    );

    /// A pass of cloud sync, to its end.
    Future<void> pass() async {
      sync.retry();
      await sync.idle();
      await persistence.flush();
    }

    Persistence open() => Persistence(
      factory: Future.value(factory),
      bus: bus,
      config: ConfigController(),
      currentUser: () => '1',
      currentProfile: () => '1',
      mediaStore: (store) => IdbMediaStore(store, fakeMediaIo),
    );

    setUp(() async {
      factory = newIdbFactoryMemory();
      bus = AppEventBus();
      log = EventLog(bus.stream);
      persistence = open();
      await persistence.restore(log);
      backend = FakeCloudBackend();
      auth = FakeAuthService();
      broker = FakeBroker();
      live = LiveSync(
        endpoint: 'abc-ats.iot.us-east-1.amazonaws.com',
        region: 'us-east-1',
        connect: broker.connect,
        minRetry: const Duration(milliseconds: 5),
      )..config = LiveConfig.always;
      sync = CloudSync(
        auth: auth,
        backend: backend,
        store: persistence.store,
        media: persistence.media,
        changes: persistence.changes,
        debounce: Duration.zero,
        live: live,
        prefetchRecordings: false,
        // As the app does.
        onRemote: (remote) async {
          final events = await persistence.importRemote(
            events: remote.events,
            clips: remote.clips,
            awaitClips: remote.live,
          );
          log.addHistory(events);
          await persistence.showArrivedClips(remote.clips, log);
          await persistence.updateFromRemote(remote.updated, log.events);
        },
      );
    });

    tearDown(() async {
      sync.dispose();
      live.dispose();
      persistence.dispose();
      log.dispose();
      await bus.close();
    });

    List<String> shown() => [for (final e in log.events) e.id];

    test('deleting a device hides its events (and the suggestions about '
        'its clips), uploads them deleted, and keeps them hidden after a '
        'restart and a full fetch', () async {
      final a = phoneEvent('phone-a');
      final b = {
        ...phoneEvent('phone-b', ago: 30000),
        'type': 'clip_requested',
        'clipId': 'phone-clip',
      };
      final other = {...phoneEvent('kettle-a'), 'deviceId': 'zesty_kettle'};
      final suggestion = {
        ...phoneEvent('suggest-b', ago: 20000),
        'deviceId': 'zesty_kettle',
        'type': SubjectSuggestion.suggestionType,
        'clipEventId': 'phone-b',
        'annotationId': 'a1',
        'subjectName': 'Rex',
        'confidence': 0.9,
      };
      for (final e in [a, b, other, suggestion]) {
        inCloud(e);
      }
      await auth.signIn();
      await sync.idle();
      await persistence.flush();
      await until(() => live.state == LiveSyncState.connected);
      expect(shown(), containsAll(['phone-a', 'phone-b', 'kettle-a']));
      expect(profileDevices(log.events, profileId: '1'), [
        'brave_phone',
        'zesty_kettle',
      ]);

      final count = await persistence.deleteDevice(
        'brave_phone',
        profileId: '1',
      );
      expect(
        count,
        3,
        reason: 'its 2 events and the suggestion about its clip',
      );
      for (final id in ['phone-a', 'phone-b', 'suggest-b']) {
        expect(shown(), isNot(contains(id)));
        final record = (await (await persistence.store).getEvent(id))!;
        expect(AppEvent.isDeletedRecord(record), isTrue, reason: id);
      }
      expect(shown(), contains('kettle-a'));
      // Gone from the devices list, the grid and the counts.
      expect(profileDevices(log.events, profileId: '1'), ['zesty_kettle']);
      expect(
        latestByDevice(log.events, profileId: '1').map((d) => d.deviceId),
        ['zesty_kettle'],
      );
      expect(EventTimeline.ofProfile(log.events, '1'), hasLength(1));

      // Uploaded deleted, and published over live sync.
      await sync.idle();
      for (final e in [a, b, suggestion]) {
        expect(AppEvent.isDeletedRecord(cloudCopy(e)), isTrue);
      }
      final published = {
        for (final m in broker.last.sent)
          (m['event']! as Map)['id']: (m['event']! as Map)['deletedAt'],
      };
      expect(published['phone-a'], isA<int>());
      expect(published['phone-b'], isA<int>());

      // A full fetch, as for a new start: still hidden.
      sync.reconnect();
      await sync.idle();
      await persistence.flush();
      expect(shown(), ['kettle-a']);

      // A restart: still hidden.
      await persistence.flush();
      final restarted = EventLog(AppEventBus().stream);
      final reopened = open();
      addTearDown(() {
        reopened.dispose();
        restarted.dispose();
      });
      await reopened.restore(restarted);
      expect([for (final e in restarted.events) e.id], ['kettle-a']);
    });

    test('this device can\'t be deleted', () async {
      bus.publish(AppEvent(icon: Icons.circle, title: 'Here'));
      await persistence.flush();
      final me = await persistence.deviceId;
      expect(await persistence.deleteDevice(me, profileId: '1'), 0);
      expect(log.events, hasLength(1));
    });

    test('a deleted copy from another device hides the event here; an older '
        'copy that isn\'t deleted doesn\'t bring it back', () async {
      final a = phoneEvent('phone-a');
      inCloud(a);
      await auth.signIn();
      await pass();
      expect(shown(), ['phone-a']);

      // Deleted on another device.
      final deleted = {...a, 'deletedAt': now()};
      inCloud(deleted);
      await pass();
      expect(shown(), isEmpty);
      final store = await persistence.store;
      expect(
        AppEvent.isDeletedRecord((await store.getEvent('phone-a'))!),
        isTrue,
      );

      // The phone, still running, uploads its copy again, not deleted
      // (say it was tagged there).
      inCloud({...a, 'title': 'Tagged on the phone'});
      await pass();
      expect(shown(), isEmpty, reason: 'deletion sticks');
      expect(
        AppEvent.isDeletedRecord((await store.getEvent('phone-a'))!),
        isTrue,
      );
      // And it goes up again deleted.
      await pass();
      expect(AppEvent.isDeletedRecord(cloudCopy(a)), isTrue);
    });

    test('a deleted copy wins over a change here not uploaded yet', () async {
      final a = phoneEvent('phone-a');
      inCloud(a);
      await auth.signIn();
      await pass();
      expect(shown(), ['phone-a']);

      // Changed here, not uploaded yet; deleted on another device.
      final store = await persistence.store;
      await store.putEvent({...a, 'title': 'Changed here'});
      inCloud({...a, 'deletedAt': now()});
      // A pass that uploads every changed event (as at start).
      sync.reconnect();
      await sync.idle();
      await persistence.flush();
      expect(shown(), isEmpty);
      expect(
        AppEvent.isDeletedRecord((await store.getEvent('phone-a'))!),
        isTrue,
      );
      expect(
        AppEvent.isDeletedRecord(cloudCopy(a)),
        isTrue,
        reason: 'not uploaded over the deleted copy',
      );
    });

    test('over live sync: a deleted copy hides the event at once, even '
        'changed here; a device that records again shows again', () async {
      final a = phoneEvent('phone-a');
      inCloud(a);
      await auth.signIn();
      await pass();
      await until(() => live.state == LiveSyncState.connected);
      expect(shown(), ['phone-a']);

      final store = await persistence.store;
      await store.putEvent({...a, 'title': 'Changed here'});
      final deleted = {...a, 'deletedAt': now()};
      broker.last.deliver(
        eventsTopic,
        messageOf(deleted, deviceId: 'zesty_kettle'),
      );
      await until(() => shown().isEmpty);
      await live.drained;
      await persistence.flush();
      expect(
        AppEvent.isDeletedRecord((await store.getEvent('phone-a'))!),
        isTrue,
      );

      // Its new events show: the device comes back.
      broker.last.deliver(eventsTopic, messageOf(phoneEvent('phone-new')));
      await until(() => shown().contains('phone-new'));
      expect(profileDevices(log.events, profileId: '1'), ['brave_phone']);
      expect(shown(), isNot(contains('phone-a')));
    });
  });
}
