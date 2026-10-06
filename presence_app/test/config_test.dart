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
}
