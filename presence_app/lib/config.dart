import 'package:flutter/foundation.dart';

/// The app's whole user configuration, as one immutable value.
///
/// Grouped by area; each group owns its defaults and limits, and clamps
/// values into range. Change it through [ConfigController.update]:
///
/// ```dart
/// config.update((c) => c.copyWith(motion: c.motion.copyWith(enabled: false)));
/// ```
///
/// It's stored as one versioned JSON record (see `persistence.dart`).
@immutable
class PresenceConfig {
  const PresenceConfig({
    this.clip = const ClipConfig(),
    this.camera = const CameraConfig(),
    this.motion = const MotionConfig(),
  });

  static const int version = 1;

  final ClipConfig clip;
  final CameraConfig camera;
  final MotionConfig motion;

  PresenceConfig copyWith({
    ClipConfig? clip,
    CameraConfig? camera,
    MotionConfig? motion,
  }) => PresenceConfig(
    clip: clip ?? this.clip,
    camera: camera ?? this.camera,
    motion: motion ?? this.motion,
  );

  Map<String, Object?> toJson() => {
    'version': version,
    'clip': clip.toJson(),
    'camera': camera.toJson(),
    'motion': motion.toJson(),
  };

  /// Reads a stored config. Missing or invalid values fall back to their
  /// defaults, and values are clamped into range, so older or hand-edited
  /// records still load.
  factory PresenceConfig.fromJson(Map<String, Object?> json) => PresenceConfig(
    clip: ClipConfig.fromJson(_map(json['clip'])),
    camera: CameraConfig.fromJson(_map(json['camera'])),
    motion: MotionConfig.fromJson(_map(json['motion'])),
  );

  /// Reads the settings record from before the config object: one flat map
  /// (`beforeMs`, `afterMs`, `brightnessEv`, `motionEnabled`, …).
  factory PresenceConfig.fromLegacy(Map<String, Object?> flat) =>
      PresenceConfig(
        clip: ClipConfig.fromJson(flat),
        camera: CameraConfig.fromJson({'brightnessEv': flat['brightnessEv']}),
        motion: MotionConfig.fromJson({
          'enabled': flat['motionEnabled'],
          'threshold': flat['motionThreshold'],
          'cooldownMs': flat['motionCooldownMs'],
        }),
      );

  @override
  bool operator ==(Object other) =>
      other is PresenceConfig &&
      other.clip == clip &&
      other.camera == camera &&
      other.motion == motion;

  @override
  int get hashCode => Object.hash(clip, camera, motion);
}

/// How long clips are around the moment they're requested.
@immutable
class ClipConfig {
  const ClipConfig({this.before = defaultLength, this.after = defaultLength});

  static const Duration min = Duration(seconds: 5);
  static const Duration max = Duration(seconds: 60);
  static const Duration step = Duration(seconds: 5);
  static const Duration defaultLength = Duration(seconds: 15);

  /// Video from before the press. Also how much history cameras keep.
  final Duration before;

  /// Video from after the press.
  final Duration after;

  Duration get total => before + after;

  ClipConfig copyWith({Duration? before, Duration? after}) => ClipConfig(
    before: _clampDuration(before ?? this.before, min, max),
    after: _clampDuration(after ?? this.after, min, max),
  );

  Map<String, Object?> toJson() => {
    'beforeMs': before.inMilliseconds,
    'afterMs': after.inMilliseconds,
  };

  factory ClipConfig.fromJson(Map<String, Object?> json) => const ClipConfig()
      .copyWith(before: _ms(json['beforeMs']), after: _ms(json['afterMs']));

  @override
  bool operator ==(Object other) =>
      other is ClipConfig && other.before == before && other.after == after;

  @override
  int get hashCode => Object.hash(before, after);
}

/// Camera picture settings.
@immutable
class CameraConfig {
  const CameraConfig({this.brightness = defaultBrightness});

  static const double minBrightness = -2;
  static const double maxBrightness = 2;
  static const double brightnessStep = 0.5;

