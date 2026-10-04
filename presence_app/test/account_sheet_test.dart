import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/auth/account_sheet.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/events.dart';

import 'fakes.dart';

/// An event recorded on [device] by [userId].
AppEvent eventOf(String device, {String userId = '1', int minutesAgo = 0}) =>
    AppEvent(
      icon: Icons.directions_run,
      title: 'Motion',
      time: DateTime(2026, 10, 5, 12).subtract(Duration(minutes: minutesAgo)),
      deviceId: device,
      userId: userId,
    );

void main() {
  group('profileDevices', () {
    test('this device first, then the user\'s other devices sorted', () {
      final events = [
        eventOf('zesty_calm_kettle'),
        eventOf('brave_quiet_lamp', minutesAgo: 1),
        eventOf('zesty_calm_kettle', minutesAgo: 2),
        eventOf('happy_tidy_gadget', minutesAgo: 3),
      ];
      expect(
        profileDevices(events, userId: '1', thisDevice: 'happy_tidy_gadget'),
        ['happy_tidy_gadget', 'brave_quiet_lamp', 'zesty_calm_kettle'],
      );
    });

    test('leaves out other users\' events and events without a device', () {
      final events = [
        eventOf('brave_quiet_lamp', userId: '2'),
        AppEvent(
          icon: Icons.login,
          title: 'Signed in',
          time: DateTime(2026, 10, 5),
          userId: '1',
        ),
      ];
      expect(profileDevices(events, userId: '1', thisDevice: 'mine'), ['mine']);
      expect(profileDevices(events, userId: '1'), isEmpty);
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
        eventOf('zesty_calm_kettle', userId: '2'),
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
