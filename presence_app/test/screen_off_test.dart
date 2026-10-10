import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/main.dart';
import 'package:presence_app/screen_off.dart';

import 'camera_pause_test.dart' show pumpGate;
import 'fakes.dart';

/// Records what the mode button's Unattended asks of the platform.
class FakeScreenOff implements ScreenOff {
  FakeScreenOff({this.supported = true});

  @override
  final bool supported;

  final List<bool> calls = [];

  @override
  Future<void> set(bool off) async => calls.add(off);
}

void main() {
  Future<FakeCameraSource> pumpApp(
    WidgetTester tester,
    FakeScreenOff screen,
  ) async {
    final camera = FakeCameraSource('Main');
    await pumpGate(
      tester,
      PresenceApp(
        consentGiven: true,
        cameras: openFakes([camera]),
        auth: FakeAuthService(),
        rolesClient: FakeRolesClient(),
        mapTiles: const SizedBox(),
        locator: NoLocation(),
        screenOff: screen,
      ),
    );
    await tester.tap(find.byKey(const Key('google-sign-in')));
    await tester.pumpAndSettle();
    return camera;
  }

  final mode = find.byKey(const Key('show-all'));
  final cover = find.byKey(const Key('screen-off-cover'));
  IconData? icon(WidgetTester tester) => tester
      .widget<Icon>(find.descendant(of: mode, matching: find.byType(Icon)))
      .icon;

  testWidgets('the mode button cycles One, All, Unattended, Stopped', (
    tester,
  ) async {
    final screen = FakeScreenOff();
    final camera = await pumpApp(tester, screen);
    // No separate Screen off button: it's one of the modes.
    expect(find.byKey(const Key('screen-off')), findsNothing);

    expect(icon(tester), Icons.crop_square);
    await tester.tap(mode);
    await tester.pumpAndSettle();
    expect(icon(tester), Icons.grid_view);
    expect(
      find.byTooltip('Turn the screen off (capture goes on)'),
      findsOneWidget,
    );

    // Unattended: the screen off, the camera still open.
    await tester.tap(mode);
    await tester.pumpAndSettle();
    expect(screen.calls, [true]);
    expect(cover, findsOneWidget);
    expect(find.textContaining('Tap to wake'), findsOneWidget);
    expect(camera.disposed, isFalse);

    // A tap wakes it for a look, still Unattended.
    await tester.tap(cover);
    await tester.pumpAndSettle();
    expect(screen.calls, [true, false]);
    expect(cover, findsNothing);
    expect(icon(tester), Icons.brightness_2_outlined);
    expect(find.byTooltip('Turn the camera off'), findsOneWidget);

    // Untouched, it goes dark again.
    await tester.pump(HomeScreen.wakeFor);
    await tester.pumpAndSettle();
    expect(screen.calls, [true, false, true]);
    expect(cover, findsOneWidget);

    // Woken, the button moves on to Stopped: the screen on, the camera off.
    await tester.tap(cover);
    await tester.pumpAndSettle();
    expect(screen.calls, [true, false, true, false]);
    await tester.tap(mode);
    await tester.pumpAndSettle();
    expect(screen.calls, [true, false, true, false]);
    expect(cover, findsNothing);
    expect(icon(tester), Icons.videocam_off);
    expect(camera.disposed, isTrue);
    expect(find.byKey(const Key('camera-paused')), findsOneWidget);

    // Stopped stays lit, and goes back to One.
    await tester.pump(HomeScreen.wakeFor);
    await tester.pumpAndSettle();
    expect(cover, findsNothing);
    await tester.tap(mode);
    await tester.pumpAndSettle();
    expect(icon(tester), Icons.crop_square);
  });

  testWidgets('no Unattended where the platform can\'t', (tester) async {
    final screen = FakeScreenOff(supported: false);
    await pumpApp(tester, screen);
    await tester.tap(mode);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Turn the camera off'), findsOneWidget);
    await tester.tap(mode);
    await tester.pumpAndSettle();
    expect(icon(tester), Icons.videocam_off);
    expect(screen.calls, isEmpty);
    expect(cover, findsNothing);
  });
}
