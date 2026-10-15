import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/main.dart';
import 'package:presence_app/screen_off.dart';

import 'camera_pause_test.dart' show pickMode, pumpGate;
import 'fakes.dart';

/// Records what the Unattended mode asks of the platform.
class FakeScreenOff implements ScreenOff {
  FakeScreenOff({this.supported = true});

  @override
  final bool supported;

  final List<bool> calls = [];

  @override
  Future<void> set(bool off) async => calls.add(off);
}

void main() {
  Future<void> pumpApp(WidgetTester tester, FakeScreenOff screen) async {
    await pumpGate(
      tester,
      PresenceApp(
        consentGiven: true,
        cameras: openFakes([FakeCameraSource('Main')]),
        auth: FakeAuthService(),
        rolesClient: FakeRolesClient(),
        mapTiles: const SizedBox(),
        locator: NoLocation(),
        screenOff: screen,
      ),
    );
    await tester.tap(find.byKey(const Key('google-sign-in')));
    await tester.pumpAndSettle();
  }

  final cover = find.byKey(const Key('screen-off-cover'));

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('Unattended darkens the screen; a tap wakes it a while', (
    tester,
  ) async {
    final screen = FakeScreenOff();
    await pumpApp(tester, screen);
    await pickMode(tester, CameraMode.all);
    expect(cover, findsNothing);
    await pickMode(tester, CameraMode.unattended);
    expect(screen.calls, [true]);
    expect(cover, findsOneWidget);
    expect(find.textContaining('Tap to wake'), findsOneWidget);

    // Woken, still Unattended.
    await tap(tester, cover);
    expect(screen.calls, [true, false]);
    expect(cover, findsNothing);
    expect(find.byKey(const Key('camera-mode')), findsOneWidget);

    // Touches keep it on; 15 s without one, it's dark again.
    await tester.pump(const Duration(seconds: 10));
    await tester.tapAt(const Offset(200, 200));
    await tester.pump(const Duration(seconds: 10));
    expect(cover, findsNothing);
    await tester.pump(const Duration(seconds: 6));
    expect(cover, findsOneWidget);
    expect(screen.calls, [true, false, true]);

    // Woken and moved on: Stopped, the screen back for good.
    await tap(tester, cover);
    await pickMode(tester, CameraMode.stopped);
    expect(cover, findsNothing);
    expect(screen.calls.last, isFalse);
    expect(find.byKey(const Key('camera-paused')), findsOneWidget);
    await tester.pump(const Duration(seconds: 20));
    expect(cover, findsNothing);
  });

  testWidgets('Unattended covers the screen where it can\'t go off', (
    tester,
  ) async {
    await pumpApp(tester, FakeScreenOff(supported: false));
    await pickMode(tester, CameraMode.unattended);
    expect(cover, findsOneWidget);
  });
}
