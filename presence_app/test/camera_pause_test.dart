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

      // None: the camera off, the single view, Clip disabled.
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(label(), Icons.videocam_off);
      expect(find.byTooltip('Turn the camera on'), findsOneWidget);
      expect(camera.disposed, isTrue);
      expect(find.byKey(const Key('camera-paused')), findsOneWidget);
      expect(find.textContaining('· live'), findsNothing);
      final clip = find.byKey(const Key('clip'));
      expect(tester.widget<FloatingActionButton>(clip).onPressed, isNull);
      expect(find.byTooltip('Camera off'), findsOneWidget);
      expect(find.text('Off'), findsNothing);

      // Back to One: the camera reopens.
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(label(), Icons.crop_square);
      expect(find.byKey(const Key('camera-paused')), findsNothing);
      expect(tester.widget<FloatingActionButton>(clip).onPressed, isNotNull);
      expect(find.byTooltip('Ready'), findsOneWidget);
      expect(backend.opened, hasLength(2));
    });
  });
}
