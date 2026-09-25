import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/camera_feeds.dart';
import 'package:presence_app/cameras/cameras.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/main.dart';

import 'fakes.dart';

void main() {
  Future<void> pumpApp(WidgetTester tester, CameraBackend cameras) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      PresenceApp(cameras: cameras, mediaIo: fakeMediaIo),
    );
    await tester.pumpAndSettle();
    await settleStorage(tester);
  }

  Finder inEvents(Finder f) =>
      find.descendant(of: find.byKey(const Key('events-page')), matching: f);

  Future<void> pressClip(WidgetTester tester) => clipAndShowEvents(tester);

  const media = ClipMedia(
    url: 'blob:fake',
    start: Duration(seconds: 3),
    end: Duration(seconds: 18),
  );

  testWidgets('no clip button until a camera is open', (tester) async {
    await pumpApp(tester, noCameras);
    expect(find.byTooltip('Clip'), findsNothing);
  });

  testWidgets('clip publishes a ClipRequested card with a thumbnail', (
    tester,
  ) async {
    final front = FakeCameraSource('Front door');
    await pumpApp(tester, openFakes([front]));

    await pressClip(tester);

    expect(inEvents(find.text('Clip requested')), findsOneWidget);
    expect(inEvents(find.text('Front door')), findsOneWidget);
    expect(inEvents(find.byKey(const Key('clip-thumbnail'))), findsOneWidget);
    expect(inEvents(find.text('Saving previous 15 s…')), findsOneWidget);

    // Default window: 15 s before and 15 s after the press.
    expect(front.requests, hasLength(1));
    expect(front.requests.single.before, const Duration(seconds: 15));
    expect(front.requests.single.after, const Duration(seconds: 15));
  });

  testWidgets('before-part is playable at once, full clip once recorded', (
    tester,
  ) async {
    final camera = FakeCameraSource('Front door');
    await pumpApp(tester, openFakes([camera]));
    await pressClip(tester);

    expect(inEvents(find.byKey(const Key('clip-play'))), findsNothing);

    camera.pastCompleters.single.complete(media);
    await tester.pumpAndSettle();
    expect(
      inEvents(find.text('Previous 15 s ready · recording next 15 s…')),
      findsOneWidget,
    );
    expect(inEvents(find.byKey(const Key('clip-play'))), findsOneWidget);

    camera.fullCompleters.single.complete(media);
    await tester.pumpAndSettle();
    expect(inEvents(find.text('30 s clip ready')), findsOneWidget);

    // Tapping a playable card opens the player.
    await tester.tap(inEvents(find.byKey(const Key('clip-play'))));
    await tester.pumpAndSettle();
    expect(find.byType(ClipPlayerView), findsOneWidget);
  });

  testWidgets('a clip event is playable the moment it is published', (
    tester,
  ) async {
    final camera = FakeCameraSource('Front door', immediatePast: media);
    await pumpApp(tester, openFakes([camera]));
    // Whether each clip was playable exactly as subscribers first saw it.
    final playableOnArrival = <bool>[];
    final sub = AppEventBusScope.of(tester.element(find.byType(HomeScreen)))
        .stream
        .listen((e) {
          if (e is ClipRequested) playableOnArrival.add(e.clip.playable);
        });
    addTearDown(sub.cancel);

    await tester.tap(find.byTooltip('Clip'));
    await tester.pump(const Duration(milliseconds: 10));
    expect(playableOnArrival, [true]);

    // And its card shows up playable.
    await showEvents(tester);
    expect(inEvents(find.byKey(const Key('clip-play'))), findsOneWidget);
    expect(
      inEvents(find.text('Previous 15 s ready · recording next 15 s…')),
      findsOneWidget,
    );
    await settleStorage(tester);
  });

  testWidgets('the same event is updated with the full clip', (tester) async {
    final camera = FakeCameraSource('Front door', immediatePast: media);
    await pumpApp(tester, openFakes([camera]));
    await pressClip(tester);
    final event = tester
        .widget<ClipEventCard>(find.byType(ClipEventCard))
        .event;
    expect(event.clipState, 'partial');

    camera.fullCompleters.single.complete(media);
    await tester.pumpAndSettle();
    await settleStorage(tester);

    // Still one event, now carrying the full clip.
    expect(find.byType(ClipEventCard), findsOneWidget);
    expect(
      tester.widget<ClipEventCard>(find.byType(ClipEventCard)).event,
      same(event),
    );
    expect(event.clipState, 'complete');
    expect(inEvents(find.text('30 s clip ready')), findsOneWidget);
  });

  testWidgets('a slow before part still publishes after the wait cap', (
    tester,
  ) async {
    final camera = FakeCameraSource('Front door');
    await pumpApp(tester, openFakes([camera]));

    await tester.tap(find.byTooltip('Clip'));
    await tester.pump(const Duration(milliseconds: 50));
    await showEvents(tester);
    expect(inEvents(find.text('Clip requested')), findsNothing);

    // After the wait cap, the event appears anyway…
    await tester.pump(CameraRig.pastWait);
    await tester.pumpAndSettle();
    expect(inEvents(find.text('Saving previous 15 s…')), findsOneWidget);

    // …and becomes playable once its before part arrives.
    camera.pastCompleters.single.complete(media);
    await tester.pumpAndSettle();
    expect(inEvents(find.byKey(const Key('clip-play'))), findsOneWidget);
    await settleStorage(tester);
  });

  testWidgets('cameras without video support say so', (tester) async {
    await pumpApp(
      tester,
      openFakes([FakeCameraSource('Phone', supportsVideo: false)]),
    );
    await pressClip(tester);

    expect(
      inEvents(find.text("Video clips aren't supported on this platform")),
      findsOneWidget,
    );
  });

  testWidgets('settings are their own tab', (tester) async {
    await pumpApp(tester, noCameras);
    expect(find.byKey(const Key('settings-page')), findsNothing);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-page')), findsOneWidget);
    expect(find.text('Before the press'), findsOneWidget);
    expect(find.text('After the press'), findsOneWidget);
    expect(find.textContaining('Clips play 30 s in total'), findsOneWidget);

    await tester.tap(find.byTooltip('Camera'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-page')), findsNothing);
  });

  testWidgets('clip durations come from the settings tab', (tester) async {
    final camera = FakeCameraSource('Front door');
    await pumpApp(tester, openFakes([camera]));

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    // Drag both sliders all the way: before to the max, after to the min.
    await tester.drag(
      find.descendant(
        of: find.byKey(const Key('clip-before-slider')),
        matching: find.byType(Slider),
      ),
      const Offset(1000, 0),
    );
    await tester.drag(
      find.descendant(
        of: find.byKey(const Key('clip-after-slider')),
        matching: find.byType(Slider),
      ),
      const Offset(-1000, 0),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Clips play 65 s in total'), findsOneWidget);

    await pressClip(tester);

    expect(camera.requests.single.before, const Duration(seconds: 60));
    expect(camera.requests.single.after, const Duration(seconds: 5));
    expect(inEvents(find.text('Saving previous 60 s…')), findsOneWidget);
  });

  testWidgets('a camera that failed to open is retried on resume', (
    tester,
  ) async {
    final camera = FakeCameraSource('Back camera');
    final backend = openFakes([camera])..openError = 'Blocked';
    await pumpApp(tester, backend);
    expect(find.byKey(const Key('preview-Back camera')), findsNothing);
    expect(find.textContaining('Blocked'), findsOneWidget);

    // Background, then foreground again.
    backend.openError = null;
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();

    expect(backend.opened, ['cam-Back camera', 'cam-Back camera']);
    expect(find.byKey(const Key('preview-Back camera')), findsOneWidget);
  });

  testWidgets('opens only the default (back) camera, with no overlays', (
    tester,
  ) async {
    final front = FakeCameraSource('Selfie', facing: CameraFacing.front);
    final back = FakeCameraSource('Main', facing: CameraFacing.back);
    final backend = openFakes([front, back]);
    await pumpApp(tester, backend);

    expect(backend.opened, ['cam-Main']);
    expect(find.byKey(const Key('preview-Main')), findsOneWidget);
    expect(find.byKey(const Key('preview-Selfie')), findsNothing);
    // No camera name (or any other text) over the camera.
    final camera = find.byKey(const Key('camera-page'));
    expect(
      find.descendant(of: camera, matching: find.byType(Text)),
      findsNothing,
    );
  });

  testWidgets('flip switches between back and front cameras', (tester) async {
    final back = FakeCameraSource('Main', facing: CameraFacing.back);
    final wide = FakeCameraSource('Wide', facing: CameraFacing.back);
    final front = FakeCameraSource('Selfie', facing: CameraFacing.front);
    final backend = openFakes([back, wide, front]);
    await pumpApp(tester, backend);

    // Beside the Clip button.
    final flip = tester.getCenter(find.byTooltip('Flip camera'));
    final clip = tester.getCenter(find.byTooltip('Clip'));
    expect(flip.dx, lessThan(clip.dx));
    expect((flip.dy - clip.dy).abs(), lessThan(1));

    await tester.tap(find.byTooltip('Flip camera'));
    await tester.pumpAndSettle();
    // Back → front, skipping the second back camera; the old one is closed.
    expect(backend.opened, ['cam-Main', 'cam-Selfie']);
    expect(back.disposed, isTrue);
    expect(find.byKey(const Key('preview-Selfie')), findsOneWidget);

    await tester.tap(find.byTooltip('Flip camera'));
    await tester.pumpAndSettle();
    expect(backend.opened.last, 'cam-Main');

    // Clips come from the camera being shown.
    await tester.tap(find.byTooltip('Flip camera'));
    await tester.pumpAndSettle();
    await pressClip(tester);
    expect(front.requests, hasLength(1));
    expect(inEvents(find.text('Selfie')), findsOneWidget);
  });

  testWidgets('cameras open brighter, and follow the brightness slider', (
    tester,
  ) async {
    final back = FakeCameraSource('Main', facing: CameraFacing.back);
    final front = FakeCameraSource('Selfie', facing: CameraFacing.front);
    await pumpApp(tester, openFakes([back, front]));

    // Default: +1 EV.
    expect(back.brightness, [1.0]);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('+1.0 EV'), findsOneWidget);
    await tester.drag(
      find.descendant(
        of: find.byKey(const Key('brightness-slider')),
        matching: find.byType(Slider),
      ),
      const Offset(1000, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('+2.0 EV'), findsOneWidget);
    // Applied live to the open camera.
    expect(back.brightness.last, 2.0);

    // A camera opened later (flip) gets the current value too.
    await tester.tap(find.byTooltip('Camera'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Flip camera'));
    await tester.pumpAndSettle();
    expect(front.brightness, [2.0]);
    await settleStorage(tester);
  });

  testWidgets('no flip button with a single camera', (tester) async {
    await pumpApp(tester, openFakes([FakeCameraSource('Only')]));
    expect(find.byTooltip('Clip'), findsOneWidget);
    expect(find.byTooltip('Flip camera'), findsNothing);
  });

  testWidgets('cameras are released when the app goes away', (tester) async {
    final camera = FakeCameraSource('Front door');
    await pumpApp(tester, openFakes([camera]));

    await tester.pumpWidget(const SizedBox());
    expect(camera.disposed, isTrue);
  });
}
