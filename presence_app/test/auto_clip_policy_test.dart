import 'package:flutter_test/flutter_test.dart';
import 'package:presence_app/camera_feeds.dart';
import 'package:presence_app/clips.dart' show ClipTrigger;
import 'package:presence_app/config.dart';
import 'package:presence_app/events.dart';

void main() {
  final t0 = DateTime.utc(2026, 10, 7, 12);

  group('AutoClipPolicy', () {
    test('the cooldown runs from the latest clip, clamped to now', () {
      const cooldown = Duration(minutes: 1);
      expect(
        AutoClipPolicy.cooldownEnds(
          lastClip: t0,
          now: t0.add(const Duration(seconds: 20)),
          cooldown: cooldown,
        ),
        t0.add(cooldown),
      );
      expect(
        AutoClipPolicy.cooldownEnds(
          lastClip: t0,
          now: t0.add(cooldown),
          cooldown: cooldown,
        ),
        isNull,
      );
      // A clip "in the future" counts as now: never longer than its length.
      expect(
        AutoClipPolicy.cooldownEnds(
          lastClip: t0.add(const Duration(hours: 1)),
          now: t0,
          cooldown: cooldown,
        ),
        t0.add(cooldown),
      );
    });

    test('no cooldown with motion and scheduled clips both off', () {
      const off = MotionConfig(enabled: false);
      expect(
        AutoClipPolicy.automaticClips(off, const ScheduleConfig()),
        isTrue,
      );
      expect(
        AutoClipPolicy.automaticClips(
          off,
          const ScheduleConfig(enabled: false),
        ),
        isFalse,
      );
    });

    test('the next scheduled clip counts from the last one, or app start', () {
      const schedule = ScheduleConfig(every: Duration(hours: 3));
      expect(
        AutoClipPolicy.nextScheduledClip(
          schedule,
          lastScheduled: null,
          scheduleFrom: t0,
        ),
        t0.add(const Duration(hours: 3)),
      );
      final last = t0.add(const Duration(hours: 1));
      expect(
        AutoClipPolicy.nextScheduledClip(
          schedule,
          lastScheduled: last,
          scheduleFrom: t0,
        ),
        last.add(const Duration(hours: 3)),
      );
      expect(
        AutoClipPolicy.nextScheduledClip(
          const ScheduleConfig(enabled: false),
          lastScheduled: null,
          scheduleFrom: t0,
        ),
        isNull,
      );
    });

    test('the countdown waits for the cooldown and stops at zero', () {
      final due = t0.add(const Duration(minutes: 1));
      expect(
        AutoClipPolicy.untilScheduledClip(
          due: due,
          cooldownEnds: null,
          now: t0,
        ),
        const Duration(minutes: 1),
      );
      expect(
        AutoClipPolicy.untilScheduledClip(
          due: due,
          cooldownEnds: t0.add(const Duration(minutes: 2)),
          now: t0,
        ),
        const Duration(minutes: 2),
      );
      expect(
        AutoClipPolicy.untilScheduledClip(
          due: due,
          cooldownEnds: null,
          now: due.add(const Duration(seconds: 1)),
        ),
        Duration.zero,
      );
      expect(
        AutoClipPolicy.untilScheduledClip(
          due: null,
          cooldownEnds: null,
          now: t0,
        ),
        isNull,
      );
    });

    test('startup clip first, once the before part is full; then on due', () {
      const before = Duration(seconds: 5);
      final due = t0.add(const Duration(hours: 3));
      ClipTrigger? at(Duration sinceOpen, {required bool startupTaken}) =>
          AutoClipPolicy.scheduledClip(
            due: due,
            openedAt: t0,
            now: t0.add(sinceOpen),
            startupTaken: startupTaken,
            before: before,
          );
      expect(at(const Duration(seconds: 4), startupTaken: false), isNull);
      expect(
        at(const Duration(seconds: 5), startupTaken: false),
        ClipTrigger.startup,
      );
      expect(at(const Duration(hours: 1), startupTaken: true), isNull);
      expect(
        at(const Duration(hours: 3), startupTaken: true),
        ClipTrigger.scheduled,
      );
    });
  });

  group('MotionTrigger', () {
    const motion = MotionConfig(threshold: 2);

    test('fires after enough frames in a row over the threshold', () {
      final trigger = MotionTrigger();
      for (var i = 1; i < MotionTrigger.framesToTrigger; i++) {
        expect(trigger.add(5, motion), isFalse);
      }
      expect(trigger.add(5, motion), isTrue);
      // Held back (not reset): the next frame over fires again.
      expect(trigger.add(5, motion), isTrue);
      trigger.reset();
      expect(trigger.add(5, motion), isFalse);
    });

    test('a frame under it, no score, or motion off starts over', () {
      final trigger = MotionTrigger();
      for (final breaker in <(double?, MotionConfig)>[
        (1, motion),
        (null, motion),
        (5, const MotionConfig(enabled: false, threshold: 2)),
      ]) {
        trigger.add(5, motion);
        trigger.add(5, motion);
        expect(trigger.add(breaker.$1, breaker.$2), isFalse);
        expect(trigger.add(5, motion), isFalse);
        trigger.reset();
      }
    });
  });

  group('CaptureAll', () {
    AppEvent request(String id, String device, DateTime time) =>
        AppEvent.captureAll(id: id, time: time, deviceId: device);

    test('asks at most once per askAllEvery, or pressAllEvery pressed', () {
      final all = CaptureAll();
      expect(all.ask(t0), isTrue);
      expect(all.ask(t0.add(const Duration(seconds: 30))), isFalse);
      expect(
        all.ask(t0.add(const Duration(seconds: 4)), pressed: true),
        isFalse,
      );
      expect(all.ask(t0.add(CaptureAll.pressAllEvery), pressed: true), isTrue);
    });

    test('answers fresh requests from others once, rate limited', () {
      final all = CaptureAll();
      expect(
        all.shouldAnswer([request('a', 'me', t0)], deviceId: 'me', now: t0),
        isFalse,
      );
      expect(
        all.shouldAnswer(
          [request('b', 'other', t0.subtract(CaptureAll.captureAllWithin))],
          deviceId: 'me',
          now: t0,
        ),
        isFalse,
      );
      expect(
        all.shouldAnswer([request('c', 'other', t0)], deviceId: 'me', now: t0),
        isTrue,
      );
      // Seen already.
      expect(
        all.shouldAnswer([request('c', 'other', t0)], deviceId: 'me', now: t0),
        isFalse,
      );
      all.tookClip(t0);
      expect(
        all.shouldAnswer([request('d', 'other', t0)], deviceId: 'me', now: t0),
        isFalse,
      );
      final later = t0.add(CaptureAll.answerAllEvery);
      expect(
        all.shouldAnswer(
          [request('e', 'other', later)],
          deviceId: 'me',
          now: later,
        ),
        isTrue,
      );
    });
  });
}
