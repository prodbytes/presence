import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presence_app/auth/account_sheet.dart';
import 'package:presence_app/auth/roles_service.dart';
import 'package:presence_app/cloud/cloud_sync.dart';
import 'package:presence_app/cloud/live_sync.dart';
import 'package:presence_app/connectivity.dart';
import 'package:presence_app/device_presence.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/storage/event_store.dart';
import 'package:presence_app/storage/media_store.dart';
import 'package:presence_app/theme.dart';

import 'fakes.dart';

/// Live sync in whatever state a test sets ([set]).
class FakeLive extends LiveSync {
  FakeLive({this.on = true})
    : super(
        endpoint: 'abc-ats.iot.us-east-1.amazonaws.com',
        region: 'us-east-1',
        connect: (url, clientId, {persistent = false}) =>
            Completer<LiveConnection>().future,
      );

  final bool on;
  LiveSyncState _fakeState = LiveSyncState.off;
  String? _fakeError;
  Duration? _fakeNext;

  void set(LiveSyncState state, {String? error, Duration? next}) {
    _fakeState = state;
    _fakeError = error;
    _fakeNext = next;
    notifyListeners();
  }

  @override
  bool get enabled => on;

  @override
  LiveSyncState get state => _fakeState;

  @override
  String? get error => _fakeError;

  @override
  Duration? get untilNext => _fakeNext;

  @override
  DateTime? seenOf(String deviceId) => null;

  @override
  Future<bool> ping() async => true;
}

