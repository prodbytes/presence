import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/camera/night_mode.dart';
import 'package:presence_app/camera_feeds.dart';
import 'package:presence_app/cameras/cameras.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/motion.dart';
import 'package:presence_app/screen_light.dart';

import 'fakes.dart';
import 'motion_test.dart' show frame, w, h;

/// A flat frame of [base] with a square of [square] at [x], 10.
Uint8List dim(int base, {int? x, int square = 0}) {
  final f = Uint8List(w * h)..fillRange(0, w * h, base);
  if (x != null) {
    for (var j = 10; j < 34; j++) {
      for (var i = x; i < x + 24; i++) {
        f[j * w + i] = square;
      }
    }
  }
  return f;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NightDetector', () {
    test('night once the picture stays dark; not before its window', () {
      final d = NightDetector(window: 4);
      for (var i = 0; i < 3; i++) {
        expect(d.add(dim(20)), isFalse);
      }
      expect(d.level, isNull);
      expect(d.add(dim(20)), isTrue);
    });

    test('the brighter night picture doesn\'t end it; dawn does', () {
      final d = NightDetector(window: 4);
      for (var i = 0; i < 4; i++) {
        d.add(dim(20));
      }
      expect(d.night, isTrue);
      // The exposure goes up: settles at 90, which is the night's level.
      for (var i = 0; i < 4; i++) {
        d.add(dim(90));
      }
      expect(d.nightLevel, 90);
      expect(d.dayAbove, 135);
      for (var i = 0; i < 8; i++) {
        d.add(dim(120));
      }
      expect(d.night, isTrue, reason: 'not much brighter than the night');
      for (var i = 0; i < 4; i++) {
        d.add(dim(180));
      }
      expect(d.night, isFalse, reason: 'dawn');
    });

    test('a dusk between the two doesn\'t flicker', () {
      final d = NightDetector(window: 4);
      for (var i = 0; i < 20; i++) {
        d.add(dim(i.isEven ? 35 : 50));
      }
      expect(d.night, isFalse, reason: 'mean 42.5, above 40');
    });

    test('paused (the app lit the scene), frames don\'t count', () {
      final d = NightDetector(window: 2)..paused = true;
      for (var i = 0; i < 4; i++) {
        d.add(dim(5));
      }
      expect(d.night, isFalse);
      d.paused = false;
      d
        ..add(dim(5))
        ..add(dim(5));
      expect(d.night, isTrue);
    });
  });

  group('the motion step follows the light', () {
    test('steps: full when lit, 4 in the dark', () {
      final m = MotionDetector();
      expect(m.stepFor(200), 24);
      expect(m.stepFor(96), 24);
      expect(m.stepFor(40), 10);
      expect(m.stepFor(10), 4);
    });

    test('an animal a little brighter than a dark scene is motion', () {
      var now = DateTime(2026, 10, 14, 23);
      final m = MotionDetector(now: () => now);
      m.add(dim(10));
      now = now.add(const Duration(seconds: 4));
      m.add(dim(10));
      // 12 brighter than the dark around it: under 24, over 4.
      final score = m.add(dim(10, x: 20, square: 22))!;
      expect(score, greaterThan(15));
      // The same by day is nothing.
      m.reset();
      m.add(frame());
      now = now.add(const Duration(seconds: 4));
      m.add(frame());
      expect(m.add(dim(100, x: 20, square: 112)), 0);
    });
  });

  group('the rig at night', () {
    final media = ClipMedia(
      url: 'blob:fake',
      start: Duration.zero,
      end: const Duration(seconds: 15),
    );
    late DateTime now;
    late ConfigController config;
    late AppEventBus bus;

    Future<(CameraRig, FakeCameraSource)> open({
      bool torch = false,
      CameraFacing facing = CameraFacing.back,
    }) async {
      now = DateTime(2026, 10, 14, 23);
      config = ConfigController();
      bus = AppEventBus();
      final camera = FakeCameraSource(
        'Main',
        immediatePast: media,
        hasTorch: torch,
        facing: facing,
      );
      final rig = CameraRig(
        backend: openFakes([camera]),
        config: config,
        bus: bus,
        now: () => now,
      );
      await rig.load();
      addTearDown(() {
        rig.dispose();
        bus.close();
      });
      return (rig, camera);
    }

    Future<void> send(FakeCameraSource camera, Uint8List f, int n) async {
      for (var i = 0; i < n; i++) {
        now = now.add(const Duration(milliseconds: 200));
        camera.motion.add(f);
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('dark for a while: night, as bright as it goes; off in '
        'Settings, back to the setting', () async {
      final (rig, camera) = await open();
      expect(rig.night, isFalse);
      await send(camera, dim(15), 40);
      expect(rig.night, isTrue);
      expect(camera.brightness.last, CameraConfig.maxBrightness);
      config.update((c) => c.copyWith(camera: c.camera.copyWith(night: false)));
      await Future<void>.delayed(Duration.zero);
      expect(rig.night, isFalse);
      expect(camera.brightness.last, CameraConfig.defaultBrightness);
    });

    test('a clip at night lights the torch while it records', () async {
      final (rig, camera) = await open(torch: true);
      await send(camera, dim(15), 40);
      await rig.requestClips(bus);
      await Future<void>.delayed(Duration.zero);
      expect(camera.lights, [true]);
      expect(rig.screenLight.value, isFalse, reason: 'the torch does it');
      camera.fullCompleters.single.complete(media);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(camera.lights, [true, false]);
    });

    test('no torch, facing the screen\'s way: the screen lights it; a back '
        'camera without one: nothing', () async {
      final (rig, camera) = await open(facing: CameraFacing.front);
      await send(camera, dim(15), 40);
      await rig.requestClips(bus);
      await Future<void>.delayed(Duration.zero);
      expect(rig.screenLight.value, isTrue);
      camera.fullCompleters.single.complete(media);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(rig.screenLight.value, isFalse);

      final (back, backCamera) = await open();
      await send(backCamera, dim(15), 40);
      await back.requestClips(bus);
      await Future<void>.delayed(Duration.zero);
      expect(back.screenLight.value, isFalse);
    });

    test('by day a clip lights nothing', () async {
      final (rig, camera) = await open(torch: true);
      await send(camera, frame(), 40);
      await rig.requestClips(bus);
      await Future<void>.delayed(Duration.zero);
      expect(camera.lights, isEmpty);
    });
  });

  testWidgets('the screen light is white over everything, taking no taps', (
    tester,
  ) async {
    final on = ValueNotifier(false);
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Center(
              child: TextButton(
                onPressed: () => taps++,
                child: const Text('under'),
              ),
            ),
            ScreenLightOverlay(on: on),
          ],
        ),
      ),
    );
    expect(find.byKey(const Key('screen-light')), findsNothing);
    on.value = true;
    await tester.pump();
    expect(find.byKey(const Key('screen-light')), findsOneWidget);
    await tester.tap(find.text('under'));
    expect(taps, 1);
    on.value = false;
    await tester.pump();
    expect(find.byKey(const Key('screen-light')), findsNothing);
  });
}
