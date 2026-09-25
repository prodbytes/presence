import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/camera_feeds.dart';
import 'package:presence_app/cameras/cameras.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/main.dart';
import 'package:presence_app/settings.dart';

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
        settings: ClipSettings(),
        bus: bus,
        now: () => now,
      );
      await rig.load();
    });

    tearDown(() {
      rig.dispose();
      bus.close();
    });

    test('buffers the before period, then is ready', () {
      var r = rig.readiness;
      expect(r.state, ClipReadinessState.buffering);
      expect(r.remaining, const Duration(seconds: 15));
      expect(r.progress, 0);

      now = now.add(const Duration(seconds: 10));
      r = rig.readiness;
      expect(r.state, ClipReadinessState.buffering);
      expect(r.remaining, const Duration(seconds: 5));
      expect(r.progress, closeTo(10 / 15, 0.01));

      now = now.add(const Duration(seconds: 5));
      expect(rig.readiness.state, ClipReadinessState.ready);
    });

    test('counts down while a clip saves, then is ready again', () async {
      now = now.add(const Duration(seconds: 20));
      await rig.requestClips(bus);

      var r = rig.readiness;
      expect(r.state, ClipReadinessState.saving);
      expect(r.remaining, const Duration(seconds: 15));

      now = now.add(const Duration(seconds: 12));
      r = rig.readiness;
      expect(r.state, ClipReadinessState.saving);
      expect(r.remaining, const Duration(seconds: 3));

      back.fullCompleters.single.complete(media);
      await Future<void>.delayed(Duration.zero);
      expect(rig.readiness.state, ClipReadinessState.ready);
    });

    test('flipping starts buffering again', () async {
      now = now.add(const Duration(seconds: 20));
      expect(rig.readiness.state, ClipReadinessState.ready);
      await rig.flip();
      expect(rig.readiness.state, ClipReadinessState.buffering);
    });

    test('raising "before" needs more history', () {
      now = now.add(const Duration(seconds: 20));
      expect(rig.readiness.state, ClipReadinessState.ready);
      rig.settings.before = const Duration(seconds: 30);
      expect(rig.readiness.state, ClipReadinessState.buffering);
      expect(rig.readiness.remaining, const Duration(seconds: 10));
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

    testWidgets('is the last button on the right: buffering, then ready', (
      tester,
    ) async {
      await pumpApp(tester);

      final pill = tester.getCenter(find.byKey(const Key('readiness')));
      final clip = tester.getCenter(find.byTooltip('Clip'));
      expect(pill.dx, greaterThan(clip.dx));
      expect((pill.dy - clip.dy).abs(), lessThan(1));
      expect(find.textContaining('Buffering'), findsOneWidget);

      await advance(tester, const Duration(seconds: 16));
      expect(find.text('Ready'), findsOneWidget);
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

      // Flip, Clip and "Buffering 15 s" in one row, without overflowing.
      expect(find.text('Buffering 15 s'), findsOneWidget);
      expect(find.byTooltip('Flip camera'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final pill = tester.getRect(find.byKey(const Key('readiness')));
      expect(pill.right, lessThanOrEqualTo(320));
    });

    testWidgets('a clip pops a message and counts down until saved', (
      tester,
    ) async {
      final camera = await pumpApp(tester);
      await advance(tester, const Duration(seconds: 16));

      await tester.tap(find.byTooltip('Clip'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Clip started · saving the next 15 s'), findsOneWidget);
      expect(find.text('15 s'), findsOneWidget);
      expect(find.textContaining('Saving'), findsNothing);

      await advance(tester, const Duration(seconds: 10));
      expect(find.text('5 s'), findsOneWidget);

      // The message was brief (4 s); the pill still counts down.
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Clip started · saving the next 15 s'), findsNothing);
      expect(find.text('5 s'), findsOneWidget);

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
      expect(find.text('15 s'), findsOneWidget);
      await settleStorage(tester);
    });
  });
}
