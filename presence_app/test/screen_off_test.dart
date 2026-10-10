import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/main.dart';
import 'package:presence_app/screen_off.dart';

import 'camera_pause_test.dart' show pumpGate;
import 'fakes.dart';

/// Records what the Screen off button asks of the platform.
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

  testWidgets('Screen off darkens the app until a tap', (tester) async {
    final screen = FakeScreenOff();
    await pumpApp(tester, screen);

    final button = find.byKey(const Key('screen-off'));
    expect(button, findsOneWidget);
    expect(
      find.byTooltip('Turn the screen off (capture goes on)'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('screen-off-cover')), findsNothing);

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(screen.calls, [true]);
    expect(find.byKey(const Key('screen-off-cover')), findsOneWidget);
    expect(find.textContaining('Tap to wake'), findsOneWidget);

    await tester.tap(find.byKey(const Key('screen-off-cover')));
    await tester.pumpAndSettle();
    expect(screen.calls, [true, false]);
    expect(find.byKey(const Key('screen-off-cover')), findsNothing);
  });

  testWidgets('no Screen off button where the platform can\'t', (tester) async {
    await pumpApp(tester, FakeScreenOff(supported: false));
    expect(find.byKey(const Key('show-all')), findsOneWidget);
    expect(find.byKey(const Key('screen-off')), findsNothing);
  });
}
