import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/camera_feeds.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/main.dart';

import 'fakes.dart';

Future<void> pumpGate(WidgetTester tester, PresenceApp app) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app);
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  group('pausing the camera', () {
    test('closes it, records nothing, and reopens it on resume', () async {
      final back = FakeCameraSource('Main');
      final backend = openFakes([back]);
      final config = ConfigController();
      final rig = CameraRig(backend: backend, config: config);
      addTearDown(rig.dispose);
      await rig.load();
      expect(rig.active, back);

      rig.setPaused(true);
      await pumpEventQueue();
      expect(config.camera.paused, isTrue);
      expect(back.disposed, isTrue);
      expect(rig.active, isNull);
      expect(rig.canClip, isFalse);
      expect(rig.readiness.state, ClipReadinessState.paused);

      // Nothing reopens it while paused: a retry, or the app coming back.
      await rig.retry();
      expect(rig.active, isNull);
      expect(backend.opened, hasLength(1));

      rig.setPaused(false);
      await pumpEventQueue();
      expect(rig.active, back);
      expect(backend.opened, hasLength(2));
      expect(rig.readiness.state, ClipReadinessState.ready);
    });

    test('a launch with the camera paused leaves it closed', () async {
      final back = FakeCameraSource('Main');
      final backend = openFakes([back]);
      final config = ConfigController(
        const PresenceConfig(camera: CameraConfig(paused: true)),
      );
      final rig = CameraRig(backend: backend, config: config);
      addTearDown(rig.dispose);
      await rig.load();
      expect(rig.devices, hasLength(1));
      expect(rig.active, isNull);
      expect(rig.busy, isFalse);
      expect(backend.opened, isEmpty);

      rig.setPaused(false);
      await pumpEventQueue();
      expect(rig.active, back);
    });

    test('is kept in the settings', () {
      const camera = CameraConfig(paused: true);
      expect(camera.toJson()['paused'], isTrue);
      expect(CameraConfig.fromJson(camera.toJson()), camera);
      // Older records, without it, aren't paused.
      expect(CameraConfig.fromJson({'brightnessEv': 0.5}).paused, isFalse);
    });

    testWidgets('the view button cycles One, All, None', (tester) async {
      final camera = FakeCameraSource('Main');
      final backend = openFakes([camera]);
      await pumpGate(
        tester,
        PresenceApp(
          consentGiven: true,
          cameras: backend,
          auth: FakeAuthService(),
          rolesClient: FakeRolesClient(),
          mapTiles: const SizedBox(),
          locator: NoLocation(),
        ),
      );
      await tester.tap(find.byKey(const Key('google-sign-in')));
      await tester.pumpAndSettle();
      final button = find.byKey(const Key('show-all'));
      // Icon only: no text, the tooltip says what a tap does.
      IconData? label() => tester
          .widget<Icon>(
            find.descendant(of: button, matching: find.byType(Icon)),
          )
          .icon;
      expect(
        find.descendant(of: button, matching: find.byType(Text)),
        findsNothing,
      );
      for (final text in ['One', 'All', 'None']) {
        expect(find.text(text), findsNothing);
      }
      expect(find.byTooltip('Show all devices'), findsOneWidget);

      expect(label(), Icons.crop_square);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(label(), Icons.grid_view);
      expect(find.byTooltip('Turn the camera off'), findsOneWidget);
      expect(find.textContaining('· live'), findsOneWidget);

      // None: the camera off, the single view, no Clip.
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(label(), Icons.videocam_off);
      expect(find.byTooltip('Turn the camera on'), findsOneWidget);
      expect(camera.disposed, isTrue);
      expect(find.byKey(const Key('camera-paused')), findsOneWidget);
      expect(find.textContaining('· live'), findsNothing);
      expect(find.byTooltip('Clip'), findsNothing);
      expect(find.byTooltip('Camera off: nothing is recorded'), findsOneWidget);
      expect(find.text('Off'), findsNothing);

      // Back to One: the camera reopens.
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(label(), Icons.crop_square);
      expect(find.byKey(const Key('camera-paused')), findsNothing);
      expect(find.byTooltip('Clip'), findsOneWidget);
      expect(backend.opened, hasLength(2));
    });
  });
}
