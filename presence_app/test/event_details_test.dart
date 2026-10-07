import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';

import 'package:presence_app/cameras/cameras.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/cloud/cloud_sync.dart';
import 'package:presence_app/cloud/live_sync.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/event_details.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/location/device_location.dart';
import 'package:presence_app/main.dart';
import 'package:presence_app/recognition/suggestion.dart';
import 'package:presence_app/storage/event_store.dart';
import 'package:presence_app/storage/media_store.dart';
import 'package:presence_app/storage/persistence.dart';

import 'fakes.dart';
import 'live_sync_test.dart' show FakeBroker, identity, until;

const profile = 'automatic_paranoid_axolotl';

ClipRequested clipEvent({
  DeviceLocation? location,
  String device = 'brave_phone',
  String? os = 'Android',
  String? profileId = profile,
}) =>
    ClipRequested(
        VideoClip.restored(
          id: 'clip-1',
          cameraId: 'cam',
          cameraLabel: 'Back camera',
          before: const Duration(seconds: 15),
          after: const Duration(seconds: 15),
          past: null,
          full: ClipMedia(
            url: 'blob:clip',
            start: Duration.zero,
            end: const Duration(seconds: 30),
          ),
        ),
        id: 'event-1',
        deviceId: device,
        profileId: profileId,
      )
      ..location = location
      ..os = os;

final lisbon = DeviceLocation(
  latitude: 38.7223,
  longitude: -9.1393,
  accuracy: 20,
  source: LocationSource.device,
  time: DateTime(2026, 10, 7, 9),
);

