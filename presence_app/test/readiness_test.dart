import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/camera_feeds.dart';
import 'package:presence_app/cameras/cameras.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/main.dart';
import 'package:presence_app/config.dart';

import 'fakes.dart';
import 'motion_test.dart' show frame;

const media = ClipMedia(
  url: 'blob:fake',
  start: Duration.zero,
  end: Duration(seconds: 15),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CameraRig.readiness', () {
    late DateTime now;
    late CameraRig rig;
    late FakeCameraSource back;
    late AppEventBus bus;

    setUp(() async {
      now = DateTime(2026, 9, 25, 12);
      bus = AppEventBus();
      back = FakeCameraSource('Main', immediatePast: media);
      final front = FakeCameraSource(
        'Selfie',
        facing: CameraFacing.front,
        immediatePast: media,
      );
      rig = CameraRig(
        backend: openFakes([back, front]),
        config: ConfigController(),
        bus: bus,
        now: () => now,
      );
      await rig.load();
    });

    tearDown(() {
      rig.dispose();
      bus.close();
    });

    test('is ready as soon as the camera opens: no countdown', () {
      final r = rig.readiness;
      expect(r.state, ClipReadinessState.ready);
      expect(r.remaining, Duration.zero);
    });

    test('a Clip press starts no countdown: still ready', () async {
      now = now.add(const Duration(seconds: 20));
      await rig.requestClips(bus);
      expect(back.fullCompleters, hasLength(1), reason: 'the clip was taken');

      var r = rig.readiness;
      expect(r.state, ClipReadinessState.ready);
      expect(r.remaining, Duration.zero);

      now = now.add(const Duration(seconds: 12));
      expect(rig.readiness.state, ClipReadinessState.ready);
      back.fullCompleters.single.complete(media);
      await Future<void>.delayed(Duration.zero);
      expect(rig.readiness.state, ClipReadinessState.ready);
    });

    var warmedUp = false;
    var step = 0; // Keeps the square alternating across bursts.
    setUp(() {
      warmedUp = false; // Each test gets a fresh rig.
      step = 0;
    });

    /// Movement that triggers on its 3rd frame; returns the trigger time.
    /// The detector's warm-up (still frames) runs only the first time.
    Future<DateTime> motionClip() async {
      if (!warmedUp) {
        for (var i = 0; i < 20; i++) {
          now = now.add(const Duration(milliseconds: 200));
          back.motion.add(frame());
          await Future<void>.delayed(Duration.zero);
        }
        warmedUp = true;
      }
      DateTime? third;
      for (var i = 0; i < 3; i++) {
        now = now.add(const Duration(milliseconds: 200));
        back.motion.add(frame(x: (step++ % 2) * 30 + 5, y: 10, size: 24));
        await Future<void>.delayed(Duration.zero);
        if (i == 2) third = now;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return third!;
    }

    test('a motion clip starts the cooldown countdown', () async {
      now = now.add(const Duration(seconds: 20));
      final triggered = await motionClip();
      expect(back.fullCompleters, hasLength(1));

      var r = rig.readiness;
      expect(r.state, ClipReadinessState.cooldown);
      expect(r.remaining, const Duration(minutes: 5));
      expect(now, triggered);
      expect(r.recording, isTrue, reason: 'still saving the after part');

      back.fullCompleters.single.complete(media);
      await Future<void>.delayed(Duration.zero);
      r = rig.readiness;
      expect(r.state, ClipReadinessState.cooldown);
      expect(r.recording, isFalse);

      now = triggered.add(const Duration(minutes: 4, seconds: 59));
      expect(rig.readiness.remaining, const Duration(seconds: 1));
    });

    test('motion retriggers only when the countdown reaches zero', () async {
      now = now.add(const Duration(seconds: 20));
      final start = await motionClip();
      back.fullCompleters.single.complete(media);

      // Motion ending one second before zero: no clip.
      now = start.add(
        const Duration(minutes: 4, seconds: 58, milliseconds: 400),
      );
      await motionClip();
      expect(back.fullCompleters, hasLength(1));
      expect(rig.readiness.state, ClipReadinessState.cooldown);

      // At zero: ready, and motion clips again.
      now = start.add(const Duration(minutes: 5));
      expect(rig.readiness.state, ClipReadinessState.ready);
      expect(rig.motionCooldownEnds, isNull);
      now = now.subtract(const Duration(milliseconds: 600));
      await motionClip();
      expect(back.fullCompleters, hasLength(2));
      expect(rig.readiness.state, ClipReadinessState.cooldown);
    });

    test(
      'a Clip press during the cooldown leaves the countdown as is',
      () async {
        now = now.add(const Duration(seconds: 20));
        final triggered = await motionClip();
        back.fullCompleters.single.complete(media);
        now = triggered.add(const Duration(minutes: 1));

        await rig.requestClips(bus);
        final r = rig.readiness;
        expect(r.state, ClipReadinessState.cooldown);
        expect(r.remaining, const Duration(minutes: 4));
        expect(r.recording, isFalse, reason: "only the motion clip's saving");
      },
    );

    test('with motion clips off, there is no cooldown', () async {
      now = now.add(const Duration(seconds: 20));
      await motionClip();
      back.fullCompleters.single.complete(media);
      await Future<void>.delayed(Duration.zero);
      rig.config.update(
        (c) => c.copyWith(motion: c.motion.copyWith(enabled: false)),
      );
      expect(rig.readiness.state, ClipReadinessState.ready);
    });

    test('is still ready right after a flip', () async {
      await rig.flip();
      expect(rig.readiness.state, ClipReadinessState.ready);
    });
  });

  group('readiness indicator and clip message', () {
    late DateTime now;

    Future<FakeCameraSource> pumpApp(WidgetTester tester) async {
      now = DateTime(2026, 9, 25, 12);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final camera = FakeCameraSource('Main', immediatePast: media);
      await tester.pumpWidget(
        PresenceApp(
          cameras: openFakes([camera]),
          mediaIo: fakeMediaIo,
          now: () => now,
        ),
      );
      await tester.pumpAndSettle();
      await settleStorage(tester);
      return camera;
    }

    Future<void> advance(WidgetTester tester, Duration d) async {
      now = now.add(d);
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('is the last button on the right, and starts Ready', (
      tester,
    ) async {
      await pumpApp(tester);

      final pill = tester.getCenter(find.byKey(const Key('readiness')));
      final clip = tester.getCenter(find.byTooltip('Clip'));
      expect(pill.dx, greaterThan(clip.dx));
      expect((pill.dy - clip.dy).abs(), lessThan(1));
      // No countdown on load (e.g. a page reload): countdowns start with a
      // clip.
      expect(find.text('Ready'), findsOneWidget);
      expect(find.textContaining(' s'), findsNothing);
    });

    testWidgets('fits on a 320 dp phone with the widest label', (tester) async {
      now = DateTime(2026, 9, 25, 12);
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final back = FakeCameraSource('Main', immediatePast: media);
      final front = FakeCameraSource('Selfie', facing: CameraFacing.front);
      await tester.pumpWidget(
        PresenceApp(
          cameras: openFakes([back, front]),
          mediaIo: fakeMediaIo,
          now: () => now,
        ),
      );
      await tester.pumpAndSettle();
      await settleStorage(tester);

      // Flip, Clip and the pill in one row, no overflow, with the pill's
      // widest label: the motion cooldown ("5:00").
      for (var i = 0; i < 20; i++) {
        now = now.add(const Duration(milliseconds: 200));
        back.motion.add(frame());
        await tester.pump();
      }
      for (var i = 0; i < 4; i++) {
        now = now.add(const Duration(milliseconds: 200));
        back.motion.add(frame(x: (i % 2) * 30, y: 10, size: 24));
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('5:00'), findsOneWidget);
      expect(find.byTooltip('Flip camera'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final pill = tester.getRect(find.byKey(const Key('readiness')));
      expect(pill.right, lessThanOrEqualTo(320));
    });

    testWidgets('a Clip press pops a message; the pill stays Ready', (
      tester,
    ) async {
      final camera = await pumpApp(tester);
      await advance(tester, const Duration(seconds: 16));

      await tester.tap(find.byTooltip('Clip'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Clip started · saving the next 15 s'), findsOneWidget);
      expect(find.text('Ready'), findsOneWidget);
      expect(find.text('15 s'), findsNothing, reason: 'no countdown');

      await advance(tester, const Duration(seconds: 10));
      expect(find.text('Ready'), findsOneWidget);

      // The message was brief (4 s).
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Clip started · saving the next 15 s'), findsNothing);

      camera.fullCompleters.single.complete(media);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Ready'), findsOneWidget);
      await settleStorage(tester);
    });

    testWidgets('motion clips pop their own message', (tester) async {
      final camera = await pumpApp(tester);
      // Still frames through the warm-up, then a moving square.
      for (var i = 0; i < 20; i++) {
        now = now.add(const Duration(milliseconds: 200));
        camera.motion.add(frame());
        await tester.pump();
      }
      for (var i = 0; i < 4; i++) {
        now = now.add(const Duration(milliseconds: 200));
        camera.motion.add(frame(x: (i % 2) * 30, y: 10, size: 24));
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        find.text('Motion detected · saving the next 15 s'),
        findsOneWidget,
      );
      // The pill counts down the motion cooldown (5 minutes by default).
      expect(find.text('5:00'), findsOneWidget);
      await settleStorage(tester);
    });
  });
}
