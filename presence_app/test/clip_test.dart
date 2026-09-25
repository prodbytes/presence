import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/camera_feeds.dart';
import 'package:presence_app/cameras/cameras.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/main.dart';

import 'fakes.dart';

void main() {
  Future<void> pumpApp(WidgetTester tester, CameraOpener open) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      PresenceApp(openCameras: open, mediaIo: fakeMediaIo),
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

  testWidgets(
    'clip publishes a ClipRequested card per camera with a thumbnail',
    (tester) async {
      final front = FakeCameraSource('Front door');
      final yard = FakeCameraSource('Back yard');
      await pumpApp(tester, openFakes([front, yard]));

      await pressClip(tester);

      expect(inEvents(find.text('Clip requested')), findsNWidgets(2));
      expect(inEvents(find.text('Front door')), findsOneWidget);
      expect(inEvents(find.text('Back yard')), findsOneWidget);
      expect(
        inEvents(find.byKey(const Key('clip-thumbnail'))),
        findsNWidgets(2),
      );
      expect(inEvents(find.text('Saving previous 15 s…')), findsNWidgets(2));

      // Default window: 15 s before and 15 s after the press.
      for (final camera in [front, yard]) {
        expect(camera.requests, hasLength(1));
        expect(camera.requests.single.before, const Duration(seconds: 15));
        expect(camera.requests.single.after, const Duration(seconds: 15));
      }
    },
  );

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

  testWidgets("a slow camera doesn't hold up the others", (tester) async {
    final fast = FakeCameraSource('Front door', immediatePast: media);
    final slow = FakeCameraSource('Back yard');
    await pumpApp(tester, openFakes([fast, slow]));

    await tester.tap(find.byTooltip('Clip'));
    await tester.pump(const Duration(milliseconds: 50));
    // Switching tabs takes a few hundred ms, still inside the 2 s wait.
    await showEvents(tester);
    expect(inEvents(find.text('Front door')), findsOneWidget);
    expect(inEvents(find.text('Back yard')), findsNothing);

    // After the wait cap, the slow camera's event appears anyway.
    await tester.pump(CameraRig.pastWait);
    await tester.pumpAndSettle();
    expect(inEvents(find.text('Back yard')), findsOneWidget);
    expect(inEvents(find.text('Saving previous 15 s…')), findsOneWidget);

    // And becomes playable once its before part arrives.
    slow.pastCompleters.single.complete(media);
    await tester.pumpAndSettle();
    expect(inEvents(find.byKey(const Key('clip-play'))), findsNWidgets(2));
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

  testWidgets('cameras that failed to open are retried on resume', (
    tester,
  ) async {
    var opens = 0;
    final live = FakeCameraSource('Back camera');
    await pumpApp(tester, (_) async {
      opens++;
      return opens == 1
          ? [UnavailableCameraSource('0', 'Back camera', 'Blocked')]
          : [live];
    });
    expect(find.byKey(const Key('preview-Back camera')), findsNothing);

    // Background, then foreground again.
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

    expect(opens, 2);
    expect(find.byKey(const Key('preview-Back camera')), findsOneWidget);
  });

  testWidgets('permanent camera limits are listed, not retried', (
    tester,
  ) async {
    var opens = 0;
    await pumpApp(tester, (_) async {
      opens++;
      return [
        FakeCameraSource('Back camera'),
        UnavailableCameraSource(
          '1',
          'Front camera',
          "This phone can't run several cameras at once",
          retryable: false,
        ),
      ];
    });

    // The live camera gets the grid; the other is a compact line below.
    expect(find.byKey(const Key('preview-Back camera')), findsOneWidget);
    expect(find.byKey(const ValueKey('unavailable-1')), findsOneWidget);
    expect(find.byType(CameraTile), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(opens, 1);
  });

  testWidgets('cameras are released when the app goes away', (tester) async {
    final camera = FakeCameraSource('Front door');
    await pumpApp(tester, openFakes([camera]));

    await tester.pumpWidget(const SizedBox());
    expect(camera.disposed, isTrue);
  });
}
