import 'package:flutter_test/flutter_test.dart';

import 'package:presence_app/config.dart';

void main() {
  const custom = PresenceConfig(
    clip: ClipConfig(
      before: Duration(seconds: 30),
      after: Duration(seconds: 10),
    ),
    camera: CameraConfig(brightness: -0.5),
    motion: MotionConfig(
      enabled: false,
      threshold: 22,
      cooldown: Duration(minutes: 12),
    ),
  );

  test('defaults', () {
    const c = PresenceConfig();
    expect(c.clip.before, const Duration(seconds: 15));
    expect(c.clip.after, const Duration(seconds: 15));
    expect(c.camera.brightness, 1);
    expect(c.motion.enabled, isTrue);
    expect(c.motion.threshold, 10);
    expect(c.motion.cooldown, const Duration(minutes: 5));
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
    expect(c, custom);
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
