import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/camera_feeds.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/main.dart';

import 'fakes.dart';

/// A clip recorded on [device] [minutesAgo] minutes before noon.
ClipRequested clipOf(
  String device, {
  int minutesAgo = 0,
  String userId = 'user-1',
  bool thumbnail = true,
}) => ClipRequested(
  VideoClip.restored(
    id: 'clip-$device-$minutesAgo',
    cameraId: 'cam',
    cameraLabel: 'Back camera',
    before: const Duration(seconds: 5),
    after: const Duration(seconds: 10),
    past: null,
    full: null,
    thumbnail: thumbnail ? onePixelPng : null,
  ),
  time: DateTime(2026, 10, 4, 12).subtract(Duration(minutes: minutesAgo)),
  id: 'event-$device-$minutesAgo',
  deviceId: device,
  userId: userId,
);

void main() {
  group('latestByDevice', () {
    test('the newest image of each other device, sorted by device', () {
      final events = [
        clipOf('this_device'),
        clipOf('zesty_owl', minutesAgo: 1),
        clipOf('brave_fox', minutesAgo: 2, thumbnail: false),
        clipOf('brave_fox', minutesAgo: 3),
        clipOf('zesty_owl', minutesAgo: 4),
        AppEvent.appStarted(deviceId: 'quiet_cat', userId: 'user-1'),
        clipOf('other_users', userId: 'user-2'),
        AppEvent.appStarted(),
      ]..sort((a, b) => b.time.compareTo(a.time));

      final latest = latestByDevice(
        events,
        thisDevice: 'this_device',
        userId: 'user-1',
      );

      expect(latest.map((d) => d.deviceId), [
        'brave_fox',
        'quiet_cat',
        'zesty_owl',
      ]);
      // Its newest clip with a thumbnail, not its newest clip.
      expect(latest[0].clip?.id, 'event-brave_fox-3');
      expect(latest[2].clip?.id, 'event-zesty_owl-1');
      // A device without images still has a cell.
      expect(latest[1].image, isNull);
    });

    test('every user counts without a user (dev)', () {
      final latest = latestByDevice([
        clipOf('other_users', userId: 'user-2'),
      ], thisDevice: 'this_device');
      expect(latest.single.deviceId, 'other_users');
    });
  });

  test('gridColumns fits 16:9 cells', () {
    const wide = Size(1600, 900);
    expect(gridColumns(1, wide), 1);
    expect(gridColumns(4, wide), 2);
    expect(gridColumns(3, const Size(1600, 300)), 3);
    expect(gridColumns(3, const Size(400, 900)), 1);
  });

  test('describeAge', () {
    expect(describeAge(const Duration(seconds: 30)), 'just now');
    expect(describeAge(const Duration(minutes: 5)), '5 min ago');
    expect(describeAge(const Duration(hours: 3)), '3 h ago');
    expect(describeAge(const Duration(days: 2)), '2 d ago');
  });

  group('the grid', () {
    late StreamController<AppEvent> bus;
    late EventLog log;
    late CameraRig rig;
    late FakeCameraBackend backend;

    setUp(() async {
      bus = StreamController<AppEvent>.broadcast();
      log = EventLog(bus.stream)
        ..addHistory([
          clipOf('brave_fox', minutesAgo: 3),
          clipOf('zesty_owl', minutesAgo: 1),
        ]);
      backend = openFakes([FakeCameraSource('Main')]);
      rig = CameraRig(backend: backend, config: ConfigController());
      await rig.load();
    });

    tearDown(() {
      rig.dispose();
      bus.close();
    });

    Future<void> show(WidgetTester tester, {required bool all}) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: CameraFeedsView(
            rig: rig,
            log: log,
            deviceId: 'this_device',
            userId: 'user-1',
            showAll: all,
          ),
        ),
      );
    }

    testWidgets('this camera top left, then each device\'s latest image', (
      tester,
    ) async {
      await show(tester, all: true);

      final live = tester.getRect(find.byKey(const Key('preview-Main')));
      final fox = tester.getRect(
        find.byKey(const Key('device-image-brave_fox')),
      );
      final owl = tester.getRect(
        find.byKey(const Key('device-image-zesty_owl')),
      );
      // Two columns of two at 1280×(800 − bars): live, fox / owl.
      expect(live.left, lessThan(fox.left));
      expect(live.top, closeTo(fox.top, 1));
      expect(owl.top, greaterThan(live.bottom - 1));
      expect(owl.left, closeTo(live.left, 1));
      // Clear of the app bar.
      expect(live.top, greaterThanOrEqualTo(kToolbarHeight));
      expect(find.text('this_device · live'), findsOneWidget);
      expect(find.textContaining('brave_fox · '), findsOneWidget);
    });

    testWidgets('without All, only the camera, full screen', (tester) async {
      await show(tester, all: false);

      final live = tester.getRect(find.byKey(const Key('preview-Main')));
      expect(live, Offset.zero & const Size(1280, 800));
      expect(find.byKey(const Key('device-image-brave_fox')), findsNothing);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('switching keeps the same preview: the camera stays open', (
      tester,
    ) async {
      await show(tester, all: false);
      final before = tester.element(find.byKey(const Key('preview-Main')));
      await show(tester, all: true);
      await show(tester, all: false);

      expect(tester.element(find.byKey(const Key('preview-Main'))), before);
      expect(backend.opened, ['cam-Main']);
    });
  });

  testWidgets('the All button toggles the grid on the Camera tab', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      PresenceApp(
        consentGiven: true,
        cameras: openFakes([FakeCameraSource('Main')]),
        mediaIo: fakeMediaIo,
        auth: FakeAuthService.signedIn(),
        rolesClient: FakeRolesClient(),
        mapTiles: const SizedBox(),
        locator: NoLocation(),
      ),
    );
    await tester.pumpAndSettle();
    await settleStorage(tester);

    // Left of Clip, clear of the status pills.
    final all = tester.getRect(find.byTooltip('Show all devices'));
    expect(all.right, lessThan(tester.getRect(find.byTooltip('Clip')).left));
    expect(
      tester.getRect(find.byKey(const Key('camera-status'))).right,
      lessThan(all.left),
    );

    await tester.tap(find.byTooltip('Show all devices'));
    await tester.pump();
    expect(find.textContaining('· live'), findsOneWidget);
    final live = tester.getRect(find.byKey(const Key('preview-Main')));
    expect(live.width, lessThan(1280));

    await tester.tap(find.byTooltip('Show only this camera'));
    await tester.pump();
    expect(find.textContaining('· live'), findsNothing);
  });
}
