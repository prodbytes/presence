import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/auth/account_sheet.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/identity/device_os.dart';

import 'fakes.dart';

/// An event recorded on [device] for [profile].
AppEvent eventOf(
  String device, {
  String profile = 'automatic_paranoid_axolotl',
  int minutesAgo = 0,
  String? os,
}) => AppEvent(
  icon: Icons.directions_run,
  title: 'Motion',
  time: DateTime(2026, 10, 5, 12).subtract(Duration(minutes: minutesAgo)),
  deviceId: device,
  userId: '1',
  profileId: profile,
)..os = os;

void main() {
  group('profileDevices', () {
    test('this device first, then the profile\'s other devices sorted', () {
      final events = [
        eventOf('zesty_calm_kettle'),
        eventOf('brave_quiet_lamp', minutesAgo: 1),
        eventOf('zesty_calm_kettle', minutesAgo: 2),
        eventOf('happy_tidy_gadget', minutesAgo: 3),
      ];
      expect(
        profileDevices(
          events,
          profileId: 'automatic_paranoid_axolotl',
          thisDevice: 'happy_tidy_gadget',
        ),
        ['happy_tidy_gadget', 'brave_quiet_lamp', 'zesty_calm_kettle'],
      );
    });

    test('leaves out other profiles\' events and events without a device', () {
      final events = [
        eventOf('brave_quiet_lamp', profile: 'other_profile_owl'),
        AppEvent(
          icon: Icons.login,
          title: 'Signed in',
          time: DateTime(2026, 10, 5),
          profileId: 'automatic_paranoid_axolotl',
        ),
      ];
      expect(
        profileDevices(
          events,
          profileId: 'automatic_paranoid_axolotl',
          thisDevice: 'mine',
        ),
        ['mine'],
      );
      expect(
        profileDevices(events, profileId: 'automatic_paranoid_axolotl'),
        isEmpty,
      );
    });
  });

  group('profileDeviceDetails', () {
    test("each device's OS and latest event, from its events", () {
      final events = [
        eventOf('brave_quiet_lamp', minutesAgo: 5),
        eventOf('brave_quiet_lamp', minutesAgo: 9, os: 'Android'),
        eventOf('brave_quiet_lamp', minutesAgo: 30, os: 'iOS'),
        eventOf('zesty_calm_kettle', minutesAgo: 2, profile: 'other_owl'),
      ];
      expect(
        profileDeviceDetails(
          events,
          profileId: 'automatic_paranoid_axolotl',
          thisDevice: 'happy_tidy_gadget',
        ),
        [
          // No events yet: this device's own OS.
          (id: 'happy_tidy_gadget', os: DeviceOs.current, lastEvent: null),
          (
            id: 'brave_quiet_lamp',
            os: 'Android',
            lastEvent: DateTime(2026, 10, 5, 11, 55),
          ),
        ],
      );
    });

    test('an older device without an OS on its events has none', () {
      expect(
        profileDeviceDetails([
          eventOf('brave_quiet_lamp'),
        ], profileId: 'automatic_paranoid_axolotl').single.os,
        isNull,
      );
    });
  });

  testWidgets("the device list shows each device's OS icon and latest event, "
      'and fits 320 dp', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final auth = FakeAuthService.signedIn();
    final roles = RolesService(
      auth: auth,
      client: FakeRolesClient(),
      oidcClient: true,
    );
    final events = StreamController<AppEvent>();
    final log = EventLog(events.stream)
      ..addHistory([
        eventOf('brave_quiet_lamp', minutesAgo: 5, os: 'Android'),
        eventOf(
          'calm_sunny_radio_with_a_long_name',
          os: 'Web (Firefox, Windows)',
        ),
        eventOf('zesty_calm_kettle', minutesAgo: 60 * 26),
      ]);
    addTearDown(() {
      log.dispose();
      events.close();
      roles.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountSheet(
            auth: auth,
            roles: roles,
            log: log,
            deviceId: 'happy_tidy_gadget',
            now: () => DateTime(2026, 10, 5, 12),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    IconData? icon(String device) =>
        tester.widget<Icon>(find.byKey(Key('profile-device-os-$device'))).icon;
    String last(String device) => tester
        .widget<Text>(find.byKey(Key('profile-device-last-$device')))
        .textSpan!
        .toPlainText();

    expect(icon('brave_quiet_lamp'), Icons.android);
    expect(last('brave_quiet_lamp'), contains('Android · '));
    expect(last('brave_quiet_lamp'), 'Android · 5 min ago');
    expect(icon('calm_sunny_radio_with_a_long_name'), Icons.language);
    expect(
      last('calm_sunny_radio_with_a_long_name'),
      'Web (Firefox, Windows) · just now',
    );
    // Older events without an OS: a generic icon, and just the time.
    expect(icon('zesty_calm_kettle'), Icons.devices_other);
    expect(last('zesty_calm_kettle'), '1 d ago');
    // This device, without events: its own OS, and none yet.
    expect(icon('happy_tidy_gadget'), DeviceOs.iconOf(DeviceOs.current));
    expect(last('happy_tidy_gadget'), '${DeviceOs.current} · No events');

    // The exact time is in the tooltip.
    expect(
      find.byWidgetPredicate(
        (w) => w is Tooltip && w.message == '2026-10-05 11:55:00',
      ),
      findsOneWidget,
    );
  });

  testWidgets('at a large system font the device list fits 320 dp, and the '
      'age is scaled once, like the rest of its line', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final now = DateTime(2026, 10, 5, 12);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 800),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: SingleChildScrollView(
              child: ProfileDevices(
                profile: 'automatic_paranoid_axolotl',
                now: () => now,
                devices: [
                  (
                    id: 'calm_sunny_radio_with_a_long_name',
                    os: 'Web (Firefox, Windows)',
                    lastEvent: now.subtract(const Duration(minutes: 5)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final line = find.byKey(
      const Key('profile-device-last-calm_sunny_radio_with_a_long_name'),
    );
    // One plain line of text: no widget inside it to scale its part again.
    expect(
      find.descendant(of: line, matching: find.byType(Text)),
      findsNothing,
    );
    final span = tester.widget<Text>(line).textSpan! as TextSpan;
    expect(span.children!.whereType<WidgetSpan>(), isEmpty);
    expect(span.toPlainText(), 'Web (Firefox, Windows) · 5 min ago');
    // The exact time is on the whole line.
    expect(
      find.ancestor(
        of: line,
        matching: find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == '2026-10-05 11:55:00',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the sheet shows the profile and its devices', (tester) async {
    final auth = FakeAuthService.signedIn();
    final roles = RolesService(
      auth: auth,
      client: FakeRolesClient(),
      oidcClient: true,
    );
    final events = StreamController<AppEvent>();
    final log = EventLog(events.stream)
      ..addHistory([
        eventOf('brave_quiet_lamp'),
        eventOf('zesty_calm_kettle', profile: 'other_profile_owl'),
      ]);
    addTearDown(() {
      log.dispose();
      events.close();
      roles.dispose();
    });

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
      tester.widget<SelectableText>(find.byKey(const Key('profile-id'))).data,
      'automatic_paranoid_axolotl',
    );
    expect(find.text('2 devices'), findsOneWidget);
    expect(
      find.byKey(const Key('profile-device-happy_tidy_gadget')),
      findsOneWidget,
    );
    expect(find.text('this device'), findsOneWidget);
    expect(
      find.byKey(const Key('profile-device-brave_quiet_lamp')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('profile-device-zesty_calm_kettle')),
      findsNothing,
    );

    // A device seen later joins the list.
    events.add(eventOf('calm_sunny_radio'));
    await tester.pumpAndSettle();
    expect(find.text('3 devices'), findsOneWidget);
  });
}
