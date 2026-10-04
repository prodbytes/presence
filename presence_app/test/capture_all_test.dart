import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';

import 'package:presence_app/camera_feeds.dart';
import 'package:presence_app/cameras/cameras.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/cloud/cloud_sync.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/main.dart';

import 'fakes.dart';

void main() {
  group('answerCaptureAll', () {
    final noon = DateTime(2026, 10, 4, 12);
    late AppEventBus bus;
    late List<ClipRequested> clips;
    late CameraRig rig;

    setUp(() async {
      bus = AppEventBus();
      clips = [];
      bus.stream
          .where((e) => e is ClipRequested)
          .cast<ClipRequested>()
          .listen(clips.add);
      rig = CameraRig(
        backend: openFakes([FakeCameraSource('Main')]),
        config: ConfigController(),
        bus: bus,
        now: () => noon,
      );
      await rig.load();
    });

    tearDown(() {
      rig.dispose();
      bus.close();
    });

    AppEvent request(String device, {int minutesAgo = 0}) =>
        AppEvent.captureAll(
          deviceId: device,
          time: noon.subtract(Duration(minutes: minutesAgo)),
        );

    Future<void> answer(List<AppEvent> events) async {
      rig.answerCaptureAll(events, deviceId: 'this_device');
      // The clip's event waits up to pastWait for the "before" part.
      await Future<void>.delayed(CameraRig.pastWait * 1.5);
    }

    test('another device\'s fresh request takes one clip here', () async {
      await answer([request('brave_fox'), request('zesty_owl', minutesAgo: 1)]);
      expect(clips.map((c) => c.trigger), [ClipTrigger.all]);
    });

    test('not this device\'s own, an old one, or other events', () async {
      await answer([
        request('this_device'),
        request('brave_fox', minutesAgo: 5),
        AppEvent.appStarted(deviceId: 'brave_fox', time: noon),
      ]);
      expect(clips, isEmpty);
    });
  });

  test('a Capture all request survives storage', () {
    final event = AppEvent.captureAll(deviceId: 'brave_fox', userId: '1');
    final restored = AppEvent.fromRecord(event.toRecord())!;
    expect(restored.type, AppEvent.captureAllType);
    expect(restored.title, 'Capture all');
    expect(restored.deviceId, 'brave_fox');
    expect(EventTimeline.isGrab(restored), isTrue);
  });

  group('the Clip button, synced', () {
    var clock = DateTime(2026, 10, 4, 12);
    late FakeCameraSource camera;
    setUp(() {
      clock = DateTime(2026, 10, 4, 12);
      camera = FakeCameraSource('Main');
    });

    Future<FakeCloudBackend> launch(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final cloud = FakeCloudBackend();
      await tester.pumpWidget(
        PresenceApp(
          consentGiven: true,
          storage: newIdbFactoryMemory(),
          cameras: openFakes([camera]),
          mediaIo: fakeMediaIo,
          now: () => clock,
          auth: FakeAuthService.signedIn(),
          rolesClient: FakeRolesClient(),
          cloud: cloud,
          mapTiles: const SizedBox(),
          locator: NoLocation(),
        ),
      );
      await tester.pumpAndSettle();
      await settleStorage(tester);
      await tester.pumpAndSettle();
      return cloud;
    }

    const prefix = 'us-east-1:identity';

    List<Map<String, Object?>> uploadedEvents(FakeCloudBackend cloud) => [
      for (final MapEntry(:key, :value) in cloud.uploads.entries)
        if (key.startsWith('$prefix/events/'))
          (jsonDecode(utf8.decode(value.bytes)) as Map).cast<String, Object?>(),
    ];

    /// Finishes the clips' recordings, so they're saved and upload.
    Future<void> finishRecording(WidgetTester tester) async {
      for (final past in camera.pastCompleters.where((c) => !c.isCompleted)) {
        past.complete(
          const ClipMedia(
            url: 'blob:past',
            start: Duration.zero,
            end: Duration(seconds: 5),
          ),
        );
      }
      await settleStorage(tester);
      for (final full in camera.fullCompleters.where((c) => !c.isCompleted)) {
        full.complete(
          const ClipMedia(
            url: 'blob:full',
            start: Duration.zero,
            end: Duration(seconds: 15),
          ),
        );
      }
      await settleStorage(tester);
      await settleStorage(tester);
    }

    Future<void> clip(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Clip'));
      await tester.pump(CameraRig.pastWait);
      await tester.pumpAndSettle();
      await finishRecording(tester);
    }

    testWidgets('alone, only this camera\'s clip', (tester) async {
      final cloud = await launch(tester);
      await clip(tester);

      final events = uploadedEvents(cloud);
      expect(
        events.where((e) => e['type'] == AppEvent.captureAllType),
        isEmpty,
      );
      expect(
        events
            .where((e) => e['type'] == ClipRequested.clipRequestedType)
            .map((e) => e['trigger']),
        [ClipTrigger.manual.name],
      );
    });

    testWidgets('with All, a Capture all request and this camera\'s clip', (
      tester,
    ) async {
      final cloud = await launch(tester);
      await tester.tap(find.byTooltip('Show all devices'));
      await tester.pump();
      await clip(tester);

      final events = uploadedEvents(cloud);
      expect(
        events.where((e) => e['type'] == AppEvent.captureAllType),
        hasLength(1),
      );
      expect(
        events
            .where((e) => e['type'] == ClipRequested.clipRequestedType)
            .map((e) => e['trigger']),
        [ClipTrigger.all.name],
      );
      expect(find.textContaining('Capture all · saving'), findsOneWidget);
    });

    testWidgets('another device\'s request, fetched, takes a clip here', (
      tester,
    ) async {
      final cloud = await launch(tester);
      final record = {
        ...AppEvent.captureAll(
          deviceId: 'brave_fox',
          userId: '1',
          time: clock,
        ).toRecord(),
      };
      cloud.uploads['$prefix/${CloudSync.eventKey(record)}'] = (
        bytes: Uint8List.fromList(utf8.encode(jsonEncode(record))),
        contentType: 'application/json',
      );

      // The next pass brings it down; the clip goes up with the one after.
      clock = clock.add(const Duration(seconds: 15));
      await tester.pump(const Duration(seconds: 15));
      await tester.pump(CameraRig.pastWait);
      await finishRecording(tester);

      // (The startup clip may come too, the camera being open 15 s.)
      final clips = uploadedEvents(cloud)
          .where((e) => e['trigger'] == ClipTrigger.all.name)
          .toList();
      expect(clips, hasLength(1));
      expect(clips.single['deviceId'], isNot('brave_fox'));
    });
  });
}
