import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/camera_feeds.dart';
import 'package:presence_app/cameras/cameras.dart';
import 'package:presence_app/clips.dart';
import 'package:presence_app/config.dart';
import 'package:presence_app/events.dart';
import 'package:presence_app/settings.dart';

import 'fakes.dart';

const media = ClipMedia(
  url: 'blob:fake',
  start: Duration.zero,
  end: Duration(seconds: 15),
);

void main() {
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

    testWidgets('then one every 240 minutes by default', (tester) async {
      await start(tester);
      await advance(tester, const Duration(seconds: 5));
      final startup = now;
      expect(rig.nextScheduledClip, startup.add(const Duration(minutes: 240)));

      await advance(tester, const Duration(minutes: 239));
      expect(clips, hasLength(1), reason: 'not yet');
      await advance(tester, const Duration(minutes: 1));
      expect(clips.map((c) => c.trigger), [
        ClipTrigger.startup,
        ClipTrigger.scheduled,
      ]);
      expect(clips.last.title, 'Scheduled clip');
      expect(clips.last.icon, Icons.schedule);
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
    expect(const ScheduleConfig().every, const Duration(minutes: 240));
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

  testWidgets('Settings: a switch and an interval slider', (tester) async {
    final config = ConfigController();
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsView(config: config)),
      ),
    );
    expect(find.text('Scheduled clips'), findsOneWidget);
    expect(find.text('4 h'), findsOneWidget);

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
  });
}
