import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/config.dart';

void main() {
  const custom = PresenceConfig(
    clip: ClipConfig(
      before: Duration(seconds: 30),
      after: Duration(seconds: 10),
    ),
    camera: CameraConfig(brightness: -0.5),
    history: HistoryConfig(keep: Duration(days: 45)),
    motion: MotionConfig(
      enabled: false,
      threshold: 22,
      cooldown: Duration(minutes: 12),
    ),
  );

  test('defaults', () {
    const c = PresenceConfig();
    expect(c.clip.before, const Duration(seconds: 5));
    expect(c.clip.after, const Duration(seconds: 10));
    expect(c.camera.brightness, 1);
    expect(c.motion.enabled, isTrue);
    expect(c.motion.threshold, 15);
    expect(c.motion.cooldown, const Duration(minutes: 5));
    expect(c.history.keep, const Duration(days: 14));
  });

  test('the Log tab follows the mode until its switch is set', () {
    const unset = LogConfig();
    expect(unset.showIn(dev: true), isTrue);
    expect(unset.showIn(dev: false), isFalse);
    expect(const LogConfig(show: false).showIn(dev: true), isFalse);
    expect(const LogConfig(show: true).showIn(dev: false), isTrue);
    // Unset stays unset in storage, and junk reads as unset.
    expect(unset.toJson(), isEmpty);
    expect(LogConfig.fromJson({'show': 'yes'}), unset);
    const on = PresenceConfig(log: LogConfig(show: true));
    expect(PresenceConfig.fromJson(on.toJson()), on);
  });

  test('the integrations\' streamers: picked ones round-trip, junk is '
      'ignored, and none follows the leader', () {
    const none = IntegrationsConfig();
    expect(none.streamerFor('blink'), isNull);
    expect(none.toJson(), isEmpty);
    final picked = none
        .withStreamer('blink', 'calm_quiet_otter')
        .withStreamer('reolink', 'brave_little_lamp');
    expect(picked.streamerFor('blink'), 'calm_quiet_otter');
    expect(picked.streamerFor('gopro'), isNull);
    final c = const PresenceConfig().copyWith(integrations: picked);
    expect(PresenceConfig.fromJson(c.toJson()), c);
    expect(PresenceConfig.fromJson(c.toJson()).integrations, picked);
    // Back to the leader.
    expect(picked.withStreamer('blink', null).streamerFor('blink'), isNull);
    expect(
      picked.withStreamer('blink', null).streamerFor('reolink'),
      isNotNull,
    );
    // Unknown integrations, bad IDs and non-strings are ignored.
    expect(none.withStreamer('nest', 'calm_quiet_otter'), none);
    expect(none.withStreamer('blink', '../etc'), none);
    expect(
      IntegrationsConfig.fromJson({
        'streamers': {
          'blink': 'calm_quiet_otter',
          'gopro': 'Not An ID',
          'reolink': 7,
          'nest': 'brave_little_lamp',
        },
      }),
      none.withStreamer('blink', 'calm_quiet_otter'),
    );
    expect(IntegrationsConfig.fromJson({'streamers': 'x'}), none);
    // Older records have none.
    expect(PresenceConfig.fromJson(const {}).integrations, none);
  });

  test('round-trips through JSON', () {
    final json = custom.toJson();
    expect(json['version'], PresenceConfig.version);
    expect(PresenceConfig.fromJson(json), custom);
  });

  test('copyWith clamps into range', () {
    final c = const PresenceConfig().copyWith(
      clip: const ClipConfig().copyWith(before: const Duration(hours: 1)),
      camera: const CameraConfig().copyWith(brightness: 9),
      motion: const MotionConfig().copyWith(
        threshold: 0,
        cooldown: const Duration(seconds: 1),
      ),
    );
    expect(c.clip.before, ClipConfig.max);
    expect(c.camera.brightness, CameraConfig.maxBrightness);
    expect(c.motion.threshold, MotionConfig.minThreshold);
    expect(c.motion.cooldown, MotionConfig.minCooldown);
    // Events are kept a day to three months.
    expect(
      const HistoryConfig().copyWith(keep: Duration.zero).keep,
      const Duration(days: 1),
    );
    expect(
      const HistoryConfig().copyWith(keep: const Duration(days: 365)).keep,
      const Duration(days: 90),
    );
  });

  test('missing or invalid stored values fall back to defaults', () {
    final c = PresenceConfig.fromJson({
      'clip': {'beforeMs': 'soon'},
      'motion': {'enabled': 'yes', 'threshold': 999},
    });
    expect(c.clip, const ClipConfig());
    expect(c.camera, const CameraConfig());
    expect(c.motion.enabled, isTrue);
    expect(c.motion.threshold, MotionConfig.maxThreshold);
  });

  test('reads the flat settings record from before the config object', () {
    final c = PresenceConfig.fromLegacy({
      'beforeMs': 30000,
      'afterMs': 10000,
      'brightnessEv': -0.5,
      'motionEnabled': false,
      'motionThreshold': 22,
      'motionCooldownMs': 720000,
    });
    // The flat record had no History setting: the default stands.
    expect(c, custom.copyWith(history: const HistoryConfig()));
  });

  test('the controller notifies only on real changes', () {
    final controller = ConfigController();
    var notified = 0;
    controller.addListener(() => notified++);

    controller.update((c) => c.copyWith());
    expect(notified, 0);

    controller.update(
      (c) => c.copyWith(motion: c.motion.copyWith(threshold: 20)),
    );
    expect(notified, 1);
    expect(controller.motion.threshold, 20);
  });

  group('Connect to live sync', () {
    test('every minute by default; older configs get it too', () {
      expect(const PresenceConfig().live, const LiveConfig());
      expect(const LiveConfig().mode, LiveMode.scheduled);
      expect(const LiveConfig().every, const Duration(minutes: 1));
      // Saved before the setting: the default.
      expect(
        PresenceConfig.fromJson({'version': 1, 'clip': {}}).live,
        const LiveConfig(),
      );
      expect(LiveConfig.fromJson({'mode': 'sometimes'}), const LiveConfig());
    });

    test('the steps: Never first, then 30 s to 60 min, Always last', () {
      expect(LiveConfig.steps, 10);
      expect(
        [for (var i = 0; i < LiveConfig.steps; i++) LiveConfig.ofStep(i).label],
        [
          'Never',
          'Every 30 s',
          'Every 1 min',
          'Every 2 min',
          'Every 5 min',
          'Every 10 min',
          'Every 15 min',
          'Every 30 min',
          'Every 60 min',
          'Always',
        ],
      );
      expect(LiveConfig.ofStep(0), LiveConfig.never);
      expect(LiveConfig.ofStep(9), LiveConfig.always);
      expect(LiveConfig.memberMaxStep, 8);
      expect(LiveConfig.ofStep(LiveConfig.memberMaxStep).label, 'Every 60 min');
      expect(LiveConfig.ofStep(-3), LiveConfig.never);
      expect(LiveConfig.ofStep(42), LiveConfig.always);
      for (var i = 0; i < LiveConfig.steps; i++) {
        expect(LiveConfig.ofStep(i).step, i);
      }
      expect(const LiveConfig().step, 2);
    });

    test('admins are always connected, whatever the setting', () {
      for (var i = 0; i < LiveConfig.steps; i++) {
        expect(
          LiveConfig.ofStep(i).effective(isAdmin: true),
          LiveConfig.always,
        );
      }
    });

    test('members connect as set, but at most every 30 s: Always becomes '
        'every 30 s', () {
      for (var i = 0; i < LiveConfig.memberMaxStep; i++) {
        final live = LiveConfig.ofStep(i);
        expect(live.effective(isAdmin: false), live);
      }
      expect(
        LiveConfig.always.effective(isAdmin: false),
        const LiveConfig(every: Duration(seconds: 30)),
      );
      expect(
        const LiveConfig().effective(isAdmin: false),
        const LiveConfig(every: Duration(minutes: 1)),
      );
      expect(
        const LiveConfig(every: Duration(seconds: 5))
            .effective(isAdmin: false)
            .every,
        const Duration(seconds: 30),
      );
    });

    test('free members: every 15 min at the most often, never Always; '
        'Never stays Never', () {
      LiveConfig free(LiveConfig set) =>
          set.effective(isAdmin: false, isPremium: false);
      expect(free(LiveConfig.never), LiveConfig.never);
      expect(
        free(LiveConfig.always),
        const LiveConfig(every: Duration(minutes: 15), free: true),
      );
      expect(
        free(const LiveConfig()),
        const LiveConfig(every: Duration(minutes: 15), free: true),
      );
      expect(
        free(const LiveConfig(every: Duration(minutes: 60))),
        const LiveConfig(every: Duration(minutes: 60), free: true),
      );
      expect(
        LiveConfig.ofStep(LiveConfig.freeMinStep).every,
        LiveConfig.freeMinEvery,
      );
      // Admins and premium members aren't free.
      expect(
        LiveConfig.always.effective(isAdmin: true, isPremium: false),
        LiveConfig.always,
      );
      expect(const LiveConfig().effective(isAdmin: false).free, isFalse);
      // Never saved: a free config stores as the plain setting.
      expect(
        LiveConfig.fromJson(
          const LiveConfig(every: Duration(minutes: 15), free: true).toJson(),
        ),
        const LiveConfig(every: Duration(minutes: 15)),
      );
    });

    test('round-trips through storage; odd intervals snap to a step', () {
      for (var i = 0; i < LiveConfig.steps; i++) {
        final live = LiveConfig.ofStep(i);
        final config = PresenceConfig(live: live);
        expect(PresenceConfig.fromJson(config.toJson()).live, live);
      }
      expect(
        LiveConfig.fromJson({'mode': 'scheduled', 'everyMs': 7 * 60000}).every,
        const Duration(minutes: 5),
      );
      expect(
        LiveConfig.fromJson({'mode': 'scheduled', 'everyMs': 9e9}).every,
        const Duration(minutes: 60),
      );
      expect(
        LiveConfig.fromJson({'mode': 'scheduled', 'everyMs': 1000}).every,
        const Duration(seconds: 30),
      );
    });
  });
}
