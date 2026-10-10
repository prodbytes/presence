import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';

import 'package:presence_app/camera_feeds.dart';
import 'package:presence_app/cameras/cameras.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/cloud/cloud_sync.dart';
import 'package:presence_app/cloud/live_sync.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/main.dart';

import 'fakes.dart';
import 'live_sync_test.dart' show FakeBroker, eventsTopic, messageOf;

void main() {
  group('answerCaptureAll', () {
    final noon = DateTime(2026, 10, 4, 12);
    late DateTime clock;
    late AppEventBus bus;
    late List<ClipRequested> clips;
    late CameraRig rig;

    setUp(() async {
      clock = noon;
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
        now: () => clock,
      );
      await rig.load();
    });

    tearDown(() {
      rig.dispose();
      bus.close();
    });

    AppEvent request(String device, {int minutesAgo = 0, String? id}) =>
        AppEvent.captureAll(
          id: id,
          deviceId: device,
          time: clock.subtract(Duration(minutes: minutesAgo)),
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
        request('brave_fox', minutesAgo: -5),
        AppEvent.appStarted(deviceId: 'brave_fox', time: noon),
      ]);
      expect(clips, isEmpty);
    });

    test('the same request twice (live sync, then the bucket): one clip, '
        'even past the 30 s', () async {
      final asked = request('brave_fox', id: 'request-1');
      await answer([asked]);
      clock = clock.add(const Duration(minutes: 1));
      await answer([AppEvent.fromRecord(asked.toRecord())!]);
      expect(clips, hasLength(1));
    });

    test('requests arriving apart make one clip within 10 s, another after '
        'it', () async {
      await answer([request('brave_fox')]);
      clock = clock.add(const Duration(seconds: 9));
      await answer([request('zesty_owl')]);
      expect(clips, hasLength(1));

      clock = clock.add(CameraRig.answerAllEvery);
      await answer([request('quiet_cat')]);
      expect(clips, hasLength(2));
      expect(clips.map((c) => c.trigger), everyElement(ClipTrigger.all));
    });

    test('askAll: one request, then none for a minute', () async {
      final requests = <AppEvent>[];
      bus.stream
          .where((e) => e.type == AppEvent.captureAllType)
          .listen(requests.add);
      expect(rig.askAll(bus)?.time, noon);
      clock = clock.add(const Duration(seconds: 59));
      expect(rig.askAll(bus), isNull);
      clock = clock.add(const Duration(seconds: 1));
      expect(rig.askAll(bus), isNotNull);
      await Future<void>.delayed(Duration.zero);
      expect(requests, hasLength(2));
      // Asking takes no clip here: this camera's cell is live.
      expect(clips, isEmpty);
    });

    test('askAll pressed (Clip in the grid): asks within the minute, but '
        'not within a few seconds of the last request', () async {
      final requests = <AppEvent>[];
      bus.stream
          .where((e) => e.type == AppEvent.captureAllType)
          .listen(requests.add);
      // The grid opens: asked.
      expect(rig.askAll(bus), isNotNull);
      // A press at once (or a double tap): nothing more.
      clock = clock.add(const Duration(seconds: 2));
      expect(rig.askAll(bus, pressed: true), isNull);
      // A press a few seconds on: asks, though the minute isn't over.
      clock = clock.add(CameraRig.pressAllEvery);
      expect(rig.askAll(bus, pressed: true), isNotNull);
      clock = clock.add(CameraRig.pressAllEvery);
      expect(rig.askAll(bus, pressed: true), isNotNull);
      // Reopening the grid still waits for its minute.
      clock = clock.add(const Duration(seconds: 10));
      expect(rig.askAll(bus), isNull);
      await Future<void>.delayed(Duration.zero);
      expect(requests, hasLength(3));
    });
  });

  test('a Capture all request survives storage', () {
    final event = AppEvent.captureAll(deviceId: 'brave_fox', userId: '1');
    final restored = AppEvent.fromRecord(event.toRecord())!;
    expect(restored.type, AppEvent.captureAllType);
    expect(restored.title, 'Capture all');
    expect(restored.deviceId, 'brave_fox');
    // No video of its own: a system event, unlike the clips it asks for.
    expect(EventTimeline.isGrab(restored), isFalse);
  });

  group('the Clip button, synced', () {
    var clock = DateTime(2026, 10, 4, 12);
    late FakeCameraSource camera;
    setUp(() {
      clock = DateTime(2026, 10, 4, 12);
      camera = FakeCameraSource('Main');
    });

    Future<FakeCloudBackend> launch(
      WidgetTester tester, {
      LiveSync? live,
    }) async {
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
          live: live,
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
          ClipMedia(
            url: 'blob:past',
            start: Duration.zero,
            end: Duration(seconds: 5),
          ),
        );
      }
      await settleStorage(tester);
      for (final full in camera.fullCompleters.where((c) => !c.isCompleted)) {
        full.complete(
          ClipMedia(
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
      await tester.tap(find.byKey(const Key('clip')));
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

    int requestsUploaded(FakeCloudBackend cloud) =>
        uploadedEvents(cloud)
            .where((e) => e['type'] == AppEvent.captureAllType)
            .length;

    /// All → None → One → All.
    Future<void> reopenAll(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Turn the camera off'));
      await tester.pump();
      await tester.tap(find.byTooltip('Turn the camera on'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Show all devices'));
      await tester.pump();
    }

    testWidgets('opening All asks every device for a fresh grab, at most '
        'once a minute (with live sync off)', (tester) async {
      final cloud = await launch(tester);
      await tester.tap(find.byTooltip('Show all devices'));
      await tester.pump();
      expect(find.text('Asked every device for a fresh grab'), findsOneWidget);
      await settleStorage(tester);
      await settleStorage(tester);
      expect(requestsUploaded(cloud), 1);
      // Asking takes no clip here: this camera's cell is live.
      expect(
        uploadedEvents(cloud)
            .where((e) => e['trigger'] == ClipTrigger.all.name),
        isEmpty,
      );

      // Again within the minute: nothing more.
      clock = clock.add(const Duration(seconds: 30));
      await reopenAll(tester);
      await settleStorage(tester);
      await settleStorage(tester);
      expect(requestsUploaded(cloud), 1);
      expect(find.text('Asked every device for a fresh grab'), findsNothing);

      // A minute after the first: asks again.
      clock = clock.add(const Duration(seconds: 31));
      await reopenAll(tester);
      await settleStorage(tester);
      await settleStorage(tester);
      expect(requestsUploaded(cloud), 2);
    });

    testWidgets('in All, pressing Clip always asks every device again, '
        'within the minute of opening', (tester) async {
      final cloud = await launch(tester);
      await tester.tap(find.byTooltip('Show all devices'));
      await tester.pump();
      await settleStorage(tester);
      await settleStorage(tester);
      expect(requestsUploaded(cloud), 1);

      clock = clock.add(const Duration(seconds: 20));
      await clip(tester);
      await settleStorage(tester);
      await settleStorage(tester);
      expect(requestsUploaded(cloud), 2);
    });

    testWidgets('another device\'s request over live sync takes one clip '
        'here; its copy in the bucket doesn\'t take another', (tester) async {
      final broker = FakeBroker();
      final live = LiveSync(
        endpoint: 'abc-ats.iot.us-east-1.amazonaws.com',
        region: 'us-east-1',
        connect: broker.connect,
      );
      addTearDown(live.stop);
      final cloud = await launch(tester, live: live);
      live.config = LiveConfig.always;
      await tester.pump();
      await settleStorage(tester);
      expect(live.state, LiveSyncState.connected);

      final record = {
        ...AppEvent.captureAll(
          id: 'request-1',
          deviceId: 'brave_fox',
          time: clock,
        ).toRecord(),
        'profileId': 'automatic_paranoid_axolotl',
      };
      broker.last.deliver(eventsTopic, messageOf(record));
      // Delivered twice (QoS 1 may repeat it).
      broker.last.deliver(eventsTopic, messageOf(record));
      await tester.pump();
      await settleStorage(tester);
      await tester.pump(CameraRig.pastWait);
      await finishRecording(tester);
      int answered() =>
          uploadedEvents(cloud)
              .where((e) => e['trigger'] == ClipTrigger.all.name)
              .length;
      expect(answered(), 1);

      // The bucket's copy, listed by the next pass: no second clip, even
      // past the 30 s between answers.
      cloud.uploads['$prefix/${CloudSync.eventKey(record)}'] = (
        bytes: Uint8List.fromList(utf8.encode(jsonEncode(record))),
        contentType: 'application/json',
      );
      clock = clock.add(const Duration(seconds: 45));
      await tester.pump(const Duration(seconds: 15));
      await tester.pump(const Duration(seconds: 15));
      await tester.pump(const Duration(seconds: 15));
      await tester.pump(CameraRig.pastWait);
      await finishRecording(tester);
      expect(answered(), 1);
    });
  });
}
