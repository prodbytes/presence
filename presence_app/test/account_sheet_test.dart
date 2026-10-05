import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/auth/account_sheet.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/events.dart';

import 'fakes.dart';

/// An event recorded on [device] for [profile].
AppEvent eventOf(
  String device, {
  String profile = 'automatic_paranoid_axolotl',
  int minutesAgo = 0,
}) => AppEvent(
  icon: Icons.directions_run,
  title: 'Motion',
  time: DateTime(2026, 10, 5, 12).subtract(Duration(minutes: minutesAgo)),
  deviceId: device,
  userId: '1',
  profileId: profile,
);

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
