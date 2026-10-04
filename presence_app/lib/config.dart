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
    this.schedule = const ScheduleConfig(),
    this.subjects = const SubjectsConfig(),
    this.recognition = const RecognitionConfig(),
    this.history = const HistoryConfig(),
  });

  static const int version = 1;

  final ClipConfig clip;
  final CameraConfig camera;
  final MotionConfig motion;
  final ScheduleConfig schedule;
  final SubjectsConfig subjects;
  final RecognitionConfig recognition;
  final HistoryConfig history;

  PresenceConfig copyWith({
    ClipConfig? clip,
    CameraConfig? camera,
    MotionConfig? motion,
    ScheduleConfig? schedule,
    SubjectsConfig? subjects,
    RecognitionConfig? recognition,
    HistoryConfig? history,
  }) => PresenceConfig(
    clip: clip ?? this.clip,
    camera: camera ?? this.camera,
    motion: motion ?? this.motion,
    schedule: schedule ?? this.schedule,
    subjects: subjects ?? this.subjects,
    recognition: recognition ?? this.recognition,
    history: history ?? this.history,
  );

  Map<String, Object?> toJson() => {
    'version': version,
    'clip': clip.toJson(),
    'camera': camera.toJson(),
    'motion': motion.toJson(),
    'schedule': schedule.toJson(),
    'subjects': subjects.toJson(),
    'recognition': recognition.toJson(),
    'history': history.toJson(),
  };

  /// Reads a stored config. Missing or invalid values fall back to their
  /// defaults, and values are clamped into range, so older or hand-edited
  /// records still load.
  factory PresenceConfig.fromJson(Map<String, Object?> json) => PresenceConfig(
    clip: ClipConfig.fromJson(_map(json['clip'])),
    camera: CameraConfig.fromJson(_map(json['camera'])),
    motion: MotionConfig.fromJson(_map(json['motion'])),
    schedule: ScheduleConfig.fromJson(_map(json['schedule'])),
    subjects: SubjectsConfig.fromJson(_map(json['subjects'])),
    recognition: RecognitionConfig.fromJson(_map(json['recognition'])),
    history: HistoryConfig.fromJson(_map(json['history'])),
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
      other.motion == motion &&
      other.schedule == schedule &&
      other.subjects == subjects &&
      other.recognition == recognition &&
      other.history == history;

  @override
  int get hashCode => Object.hash(
    clip,
    camera,
    motion,
    schedule,
    subjects,
    recognition,
    history,
  );
}

/// How long clips are around the moment they're requested.
@immutable
class ClipConfig {
  const ClipConfig({this.before = defaultBefore, this.after = defaultAfter});

  static const Duration min = Duration(seconds: 5);
  static const Duration max = Duration(seconds: 60);
  static const Duration step = Duration(seconds: 5);
  static const Duration defaultBefore = Duration(seconds: 5);
  static const Duration defaultAfter = Duration(seconds: 10);

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

/// Automatic clips on a timer, whatever the picture does: one every
/// [every], through the same path as the Clip button and motion clips.
@immutable
class ScheduleConfig {
  const ScheduleConfig({this.enabled = true, this.every = defaultEvery});

  static const Duration minEvery = Duration(minutes: 30);
  static const Duration maxEvery = Duration(days: 1);
  static const Duration everyStep = Duration(minutes: 30);
  static const Duration defaultEvery = Duration(minutes: 240);

  /// Whether a clip is taken every [every].
  final bool enabled;

  /// How long between scheduled clips: half an hour to a day.
  final Duration every;

  ScheduleConfig copyWith({bool? enabled, Duration? every}) => ScheduleConfig(
    enabled: enabled ?? this.enabled,
    every: _clampDuration(every ?? this.every, minEvery, maxEvery),
  );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'everyMs': every.inMilliseconds,
  };

  factory ScheduleConfig.fromJson(Map<String, Object?> json) =>
      const ScheduleConfig().copyWith(
        enabled: json['enabled'] is bool ? json['enabled']! as bool : null,
        every: _ms(json['everyMs']),
      );

  @override
  bool operator ==(Object other) =>
      other is ScheduleConfig &&
      other.enabled == enabled &&
      other.every == every;

  @override
  int get hashCode => Object.hash(enabled, every);
}

/// How long this device keeps events (see `EventRetention`).
@immutable
class HistoryConfig {
  const HistoryConfig({this.keep = defaultKeep});

  static const Duration minKeep = Duration(days: 1);
  static const Duration maxKeep = Duration(days: 90);
  static const Duration keepStep = Duration(days: 1);
  static const Duration defaultKeep = Duration(days: 14);

