import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/camera_feeds.dart' show describeCameraError;
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
    await tester.pumpWidget(
      PresenceApp(
        consentGiven: true,
        cameras: cameras ?? noCameras,
        auth: FakeAuthService.signedIn(),
        rolesClient: FakeRolesClient(),
        mapTiles: const SizedBox(),
        locator: NoLocation(),
      ),
    );
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
      final monitoring = tester.getCenter(find.byTooltip('Monitoring'));
      final settings = tester.getCenter(find.byTooltip('Settings'));
      final login = tester.getCenter(find.byKey(const Key('account-button')));
      final title = tester.getRect(find.text('Presence'));
      for (final c in [camera, monitoring, settings, login]) {
        expect(c.dy, lessThan(kToolbarHeight));
        // Right of the title, which shrinks to make room on small phones.
        expect(c.dx, greaterThan(title.right));
      }
      expect(camera.dx, lessThan(monitoring.dx));
      expect(monitoring.dx, lessThan(settings.dx));
      expect(find.byTooltip('Device'), findsNothing);
      expect(settings.dx, lessThan(login.dx));
    });

    testWidgets("an admin's app bar fits at $name", (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        PresenceApp(
          cameras: noCameras,
          auth: FakeAuthService.signedIn(),
          rolesClient: FakeRolesClient(const [userRole, adminRole]),
          consentGiven: true,
          mapTiles: const SizedBox(),
          locator: NoLocation(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const Key('admin')), findsOneWidget);
      expect(
        tester.getRect(find.byKey(const Key('account-button'))).right,
        lessThanOrEqualTo(size.width),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('each tab flips to its own screen', (tester) async {
    await pumpAt(tester, const Size(1280, 800));
    expect(find.byKey(const Key('camera-page')), findsOneWidget);

    await openTab(tester, 'Monitoring');
    expect(tabs(tester).index, HomeTab.monitoring.index);
    expect(find.byKey(const Key('monitoring-page')), findsOneWidget);
    expect(find.byKey(const Key('subjects-map')), findsOneWidget);
    expect(find.byKey(const Key('events-page')), findsOneWidget);
    await revealSystemEvents(tester);
    expect(find.text('Application started'), findsOneWidget);

    await openTab(tester, 'Settings');
    expect(tabs(tester).index, HomeTab.settings.index);
    expect(find.byKey(const Key('settings-page')), findsOneWidget);
    // Location first, the other sections under it.
    expect(find.text('Location'), findsOneWidget);
    await scrollSettingsTo(tester, find.text('Before the press'));
    expect(find.text('Before the press'), findsOneWidget);

    await openTab(tester, 'Camera');
    expect(tabs(tester).index, HomeTab.camera.index);
    expect(find.byKey(const Key('camera-page')), findsOneWidget);
  });

  testWidgets('swiping flips between tabs', (tester) async {
    await pumpAt(tester, const Size(320, 640));

    await tester.fling(find.byType(TabBarView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(tabs(tester).index, HomeTab.monitoring.index);
  });

  Future<void> pumpGate(WidgetTester tester, PresenceApp app) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('dev mode (no client ID): everything but accounts, labelled', (
    tester,
  ) async {
    final backend = openFakes([FakeCameraSource('Main')]);
    // The real Google service and auth API client: tests configure no
    // client ID and reach no API, so the app starts in dev mode.
    await pumpGate(
      tester,
      PresenceApp(
        cameras: backend,
        consentGiven: true,
        mapTiles: const SizedBox(),
        locator: NoLocation(),
      ),
    );
    await tester.pumpAndSettle();

    expect(backend.opened, hasLength(1), reason: 'the camera still shows');
    expect(find.byKey(const Key('dev-mode')), findsOneWidget);
    expect(find.byType(TabBar), findsOneWidget);
    expect(find.byTooltip('Clip'), findsOneWidget);
    expect(find.byKey(const Key('account-button')), findsNothing);
    expect(find.byKey(const Key('google-sign-in')), findsNothing);
    expect(find.byKey(const Key('sign-up')), findsNothing);
    expect(find.byKey(const Key('admin')), findsNothing);
    await openTab(tester, 'Settings');
    expect(tabs(tester).index, HomeTab.settings.index);

    // No API in tests, and no AWS or OIDC settings: events stay local.
    await scrollSettingsTo(tester, find.byKey(const Key('system-health')));
    expect(find.text('🔌 API ❌'), findsOneWidget);
    expect(find.text('☁️ AWS ⚪'), findsOneWidget);
    expect(find.text('🔑 OIDC ⚪'), findsOneWidget);
  });

  testWidgets('settings show the API answered', (tester) async {
    await pumpAt(tester, const Size(1280, 800));
    await openTab(tester, 'Settings');
    await scrollSettingsTo(tester, find.byKey(const Key('system-health')));
    expect(find.text('🔌 API ✅'), findsOneWidget);
    expect(find.text('☁️ AWS ⚪'), findsOneWidget);
  });

  testWidgets('nothing shows until the execution mode is known', (
    tester,
  ) async {
    final roles = _SlowRolesClient();
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      PresenceApp(
        consentGiven: true,
        cameras: openFakes([FakeCameraSource('Main')]),
        auth: FakeAuthService(),
        rolesClient: roles,
        mapTiles: const SizedBox(),
        locator: NoLocation(),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('starting')), findsOneWidget);
    expect(find.byType(TabBar), findsNothing);
    expect(find.byKey(const Key('google-sign-in')), findsNothing);

    roles.answer.complete((
      mode: ExecutionMode.rbac,
      roles: [anonymousRole],
      settings: (oidc: true, aws: false),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('starting')), findsNothing);
    expect(find.byKey(const Key('dev-mode')), findsNothing);
    expect(find.byKey(const Key('google-sign-in')), findsOneWidget);
  });

  testWidgets('signed out: camera and sign-in only; signed in: all buttons', (
    tester,
  ) async {
    final camera = FakeCameraSource('Main');
    final backend = openFakes([camera]);
    await pumpGate(
      tester,
      PresenceApp(
        consentGiven: true,
        cameras: backend,
        auth: FakeAuthService(),
        rolesClient: FakeRolesClient(),
        mapTiles: const SizedBox(),
        locator: NoLocation(),
      ),
    );

    // Signed out: the camera shows, with no buttons on it and no
    // navigation; only the sign-in button in the app bar.
    expect(backend.opened, [camera.id]);
    expect(find.byKey(const Key('camera-page')), findsOneWidget);
    expect(find.byTooltip('Clip'), findsNothing);
    expect(find.byTooltip('Flip camera'), findsNothing);
    expect(find.byType(ReadinessIndicator), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.byType(TabBar), findsNothing);
    expect(find.byKey(const Key('account-button')), findsNothing);
    expect(find.byKey(const Key('sign-in-screen')), findsNothing);

    await tester.tap(find.byKey(const Key('google-sign-in')));
    await tester.pumpAndSettle();

    // Signed in: the camera's buttons, the tabs and the account button.
    expect(find.byTooltip('Clip'), findsOneWidget);
    expect(find.byType(ReadinessIndicator), findsOneWidget);
    expect(find.byType(TabBar), findsOneWidget);
    expect(find.byKey(const Key('google-sign-in')), findsNothing);
    expect(
      find.byTooltip('Signed in as Ana · ana@example.com'),
      findsOneWidget,
    );
    await openTab(tester, 'Monitoring');
    await revealSystemEvents(tester);
    expect(find.text('Signed in'), findsOneWidget);

    // Sign out from the account sheet: back to the camera, tabs hidden,
    // the camera still running.
    await tester.tap(find.byKey(const Key('account-button')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('account-sheet')),
        matching: find.text('ana@example.com'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('sign-out')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account-sheet')), findsNothing);
    expect(find.byType(TabBar), findsNothing);
    expect(find.byKey(const Key('camera-page')), findsOneWidget);
    expect(find.byKey(const Key('google-sign-in')), findsOneWidget);
    expect(find.byTooltip('Clip'), findsNothing);
    expect(camera.disposed, isFalse);
    expect(backend.opened, [camera.id]);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a restored session shows all buttons at once', (tester) async {
    await pumpGate(
      tester,
      PresenceApp(
        consentGiven: true,
        cameras: noCameras,
        auth: FakeAuthService.signedIn(),
        rolesClient: FakeRolesClient(),
        mapTiles: const SizedBox(),
        locator: NoLocation(),
      ),
    );
    expect(find.byType(TabBar), findsOneWidget);
    expect(
      find.byTooltip('Signed in as Ana · ana@example.com'),
      findsOneWidget,
    );
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

    await openTab(tester, 'Monitoring');
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
    await openTab(tester, 'Monitoring');
    await revealSystemEvents(tester);

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
      listError: const CameraUnavailable('Camera access is blocked'),
    );
    await pumpAt(tester, const Size(1280, 800), cameras: backend);

    expect(find.textContaining('Could not open the camera'), findsOneWidget);
    expect(find.textContaining('Camera access is blocked'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(backend.lists, 2);
  });

  testWidgets('unexpected camera errors get a human message', (tester) async {
    final backend = FakeCameraBackend(
      [],
      // What reading an undefined navigator.mediaDevices used to show.
      listError: TypeError(),
    );
    await pumpAt(tester, const Size(1280, 800), cameras: backend);

    expect(
      find.text(
        'Could not open the camera\n'
        'Something went wrong while starting the camera.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('TypeError'), findsNothing);
  });

  test('camera errors are described for people', () {
    expect(
      describeCameraError(const CameraUnavailable('No camera was found.')),
      'No camera was found.',
    );
    expect(
      describeCameraError(const CameraAccessDenied()),
      'Camera permission was denied. Allow it in Settings.',
    );
    expect(
      describeCameraError(
        PlatformException(code: 'camera', message: 'Camera not found'),
      ),
      'Camera not found',
    );
    expect(
      describeCameraError(PlatformException(code: 'camera')),
      'Something went wrong while starting the camera.',
    );
    expect(
      describeCameraError(Exception('boom')),
      'Something went wrong while starting the camera.',
    );
  });
}

/// Answers the start check only when the test says so.
class _SlowRolesClient extends FakeRolesClient {
  final answer = Completer<AnonymousAccess>();

  @override
  Future<AnonymousAccess> anonymous() => answer.future;
}
