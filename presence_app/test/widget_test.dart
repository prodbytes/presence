import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher/link.dart';

import 'package:presence_app/cameras/cameras.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/main.dart';
import 'package:presence_app/theme.dart';

import 'fakes.dart';

void main() {
  Future<void> pumpAt(
    WidgetTester tester,
    Size size, {
    CameraOpener openCameras = noCameras,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(PresenceApp(openCameras: openCameras));
    await tester.pump();
  }

  testWidgets('uses the gruvbox soft dark palette', (tester) async {
    await pumpAt(tester, const Size(1280, 800));

    final theme = Theme.of(tester.element(find.byType(MonitorPage)));
    expect(theme.brightness, Brightness.dark);
    expect(theme.scaffoldBackgroundColor, Gruvbox.bg0Soft);
    expect(theme.colorScheme.onSurface, Gruvbox.fg);
    expect(theme.colorScheme.primary, Gruvbox.yellow);
  });

  testWidgets('camera feeds panel is left of the events panel', (tester) async {
    await pumpAt(tester, const Size(1280, 800));

    final cameras = tester.getRect(find.byKey(const Key('camera-feeds-panel')));
    final events = tester.getRect(find.byKey(const Key('events-panel')));

    expect(cameras.right, lessThan(events.left));
    expect(cameras.width, greaterThan(events.width));
  });

  testWidgets('cameras panel title is the app name linking to the site', (
    tester,
  ) async {
    await pumpAt(tester, const Size(1280, 800));

    final cameras = find.byKey(const Key('camera-feeds-panel'));
    final title = find.descendant(of: cameras, matching: find.text('Presence'));
    expect(title, findsOneWidget);
    expect(find.text('Cameras'), findsNothing);

    final link = tester.widget<Link>(
      find.ancestor(of: title, matching: find.byType(Link)),
    );
    expect(link.uri, Uri.parse('https://presence.nu01.com'));
    expect(link.target, LinkTarget.blank);
  });

  testWidgets('cameras panel header has the clip button', (tester) async {
    await pumpAt(tester, const Size(1280, 800));

    final cameras = find.byKey(const Key('camera-feeds-panel'));
    final events = find.byKey(const Key('events-panel'));

    expect(
      find.descendant(of: cameras, matching: find.byTooltip('Clip')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: events, matching: find.byTooltip('Clip')),
      findsNothing,
    );
  });

  testWidgets('events panel has settings then login buttons', (tester) async {
    await pumpAt(tester, const Size(1280, 800));

    final events = find.byKey(const Key('events-panel'));
    Rect iconRect(IconData icon) => tester.getRect(
      find.descendant(of: events, matching: find.byIcon(icon)),
    );

    expect(
      iconRect(Icons.settings).left,
      lessThan(iconRect(Icons.person).left),
    );
    expect(find.byTooltip('Settings'), findsOneWidget);
    expect(find.byTooltip('Login'), findsOneWidget);
  });

  for (final width in [900.0, 1280.0, 1920.0]) {
    testWidgets('events panel is fixed width at ${width.toInt()} px', (
      tester,
    ) async {
      await pumpAt(tester, Size(width, 800));

      final cameras = tester.getRect(
        find.byKey(const Key('camera-feeds-panel')),
      );
      final events = tester.getRect(find.byKey(const Key('events-panel')));

      expect(events.width, MonitorPage.eventsPanelWidth);
      expect(events.right, width - MonitorPage.gap);
      // Cameras take everything else.
      expect(cameras.left, MonitorPage.gap);
      expect(cameras.right, events.left - MonitorPage.gap);
    });
  }

  testWidgets('header buttons are visibly separated', (tester) async {
    await pumpAt(tester, const Size(1280, 800));

    final events = find.byKey(const Key('events-panel'));
    Rect buttonRect(String tooltip) => tester.getRect(
      find.descendant(of: events, matching: find.byTooltip(tooltip)),
    );

    final settings = buttonRect('Settings');
    final login = buttonRect('Login');

    expect(login.left - settings.right, greaterThanOrEqualTo(8));
  });

  testWidgets('pushes an application started event on load', (tester) async {
    await pumpAt(tester, const Size(1280, 800));

    final events = find.byKey(const Key('events-panel'));
    expect(
      find.descendant(of: events, matching: find.text('Application started')),
      findsOneWidget,
    );
    expect(find.text('No events'), findsNothing);
  });

  testWidgets('any widget can publish to the bus via its scope', (
    tester,
  ) async {
    await pumpAt(tester, const Size(1280, 800));

    final context = tester.element(find.byType(CameraFeedsPanel));
    AppEventBusScope.of(context)
        .publish(AppEvent(icon: Icons.videocam, title: 'Motion detected'));
    await tester.pumpAndSettle();

    final events = find.byKey(const Key('events-panel'));
    expect(
      find.descendant(of: events, matching: find.text('Motion detected')),
      findsOneWidget,
    );
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

    expect(find.text('No camera feeds'), findsOneWidget);
  });

  testWidgets('shows camera access errors with a retry', (tester) async {
    var calls = 0;
    await pumpAt(
      tester,
      const Size(1280, 800),
      openCameras: (_) async {
        calls++;
        throw CameraException('permissionDenied', 'Camera access was denied');
      },
    );

    expect(find.textContaining('Camera access was denied'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(calls, 2);
  });
}