void main() {
  group('the clip player\'s end', () {
    late List<String> deleted;
    late bool deleteResult;

    setUp(() {
      deleted = [];
      deleteResult = true;
    });

    Future<void> show(
      WidgetTester tester,
      ClipRequested event, {
      String? profileId = profile,
      double width = 320,
      double scale = 1,
    }) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        EventDetailsScope(
          profileId: profileId,
          thisDevice: 'happy_tidy_gadget',
          tiles: const SizedBox(),
          deleteEvent: (e) async {
            deleted.add(e.id);
            return deleteResult;
          },
          child: MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 800),
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showClipPlayer(context, event),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Future<void> reveal(WidgetTester tester, Finder f) async {
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
    }

    testWidgets('a located event shows its map, with a marker, and where '
        'the position came from', (tester) async {
      await show(tester, clipEvent(location: lisbon));
      await reveal(tester, find.byKey(const Key('event-map')));
      expect(find.byKey(const Key('event-map-marker')), findsOneWidget);
      expect(find.byKey(const Key('event-no-location')), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const Key('event-location-text'))).data,
        "38.72230, -9.13930 · The device's position · ±20 m",
      );
      expect(
        tester.getSize(find.byKey(const Key('event-map'))).height,
        EventMap.height,
      );
    });

    testWidgets('a pinned position says so', (tester) async {
      await show(
        tester,
        clipEvent(
          location: DeviceLocation(
            latitude: 1,
            longitude: 2,
            source: LocationSource.map,
            time: DateTime(2026),
            pinned: true,
          ),
        ),
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('event-location-text'))).data,
        '1.00000, 2.00000 · Pinned',
      );
    });

    testWidgets('an event without a location says so instead', (tester) async {
      await show(tester, clipEvent());
      expect(find.byKey(const Key('event-map')), findsNothing);
      expect(find.text('No location for this event'), findsOneWidget);
    });

    testWidgets('the device: its OS icon and name, its ID and presence', (
      tester,
    ) async {
      await show(tester, clipEvent());
      await reveal(tester, find.byKey(const Key('event-device')));
      expect(
        tester.widget<Icon>(find.byKey(const Key('event-device-icon'))).icon,
        Icons.android,
      );
      expect(find.text('brave_phone'), findsOneWidget);
      expect(find.text('Android'), findsOneWidget);
      expect(find.byKey(const Key('event-device-presence')), findsOneWidget);
      expect(find.text('this device'), findsNothing);
    });

    testWidgets('signed out: no presence dot and no delete button', (
      tester,
    ) async {
      await show(tester, clipEvent(), profileId: null);
      expect(find.byKey(const Key('event-device')), findsOneWidget);
      expect(find.byKey(const Key('event-device-presence')), findsNothing);
      expect(find.byKey(const Key('delete-event')), findsNothing);
    });

    testWidgets('another profile\'s event has no delete button', (
      tester,
    ) async {
      await show(tester, clipEvent(profileId: 'other_profile'));
      expect(find.byKey(const Key('delete-event')), findsNothing);
    });

    testWidgets('Delete asks first: Cancel keeps it; Delete deletes it, '
        'closes the player and says so', (tester) async {
      await show(tester, clipEvent(location: lisbon));
      final button = find.byKey(const Key('delete-event'));
      await reveal(tester, button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('delete-event-dialog')), findsOneWidget);
      expect(
        find.text('Delete this event? It will be hidden on every device.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull, reason: 'fits 320 dp');

      await tester.tap(find.byKey(const Key('delete-event-cancel')));
      await tester.pumpAndSettle();
      expect(deleted, isEmpty);
      expect(find.byType(ClipPlayerDialog), findsOneWidget);

      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-event-confirm')));
      await tester.pumpAndSettle();
      expect(deleted, ['event-1']);
      expect(find.byType(ClipPlayerDialog), findsNothing);
      expect(find.text('Event deleted on every device'), findsOneWidget);
    });

    testWidgets('nothing deleted: the player stays', (tester) async {
      deleteResult = false;
      await show(tester, clipEvent());
      final button = find.byKey(const Key('delete-event'));
      await reveal(tester, button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-event-confirm')));
      await tester.pumpAndSettle();
      expect(find.byType(ClipPlayerDialog), findsOneWidget);
      expect(find.text('Event already deleted'), findsOneWidget);
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets('it fits 320 dp at ${scale}x text', (tester) async {
        await show(tester, clipEvent(location: lisbon), scale: scale);
        for (final key in ['event-map', 'event-device', 'delete-event']) {
          await reveal(tester, find.byKey(Key(key)));
          expect(tester.takeException(), isNull, reason: key);
          expect(
            tester.getTopRight(find.byKey(Key(key))).dx,
            lessThanOrEqualTo(320),
            reason: key,
          );
        }
      });
    }
  });

  testWidgets('in the app: deleting an event hides it from the timeline '
      'and its count', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final storage = newIdbFactoryMemory();
    final noon = DateTime(2026, 10, 7, 12);
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
          'profileId': profile,
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

    // As the player's Delete event button does.
    final scope = tester.widget<EventDetailsScope>(
      find.byType(EventDetailsScope),
    );
    expect(scope.profileId, profile);
    final home = tester.widget<HomeScreen>(find.byType(HomeScreen));
    final motion = home.log.events.firstWhere((e) => e.id == 'phone-0');
    bool? result;
    scope.deleteEvent!(motion).then((r) => result = r);
    await tester.pump();
    await settleStorage(tester);
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(find.text('Phone motion'), findsNothing);
    expect(find.text('Phone door'), findsOneWidget);
    final [shown, all] = before.split(' / ').map(int.parse).toList();
    expect(count(), '${shown - 1} / ${all - 1}');
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

    void inCloud(Map<String, Object?> event) =>
        backend.uploads['$identity/${CloudSync.eventKey(event)}'] = (
          bytes: json(event),
          contentType: 'application/json',
        );

    Map<String, Object?> cloudCopy(Map<String, Object?> event) => decode(
      backend.uploads['$identity/${CloudSync.eventKey(event)}']!.bytes,
    );

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

    test('deleting an event hides it (and the suggestions about its clip), '
        'uploads it deleted, publishes it, and keeps it hidden after a '
        'full fetch and a restart', () async {
      final clip = {
        ...phoneEvent('phone-b', ago: 30000),
        'type': 'clip_requested',
        'clipId': 'phone-clip',
      };
      final other = phoneEvent('phone-a');
      final suggestion = {
        ...phoneEvent('suggest-b', ago: 20000),
        'deviceId': 'zesty_kettle',
        'type': SubjectSuggestion.suggestionType,
        'clipEventId': 'phone-b',
        'annotationId': 'a1',
        'subjectName': 'Rex',
        'confidence': 0.9,
      };
      for (final e in [clip, other, suggestion]) {
        inCloud(e);
      }
      await auth.signIn();
      await sync.idle();
      await persistence.flush();
      await until(() => live.state == LiveSyncState.connected);
      expect(shown(), containsAll(['phone-a', 'phone-b']));

      expect(await persistence.deleteEvent('phone-b', profileId: '1'), isTrue);
      final store = await persistence.store;
      for (final id in ['phone-b', 'suggest-b']) {
        expect(shown(), isNot(contains(id)));
        expect(
          AppEvent.isDeletedRecord((await store.getEvent(id))!),
          isTrue,
          reason: id,
        );
      }
      expect(shown(), contains('phone-a'), reason: 'the device stays');
      expect(
        AppEvent.isDeletedRecord((await store.getEvent('phone-a'))!),
        isFalse,
      );
      // Again: nothing more to delete.
      expect(await persistence.deleteEvent('phone-b', profileId: '1'), isFalse);

      await sync.idle();
      expect(AppEvent.isDeletedRecord(cloudCopy(clip)), isTrue);
      expect(AppEvent.isDeletedRecord(cloudCopy(suggestion)), isTrue);
      expect(AppEvent.isDeletedRecord(cloudCopy(other)), isFalse);
      final published = {
        for (final m in broker.last.sent)
          (m['event']! as Map)['id']: (m['event']! as Map)['deletedAt'],
      };
      expect(published['phone-b'], isA<int>());

      sync.reconnect();
      await sync.idle();
      await persistence.flush();
      expect(shown(), ['phone-a']);

      final restarted = EventLog(AppEventBus().stream);
      final reopened = open();
      addTearDown(() {
        reopened.dispose();
        restarted.dispose();
      });
      await reopened.restore(restarted);
      expect([for (final e in restarted.events) e.id], ['phone-a']);
    });

    test('this device\'s own event can be deleted', () async {
      bus.publish(AppEvent(icon: Icons.circle, title: 'Here')..profileId = '1');
      await persistence.flush();
      final id = log.events.single.id;
      expect(await persistence.deleteEvent(id, profileId: '1'), isTrue);
      expect(log.events, isEmpty);
    });

    test(
      'another profile\'s event, or an unknown one, isn\'t deleted',
      () async {
        final a = phoneEvent('phone-a');
        inCloud(a);
        await auth.signIn();
        await pass();
        expect(
          await persistence.deleteEvent('phone-a', profileId: 'other'),
          isFalse,
        );
        expect(await persistence.deleteEvent('nope', profileId: '1'), isFalse);
        expect(shown(), ['phone-a']);
      },
    );

    test('an event deleted on another device hides here; an older copy '
        'that isn\'t deleted doesn\'t bring it back', () async {
      final a = phoneEvent('phone-a');
      final b = phoneEvent('phone-b', ago: 30000);
      inCloud(a);
      inCloud(b);
      await auth.signIn();
      await pass();
      expect(shown(), containsAll(['phone-a', 'phone-b']));

      inCloud({...a, 'deletedAt': now()});
      await pass();
      expect(shown(), ['phone-b']);

      inCloud({...a, 'title': 'Tagged on the phone'});
      await pass();
      expect(shown(), ['phone-b'], reason: 'deletion sticks');
      await pass();
      expect(AppEvent.isDeletedRecord(cloudCopy(a)), isTrue);
    });
  });
}
