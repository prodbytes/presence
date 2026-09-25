import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/cameras/cameras.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/main.dart';
import 'package:presence_app/theme.dart';

import 'fakes.dart';

void main() {
  Future<void> pumpAt(
    WidgetTester tester,
    Size size, {
    CameraBackend? cameras,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(PresenceApp(cameras: cameras ?? noCameras));
    await tester.pump();
    // Let the startup writes to (in-memory) storage finish.
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(find.byTooltip(label));
    await tester.pumpAndSettle();
  }

  TabController tabs(WidgetTester tester) =>
      tester.widget<TabBar>(find.byType(TabBar)).controller!;

  for (final size in [const Size(320, 640), const Size(1280, 800)]) {
    final name = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('opens on the full-screen camera at $name', (tester) async {
      await pumpAt(tester, size);

      expect(tabs(tester).index, HomeTab.camera.index);
      // The camera fills the whole screen, under the app bar.
      expect(
        tester.getRect(find.byKey(const Key('camera-page'))),
        Offset.zero & size,
      );
      // The title overlays the camera, top left.
      final title = tester.getRect(find.text('Presence'));
      expect(title.top, lessThan(kToolbarHeight));
      expect(title.left, lessThan(size.width / 2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('tabs sit in the top right at $name', (tester) async {
      await pumpAt(tester, size);

      final camera = tester.getCenter(find.byTooltip('Camera'));
      final events = tester.getCenter(find.byTooltip('Events'));
      final settings = tester.getCenter(find.byTooltip('Settings'));
      final login = tester.getCenter(find.byKey(const Key('account-button')));
      for (final c in [camera, events, settings, login]) {
        expect(c.dy, lessThan(kToolbarHeight));
        expect(c.dx, greaterThan(size.width / 2 - 40));
      }
      expect(camera.dx, lessThan(events.dx));
      expect(events.dx, lessThan(settings.dx));
      expect(settings.dx, lessThan(login.dx));
    });
  }

  testWidgets('each tab flips to its own screen', (tester) async {
    await pumpAt(tester, const Size(1280, 800));
    expect(find.byKey(const Key('camera-page')), findsOneWidget);

    await openTab(tester, 'Events');
    expect(tabs(tester).index, HomeTab.events.index);
    expect(find.byKey(const Key('events-page')), findsOneWidget);
    expect(find.text('Application started'), findsOneWidget);

    await openTab(tester, 'Settings');
    expect(tabs(tester).index, HomeTab.settings.index);
    expect(find.byKey(const Key('settings-page')), findsOneWidget);
    expect(find.text('Before the press'), findsOneWidget);

    await openTab(tester, 'Camera');
    expect(tabs(tester).index, HomeTab.camera.index);
    expect(find.byKey(const Key('camera-page')), findsOneWidget);
  });

  testWidgets('swiping flips between tabs', (tester) async {
    await pumpAt(tester, const Size(320, 640));

    await tester.fling(find.byType(TabBarView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(tabs(tester).index, HomeTab.events.index);
  });

  testWidgets(
    'without a client ID, the account sheet says sign-in is not set up',
    (tester) async {
      await pumpAt(tester, const Size(1280, 800));

      await tester.tap(find.byTooltip('Sign in'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('account-sheet')), findsOneWidget);
      expect(find.textContaining("isn't set up yet"), findsOneWidget);
      expect(find.byKey(const Key('google-sign-in')), findsNothing);
    },
  );

  testWidgets('sign in and out from the account sheet', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      PresenceApp(cameras: noCameras, auth: FakeAuthService()),
    );
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(find.byTooltip('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('google-sign-in')));
    await tester.pumpAndSettle();

    // Signed in: the sheet shows who, and the button shows the avatar.
    expect(find.text('julio@nu01.com'), findsOneWidget);
    expect(find.byKey(const Key('sign-out')), findsOneWidget);
    expect(find.byTooltip('Account: Julio'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sign-out')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Sign in'), findsOneWidget);

    // Both show on the event stream.
    Navigator.of(tester.element(find.byKey(const Key('account-sheet')))).pop();
    await tester.pumpAndSettle();
    await openTab(tester, 'Events');
    expect(find.text('Signed in'), findsOneWidget);
    expect(find.text('Signed out'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('clip button is only on the camera tab, with a camera', (
    tester,
  ) async {
    await pumpAt(
      tester,
      const Size(1280, 800),
      cameras: openFakes([FakeCameraSource('Front door')]),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Clip'), findsOneWidget);

    await openTab(tester, 'Events');
    expect(find.byTooltip('Clip'), findsNothing);
  });

  testWidgets('no clip button without a camera', (tester) async {
    await pumpAt(tester, const Size(1280, 800));
    expect(find.byTooltip('Clip'), findsNothing);
  });

  testWidgets('uses the gruvbox soft dark palette', (tester) async {
    await pumpAt(tester, const Size(1280, 800));

    final theme = Theme.of(tester.element(find.byType(HomeScreen)));
    expect(theme.brightness, Brightness.dark);
    expect(theme.colorScheme.surface, Gruvbox.bg0Soft);
    expect(theme.colorScheme.onSurface, Gruvbox.fg);
    expect(theme.colorScheme.primary, Gruvbox.yellow);
  });

  testWidgets('any widget can publish to the bus via its scope', (
    tester,
  ) async {
    await pumpAt(tester, const Size(1280, 800));

    AppEventBusScope.of(tester.element(find.byType(HomeScreen)))
        .publish(AppEvent(icon: Icons.videocam, title: 'Motion detected'));
    await openTab(tester, 'Events');

    expect(find.text('Motion detected'), findsOneWidget);
    // Newest first: the new event sits above the startup event.
    expect(
      tester.getTopLeft(find.text('Motion detected')).dy,
      lessThan(tester.getTopLeft(find.text('Application started')).dy),
    );
  });

  testWidgets('timeline lists newest first and scrolls', (tester) async {
    final bus = AppEventBus();
    final log = EventLog(bus.stream);
    addTearDown(() {
      log.dispose();
      bus.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(height: 300, child: EventTimeline(log: log)),
        ),
      ),
    );
    expect(find.text('No events'), findsOneWidget);

    for (var i = 0; i < 20; i++) {
      bus.publish(AppEvent(icon: Icons.circle, title: 'Event $i'));
    }
    await tester.pumpAndSettle();

    expect(find.text('Event 19'), findsOneWidget);
    expect(find.text('Event 0'), findsNothing);

    await tester.scrollUntilVisible(find.text('Event 0'), 200);
    expect(find.text('Event 0'), findsOneWidget);

    // A new event scrolls the timeline back to the top.
    bus.publish(AppEvent(icon: Icons.circle, title: 'Newest'));
    await tester.pumpAndSettle();
    expect(find.text('Newest'), findsOneWidget);
  });

  testWidgets('shows an empty state when the device has no cameras', (
    tester,
  ) async {
    await pumpAt(tester, const Size(1280, 800));

    expect(find.text('No camera found'), findsOneWidget);
  });

  testWidgets('shows camera access errors with a retry', (tester) async {
    final backend = FakeCameraBackend(
      [],
      listError: Exception('Camera access was denied'),
    );
    await pumpAt(tester, const Size(1280, 800), cameras: backend);

    expect(find.textContaining('Camera access was denied'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(backend.lists, 2);
  });
}
