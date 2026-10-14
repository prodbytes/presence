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

  testWidgets('the account sheet: no live sync or cloud backup line (the '
      'other pages have them), this device\'s dot in the connectivity\'s '
      'color, and it fits 320 dp at 2x text', (tester) async {
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
    expect(find.byKey(const Key('connectivity')), findsNothing);
    expect(find.byKey(const Key('cloud-sync-status')), findsNothing);
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
    live.set(LiveSyncState.error, error: 'refused');
    await tester.pump();
    expect(dotOf('presence-calm_sunny_radio_with_a_long_name'), Gruvbox.red);
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
