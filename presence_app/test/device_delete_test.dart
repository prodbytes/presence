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
import 'package:presence_app/delete_device.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/main.dart';
import 'package:presence_app/recognition/suggestion.dart';
import 'package:presence_app/storage/event_store.dart';
import 'package:presence_app/storage/media_store.dart';
import 'package:presence_app/storage/persistence.dart';

import 'account_sheet_test.dart' show eventOf;
import 'camera_all_test.dart' show clipOf;
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

  test('deviceEventCount counts the device\'s events in the profile', () {
    final events = [
      eventOf('brave_quiet_lamp'),
      eventOf('brave_quiet_lamp', minutesAgo: 1),
      eventOf('brave_quiet_lamp', profile: 'other_profile'),
      eventOf('zesty_calm_kettle'),
    ];
    expect(
      deviceEventCount(
        events,
        deviceId: 'brave_quiet_lamp',
        profileId: 'automatic_paranoid_axolotl',
      ),
      2,
    );
  });

  group('the account sheet', () {
    late FakeAuthService auth;
    late RolesService roles;
    late StreamController<AppEvent> bus;
    late EventLog log;
    late List<String> deleted;

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
      deleted = [];
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
                deleteDevice: (id) async {
                  deleted.add(id);
                  // As Persistence.deleteDevice: out of the log.
                  log.remove({
                    for (final e in log.events)
                      if (e.deviceId == id) e.id,
                  });
                  return 2;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('every other device has a delete button; this one has none', (
      tester,
    ) async {
      await show(tester);
      expect(
        find.byKey(const Key('profile-device-delete-brave_quiet_lamp')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('profile-device-delete-happy_tidy_gadget')),
        findsNothing,
      );
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets('the delete button fits 320 dp at ${scale}x text', (
        tester,
      ) async {
        await show(tester, scale: scale);
        expect(tester.takeException(), isNull);
        final button = find.byKey(
          const Key('profile-device-delete-brave_quiet_lamp'),
        );
        expect(tester.getTopRight(button).dx, lessThanOrEqualTo(320));
      });
    }

    testWidgets('a confirmation names the device and its events; Cancel '
        'keeps it, Delete deletes it and it leaves the list', (tester) async {
      await show(tester);
      expect(find.text('2 devices'), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('profile-device-delete-brave_quiet_lamp')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('delete-device-dialog')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('delete-device-message')))
            .data,
        'Delete device brave_quiet_lamp? Its 2 events will be hidden on '
        'every device.',
      );
      expect(tester.takeException(), isNull, reason: 'fits 320 dp');

      await tester.tap(find.byKey(const Key('delete-device-cancel')));
      await tester.pumpAndSettle();
      expect(deleted, isEmpty);
      expect(find.text('2 devices'), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('profile-device-delete-brave_quiet_lamp')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-device-confirm')));
      await tester.pumpAndSettle();
      expect(deleted, ['brave_quiet_lamp']);
      expect(
        find.byKey(const Key('profile-device-brave_quiet_lamp')),
        findsNothing,
      );
      expect(find.text('1 device'), findsOneWidget);
      expect(
        find.text('Deleted brave_quiet_lamp: 2 events hidden'),
        findsOneWidget,
      );
    });

    testWidgets('without a delete, no delete buttons', (tester) async {
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
        find.byKey(const Key('profile-device-delete-brave_quiet_lamp')),
        findsNothing,
      );
    });
  });

  group('the All grid', () {
    late StreamController<AppEvent> bus;
    late EventLog log;
    late CameraRig rig;

    setUp(() async {
      bus = StreamController<AppEvent>.broadcast();
      log = EventLog(bus.stream)
        ..addHistory([
          clipOf('brave_fox', minutesAgo: 3),
          clipOf('brave_fox', minutesAgo: 5),
          clipOf('zesty_owl', minutesAgo: 1),
        ]);
      rig = CameraRig(
        backend: openFakes([FakeCameraSource('Main')]),
        config: ConfigController(),
      );
      await rig.load();
    });

    tearDown(() {
      rig.dispose();
      bus.close();
    });

    testWidgets('no cell has a delete button: devices are deleted from '
        'the account sheet', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: CameraFeedsView(
            rig: rig,
            log: log,
            deviceId: 'this_device',
            profileId: 'user-1',
            showAll: true,
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('device-image-brave_fox')), findsOneWidget);
      expect(find.byKey(const Key('device-image-zesty_owl')), findsOneWidget);
      for (final device in ['brave_fox', 'zesty_owl', 'this_device']) {
        expect(find.byKey(Key('device-delete-$device')), findsNothing);
      }
      expect(find.byIcon(Icons.delete_outline), findsNothing);
      expect(find.byTooltip('Delete brave_fox'), findsNothing);
    });
  });

  testWidgets('in the app: deleting a device from the account sheet hides '
      'its events from the timeline and its count', (tester) async {
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
    await tester.pumpWidget(
      PresenceApp(
        consentGiven: true,
        cameras: openFakes(const []),
        storage: storage,
        mediaIo: fakeMediaIo,
        now: () => noon,
        auth: FakeAuthService.signedIn(),
        rolesClient: FakeRolesClient(),
        mapTiles: const SizedBox(),
        locator: NoLocation(),
      ),
    );
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
    await tester.tap(
      find.byKey(const Key('profile-device-delete-brave_phone')),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('delete-device-message'))).data,
      'Delete device brave_phone? Its 2 events will be hidden on every '
      'device.',
    );
    await tester.tap(find.byKey(const Key('delete-device-confirm')));
    await tester.pump();
    await settleStorage(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profile-device-brave_phone')), findsNothing);
    expect(
      find.byKey(const Key('profile-device-delete-brave_phone')),
      findsNothing,
    );

    // The account is a tab: back to Monitoring.
    await tester.tap(find.byTooltip('Monitoring'));
    await tester.pumpAndSettle();
    expect(find.text('Phone motion'), findsNothing);
    expect(find.text('Phone door'), findsNothing);
    final [shown, all] = before.split(' / ').map(int.parse).toList();
    expect(count(), '${shown - 2} / ${all - 2}');
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
