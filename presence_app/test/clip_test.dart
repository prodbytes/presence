import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/cameras/cameras.dart';
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
      find.descendant(of: find.byKey(const Key('events-panel')), matching: f);

  Future<void> pressClip(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Clip'));
    await tester.pumpAndSettle();
    await settleStorage(tester);
  }

  const media = ClipMedia(
    url: 'blob:fake',
    start: Duration(seconds: 3),
    end: Duration(seconds: 18),
  );

  testWidgets('clip is disabled until a camera is open', (tester) async {
    await pumpApp(tester, noCameras);

    final button = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.photo_camera),
        matching: find.byType(IconButton),
      ),
    );
    expect(button.onPressed, isNull);
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

  testWidgets('settings pane is hidden until the settings button opens it', (
    tester,
  ) async {
    await pumpApp(tester, noCameras);
    expect(find.byKey(const Key('settings-pane')), findsNothing);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-pane')), findsOneWidget);
    expect(find.text('Before the press'), findsOneWidget);
    expect(find.text('After the press'), findsOneWidget);
    expect(find.textContaining('Clips play 30 s in total'), findsOneWidget);

    await tester.tap(find.byTooltip('Close settings'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-pane')), findsNothing);
  });

  testWidgets('clip durations come from the settings pane', (tester) async {
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

    await tester.tap(find.byTooltip('Close settings'));
    await tester.pumpAndSettle();
    await pressClip(tester);

    expect(camera.requests.single.before, const Duration(seconds: 60));
    expect(camera.requests.single.after, const Duration(seconds: 5));
    expect(inEvents(find.text('Saving previous 60 s…')), findsOneWidget);
  });

  testWidgets('cameras are released when the app goes away', (tester) async {
    final camera = FakeCameraSource('Front door');
    await pumpApp(tester, openFakes([camera]));

    await tester.pumpWidget(const SizedBox());
    expect(camera.disposed, isTrue);
  });
}
