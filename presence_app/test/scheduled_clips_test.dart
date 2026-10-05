import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idb_shim/idb_shim.dart';

import 'package:presence_app/camera_feeds.dart';
import 'package:presence_app/cameras/cameras.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/main.dart';
import 'package:presence_app/recognition/frames.dart';
import 'package:presence_app/recognition/image.dart';
import 'package:presence_app/recognition/recognizer.dart';
import 'package:presence_app/recognition/runtime.dart';
import 'package:presence_app/recognition/vision.dart';
import 'package:presence_app/settings.dart';

import 'fakes.dart';

const media = ClipMedia(
  url: 'blob:fake',
  start: Duration.zero,
  end: Duration(seconds: 15),
);

void main() {
  _endToEnd();

  group('CameraRig on a schedule', () {
    late DateTime now;
    late ConfigController config;
    late AppEventBus bus;
    late List<ClipRequested> clips;
    late CameraRig rig;

    Future<void> start(WidgetTester tester, {ScheduleConfig? schedule}) async {
      now = DateTime(2026, 10, 1, 12);
      config = ConfigController();
      if (schedule != null) {
        config.update((c) => c.copyWith(schedule: schedule));
      }
      bus = AppEventBus();
      clips = [];
      bus.stream.listen((e) {
        if (e is ClipRequested) clips.add(e);
      });
      rig = CameraRig(
        backend: openFakes([FakeCameraSource('Main', immediatePast: media)]),
        config: config,
        bus: bus,
        now: () => now,
      );
      await rig.load();
      await tester.pump();
    }

    /// Stops the rig's timer before the test ends (flutter_test checks for
    /// pending timers before tear-down).
    Future<void> stop() async {
      rig.dispose();
      await bus.close();
    }

    /// Moves the clock and the timers together.
    Future<void> advance(WidgetTester tester, Duration by) async {
      final step = CameraRig.scheduleCheck;
      for (var t = Duration.zero; t < by; t += step) {
        now = now.add(step);
        await tester.pump(step);
      }
    }

    testWidgets('a startup clip, once the "before" part is full', (
      tester,
    ) async {
      await start(tester);
      expect(clips, isEmpty, reason: 'the 5 s before part is still empty');

      await advance(tester, const Duration(seconds: 5));
      expect(clips.map((c) => c.trigger), [ClipTrigger.startup]);
      expect(clips.single.title, 'Startup clip');
      expect(clips.single.icon, Icons.power_settings_new);
      // Like any clip: a "before" part and a full clip on the way.
      expect(clips.single.clip.past, isNotNull);
      await stop();
    });

    testWidgets('then one every 3 hours by default', (tester) async {
      await start(tester);
      expect(rig.startupClipPending, isTrue);
      await advance(tester, const Duration(seconds: 5));
      final startup = now;
      expect(rig.startupClipPending, isFalse);
      expect(rig.nextScheduledClip, startup.add(const Duration(hours: 3)));
      expect(rig.untilScheduledClip, const Duration(hours: 3));

      await advance(tester, const Duration(minutes: 179));
      expect(rig.untilScheduledClip, const Duration(minutes: 1));
      expect(clips, hasLength(1), reason: 'not yet');
      await advance(tester, const Duration(minutes: 1));
      expect(clips.map((c) => c.trigger), [
        ClipTrigger.startup,
        ClipTrigger.scheduled,
      ]);
      expect(clips.last.title, 'Scheduled clip');
      expect(clips.last.icon, Icons.schedule);
      expect(rig.untilScheduledClip, const Duration(hours: 3));
      await stop();
    });

    testWidgets('Settings counts down to the next clip', (tester) async {
      await start(tester);
      Future<void> show() => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ScheduledClipCountdown(rig: rig)),
        ),
      );
      await show();
      expect(find.text('Startup clip: once the camera is ready'), findsOne);

      await advance(tester, const Duration(seconds: 5));
      await tester.pump();
      expect(find.text('Next clip in 3 h 0 min 0 s'), findsOne);
      // It ticks every second.
      await advance(tester, const Duration(seconds: 5));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Next clip in 2 h 59 min 55 s'), findsOne);

      // Due with no camera open: taken once one is.
      rig.config.update(
        (c) => c.copyWith(
          schedule: c.schedule.copyWith(every: const Duration(minutes: 30)),
        ),
      );
      now = now.add(const Duration(hours: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Next clip: due, once a camera is open'), findsOne);

      rig.config.update(
        (c) => c.copyWith(schedule: c.schedule.copyWith(enabled: false)),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const Key('schedule-countdown')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await stop();
    });

    testWidgets('a new interval applies from the last clip', (tester) async {
      await start(tester);
      await advance(tester, const Duration(seconds: 15));
      config.update(
        (c) => c.copyWith(
          schedule: c.schedule.copyWith(every: const Duration(minutes: 30)),
        ),
      );
      await advance(tester, const Duration(minutes: 30));
      expect(clips.map((c) => c.trigger), [
        ClipTrigger.startup,
        ClipTrigger.scheduled,
      ]);
      await advance(tester, const Duration(minutes: 30));
      expect(clips, hasLength(3));
      await stop();
    });

    testWidgets('switched off: no startup clip and no schedule', (
      tester,
    ) async {
      await start(tester, schedule: const ScheduleConfig(enabled: false));
      expect(rig.nextScheduledClip, isNull);
      await advance(tester, const Duration(hours: 25));
      expect(clips, isEmpty);
      await stop();
    });
  });

  test('the interval is half an hour to a day, stored with the config', () {
    expect(const ScheduleConfig().enabled, isTrue);
    expect(const ScheduleConfig().every, const Duration(minutes: 180));
    expect(
      const ScheduleConfig().copyWith(every: const Duration(minutes: 1)).every,
      const Duration(minutes: 30),
    );
    expect(
      const ScheduleConfig().copyWith(every: const Duration(days: 3)).every,
      const Duration(days: 1),
    );
    final config = const PresenceConfig().copyWith(
      schedule: const ScheduleConfig(
        enabled: false,
        every: Duration(minutes: 90),
      ),
    );
    expect(PresenceConfig.fromJson(config.toJson()), config);
    // Configs stored before the setting existed get the default.
    expect(
      PresenceConfig.fromJson({'version': 1}).schedule,
      const ScheduleConfig(),
    );
  });

  test('intervals read as minutes and hours', () {
    expect(formatEvery(const Duration(minutes: 30)), '30 min');
    expect(formatEvery(const Duration(minutes: 240)), '4 h');
    expect(formatEvery(const Duration(minutes: 90)), '1 h 30 min');
    expect(formatEvery(const Duration(days: 1)), '24 h');
  });

  test('countdowns read as hours, minutes and seconds, rounded up', () {
    expect(formatCountdown(const Duration(hours: 3)), '3 h 0 min 0 s');
    expect(
      formatCountdown(const Duration(hours: 2, minutes: 59, seconds: 58)),
      '2 h 59 min 58 s',
    );
    expect(formatCountdown(const Duration(minutes: 4)), '4 min 0 s');
    expect(formatCountdown(const Duration(milliseconds: 11200)), '12 s');
    expect(formatCountdown(const Duration(milliseconds: 1)), '1 s');
  });

  testWidgets('Settings: a switch and an interval slider', (tester) async {
    final config = ConfigController();
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsView(config: config, nextClip: const Text('Next')),
        ),
      ),
    );
    expect(find.text('Scheduled clips'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget, reason: 'the countdown');
    expect(find.text('3 h'), findsOneWidget);

    final slider = find.descendant(
      of: find.byKey(const Key('schedule-every-slider')),
      matching: find.byType(Slider),
    );
    await tester.drag(slider, const Offset(-1000, 0));
    await tester.pump();
    expect(config.schedule.every, const Duration(minutes: 30));
    await tester.drag(slider, const Offset(1000, 0));
    await tester.pump();
    expect(config.schedule.every, const Duration(days: 1));
    expect(find.text('24 h'), findsOneWidget);

    await tester.tap(find.byKey(const Key('schedule-switch')));
    await tester.pump();
    expect(config.schedule.enabled, isFalse);
    expect(tester.widget<Slider>(slider).onChanged, isNull);
    expect(find.text('Next'), findsNothing);
  });
}

