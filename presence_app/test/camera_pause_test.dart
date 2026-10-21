import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/camera_feeds.dart';
import 'package:presence_app/cameras/cameras.dart';
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

/// Cameras that open when the test says ([finish]), each open a new
/// source, so a leaked one shows as not disposed.
class GatedCameraBackend implements CameraBackend {
  GatedCameraBackend(this.devices);

  final List<CameraDevice> devices;
  final List<Completer<CameraSource>> pending = [];
  final List<FakeCameraSource> sources = [];

  @override
  Future<List<CameraDevice>> listCameras() async => devices;

  @override
  Future<CameraSource> open(CameraDevice device, Duration Function() preRoll) {
    final opening = Completer<CameraSource>();
    pending.add(opening);
    return opening.future;
  }

  /// Finishes the [i]th open with a new source for [device].
  FakeCameraSource finish(int i, CameraDevice device) {
    final source = FakeCameraSource(
      device.label,
      id: device.id,
      facing: device.facing,
    );
    sources.add(source);
    pending[i].complete(source);
    return source;
  }
}

void main() {
  group('an open in flight', () {
    const back = CameraDevice(
      id: 'back',
      label: 'Back',
      facing: CameraFacing.back,
    );
    const front = CameraDevice(
      id: 'front',
      label: 'Front',
      facing: CameraFacing.front,
    );

    test('a pause and a resume during it leave one camera open', () async {
      final backend = GatedCameraBackend([back]);
      final config = ConfigController();
      final rig = CameraRig(backend: backend, config: config);
      addTearDown(rig.dispose);
      unawaited(rig.load());
      await pumpEventQueue();
      expect(backend.pending, hasLength(1));

      rig.setPaused(true);
      await pumpEventQueue();
      rig.setPaused(false);
      await pumpEventQueue();
      expect(backend.pending, hasLength(2), reason: 'the resume opens');

      // The first open finishes last-but-one: it's stale, and released.
      final first = backend.finish(0, back);
      await pumpEventQueue();
      expect(first.disposed, isTrue);
      expect(rig.active, isNull);
      expect(rig.busy, isTrue, reason: 'the resume is still opening');

      final second = backend.finish(1, back);
      await pumpEventQueue();
      expect(rig.active, second);
      expect(second.disposed, isFalse);
      expect(rig.busy, isFalse);
      expect(rig.error, isNull);
    });

    test('a pause during it releases what it opens', () async {
      final backend = GatedCameraBackend([back]);
      final config = ConfigController();
      final rig = CameraRig(backend: backend, config: config);
      addTearDown(rig.dispose);
      unawaited(rig.load());
      await pumpEventQueue();
      rig.setPaused(true);
      await pumpEventQueue();
      expect(rig.busy, isFalse);
      final source = backend.finish(0, back);
      await pumpEventQueue();
      expect(source.disposed, isTrue);
      expect(rig.active, isNull);
      expect(rig.readiness.state, ClipReadinessState.paused);
    });

    test('a stale open that fails shows no error', () async {
      final backend = GatedCameraBackend([back]);
      final config = ConfigController();
      final rig = CameraRig(backend: backend, config: config);
      addTearDown(rig.dispose);
      unawaited(rig.load());
      await pumpEventQueue();
      rig.setPaused(true);
      await pumpEventQueue();
      rig.setPaused(false);
      await pumpEventQueue();
      backend.pending[0].completeError(
        const CameraUnavailable('The camera is in use'),
      );
      final second = backend.finish(1, back);
      await pumpEventQueue();
      expect(rig.active, second);
      expect(rig.error, isNull);
    });

    test('a flip during it is ignored, and a flip after it switches', () async {
      final backend = GatedCameraBackend([back, front]);
      final config = ConfigController();
      final rig = CameraRig(backend: backend, config: config);
      addTearDown(rig.dispose);
      unawaited(rig.load());
      await pumpEventQueue();
      expect(rig.canFlip, isFalse);
      await rig.flip();
      expect(backend.pending, hasLength(1), reason: 'no second open');
      final first = backend.finish(0, back);
      await pumpEventQueue();
      expect(rig.active, first);

      unawaited(rig.flip());
      await pumpEventQueue();
      expect(first.disposed, isTrue);
      final second = backend.finish(1, front);
      await pumpEventQueue();
      expect(rig.active, second);
      expect(backend.sources.where((s) => !s.disposed), [second]);
    });
  });

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

    testWidgets('the app bar\'s mode menu picks This camera, All, '
        'Unattended or Stopped', (tester) async {
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
      final menu = find.byKey(const Key('camera-mode'));
      IconData? icon() => tester
          .widget<Icon>(
            find.descendant(of: menu, matching: find.byType(Icon)).first,
          )
          .icon;
      String? label() =>
          tester.widget<Text>(find.byKey(const Key('camera-mode-label'))).data;
      // In the app bar, top left; This camera at launch.
      expect(
        find.descendant(of: find.byType(AppBar), matching: menu),
        findsOneWidget,
      );
      expect(label(), 'This camera');
      expect(icon(), Icons.crop_square);
      expect(find.byTooltip('Camera mode'), findsOneWidget);

      // The menu lists every mode, with what it does.
      await tester.tap(menu);
      await tester.pumpAndSettle();
      for (final text in [
        'All devices',
        'Every device in a grid',
        'Unattended',
        'Screen off, still capturing',
        'Stopped',
        'Camera off, still syncing',
      ]) {
        expect(find.text(text), findsOneWidget);
      }
      await tester.tap(find.byKey(const Key('camera-mode-all')));
      await tester.pumpAndSettle();
      expect(label(), 'All devices');
      expect(icon(), Icons.grid_view);
      expect(find.text('live'), findsOneWidget);

      // Unattended: the screen dark, the camera still on.
      await pickMode(tester, CameraMode.unattended);
      expect(find.byKey(const Key('screen-off-cover')), findsOneWidget);
      expect(camera.disposed, isFalse);
      // A tap wakes it, still Unattended.
      await tester.tap(find.byKey(const Key('screen-off-cover')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('screen-off-cover')), findsNothing);
      expect(icon(), Icons.brightness_2_outlined);
      expect(label(), 'Unattended');

      // Stopped: the camera off, the single view, Clip disabled.
      await pickMode(tester, CameraMode.stopped);
      expect(icon(), Icons.stop_circle_outlined);
      expect(label(), 'Stopped');
      expect(camera.disposed, isTrue);
      expect(find.byKey(const Key('camera-paused')), findsOneWidget);
      expect(find.text('live'), findsNothing);
      final clip = find.byKey(const Key('clip'));
      expect(tester.widget<FloatingActionButton>(clip).onPressed, isNull);
      expect(find.byTooltip('Camera off'), findsOneWidget);
      expect(find.text('Off'), findsNothing);

      // Straight to All: the camera reopens, in the grid.
      await pickMode(tester, CameraMode.all);
      expect(label(), 'All devices');
      expect(find.byKey(const Key('camera-paused')), findsNothing);
      expect(find.text('live'), findsOneWidget);
      expect(backend.opened, hasLength(2));

      // Back to This camera.
      await pickMode(tester, CameraMode.normal);
      expect(icon(), Icons.crop_square);
      expect(find.text('live'), findsNothing);
      expect(tester.widget<FloatingActionButton>(clip).onPressed, isNotNull);
      expect(find.byTooltip('Ready'), findsOneWidget);
      expect(backend.opened, hasLength(2));
    });
  });
}

/// Picks [mode] from the Camera tab's mode menu, in the app bar, waiting
/// out the menu's animations only (not settling: some screens never do).
Future<void> pickMode(WidgetTester tester, CameraMode mode) async {
  const menu = Duration(milliseconds: 400);
  await tester.tap(find.byKey(const Key('camera-mode')));
  await tester.pump();
  await tester.pump(menu);
  await tester.tap(find.byKey(Key('camera-mode-${mode.name}')));
  await tester.pump();
  await tester.pump(menu);
}