  /// Events older than this are deleted from the device, with their clips:
  /// a day to three months.
  final Duration keep;

  HistoryConfig copyWith({Duration? keep}) =>
      HistoryConfig(keep: _clampDuration(keep ?? this.keep, minKeep, maxKeep));

  Map<String, Object?> toJson() => {'keepMs': keep.inMilliseconds};

  factory HistoryConfig.fromJson(Map<String, Object?> json) =>
      const HistoryConfig().copyWith(keep: _ms(json['keepMs']));

  @override
  bool operator ==(Object other) =>
      other is HistoryConfig && other.keep == keep;

  @override
  int get hashCode => keep.hashCode;
}

/// The Subjects screens.
@immutable
class SubjectsConfig {
  const SubjectsConfig({this.mapEvents = defaultMapEvents});

  static const int minMapEvents = 5;
  static const int maxMapEvents = 100;
  static const int mapEventsStep = 5;
  static const int defaultMapEvents = 20;

  /// How many of a subject's latest events its screen shows (and maps).
  final int mapEvents;

  SubjectsConfig copyWith({int? mapEvents}) => SubjectsConfig(
    mapEvents: (mapEvents ?? this.mapEvents).clamp(minMapEvents, maxMapEvents),
  );

  Map<String, Object?> toJson() => {'mapEvents': mapEvents};

  factory SubjectsConfig.fromJson(Map<String, Object?> json) =>
      const SubjectsConfig().copyWith(
        mapEvents: _num(json['mapEvents'])?.round(),
      );

  @override
  bool operator ==(Object other) =>
      other is SubjectsConfig && other.mapEvents == mapEvents;

  @override
  int get hashCode => mapEvents.hashCode;
}

/// Recognizing subjects on new clips (see `recognition/`): on or off, and
/// how sure it must be to tag on its own, or to ask; and tagging the
/// objects seen on them ([objects]).
@immutable
class RecognitionConfig {
  const RecognitionConfig({
    this.enabled = true,
    this.objects = true,
    this.autoTag = defaultAutoTag,
    this.ask = defaultAsk,
  });

  static const double minConfidence = 0.3;
  static const double maxConfidence = 0.95;
  static const double step = 0.05;
  static const double defaultAutoTag = 0.8;
  static const double defaultAsk = 0.5;

  final bool enabled;

  /// Whether new clips get object tags (`human`, `cat`, `bicycle`...).
  final bool objects;

  /// From this confidence (0 to 1) a recognized subject is tagged.
  final double autoTag;

  /// From this confidence, below [autoTag], a `SubjectSuggestion` asks
  /// whether it's them. Never above [autoTag].
  final double ask;

  RecognitionConfig copyWith({
    bool? enabled,
    bool? objects,
    double? autoTag,
    double? ask,
  }) {
    final auto = (autoTag ?? this.autoTag).clamp(minConfidence, maxConfidence);
    final asking = (ask ?? this.ask).clamp(minConfidence, maxConfidence);
    return RecognitionConfig(
      enabled: enabled ?? this.enabled,
      objects: objects ?? this.objects,
      autoTag: auto,
      // Raising "ask" past "tag" would leave nothing to ask about.
      ask: asking > auto ? auto : asking,
    );
  }

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'objects': objects,
    'autoTag': autoTag,
    'ask': ask,
  };

  factory RecognitionConfig.fromJson(Map<String, Object?> json) =>
      const RecognitionConfig().copyWith(
        enabled: json['enabled'] is bool ? json['enabled']! as bool : null,
        objects: json['objects'] is bool ? json['objects']! as bool : null,
        autoTag: _num(json['autoTag']),
        ask: _num(json['ask']),
      );

  @override
  bool operator ==(Object other) =>
      other is RecognitionConfig &&
      other.enabled == enabled &&
      other.objects == objects &&
      other.autoTag == autoTag &&
      other.ask == ask;

  @override
  int get hashCode => Object.hash(enabled, objects, autoTag, ask);
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
  ScheduleConfig get schedule => _config.schedule;
  SubjectsConfig get subjects => _config.subjects;
  RecognitionConfig get recognition => _config.recognition;
  HistoryConfig get history => _config.history;
}

Duration _clampDuration(Duration d, Duration min, Duration max) =>
    d < min ? min : (d > max ? max : d);

Duration? _ms(Object? value) =>
    value is num ? Duration(milliseconds: value.round()) : null;

double? _num(Object? value) => value is num ? value.toDouble() : null;

Map<String, Object?> _map(Object? value) =>
    value is Map ? value.cast<String, Object?>() : const {};
