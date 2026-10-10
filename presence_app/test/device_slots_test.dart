import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:idb_shim/idb_shim.dart';

import 'package:presence_app/auth/account_sheet.dart';
import 'package:presence_app/auth/plan_notice.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/cloud/cloud_sync.dart';
import 'package:presence_app/cloud/cognito.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/storage/event_store.dart';
import 'package:presence_app/storage/media_store.dart';

import 'fakes.dart';

const profile = 'automatic_paranoid_axolotl';
const first = 'first_quiet_gadget';
const second = 'second_bold_lamp';
const third = 'third_shy_kettle';

/// A free profile's slots: [first] and [second] show, [third] doesn't.
const freeSlots = DeviceSlots(limit: 2, devices: [first, second, third]);

AppEvent eventOn(String device, {int minute = 0}) => AppEvent(
  icon: Icons.directions_run,
  title: 'Motion on $device',
  time: DateTime(2026, 10, 10, 12, minute),
  deviceId: device,
  userId: '1',
  profileId: profile,
);

void main() {
  group('DeviceSlots', () {
    test('the first [limit] devices show', () {
      expect(freeSlots.shown, [first, second]);
      expect(freeSlots.shows(first), isTrue);
      expect(freeSlots.shows(third), isFalse);
      expect(freeSlots.shows('unknown_new_device'), isFalse);
      expect(freeSlots.full, isTrue);
      expect(freeSlots.premium, isFalse);
    });

    test('a device that shows sees those that show; one past the limit, '
        'only itself', () {
      expect(freeSlots.visibleFrom(first), {first, second});
      expect(freeSlots.visibleFrom(third), {third});
    });

    test("read from the auth API's answer; an older one says nothing", () {
      expect(
        DeviceSlots.fromJson({
          'deviceLimit': 50,
          'devices': [first, second],
        }),
        const DeviceSlots(limit: 50, devices: [first, second]),
      );
      expect(DeviceSlots.fromJson({'identityId': 'x', 'token': 't'}), isNull);
    });
  });

  group('CognitoCredentials', () {
    test('names this device and keeps the slots the answer lists', () async {
      final bodies = <String>[];
      final cognito = CognitoCredentials(
        region: 'us-east-1',
        api: Uri.parse('https://presence.example'),
        deviceId: () async => first,
        now: () => DateTime.utc(2026, 10, 10),
        client: MockClient((request) async {
          if (request.url.host == 'presence.example') {
            bodies.add(request.body);
            if (request.url.path == '/api/auth/profile/devices/remove') {
              return http.Response(
                jsonEncode({
                  'deviceLimit': 2,
                  'devices': [first],
                }),
                200,
              );
            }
            return http.Response(
              jsonEncode({
                'identityId': 'us-east-1:p',
                'token': 'oidc',
                'deviceLimit': 2,
                'devices': [first, second],
                'tier': 'free',
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'IdentityId': 'us-east-1:p',
              'Credentials': {
                'AccessKeyId': 'AKIA',
                'SecretKey': 'secret',
                'Expiration': 4102444800,
              },
            }),
            200,
          );
        }),
      );
      final session = await cognito.session('t');
      expect(bodies, [first]);
      expect(
        session.deviceSlots,
        const DeviceSlots(limit: 2, devices: [first, second]),
      );

      expect(
        await cognito.removeDevice('t', second),
        const DeviceSlots(limit: 2, devices: [first]),
      );
      expect(bodies.last, second);
    });
  });

  group('EventLog.visibleDevices', () {
    late StreamController<AppEvent> bus;
    late EventLog log;
    setUp(() {
      bus = StreamController<AppEvent>.broadcast();
      log = EventLog(bus.stream)
        ..addHistory([
          eventOn(first, minute: 1),
          eventOn(second, minute: 2),
          eventOn(third, minute: 3),
        ]);
    });
    tearDown(() {
      log.dispose();
      bus.close();
    });

    test("hides other devices' events from the profile's", () {
      expect(log.eventsOf(profile), hasLength(3));
      log.visibleDevices = freeSlots.visibleFrom(first);
      expect(log.eventsOf(profile).map((e) => e.deviceId), [second, first]);
      // Every event is still there, for syncing.
      expect(log.events, hasLength(3));

      // Past the limit, only this device's own.
      log.visibleDevices = freeSlots.visibleFrom(third);
      expect(log.eventsOf(profile).map((e) => e.deviceId), [third]);

      log.visibleDevices = null;
      expect(log.eventsOf(profile), hasLength(3));
    });

    test('notifies only when the devices change', () {
      var notified = 0;
      log.addListener(() => notified++);
      log.visibleDevices = {first, second};
      log.visibleDevices = {second, first};
      expect(notified, 1);
    });

    test('lists the hidden devices', () {
      log.visibleDevices = freeSlots.visibleFrom(first);
      expect(hiddenDevices(log, profileId: profile, thisDevice: first), [
        third,
      ]);
    });
  });

  group('CloudSync', () {
    late EventStore store;
    late StreamController<Set<String>?> changes;
    late FakeCloudBackend backend;
    late FakeAuthService auth;
    late CloudSync sync;
    var now = DateTime.utc(2026, 10, 10, 12);

    setUp(() async {
      now = DateTime.utc(2026, 10, 10, 12);
      store = await EventStore.open(newIdbFactoryMemory());
      changes = StreamController<Set<String>?>.broadcast();
      backend = FakeCloudBackend()
        ..deviceSlots = const DeviceSlots(limit: 2, devices: [first]);
      auth = FakeAuthService();
      sync = CloudSync(
        auth: auth,
        backend: backend,
        store: Future.value(store),
        media: Future.value(IdbMediaStore(store)),
        changes: changes.stream,
        debounce: Duration.zero,
        now: () => now,
      );
    });

    tearDown(() {
      sync.dispose();
      changes.close();
      store.close();
    });

    test('takes the slots from its session; none signed out', () async {
      expect(sync.deviceSlots, isNull);
      await auth.signIn();
      await sync.idle();
      expect(sync.deviceSlots, backend.deviceSlots);
      await auth.signOut();
      await sync.idle();
      expect(sync.deviceSlots, isNull);
    });

    test('a device the slots don\'t list, while there\'s room, asks for '
        'them again: once per device, at most every 30 s', () async {
      await auth.signIn();
      await sync.idle();
      final resets = backend.resets;

      // Listed: nothing to ask.
      sync.noticeDevices([first]);
      expect(backend.resets, resets);

      backend.deviceSlots = const DeviceSlots(
        limit: 3,
        devices: [first, second],
      );
      sync.noticeDevices([first, second]);
      await sync.idle();
      expect(backend.resets, resets + 1);
      expect(sync.deviceSlots!.shows(second), isTrue);

      // One still not listed (an older app): asked about once.
      sync.noticeDevices([first, second, third]);
      expect(backend.resets, resets + 1, reason: 'within 30 s');
      now = now.add(const Duration(seconds: 31));
      sync.noticeDevices([first, second, third]);
      await sync.idle();
      expect(backend.resets, resets + 2);
      now = now.add(const Duration(minutes: 5));
      sync.noticeDevices([first, second, third]);
      expect(backend.resets, resets + 2);
    });

    test('full: a device the slots don\'t list won\'t show, so nothing is '
        'asked', () async {
      backend.deviceSlots = const DeviceSlots(
        limit: 2,
        devices: [first, second],
      );
      await auth.signIn();
      await sync.idle();
      final resets = backend.resets;
      sync.noticeDevices([first, second, third]);
      expect(backend.resets, resets);
    });

    test('a deleted device gives its place to the next', () async {
      backend.deviceSlots = freeSlots;
      await auth.signIn();
      await sync.idle();
      expect(sync.deviceSlots!.shows(third), isFalse);

      await sync.releaseDevice(second);
      expect(backend.removedDevices, [second]);
      expect(sync.deviceSlots!.shows(third), isTrue);
    });
  });

  group('PlanNotice', () {
    Future<List<Uri>> show(
      WidgetTester tester, {
      required bool premium,
      DeviceSlots? slots,
      String? thisDevice,
      int hidden = 0,
    }) async {
      final opened = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlanNotice(
              premium: premium,
              slots: slots,
              thisDevice: thisDevice,
              hidden: hidden,
              openLink: (url) async {
                opened.add(url);
                return true;
              },
            ),
          ),
        ),
      );
      return opened;
    }

    testWidgets('Free: two devices, and signing up at nu01.com', (
      tester,
    ) async {
      final opened = await show(tester, premium: false);
      expect(find.text('Free'), findsOneWidget);
      expect(find.textContaining('up to 2 devices sync'), findsOneWidget);
      expect(find.textContaining('nu01.com'), findsWidgets);
      await tester.tap(find.byKey(const Key('plan-sign-up')));
      await tester.pump();
      expect(opened, [Uri.parse('https://nu01.com')]);
    });

    testWidgets('Premium: fifty devices, no sign-up', (tester) async {
      await show(tester, premium: true);
      expect(find.text('Premium'), findsOneWidget);
      expect(find.textContaining('up to 50 devices'), findsOneWidget);
      expect(find.byKey(const Key('plan-sign-up')), findsNothing);
    });

    testWidgets('says when this device is past the limit', (tester) async {
      await show(tester, premium: false, slots: freeSlots, thisDevice: third);
      expect(
        tester.widget<Text>(find.byKey(const Key('plan-warning'))).data,
        contains('This device is past your first 2'),
      );
    });

    testWidgets('says how many devices are hidden', (tester) async {
      await show(
        tester,
        premium: false,
        slots: freeSlots,
        thisDevice: first,
        hidden: 1,
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('plan-warning'))).data,
        '1 more device syncs, but its events are hidden: Free shows your '
        'first 2.',
      );
    });
  });

  group('DeviceLimitNotice', () {
    late StreamController<AppEvent> bus;
    late EventLog log;
    setUp(() {
      bus = StreamController<AppEvent>.broadcast();
      log = EventLog(bus.stream)
        ..addHistory([eventOn(first), eventOn(second), eventOn(third)]);
    });
    tearDown(() {
      log.dispose();
      bus.close();
    });

    Future<void> show(
      WidgetTester tester,
      DeviceSlots? slots,
      String thisDevice,
    ) async {
      log.visibleDevices = slots?.visibleFrom(thisDevice);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DeviceLimitNotice(
              log: log,
              slots: slots,
              profileId: profile,
              thisDevice: thisDevice,
            ),
          ),
        ),
      );
    }

    testWidgets('nothing when nothing is hidden', (tester) async {
      await show(tester, null, first);
      expect(find.byKey(const Key('device-limit-notice')), findsNothing);
      await show(
        tester,
        const DeviceSlots(limit: 50, devices: [first, second, third]),
        first,
      );
      expect(find.byKey(const Key('device-limit-notice')), findsNothing);
    });

    testWidgets('on a device that shows: how many are hidden, and sign up', (
      tester,
    ) async {
      await show(tester, freeSlots, first);
      expect(find.textContaining("1 device's events are hidden"), findsOne);
      expect(find.byKey(const Key('device-limit-sign-up')), findsOneWidget);
    });

    testWidgets("past the limit: the other devices' events are hidden", (
      tester,
    ) async {
      await show(tester, freeSlots, third);
      expect(
        find.textContaining("Your other devices' events are hidden"),
        findsOne,
      );
    });
  });

  testWidgets('the account sheet says Free or Premium, and labels hidden '
      'devices', (tester) async {
    tester.view.physicalSize = const Size(360, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final auth = FakeAuthService.signedIn();
    final client = FakeRolesClient(const [userRole]);
    final roles = RolesService(auth: auth, client: client, oidcClient: true);
    final bus = StreamController<AppEvent>();
    final log = EventLog(bus.stream)
      ..addHistory([eventOn(first), eventOn(second), eventOn(third)])
      ..visibleDevices = freeSlots.visibleFrom(first);
    addTearDown(() {
      log.dispose();
      bus.close();
      roles.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountSheet(
            auth: auth,
            roles: roles,
            log: log,
            deviceId: first,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('plan-notice')), findsOneWidget);
    expect(find.text('Free'), findsOneWidget);
    expect(find.byKey(const Key('plan-sign-up')), findsOneWidget);
    expect(find.byKey(Key('profile-device-hidden-$third')), findsOneWidget);
    expect(find.byKey(Key('profile-device-hidden-$second')), findsNothing);

    client.roles = const [userRole, premiumRole];
    await roles.refresh();
    await tester.pumpAndSettle();
    expect(find.text('Premium'), findsWidgets);
    expect(find.byKey(const Key('plan-sign-up')), findsNothing);

    // An admin isn't asked to sign up, even without the premium role.
    client.roles = const [userRole, adminRole];
    await roles.refresh();
    await tester.pumpAndSettle();
    expect(find.text('Premium'), findsWidgets);
    expect(find.byKey(const Key('plan-sign-up')), findsNothing);
  });
}