  /// Brighter by default: small phone sensors run dark indoors.
  static const double defaultBrightness = 1;

  /// Exposure compensation in EV, applied live where the camera supports it.
  final double brightness;

  CameraConfig copyWith({double? brightness}) => CameraConfig(
    brightness: (brightness ?? this.brightness)
        .clamp(minBrightness, maxBrightness)
        .toDouble(),
  );

  Map<String, Object?> toJson() => {'brightnessEv': brightness};

  factory CameraConfig.fromJson(Map<String, Object?> json) =>
      const CameraConfig().copyWith(brightness: _num(json['brightnessEv']));

  @override
  bool operator ==(Object other) =>
      other is CameraConfig && other.brightness == brightness;

  @override
  int get hashCode => brightness.hashCode;
}

/// Automatic clips when the picture moves.
@immutable
class MotionConfig {
  const MotionConfig({
    this.enabled = true,
    this.threshold = defaultThreshold,
    this.cooldown = defaultCooldown,
  });

  static const double minThreshold = 1;
  static const double maxThreshold = 50;
  static const double defaultThreshold = 10;
  static const Duration minCooldown = Duration(minutes: 1);
  static const Duration maxCooldown = Duration(minutes: 60);
  static const Duration defaultCooldown = Duration(minutes: 5);

  /// Whether enough motion takes a clip automatically.
  final bool enabled;

  /// How much of the picture (percent of pixels) must change.
  final double threshold;

  /// At most one automatic clip per this period.
  final Duration cooldown;

  MotionConfig copyWith({
    bool? enabled,
    double? threshold,
    Duration? cooldown,
  }) => MotionConfig(
    enabled: enabled ?? this.enabled,
    threshold: (threshold ?? this.threshold)
        .clamp(minThreshold, maxThreshold)
        .toDouble(),
    cooldown: _clampDuration(
      cooldown ?? this.cooldown,
      minCooldown,
      maxCooldown,
    ),
  );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'threshold': threshold,
    'cooldownMs': cooldown.inMilliseconds,
  };

  factory MotionConfig.fromJson(Map<String, Object?> json) =>
      const MotionConfig().copyWith(
        enabled: json['enabled'] is bool ? json['enabled']! as bool : null,
        threshold: _num(json['threshold']),
        cooldown: _ms(json['cooldownMs']),
      );

  @override
  bool operator ==(Object other) =>
      other is MotionConfig &&
      other.enabled == enabled &&
      other.threshold == threshold &&
      other.cooldown == cooldown;

  @override
  int get hashCode => Object.hash(enabled, threshold, cooldown);
}

/// Holds the current [PresenceConfig] and notifies listeners when it
/// changes. Owned by the app; the Settings screen, cameras, motion
/// detection and persistence all read from it.
class ConfigController extends ChangeNotifier {
  ConfigController([PresenceConfig initial = const PresenceConfig()])
    : _config = initial;

  PresenceConfig _config;

  PresenceConfig get config => _config;

  /// Replaces the whole config (e.g. when restoring from storage).
  set config(PresenceConfig value) {
    if (value == _config) return;
    _config = value;
    notifyListeners();
  }

  /// Changes part of the config: `update((c) => c.copyWith(…))`.
  void update(PresenceConfig Function(PresenceConfig current) change) =>
      config = change(_config);

  // Shorthands for the values read most often.
  ClipConfig get clip => _config.clip;
  CameraConfig get camera => _config.camera;
  MotionConfig get motion => _config.motion;
}

Duration _clampDuration(Duration d, Duration min, Duration max) =>
    d < min ? min : (d > max ? max : d);

Duration? _ms(Object? value) =>
    value is num ? Duration(milliseconds: value.round()) : null;

double? _num(Object? value) => value is num ? value.toDouble() : null;

Map<String, Object?> _map(Object? value) =>
    value is Map ? value.cast<String, Object?>() : const {};