/// Recognition with fake models: every frame shows a dog.
class _DogVision extends Vision {
  int frames = 0;

  @override
  Future<FrameAnalysis> analyse(
    RgbaImage image, {
    bool faces = true,
    bool subjects = true,
    Set<SeenKind>? kinds,
    int? maxSeen,
  }) async {
    frames++;
    return const FrameAnalysis(objects: {'dog': 0.9});
  }
}

class _Runtime implements TfliteRuntime {
  @override
  bool get supported => true;

  @override
  Future<TfliteModel> load(Uint8List bytes) => throw UnimplementedError();
}

class _OneFrame implements ClipFrameSampler {
  @override
  bool get supported => true;

  @override
  Stream<SampledFrame> sample(
    ClipMedia media, {
    required Duration every,
    int maxWidth = 960,
  }) async* {
    yield SampledFrame(
      const Duration(seconds: 1),
      RgbaImage(1, 1, Uint8List(4)),
      () async => onePixelPng,
    );
  }
}

/// The whole app, signed in and syncing: the grab at start and the one 3 h
/// later are each triggered, captured, recognized and synced.
void _endToEnd() {
  testWidgets('at start and every 3 h: triggered, captured, recognized and '
      'synced', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var clock = DateTime(2026, 10, 5, 12);
    final camera = FakeCameraSource('Main');
    final cloud = FakeCloudBackend();
    final vision = _DogVision();
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
        recognizer: (bus, log, config) => SubjectRecognizer(
          bus: bus,
          log: log,
          config: config,
          runtime: _Runtime(),
          sampler: _OneFrame(),
          loadVision: () async => vision,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await settleStorage(tester);

    /// Moves the clock and the timers together, in schedule checks.
    Future<void> advance(Duration by) async {
      final step = CameraRig.scheduleCheck;
      for (var t = Duration.zero; t < by; t += step) {
        clock = clock.add(step);
        await tester.pump(step);
      }
    }

    /// The camera finishes recording the clips, which are then saved,
    /// searched and uploaded.
    Future<void> finishRecording() async {
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
      for (var i = 0; i < 4; i++) {
        await settleStorage(tester);
      }
    }

    const prefix = 'us-east-1:identity';
    List<Map<String, Object?>> uploadedClips() => [
      for (final MapEntry(:key, :value) in cloud.uploads.entries)
        if (key.startsWith('$prefix/events/'))
          if ((jsonDecode(utf8.decode(value.bytes)) as Map)
                  .cast<String, Object?>()
              case final e when e['type'] == ClipRequested.clipRequestedType)
            e,
    ];

    /// The grab with [trigger] made it all the way: its event uploaded,
    /// complete and with what recognition saw, and its recording and
    /// thumbnail uploaded beside it.
    void expectSynced(ClipTrigger trigger) {
      final event = uploadedClips().singleWhere(
        (e) => e['trigger'] == trigger.name,
      );
      expect(event['clipState'], 'complete');
      expect((event['objectTags']! as List).map((o) => (o as Map)['label']), [
        'dog',
      ]);
      final media = '$prefix/media/${event['clipId']}';
      expect(
        cloud.uploads.keys.where((k) => k.startsWith(media)),
        containsAll(['$media.webm', '$media.jpg']),
      );
    }

    // At load: nothing until the 5 s "before" part is full, then the
    // startup grab.
    expect(camera.requests, isEmpty);
    await advance(const Duration(seconds: 5));
    expect(camera.requests, hasLength(1), reason: 'triggered and captured');
    await finishRecording();
    expect(vision.frames, 1, reason: 'recognized');
    expectSynced(ClipTrigger.startup);

    // Not a moment early.
    await advance(const Duration(hours: 3) - const Duration(minutes: 1));
    expect(camera.requests, hasLength(1));
    await advance(const Duration(minutes: 1));
    expect(camera.requests, hasLength(2));
    await finishRecording();
    expect(vision.frames, 2);
    expectSynced(ClipTrigger.scheduled);
    expect(uploadedClips(), hasLength(2));

    await tester.pumpWidget(const SizedBox());
    await settleStorage(tester);
  });
}
