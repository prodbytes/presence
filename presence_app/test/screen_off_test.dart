import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/main.dart';
import 'package:presence_app/screen_off.dart';

import 'camera_pause_test.dart' show pumpGate;
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

  final mode = find.byKey(const Key('camera-mode'));
  final cover = find.byKey(const Key('screen-off-cover'));

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('Screen off is the Unattended mode, not a button of its own', (
    tester,
  ) async {
    await pumpApp(tester, FakeScreenOff());
    expect(find.byKey(const Key('screen-off')), findsNothing);
    expect(mode, findsOneWidget);
  });

  testWidgets('Unattended darkens the screen; a tap wakes it a while', (
    tester,
  ) async {
    final screen = FakeScreenOff();
    await pumpApp(tester, screen);
    await tap(tester, mode); // All
    expect(cover, findsNothing);
    await tap(tester, mode); // Unattended
    expect(screen.calls, [true]);
    expect(cover, findsOneWidget);
    expect(find.textContaining('Tap to wake'), findsOneWidget);

    // Woken, still Unattended.
    await tap(tester, cover);
    expect(screen.calls, [true, false]);
    expect(cover, findsNothing);
    expect(find.byTooltip('Stop: no capturing or syncing'), findsOneWidget);

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
    await tap(tester, mode);
    expect(cover, findsNothing);
    expect(screen.calls.last, isFalse);
    expect(find.byTooltip('Back to normal: this camera'), findsOneWidget);
    await tester.pump(const Duration(seconds: 20));
    expect(cover, findsNothing);
  });

  testWidgets('Unattended covers the screen where it can\'t go off', (
    tester,
  ) async {
    await pumpApp(tester, FakeScreenOff(supported: false));
    await tap(tester, mode);
    await tap(tester, mode);
    expect(cover, findsOneWidget);
  });
}