void main() {
  late FakeRolesClient client;
  late RolesService roles;
  late StreamController<Set<String>?> changes;
  late CloudSync sync;

  /// Cloud sync set up (signed out here, so "set; syncs once signed in"),
  /// with [live].
  Future<void> setUpSync(WidgetTester tester, LiveSync? live) async {
    changes = StreamController<Set<String>?>.broadcast();
    sync = CloudSync(
      auth: FakeAuthService(),
      backend: FakeCloudBackend(),
      // Never opened: signed out, the sync doesn't need it.
      store: Completer<EventStore>().future,
      media: Completer<MediaStore>().future,
      changes: changes.stream,
      debounce: Duration.zero,
      live: live,
    );
  }

  /// Ends the test: the sync and the roles stop their timers.
  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    sync.dispose();
    roles.dispose();
    await changes.close();
  }

  Future<void> setUpRoles(
    WidgetTester tester, {
    Object? apiError,
    FakeAuthService? auth,
  }) async {
    client = FakeRolesClient()
      ..settings = (oidc: true, aws: true, rbacr: null)
      ..anonymousError = apiError;
    roles = RolesService(
      auth: auth ?? FakeAuthService(),
      client: client,
      oidcClient: true,
      retryDelays: const [Duration(hours: 1)],
    );
    // The start check.
    await tester.pump();
  }

  Future<void> pump(WidgetTester tester, {LiveSync? live}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ConnectivityIndicator(
              roles: roles,
              sync: sync,
              live: live,
              oidcClient: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  String headline(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('connectivity-headline'))).data!;

  Color dot(WidgetTester tester) =>
      (tester
                  .widget<Container>(find.byKey(const Key('connectivity-dot')))
                  .decoration!
              as BoxDecoration)
          .color!;

  testWidgets('live sync not in this build: amber, and it says so', (
    tester,
  ) async {
    await setUpRoles(tester);
    await setUpSync(tester, null);
    await pump(tester);
    expect(headline(tester), "Live sync isn't set up in this build");
    expect(dot(tester), Gruvbox.yellow);
    expect(
      find.bySemanticsLabel(
        RegExp("^Connectivity: Live sync isn't set up in this build\n"),
      ),
      findsOneWidget,
    );
    await done(tester);
  });

  testWidgets('connected: green; then idle with a countdown that runs, '
      'then failed: red with the error, updating as it changes', (
    tester,
  ) async {
    final live = FakeLive()..set(LiveSyncState.connected);
    addTearDown(live.dispose);
    await setUpRoles(tester);
    await setUpSync(tester, live);
    await pump(tester, live: live);
    expect(headline(tester), 'Online · live sync connected');
    expect(dot(tester), Gruvbox.green);

    live.set(LiveSyncState.idle, next: const Duration(seconds: 42));
    await tester.pump();
    expect(headline(tester), 'Live sync idle · next in 0:42');
    expect(dot(tester), Gruvbox.yellow);
    live.set(LiveSyncState.idle, next: const Duration(seconds: 41));
    await tester.pump(const Duration(seconds: 1));
    expect(headline(tester), 'Live sync idle · next in 0:41');

    live.set(LiveSyncState.connecting);
    await tester.pump();
    expect(headline(tester), 'Connecting to live sync…');
    expect(dot(tester), Gruvbox.yellow);

    live.set(LiveSyncState.error, error: 'refused');
    await tester.pump();
    expect(headline(tester), 'Live sync failed');
    expect(dot(tester), Gruvbox.red);
    // Tap for the details: the error is in them.
    await tester.tap(find.byKey(const Key('connectivity')));
    await tester.pump();
    expect(find.byKey(const Key('connectivity-details')), findsOneWidget);
    expect(find.textContaining('Live: failed (refused)'), findsOneWidget);
    expect(find.text('✅ AWS: set; syncs once signed in'), findsOneWidget);
    await tester.tap(find.byKey(const Key('connectivity')));
    await tester.pump();
    expect(find.byKey(const Key('connectivity-details')), findsNothing);
    await done(tester);
  });

  testWidgets('the auth API unreachable: red, offline, even with live sync '
      'connected; asked again when it shows', (tester) async {
    final live = FakeLive()..set(LiveSyncState.connected);
    addTearDown(live.dispose);
    await setUpRoles(tester, apiError: StateError('no network'));
    await setUpSync(tester, live);
    final calls = client.anonymousCalls;
    await pump(tester, live: live);
    expect(client.anonymousCalls, calls + 1);
    expect(headline(tester), "Offline: can't reach the server");
    expect(dot(tester), Gruvbox.red);
    // It answers again: green.
    client.anonymousError = null;
    await tester.pump(const Duration(seconds: 60));
    await tester.pump();
    expect(client.anonymousCalls, calls + 2);
    expect(headline(tester), 'Online · live sync connected');
    await done(tester);
  });

  testWidgets('the account sheet shows it at the top, this device\'s dot in '
      'the same color, and fits 320 dp at 2x text', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final live = FakeLive()
      ..set(LiveSyncState.idle, next: const Duration(minutes: 3));
    addTearDown(live.dispose);
    final auth = FakeAuthService.signedIn();
    await setUpRoles(tester, auth: auth);
    await setUpSync(tester, live);
    final events = StreamController<AppEvent>();
    final log = EventLog(events.stream);
    addTearDown(() {
      log.dispose();
      events.close();
    });
    await roles.refresh();
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountSheet(
            auth: auth,
            roles: roles,
            sync: sync,
            log: log,
            deviceId: 'calm_sunny_radio_with_a_long_name',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('connectivity')), findsOneWidget);
    expect(headline(tester), 'Live sync idle · next in 3:00');
    Color dotOf(String key) =>
        (tester
                    .widget<Container>(
                      find.descendant(
                        of: find.byKey(Key(key)),
                        matching: find.byType(Container),
                      ),
                    )
                    .decoration!
                as BoxDecoration)
            .color!;
    expect(dotOf('presence-calm_sunny_radio_with_a_long_name'), Gruvbox.yellow);
    expect(
      find.byTooltip(RegExp(r'^This device — Live sync idle')),
      findsOneWidget,
    );
    // Above the profile.
    expect(
      tester.getTopLeft(find.byKey(const Key('connectivity'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('profile-id'))).dy),
    );
    live.set(LiveSyncState.error, error: 'refused');
    await tester.pump();
    expect(dotOf('presence-calm_sunny_radio_with_a_long_name'), Gruvbox.red);
    await tester.tap(find.byKey(const Key('connectivity')));
    await tester.pump();
    expect(tester.takeException(), isNull);
    live.set(LiveSyncState.connected);
    await tester.pump();
    expect(dotOf('presence-calm_sunny_radio_with_a_long_name'), Gruvbox.green);
    await done(tester);
  });

  test('the worst check decides, the API first among equals', () {
    final roles = RolesService(
      auth: FakeAuthService(),
      client: FakeRolesClient(),
      oidcClient: true,
    );
    addTearDown(roles.dispose);
    // Before the start check: checking, and no cloud sync in this build.
    final status = Connectivity.of(roles, null, oidcClient: true);
    expect(status.level, PresenceLevel.recent);
    expect(status.headline, 'Checking the connection…');
    expect(status.presence.reason, 'This device — Checking the connection…');
    expect(status.details, hasLength(3));
  });
}
