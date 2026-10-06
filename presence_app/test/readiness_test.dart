import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/camera_feeds.dart';
import 'package:presence_app/cameras/cameras.dart';
import 'package:presence_app/clips.dart';
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

    test('a Clip press starts the cooldown countdown too', () async {
      now = now.add(const Duration(seconds: 20));
      final pressed = now;
      await rig.requestClips(bus);
      expect(back.fullCompleters, hasLength(1), reason: 'the clip was taken');

      var r = rig.readiness;
      expect(r.state, ClipReadinessState.cooldown);
      expect(r.remaining, const Duration(minutes: 5));
      expect(r.recording, isTrue, reason: 'still saving the after part');

      now = now.add(const Duration(seconds: 12));
      back.fullCompleters.single.complete(media);
      await Future<void>.delayed(Duration.zero);
      r = rig.readiness;
      expect(r.state, ClipReadinessState.cooldown);
      expect(r.recording, isFalse);
      expect(r.remaining, const Duration(minutes: 4, seconds: 48));

      now = pressed.add(const Duration(minutes: 5));
      expect(rig.readiness.state, ClipReadinessState.ready);
    });

    for (final trigger in ClipTrigger.values) {
      test('a ${trigger.name} clip starts the cooldown', () async {
        now = now.add(const Duration(seconds: 20));
        await rig.requestClips(bus, trigger: trigger);
        expect(rig.readiness.state, ClipReadinessState.cooldown);
        expect(rig.cooldownEnds, now.add(const Duration(minutes: 5)));
      });
    }

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
      expect(rig.cooldownEnds, isNull);
      now = now.subtract(const Duration(milliseconds: 600));
      await motionClip();
      expect(back.fullCompleters, hasLength(2));
      expect(rig.readiness.state, ClipReadinessState.cooldown);
    });

    test('a Clip press during the cooldown clips and restarts it', () async {
      now = now.add(const Duration(seconds: 20));
      final triggered = await motionClip();
      back.fullCompleters.single.complete(media);
      await Future<void>.delayed(Duration.zero);
      now = triggered.add(const Duration(minutes: 1));

      await rig.requestClips(bus);
      expect(back.fullCompleters, hasLength(2), reason: 'never blocked');
      final r = rig.readiness;
      expect(r.state, ClipReadinessState.cooldown);
      expect(r.remaining, const Duration(minutes: 5));
      expect(r.recording, isTrue, reason: "the press's clip is saving");
    });

    test(
      'motion during the cooldown after a Clip press takes no clip',
      () async {
        now = now.add(const Duration(seconds: 20));
        final pressed = now;
        await rig.requestClips(bus);
        expect(back.fullCompleters, hasLength(1));

        now = pressed.add(const Duration(minutes: 2));
        await motionClip();
        expect(back.fullCompleters, hasLength(1), reason: 'motion ignored');

        now = pressed.add(const Duration(minutes: 5));
        await motionClip();
        expect(back.fullCompleters, hasLength(2), reason: 'clips again');
      },
    );

    test('with motion clips off, a clip still starts the cooldown', () async {
      rig.config.update(
        (c) => c.copyWith(motion: c.motion.copyWith(enabled: false)),
      );
      now = now.add(const Duration(seconds: 20));
      await rig.requestClips(bus);
      expect(rig.readiness.state, ClipReadinessState.cooldown);
    });

    test('restoring keeps the later of the stored and the latest clip', () {
      final restored = now.subtract(const Duration(minutes: 1));
      rig.restoreCooldown(restored);
      expect(rig.readiness.remaining, const Duration(minutes: 4));
      rig.restoreCooldown(restored.subtract(const Duration(minutes: 1)));
      expect(rig.readiness.remaining, const Duration(minutes: 4));
    });

    test('is still ready right after a flip', () async {
      await rig.flip();
      expect(rig.readiness.state, ClipReadinessState.ready);
    });
  });

  group('readiness indicator and clip message', () {
    late DateTime now;

    Future<FakeCameraSource> pumpApp(
      WidgetTester tester, {
      Size size = const Size(1280, 800),
    }) async {
      now = DateTime(2026, 9, 25, 12);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final camera = FakeCameraSource('Main', immediatePast: media);
      await tester.pumpWidget(
        PresenceApp(
          consentGiven: true,
          cameras: openFakes([camera]),
          mediaIo: fakeMediaIo,
          now: () => now,
          auth: FakeAuthService.signedIn(),
          rolesClient: FakeRolesClient(),
          mapTiles: const SizedBox(),
          locator: NoLocation(),
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

    testWidgets('sits bottom left, level with Clip, and starts Ready', (
      tester,
    ) async {
      await pumpApp(tester);

      final pill = tester.getCenter(find.byKey(const Key('readiness')));
      final clip = tester.getCenter(find.byTooltip('Clip'));
      expect(pill.dx, lessThan(clip.dx));
      expect(tester.getRect(find.byKey(const Key('readiness'))).left, 16);
      expect((pill.dy - clip.dy).abs(), lessThan(1));
      // No countdown on load (e.g. a page reload): countdowns start with a
      // clip.
      expect(find.byTooltip('Ready to clip'), findsOneWidget);
      expect(find.textContaining(' s'), findsNothing);
    });

    testWidgets('the readiness pill is only its dot; the tooltip names it', (
      tester,
    ) async {
      await pumpApp(tester);

      final pill = find.byKey(const Key('readiness'));
      expect(
        find.descendant(of: pill, matching: find.byType(Text)),
        findsNothing,
      );
      expect(find.text('Ready'), findsNothing);
      expect(find.byTooltip('Ready to clip'), findsOneWidget);
      expect(find.bySemanticsLabel('Ready to clip'), findsOneWidget);
      // A round pill around the dot.
      expect(tester.getSize(pill), const Size(40, 40));
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
          consentGiven: true,
          cameras: openFakes([back, front]),
          mediaIo: fakeMediaIo,
          now: () => now,
          auth: FakeAuthService.signedIn(),
          rolesClient: FakeRolesClient(),
          mapTiles: const SizedBox(),
          locator: NoLocation(),
        ),
      );
      await tester.pumpAndSettle();
      await settleStorage(tester);

      // The pill clear of Flip and Clip, no overflow, with its widest
      // label: the motion cooldown ("5:00").
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
      expect(pill.left, 16);
      expect(pill.overlaps(tester.getRect(find.byTooltip('Clip'))), isFalse);
      expect(
        pill.overlaps(tester.getRect(find.byTooltip('Flip camera'))),
        isFalse,
      );
    });

    testWidgets('a Clip press pops a message; the pill counts down', (
      tester,
    ) async {
      final camera = await pumpApp(tester);
      await advance(tester, const Duration(seconds: 16));

      await tester.tap(find.byTooltip('Clip'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Clip started · saving the next 10 s'), findsOneWidget);
      // The cooldown, red while the clip's after part is still saving.
      expect(find.text('5:00'), findsOneWidget);
      expect(
        find.byTooltip('Clip saving; next automatic clip in 5:00'),
        findsOneWidget,
      );

      await advance(tester, const Duration(seconds: 10));
      expect(find.text('4:50'), findsOneWidget);

      // The message was brief (4 s).
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Clip started · saving the next 10 s'), findsNothing);

      // Only the press's clip: the startup clip, due 5 s after the camera
      // opened, waits for the end of the press's cooldown.
      expect(camera.fullCompleters, hasLength(1));
      camera.fullCompleters.last.complete(media);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byTooltip('Next automatic clip in 4:50'), findsOneWidget);
      expect(find.bySemanticsLabel('Next automatic clip in 4:50'), findsOne);

      // Once the cooldown is over, the held-back startup clip is taken
      // (the schedule checks every 5 s), and counts down in turn.
      now = now.add(const Duration(minutes: 5));
      await tester.pump(CameraRig.scheduleCheck);
      await tester.pump(const Duration(milliseconds: 600));
      expect(camera.fullCompleters, hasLength(2));
      expect(find.text('5:00'), findsOneWidget);
      camera.fullCompleters.last.complete(media);

      // Ready (the dot alone) once that one's is over too.
      now = now.add(const Duration(minutes: 5));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byTooltip('Ready to clip'), findsOneWidget);
      expect(find.text('0 s'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      await settleStorage(tester);
    });

    for (final size in [const Size(320, 640), const Size(1280, 800)]) {
      testWidgets('the message is a pill beside the readiness one, at '
          '${size.width.toInt()} wide', (tester) async {
        await pumpApp(tester, size: size);
        await advance(tester, const Duration(seconds: 16));
        await tester.tap(find.byTooltip('Clip'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        final message = find.byKey(const Key('camera-message'));
        expect(message, findsOneWidget);
        expect(find.byType(SnackBar), findsNothing);
        final pill = tester.getRect(message);
        final readiness = tester.getRect(find.byKey(const Key('readiness')));
        // On the same line, just after it.
        expect(pill.center.dy, closeTo(readiness.center.dy, 1));
        expect(pill.left, closeTo(readiness.right + 8, 1));
        // Clear of Flip and Clip, and of the screen's edge.
        expect(pill.overlaps(tester.getRect(find.byTooltip('Clip'))), isFalse);
        expect(pill.right, lessThanOrEqualTo(size.width - 16));
        expect(tester.takeException(), isNull);

        // Tapping it opens the clip's event, in Monitoring.
        await tester.tap(message);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('events-page')), findsOneWidget);
        await settleStorage(tester);
      });
    }

    testWidgets('signed out, a failed sign-in is a pill too, not a snackbar', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final auth = FakeAuthService();
      await tester.pumpWidget(
        PresenceApp(
          consentGiven: true,
          cameras: openFakes([FakeCameraSource('Main', immediatePast: media)]),
          mediaIo: fakeMediaIo,
          auth: auth,
          rolesClient: FakeRolesClient(),
          mapTiles: const SizedBox(),
          locator: NoLocation(),
        ),
      );
      await tester.pumpAndSettle();
      auth.fail('popup closed');
      await tester.pump();

      final message = find.byKey(const Key('camera-message'));
      expect(message, findsOneWidget);
      expect(find.text('Sign-in failed: popup closed'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      // Bottom left, as the only pill (no readiness signed out).
      final pill = tester.getRect(message);
      expect(pill.left, 16);
      expect(pill.right, lessThanOrEqualTo(400 - 16));

      await tester.pump(const Duration(seconds: 5));
      expect(message, findsNothing);
      await settleStorage(tester);
    });

    testWidgets('a message moves nothing: readiness and Clip stay put', (
      tester,
    ) async {
      await pumpApp(tester, size: const Size(320, 640));
      await advance(tester, const Duration(seconds: 16));
      final readiness = tester.getRect(find.byKey(const Key('readiness')));
      final clip = tester.getRect(find.byTooltip('Clip'));
      await tester.tap(find.byTooltip('Clip'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('camera-message')), findsOneWidget);
      // The readiness pill only widens for its countdown.
      final after = tester.getRect(find.byKey(const Key('readiness')));
      expect(after.topLeft, readiness.topLeft);
      expect(after.height, readiness.height);
      expect(tester.getRect(find.byTooltip('Clip')), clip);
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
        find.text('Motion detected · saving the next 10 s'),
        findsOneWidget,
      );
      // The pill counts down the motion cooldown (5 minutes by default).
      expect(find.text('5:00'), findsOneWidget);
      await settleStorage(tester);
    });
  });
}
