import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:idb_shim/idb_shim.dart';

import 'package:presence_app/auth/account_sheet.dart';
import 'package:presence_app/auth/payments_client.dart';
import 'package:presence_app/auth/plan_notice.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/auth/store_billing.dart';
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

/// Slots with a small limit: [first] and [second] show, [third] doesn't.
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
      expect(freeSlots.plan, Plan.free);
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

    test('the plans: Free 10, Premium 25, Pro 50', () {
      expect(Plan.free.deviceLimit, 10);
      expect(Plan.premium.deviceLimit, 25);
      expect(Plan.pro.deviceLimit, 50);
      expect(Plan.ofLimit(10), Plan.free);
      expect(Plan.ofLimit(25), Plan.premium);
      expect(Plan.ofLimit(50), Plan.pro);
      expect(Plan.free.next, Plan.premium);
      expect(Plan.premium.next, Plan.pro);
      expect(Plan.pro.next, isNull);
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

    test(
      'past the plan\'s limit: refused, with the slots that say so',
      () async {
        final cognito = CognitoCredentials(
          region: 'us-east-1',
          api: Uri.parse('https://presence.example'),
          deviceId: () async => third,
          client: MockClient(
            (request) async => http.Response(
              jsonEncode({
                'error': "this device is past your plan's device limit",
                'reason': 'deviceLimit',
                'deviceLimit': 2,
                'devices': [first, second, third],
              }),
              403,
            ),
          ),
        );
        final error = await cognito
            .session('t')
            .then<CognitoException?>(
              (_) => null,
              onError: (Object e) => e as CognitoException,
            );
        expect(error!.pastDeviceLimit, isTrue);
        expect(error.needsSignIn, isFalse);
        expect(error.deviceSlots, freeSlots);

        // Another 403 has no slots.
        final other = CognitoCredentials(
          region: 'us-east-1',
          api: Uri.parse('https://presence.example'),
          client: MockClient(
            (request) async =>
                http.Response('{"error":"presence_user is required"}', 403),
          ),
        );
        final refused = await other
            .session('t')
            .then<CognitoException?>(
              (_) => null,
              onError: (Object e) => e as CognitoException,
            );
        expect(refused!.pastDeviceLimit, isFalse);
      },
    );
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

    test('refreshDevices asks for the slots again, at most every 30 s, and '
        'Sync asks too', () async {
      await auth.signIn();
      await sync.idle();
      final resets = backend.resets;

      // A Pi streamer joined: no event of it here yet.
      backend.deviceSlots = const DeviceSlots(
        limit: 50,
        devices: [first, second],
      );
      sync.refreshDevices();
      await sync.idle();
      expect(backend.resets, resets + 1);
      expect(sync.deviceSlots!.devices, [first, second]);

      sync.refreshDevices();
      await sync.syncAll();
      await sync.idle();
      expect(backend.resets, resets + 1, reason: 'within 30 s');

      now = now.add(const Duration(seconds: 31));
      await sync.syncAll();
      await sync.idle();
      expect(backend.resets, resets + 2);
    });

    test('refreshDevices while Stopped: the slots, and no pass', () async {
      await auth.signIn();
      await sync.idle();
      sync.setHalted(true);
      final listings = backend.listings.length;

      backend.deviceSlots = const DeviceSlots(
        limit: 50,
        devices: [first, second],
      );
      await sync.refreshDevices();
      await sync.idle();
      expect(sync.deviceSlots!.devices, [first, second]);
      expect(sync.halted, isTrue);
      expect(backend.listings.length, listings, reason: 'no pass');
    });

    test('refreshDevices before the sign-in, Stopped: asked once the '
        'profile is known', () async {
      sync.setHalted(true);
      await sync.refreshDevices();
      expect(sync.deviceSlots, isNull);
      await auth.signIn();
      await sync.idle();
      await pumpEventQueue();
      expect(sync.deviceSlots, backend.deviceSlots);
      expect(backend.listings, isEmpty, reason: 'no pass');
    });

    test('refreshDevices: nothing signed out', () async {
      sync.refreshDevices();
      await sync.idle();
      expect(backend.resets, 0);
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
      required Plan plan,
      Future<void> Function()? onCheckAgain,
      PaymentLinks? links,
    }) async {
      final opened = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlanNotice(
              plan: plan,
              email: 'ana@example.com',
              profileId: 'automatic_paranoid_axolotl',
              onCheckAgain: onCheckAgain,
              links: links,
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

    testWidgets('Free: ten devices, the price, and upgrading', (tester) async {
      var checked = 0;
      final opened = await show(
        tester,
        plan: Plan.free,
        onCheckAgain: () async => checked++,
      );
      expect(find.text('Free'), findsOneWidget);
      expect(
        find.textContaining('up to 10 devices share them every 15 minutes'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Premium syncs them instantly'),
        findsOneWidget,
      );
      expect(find.textContaining('up to 25 devices'), findsOneWidget);
      expect(find.textContaining('Pro: up to 50 devices'), findsOneWidget);
      expect(
        find.textContaining(r'US$20 a month, the first week free'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('plan-upgrade')));
      await tester.pump();
      // No links from the payments API: nu01.com.
      expect(opened, [Uri.parse('https://nu01.com')]);
      await tester.tap(find.byKey(const Key('plan-check-again')));
      expect(checked, 1);
    });

    testWidgets('Premium: twenty-five devices, Pro without a link to buy it', (
      tester,
    ) async {
      await show(tester, plan: Plan.premium);
      expect(find.text('Premium'), findsOneWidget);
      expect(find.textContaining('up to 25 devices sync'), findsOneWidget);
      expect(find.textContaining('Pro: up to 50 devices'), findsOneWidget);
      expect(find.byKey(const Key('plan-upgrade')), findsNothing);
      expect(find.byKey(const Key('plan-upgrade-pro-monthly')), findsNothing);
      expect(find.byKey(const Key('plan-check-again')), findsNothing);

      // Premium's links only: still no Pro button.
      await show(
        tester,
        plan: Plan.premium,
        links: const PaymentLinks(monthly: 'https://buy.stripe.com/m00'),
      );
      expect(find.byKey(const Key('plan-upgrade-monthly')), findsNothing);
      expect(find.byKey(const Key('plan-upgrade-pro-monthly')), findsNothing);
    });

    testWidgets("Premium: Pro's buttons once the payments API has its links", (
      tester,
    ) async {
      final opened = await show(
        tester,
        plan: Plan.premium,
        onCheckAgain: () async {},
        links: const PaymentLinks(
          monthly: 'https://buy.stripe.com/m00',
          proYearly: 'https://buy.stripe.com/proyearly00',
        ),
      );
      expect(find.byKey(const Key('plan-upgrade-pro-monthly')), findsNothing);
      expect(find.text('Pro yearly'), findsOneWidget);
      expect(find.byKey(const Key('plan-check-again')), findsOneWidget);
      await tester.tap(find.byKey(const Key('plan-upgrade-pro-yearly')));
      await tester.pump();
      expect(opened.single.path, '/proyearly00');
      expect(
        opened.single.queryParameters['prefilled_email'],
        'ana@example.com',
      );
    });

    testWidgets('Pro: fifty devices, nothing to buy', (tester) async {
      await show(
        tester,
        plan: Plan.pro,
        links: const PaymentLinks(
          monthly: 'https://buy.stripe.com/m00',
          proMonthly: 'https://buy.stripe.com/pm00',
        ),
      );
      expect(find.text('Pro'), findsOneWidget);
      expect(find.textContaining('up to 50 devices sync'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
    });

    testWidgets('a button per plan the payments API offers', (tester) async {
      const monthly = 'https://buy.stripe.com/monthly00';
      const yearly = 'https://buy.stripe.com/yearly00';
      var opened = await show(
        tester,
        plan: Plan.free,
        links: const PaymentLinks(monthly: monthly, yearly: yearly),
      );
      expect(find.byKey(const Key('plan-upgrade')), findsNothing);
      expect(find.text('Premium monthly'), findsOneWidget);
      await tester.tap(find.byKey(const Key('plan-upgrade-yearly')));
      await tester.pump();
      expect(opened.single.origin, 'https://buy.stripe.com');
      expect(opened.single.path, '/yearly00');
      expect(opened.single.queryParameters, {
        'prefilled_email': 'ana@example.com',
        'locked_prefilled_email': 'true',
        'client_reference_id': 'automatic_paranoid_axolotl',
      });

      // Only the plans with a link.
      opened = await show(
        tester,
        plan: Plan.free,
        links: const PaymentLinks(monthly: monthly),
      );
      expect(find.byKey(const Key('plan-upgrade-yearly')), findsNothing);
      await tester.tap(find.byKey(const Key('plan-upgrade-monthly')));
      await tester.pump();
      expect(opened.single.path, '/monthly00');

      // None: nu01.com, as before.
      await show(tester, plan: Plan.free, links: const PaymentLinks());
      expect(find.byKey(const Key('plan-upgrade')), findsOneWidget);
    });
  });

  group('HiddenDevicesLine', () {
    Future<List<Uri>> show(
      WidgetTester tester, {
      Plan plan = Plan.free,
      int hidden = 0,
      bool pastLimit = false,
      PaymentLinks? links,
    }) async {
      final opened = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HiddenDevicesLine(
              plan: plan,
              hidden: hidden,
              pastLimit: pastLimit,
              email: 'ana@example.com',
              profileId: profile,
              links: links,
              channel: PurchaseChannel.stripe,
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

    testWidgets('nothing when nothing is hidden', (tester) async {
      await show(tester);
      expect(find.byKey(const Key('hidden-devices-line')), findsNothing);
    });

    testWidgets('how many are hidden, quietly, and a link to upgrade', (
      tester,
    ) async {
      final opened = await show(tester, hidden: 1);
      expect(find.text('1 device hidden'), findsOneWidget);
      // A muted line, no card or banner.
      expect(find.byType(Card), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      await tester.tap(find.byKey(const Key('hidden-devices-upgrade')));
      await tester.pump();
      // No links from the payments API: nu01.com.
      expect(opened, [Uri.parse('https://nu01.com')]);
    });

    testWidgets('past the limit: this device does not sync', (tester) async {
      await show(tester, pastLimit: true);
      expect(find.text("This device doesn't sync"), findsOneWidget);
    });

    testWidgets("Premium: Pro's checkout once its link is set, never named", (
      tester,
    ) async {
      await show(tester, plan: Plan.premium, hidden: 2);
      expect(find.text('2 devices hidden'), findsOneWidget);
      expect(find.byKey(const Key('hidden-devices-upgrade')), findsNothing);

      final opened = await show(
        tester,
        plan: Plan.premium,
        hidden: 2,
        links: const PaymentLinks(proMonthly: 'https://buy.stripe.com/pm00'),
      );
      expect(find.textContaining('Pro'), findsNothing);
      await tester.tap(find.byKey(const Key('hidden-devices-upgrade')));
      await tester.pump();
      expect(opened.single.path, '/pm00');
    });

    testWidgets('Pro: no link', (tester) async {
      await show(tester, plan: Plan.pro, hidden: 2);
      expect(find.text('2 devices hidden'), findsOneWidget);
      expect(find.byKey(const Key('hidden-devices-upgrade')), findsNothing);
    });
  });

  testWidgets('the account sheet says Free, Premium or Pro, and labels hidden '
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
    expect(find.byKey(const Key('plan-upgrade')), findsOneWidget);
    expect(find.byKey(Key('profile-device-hidden-$third')), findsOneWidget);
    expect(find.byKey(Key('profile-device-hidden-$second')), findsNothing);
    // One quiet line under the list says how many are hidden.
    expect(find.byKey(const Key('hidden-devices-line')), findsOneWidget);
    expect(find.text('1 device hidden'), findsOneWidget);

    client.roles = const [userRole, premiumRole];
    await roles.refresh();
    await tester.pumpAndSettle();
    expect(find.text('Premium'), findsWidgets);
    expect(find.byKey(const Key('plan-upgrade')), findsNothing);

    client.roles = const [userRole, premiumRole, proRole];
    await roles.refresh();
    await tester.pumpAndSettle();
    expect(find.text('Pro'), findsWidgets);
    expect(find.textContaining('up to 50 devices sync'), findsOneWidget);

    // An admin is Pro, even without the premium or pro role.
    client.roles = const [userRole, adminRole];
    await roles.refresh();
    await tester.pumpAndSettle();
    expect(find.text('Pro'), findsWidgets);
    expect(find.byKey(const Key('plan-upgrade')), findsNothing);

    // Nothing hidden: no line.
    log.visibleDevices = null;
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('hidden-devices-line')), findsNothing);
  });
}
