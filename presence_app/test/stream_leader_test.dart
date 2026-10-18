import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/auth/account_sheet.dart';
import 'package:presence_app/blink_settings.dart';
import 'package:presence_app/cloud/device_slots.dart';

/// The profile's leading streamer (specs/streamer-leader.md): read from the
/// auth API's answers, labelled in the device list, first among Blink's
/// streamers.
void main() {
  const pi = 'calm_quiet_otter';
  const other = 'brave_little_lamp';

  test("the leader comes with the devices in the auth API's answer", () {
    final slots = DeviceSlots.fromJson({
      'deviceLimit': 25,
      'devices': [other, pi],
      'streamLeader': {'device': pi, 'seenAt': 1791982808532},
    });
    expect(slots?.leader, pi);
    expect(
      slots,
      const DeviceSlots(limit: 25, devices: [other, pi], leader: pi),
    );
    // Another leader is another answer, for the sheet to show.
    expect(
      slots == const DeviceSlots(limit: 25, devices: [other, pi]),
      isFalse,
    );
    // None, or something else there: no leader.
    expect(
      DeviceSlots.fromJson({
        'deviceLimit': 25,
        'devices': [pi],
      })?.leader,
      isNull,
    );
    expect(
      DeviceSlots.fromJson({
        'deviceLimit': 25,
        'devices': [pi],
        'streamLeader': 'nonsense',
      })?.leader,
      isNull,
    );
  });

  testWidgets('the device list labels the leader, with what it means', (
    tester,
  ) async {
    final now = DateTime(2026, 10, 18, 12);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileDevices(
            now: () => now,
            leader: pi,
            devices: [
              (id: pi, os: 'Linux', lastEvent: now, memoryMb: null),
              (id: other, os: 'Linux', lastEvent: now, memoryMb: null),
            ],
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('profile-device-leader-$pi')), findsOneWidget);
    expect(find.byKey(const Key('profile-device-leader-$other')), findsNothing);
    expect(find.text('leader'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Tooltip &&
            (w.message ?? '').startsWith("The profile's leading streamer"),
      ),
      findsOneWidget,
    );
  });

  test("Blink's streamers: the leader first, since only it streams", () {
    expect(BlinkSettings.leaderFirst([other, pi], pi), [pi, other]);
    expect(BlinkSettings.leaderFirst([other, pi], null), [other, pi]);
    // A leader that isn't one of them (not Linux) changes nothing.
    expect(BlinkSettings.leaderFirst([other], pi), [other]);
  });
}
