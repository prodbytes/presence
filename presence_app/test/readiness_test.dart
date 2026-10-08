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

final media = ClipMedia(
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

    test('a stored clip time later than now counts as now', () {
      rig.restoreCooldown(now.add(const Duration(hours: 2)));
      expect(rig.cooldownEnds, now.add(const Duration(minutes: 5)));
      expect(rig.readiness.remaining, const Duration(minutes: 5));
      now = now.add(const Duration(minutes: 5));
      expect(rig.readiness.state, ClipReadinessState.ready);
    });

    test('a clock set back never stretches the cooldown', () async {
      now = now.add(const Duration(seconds: 20));
      await rig.requestClips(bus);
      now = now.subtract(const Duration(hours: 1));
      expect(rig.cooldownEnds, now.add(const Duration(minutes: 5)));
      now = now.add(const Duration(minutes: 5));
      expect(rig.cooldownEnds, isNull);
    });

    test('motion and scheduled clips both off: no cooldown', () async {
      rig.config.update(
        (c) => c.copyWith(
          motion: c.motion.copyWith(enabled: false),
          schedule: c.schedule.copyWith(enabled: false),
        ),
      );
      now = now.add(const Duration(seconds: 20));
      await rig.requestClips(bus);
      expect(back.fullCompleters, hasLength(1), reason: 'Clip still works');
      expect(rig.cooldownEnds, isNull);
      expect(rig.readiness.state, ClipReadinessState.ready);
      // Either one switched back on: the cooldown from that clip shows.
      rig.config.update(
        (c) => c.copyWith(schedule: c.schedule.copyWith(enabled: true)),
      );
      expect(rig.readiness.state, ClipReadinessState.cooldown);
      expect(rig.readiness.remaining, const Duration(minutes: 5));
    });

    test('is still ready right after a flip', () async {
      await rig.flip();
      expect(rig.readiness.state, ClipReadinessState.ready);
    });
  });

  group('ClipButtonColors', () {
    double contrast(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      return (la > lb ? (la + 0.05) / (lb + 0.05) : (lb + 0.05) / (la + 0.05));
    }

    for (final brightness in Brightness.values) {
      test('meet 4.5:1 contrast in the ${brightness.name} theme', () {
        for (final tone in ClipTone.values) {
          final (background, foreground) = ClipButtonColors.of(
            tone,
            brightness,
          );
          expect(
            contrast(background, foreground),
            greaterThanOrEqualTo(4.5),
            reason: '$tone',
          );
        }
      });
    }

    test('green when ready, amber in the cooldown, red saving, grey off', () {
      for (final brightness in Brightness.values) {
        Color fg(ClipTone t) => ClipButtonColors.of(t, brightness).$2;
        HSVColor hsv(ClipTone t) => HSVColor.fromColor(fg(t));
        expect(hsv(ClipTone.ready).hue, inInclusiveRange(55, 90));
        expect(hsv(ClipTone.cooldown).hue, inInclusiveRange(30, 50));
        expect(
          hsv(ClipTone.recording).hue,
          anyOf(lessThan(15), greaterThan(345)),
        );
        expect(hsv(ClipTone.disabled).saturation, lessThan(0.25));
        // Muted on the dark theme (the app's), not Gruvbox's brightest.
        // (The light theme's are deep shades, saturated by nature.)
        if (brightness == Brightness.dark) {
          for (final tone in ClipTone.values) {
            expect(hsv(tone).saturation, lessThan(0.65), reason: '$tone');
          }
        }
      }
    });

    test('the background is the same quiet neutral for every tone', () {
      for (final brightness in Brightness.values) {
        final backgrounds = {
          for (final tone in ClipTone.values)
            ClipButtonColors.of(tone, brightness).$1,
        };
        expect(backgrounds, {ClipButtonColors.background(brightness)});
        expect(
          HSVColor.fromColor(backgrounds.single).saturation,
          lessThan(0.3),
        );
      }
    });
  });

  test('with automatic clips off, the button is red while the clip saves, '
      'then green', () async {
    final bus = AppEventBus();
    final camera = FakeCameraSource('Main', immediatePast: media);
    final config = ConfigController();
    config.update(
      (c) => c.copyWith(
        motion: c.motion.copyWith(enabled: false),
        schedule: c.schedule.copyWith(enabled: false),
      ),
    );
    final rig = CameraRig(
      backend: openFakes([camera]),
      config: config,
      bus: bus,
    );
    addTearDown(() {
      rig.dispose();
      bus.close();
    });
    await rig.load();
    expect(ClipButtonStatus.of(rig).tone, ClipTone.ready);
    await rig.requestClips(bus);
    // No cooldown to count down, but the clip is saving.
    var status = ClipButtonStatus.of(rig);
    expect(status.tone, ClipTone.recording);
    expect(status.enabled, isTrue);
    expect(status.countdown, isNull);
    expect(status.status, 'Clip saving…');
    camera.fullCompleters.last.complete(media);
    await Future<void>.delayed(Duration.zero);
    status = ClipButtonStatus.of(rig);
    expect(status.tone, ClipTone.ready);
    expect(status.status, 'Ready');
  });

  test('disabled reasons: no camera, camera off', () async {
    final none = CameraRig(backend: openFakes([]), config: ConfigController());
    addTearDown(none.dispose);
    await none.load();
    expect(ClipButtonStatus.of(none).tone, ClipTone.disabled);
    expect(ClipButtonStatus.of(none).status, 'No camera');

    final off = CameraRig(
      backend: openFakes([FakeCameraSource('Main')]),
      config: ConfigController(
        const PresenceConfig(camera: CameraConfig(paused: true)),
      ),
    );
    addTearDown(off.dispose);
    await off.load();
    expect(ClipButtonStatus.of(off).tone, ClipTone.disabled);
    expect(ClipButtonStatus.of(off).status, 'Camera off');
  });

  group('the Clip button and clip messages', () {
    late DateTime now;

    Future<FakeCameraSource> pumpApp(
      WidgetTester tester, {
      Size size = const Size(1280, 800),
      List<FakeCameraSource>? cameras,
    }) async {
      now = DateTime(2026, 9, 25, 12);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final camera = FakeCameraSource('Main', immediatePast: media);
      await tester.pumpWidget(
        PresenceApp(
          consentGiven: true,
          cameras: openFakes(cameras ?? [camera]),
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
      return cameras?.first ?? camera;
    }

    Future<void> advance(WidgetTester tester, Duration d) async {
      now = now.add(d);
      await tester.pump(const Duration(milliseconds: 600));
    }

    final clip = find.byKey(const Key('clip'));
    FloatingActionButton button(WidgetTester tester) =>
        tester.widget<FloatingActionButton>(clip);
    // The tone is the label's and icon's color, not the background's.
    Color? color(WidgetTester tester) => button(tester).foregroundColor;
    Color tone(ClipTone t) => ClipButtonColors.of(t, Brightness.dark).$2;

    /// Motion past the warm-up: takes a motion clip.
    Future<void> move(WidgetTester tester, FakeCameraSource camera) async {
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
    }

    testWidgets('starts green and Ready; no separate readiness pill', (
      tester,
    ) async {
      await pumpApp(tester);

      expect(find.byKey(const Key('readiness')), findsNothing);
      expect(color(tester), tone(ClipTone.ready));
      expect(button(tester).onPressed, isNotNull);
      expect(find.descendant(of: clip, matching: find.text('Clip')), findsOne);
      expect(find.byTooltip('Ready'), findsOneWidget);
      // No countdown on load (e.g. a page reload): countdowns start with a
      // clip.
      expect(find.textContaining(' s'), findsNothing);
      // Bottom right, as before.
      expect(tester.getRect(clip).right, 1280 - 16);
    });

    testWidgets('a Clip press: red while saving, still pressable, then amber '
        'with the countdown, then green', (tester) async {
      final camera = await pumpApp(tester);
      await advance(tester, const Duration(seconds: 16));

      await tester.tap(clip);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Clip started · saving the next 10 s'), findsOneWidget);
      // Red while the clip's after part is still saving, with the cooldown.
      expect(color(tester), tone(ClipTone.recording));
      expect(button(tester).onPressed, isNotNull);
      expect(find.text('Clip · 5:00'), findsOneWidget);
      expect(
        find.byTooltip('Clip saving… Next automatic clip in 5:00'),
        findsOneWidget,
      );

      await advance(tester, const Duration(seconds: 10));
      expect(find.text('Clip · 4:50'), findsOneWidget);

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
      // Amber, counting down, still pressable.
      expect(color(tester), tone(ClipTone.cooldown));
      expect(button(tester).onPressed, isNotNull);
      expect(find.byTooltip('Next automatic clip in 4:50'), findsOneWidget);
      expect(find.text('Clip · 4:50'), findsOneWidget);

      // Below a minute, in seconds.
      await advance(tester, const Duration(minutes: 4, seconds: 5));
      expect(find.text('Clip · 45 s'), findsOneWidget);

      // Once the cooldown is over, the held-back startup clip is taken
      // (the schedule checks every 5 s), and counts down in turn.
      now = now.add(const Duration(minutes: 1));
      await tester.pump(CameraRig.scheduleCheck);
      await tester.pump(const Duration(milliseconds: 600));
      expect(camera.fullCompleters, hasLength(2));
      expect(find.text('Clip · 5:00'), findsOneWidget);
      camera.fullCompleters.last.complete(media);

      // Green and Ready once that one's is over too.
      now = now.add(const Duration(minutes: 5));
      await tester.pump(const Duration(milliseconds: 600));
      expect(color(tester), tone(ClipTone.ready));
      expect(find.byTooltip('Ready'), findsOneWidget);
      expect(find.descendant(of: clip, matching: find.text('Clip')), findsOne);
      await tester.pump(const Duration(seconds: 5));
      await settleStorage(tester);
    });

    testWidgets('a press while the clip is saving takes another, as always', (
      tester,
    ) async {
      final camera = await pumpApp(tester);
      await advance(tester, const Duration(seconds: 16));
      await tester.tap(clip);
      await tester.pump(CameraRig.pastWait);
      expect(color(tester), tone(ClipTone.recording));
      await advance(tester, const Duration(seconds: 3));
      await tester.tap(clip);
      await tester.pump(CameraRig.pastWait);
      expect(camera.fullCompleters, hasLength(2));
      // The cooldown restarted from the second press.
      expect(find.text('Clip · 5:00'), findsOneWidget);
      for (final c in camera.fullCompleters) {
        c.complete(media);
      }
      await tester.pump(const Duration(seconds: 5));
      await settleStorage(tester);
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets('fits on a 320 dp phone with Flip, counting down, at '
          '${scale}x text', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final back = FakeCameraSource('Main', immediatePast: media);
        final front = FakeCameraSource('Selfie', facing: CameraFacing.front);
        await pumpApp(
          tester,
          size: const Size(320, 640),
          cameras: [back, front],
        );
        await move(tester, back);
        // The motion cooldown ("5:00"), with "Clip" when there's room, the
        // icon alone when not even the time fits; the tooltip has it all.
        if (scale == 1) {
          expect(
            find.descendant(of: clip, matching: find.textContaining('5:00')),
            findsOneWidget,
          );
        }
        expect(find.byTooltip('Next automatic clip in 5:00'), findsNothing);
        expect(
          find.byTooltip('Clip saving… Next automatic clip in 5:00'),
          findsOneWidget,
        );
        expect(find.byTooltip('Flip camera'), findsOneWidget);
        expect(tester.takeException(), isNull);
        final rect = tester.getRect(clip);
        final flip = tester.getRect(find.byTooltip('Flip camera'));
        final view = tester.getRect(find.byKey(const Key('show-all')));
        expect(rect.right, lessThanOrEqualTo(320 - 16));
        expect(view.left, greaterThanOrEqualTo(16));
        expect(rect.overlaps(flip), isFalse);
        expect(flip.overlaps(view), isFalse);
        back.fullCompleters.last.complete(media);
        await tester.pump(const Duration(seconds: 5));
        await settleStorage(tester);
      });
    }

    for (final size in [const Size(320, 640), const Size(1280, 800)]) {
      testWidgets('the message is a pill bottom left, clear of the buttons, '
          'at ${size.width.toInt()} wide', (tester) async {
        await pumpApp(tester, size: size);
        await advance(tester, const Duration(seconds: 16));
        await tester.tap(clip);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        final message = find.byKey(const Key('camera-message'));
        expect(message, findsOneWidget);
        expect(find.byType(SnackBar), findsNothing);
        final pill = tester.getRect(message);
        expect(pill.left, 16);
        if (size.width < 600) {
          // Stacked, just above the buttons' row.
          expect(pill.bottom, lessThanOrEqualTo(tester.getRect(clip).top));
        } else {
          // Level with the buttons.
          expect(pill.center.dy, closeTo(tester.getRect(clip).center.dy, 1));
        }
        // Clear of Flip and Clip, and of the screen's edge.
        expect(pill.overlaps(tester.getRect(clip)), isFalse);
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
      // Bottom left, as the only pill; no buttons signed out.
      expect(clip, findsNothing);
      final pill = tester.getRect(message);
      expect(pill.left, 16);
      expect(pill.right, lessThanOrEqualTo(400 - 16));

      await tester.pump(const Duration(seconds: 5));
      expect(message, findsNothing);
      await settleStorage(tester);
    });

    testWidgets('a message moves nothing: Clip stays anchored', (tester) async {
      await pumpApp(tester, size: const Size(320, 640));
      await advance(tester, const Duration(seconds: 16));
      final before = tester.getRect(clip);
      await tester.tap(clip);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('camera-message')), findsOneWidget);
      // Clip only widens (leftwards) for its countdown.
      final after = tester.getRect(clip);
      expect(after.right, before.right);
      expect(after.bottom, before.bottom);
      expect(after.height, before.height);
      await settleStorage(tester);
    });

    testWidgets('motion clips pop their own message', (tester) async {
      final camera = await pumpApp(tester);
      await move(tester, camera);
      expect(
        find.text('Motion detected · saving the next 10 s'),
        findsOneWidget,
      );
      // Clip counts down the motion cooldown (5 minutes by default).
      expect(find.text('Clip · 5:00'), findsOneWidget);
      await settleStorage(tester);
    });

    testWidgets('disabled and red-tinted while the camera is off', (
      tester,
    ) async {
      await pumpApp(tester);
      // One, All, then None: the camera off.
      await tester.tap(find.byKey(const Key('show-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('show-all')));
      await tester.pumpAndSettle();
      expect(button(tester).onPressed, isNull);
      expect(color(tester), tone(ClipTone.disabled));
      expect(find.byTooltip('Camera off'), findsOneWidget);
      await settleStorage(tester);
    });
  });
}
