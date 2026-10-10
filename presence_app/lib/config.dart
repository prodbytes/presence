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
    this.log = const LogConfig(),
    this.live = const LiveConfig(),
  });

  static const int version = 1;

  final ClipConfig clip;
  final CameraConfig camera;
  final MotionConfig motion;
  final ScheduleConfig schedule;
  final SubjectsConfig subjects;
  final RecognitionConfig recognition;
  final HistoryConfig history;
  final LogConfig log;
  final LiveConfig live;

  PresenceConfig copyWith({
    ClipConfig? clip,
    CameraConfig? camera,
    MotionConfig? motion,
    ScheduleConfig? schedule,
    SubjectsConfig? subjects,
    RecognitionConfig? recognition,
    HistoryConfig? history,
    LogConfig? log,
    LiveConfig? live,
  }) => PresenceConfig(
    clip: clip ?? this.clip,
    camera: camera ?? this.camera,
    motion: motion ?? this.motion,
    schedule: schedule ?? this.schedule,
    subjects: subjects ?? this.subjects,
    recognition: recognition ?? this.recognition,
    history: history ?? this.history,
    log: log ?? this.log,
    live: live ?? this.live,
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
    'log': log.toJson(),
    'live': live.toJson(),
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
    log: LogConfig.fromJson(_map(json['log'])),
    live: LiveConfig.fromJson(_map(json['live'])),
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
      other.history == history &&
      other.log == log &&
      other.live == live;

  @override
  int get hashCode => Object.hash(
    clip,
    camera,
    motion,
    schedule,
    subjects,
    recognition,
    history,
    log,
    live,
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
  const CameraConfig({
    this.brightness = defaultBrightness,
    this.paused = false,
    this.chosen,
  });

  static const double minBrightness = -2;
  static const double maxBrightness = 2;
  static const double brightnessStep = 0.5;

  /// Brighter by default: small phone sensors run dark indoors.
  static const double defaultBrightness = 1;

  /// Exposure compensation in EV, applied live where the camera supports it.
  final double brightness;

  /// The user switched the camera off (Pause): it stays closed, recording
  /// nothing, until they press Play, across restarts too.
  final bool paused;

  /// The camera last picked with Flip, reopened at launch (null: the
  /// default camera). Kept in this device's settings, never another's.
  final ChosenCamera? chosen;

  CameraConfig copyWith({
    double? brightness,
    bool? paused,
    ChosenCamera? chosen,
  }) => CameraConfig(
    brightness: (brightness ?? this.brightness)
        .clamp(minBrightness, maxBrightness)
        .toDouble(),
    paused: paused ?? this.paused,
    chosen: chosen ?? this.chosen,
  );

  Map<String, Object?> toJson() => {
    'brightnessEv': brightness,
    'paused': paused,
    'chosen': ?chosen?.toJson(),
  };

  factory CameraConfig.fromJson(Map<String, Object?> json) =>
      const CameraConfig().copyWith(
        brightness: _num(json['brightnessEv']),
        paused: json['paused'] == true,
        chosen: ChosenCamera.fromJson(json['chosen']),
      );

  @override
  bool operator ==(Object other) =>
      other is CameraConfig &&
      other.brightness == brightness &&
      other.paused == paused &&
      other.chosen == chosen;

  @override
  int get hashCode => Object.hash(brightness, paused, chosen);
}

/// A camera of this device, remembered across restarts: the camera
/// backend's [id] (on Android the camera's ID, on web the browser's device
/// ID), with its [label] and [facing] (`back`, `front` or `unknown`) to find
/// it again if the ID changed.
@immutable
class ChosenCamera {
  const ChosenCamera({
    required this.id,
    required this.label,
    this.facing = 'unknown',
  });

  final String id;
  final String label;
  final String facing;

  Map<String, Object?> toJson() => {'id': id, 'label': label, 'facing': facing};

  /// Null when [json] isn't a camera (missing, or damaged).
  static ChosenCamera? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final label = json['label'];
    final facing = json['facing'];
    return ChosenCamera(
      id: id,
      label: label is String ? label : '',
      facing: facing is String ? facing : 'unknown',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ChosenCamera &&
      other.id == id &&
      other.label == label &&
      other.facing == facing;

  @override
  int get hashCode => Object.hash(id, label, facing);
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

  /// 15 % of the picture: enough to ignore light flicker and leaves.
  static const double defaultThreshold = 15;
  static const Duration minCooldown = Duration(minutes: 1);
  static const Duration maxCooldown = Duration(minutes: 60);
  static const Duration defaultCooldown = Duration(minutes: 5);

  /// Whether enough motion takes a clip automatically.
  final bool enabled;

  /// How much of the picture (percent of pixels) must change.
  final double threshold;

  /// The cooldown: after any clip (whatever took it), no automatic clip
  /// (motion, scheduled, startup) for this long. The Clip button ignores
  /// it.
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
  static const Duration defaultEvery = Duration(minutes: 180);

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

/// The Log tab (admins only): shown or not. Unset, it follows the
/// execution mode: shown in DEV, hidden otherwise ([showIn]).
@immutable
class LogConfig {
  const LogConfig({this.show});

  /// Set by the Settings switch; null until then.
  final bool? show;

  /// Whether the Log tab shows, [dev] being the execution mode.
  bool showIn({required bool dev}) => show ?? dev;

  LogConfig copyWith({bool? show}) => LogConfig(show: show ?? this.show);

  Map<String, Object?> toJson() => {'show': ?show};

  factory LogConfig.fromJson(Map<String, Object?> json) =>
      LogConfig(show: json['show'] is bool ? json['show'] as bool : null);

  @override
  bool operator ==(Object other) => other is LogConfig && other.show == show;

  @override
  int get hashCode => show.hashCode;
}

/// How live sync (MQTT, see `cloud/live_sync.dart`) connects.
enum LiveMode {
  /// Never: events arrive with each sync of the bucket only.
  never,

  /// Every [LiveConfig.every]: connects, takes what the broker kept for
  /// this device while it was away, and disconnects; and connects at once
  /// to send this device's new events.
  scheduled,

  /// Always connected (reconnecting after a drop).
  always,
}

/// The **Connect to live sync** setting: [LiveMode.never], every
/// [LiveConfig.every] ([LiveMode.scheduled]), or [LiveMode.always]. Kept per
/// device. The slider's steps are [steps]: Never, then [intervals], then
/// Always.
///
/// What it's set to isn't always how live sync connects: that depends on
/// the user's roles too ([effective]). Admins are always connected; other
/// users (members) connect at most every 30 s, so Always isn't theirs.
@immutable
class LiveConfig {
  /// Not clamped (tests use short intervals); [fromJson] and [ofStep]
  /// snap to [intervals].
  const LiveConfig({this.mode = LiveMode.scheduled, this.every = defaultEvery});

  static const LiveConfig never = LiveConfig(mode: LiveMode.never);
  static const LiveConfig always = LiveConfig(mode: LiveMode.always);

  /// The scheduled intervals, in order: all within AWS IoT's default
  /// persistent session expiry (1 h), so the broker still holds what
  /// arrived while the device was away.
  static const List<Duration> intervals = [
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
    Duration(minutes: 10),
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(minutes: 60),
  ];

  static const Duration defaultEvery = Duration(minutes: 1);

  /// The most often a member (not an admin) connects: what Always becomes
  /// for them ([effective]).
  static const Duration memberMinEvery = Duration(seconds: 30);

  /// How many steps the slider has: Never, the [intervals], Always.
  static const int steps = 2 + 8;

  /// The last step a member may pick: the slowest interval (Always, the
  /// step after it, is for admins).
  static const int memberMaxStep = steps - 2;

  final LiveMode mode;

  /// Between scheduled connections ([LiveMode.scheduled] only).
  final Duration every;

  /// How live sync connects with this setting, for a user who [isAdmin]
  /// or not. Admins: [always], whatever it's set to, so their (often
  /// unattended) devices are always reachable. Others: as set, but Always
  /// becomes every [memberMinEvery], and nothing more often than that.
  /// The setting itself is kept, so an admin who stops being one gets
  /// their own choice back (clamped).
  LiveConfig effective({required bool isAdmin}) {
    if (isAdmin) return always;
    return switch (mode) {
      LiveMode.never => this,
      LiveMode.always => const LiveConfig(every: memberMinEvery),
      LiveMode.scheduled =>
        every < memberMinEvery ? const LiveConfig(every: memberMinEvery) : this,
    };
  }

  /// This setting's step on the slider: 0 is Never, the last is Always.
  int get step => switch (mode) {
    LiveMode.never => 0,
    LiveMode.always => steps - 1,
    LiveMode.scheduled => 1 + intervals.indexOf(_snap(every)),
  };

  /// The setting at [step] of the slider (clamped).
  static LiveConfig ofStep(int step) {
    if (step <= 0) return never;
    if (step >= steps - 1) return always;
    return LiveConfig(every: intervals[step - 1]);
  }

  /// The step's label: "Never", "Every 30 s", "Every 60 min", "Always".
  String get label => switch (mode) {
    LiveMode.never => 'Never',
    LiveMode.always => 'Always',
    LiveMode.scheduled => 'Every ${formatEvery(_snap(every))}',
  };

  /// [every] as "30 s" under a minute, else "5 min".
  static String formatEvery(Duration every) =>
      every < const Duration(minutes: 1)
      ? '${every.inSeconds} s'
      : '${every.inMinutes} min';

  /// [d] as the nearest of [intervals].
  static Duration _snap(Duration d) =>
      intervals.reduce((a, b) => (a - d).abs() <= (b - d).abs() ? a : b);

  Map<String, Object?> toJson() => {
    'mode': mode.name,
    'everyMs': every.inMilliseconds,
  };

  /// Missing or unknown values fall back to the default (every minute);
  /// an interval snaps to the nearest of [intervals].
  factory LiveConfig.fromJson(Map<String, Object?> json) {
    final mode = LiveMode.values.asNameMap()[json['mode']];
    final every = _ms(json['everyMs']);
    return LiveConfig(
      mode: mode ?? LiveMode.scheduled,
      every: every == null ? defaultEvery : _snap(every),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LiveConfig && other.mode == mode && other.every == every;

  @override
  int get hashCode => Object.hash(mode, every);
}

/// The Subjects screens.
@immutable
class SubjectsConfig {
  const SubjectsConfig({this.mapEvents = defaultMapEvents});

  static const int minMapEvents = 10;
  static const int maxMapEvents = 500;
  static const int mapEventsStep = 10;
  static const int defaultMapEvents = 100;

  /// How many events load at once: a subject's latest events its screen
  /// shows (and maps), and each subject's on the Subjects map.
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
/// how sure it must be to tag on its own; and tagging the objects seen on
/// them ([objects]). A subject recognized below [autoTag] is always asked
/// about, from [askFloor] up.
@immutable
class RecognitionConfig {
  const RecognitionConfig({
    this.enabled = true,
    this.objects = true,
    this.autoTag = defaultAutoTag,
  });

  static const double minConfidence = 0.5;
  static const double maxConfidence = 0.95;
  static const double step = 0.05;

  /// 90 %: a face's cosine of 0.615, a person's look's of 0.79 (see
  /// `faceConfidence`, `lookConfidence`). It was 85 %, which tagged too
  /// many strangers as someone known.
  static const double defaultAutoTag = 0.90;

  /// The default before it was raised: a device still on it (never
  /// changed) takes the new [defaultAutoTag].
  static const double oldDefaultAutoTag = 0.85;

  /// Under this confidence a match isn't asked about: a face scoring 50 %
  /// has a cosine of 0.475, above 99.9 % of different people's (LFW), a
  /// person's look 0.675 (see `faceConfidence`, `lookConfidence`); lower,
  /// asking would mostly be about strangers.
  static const double askFloor = minConfidence;

  final bool enabled;

  /// Whether new clips get object tags (`human`, `cat`, `bicycle`...).
  final bool objects;

  /// From this confidence (0 to 1) a recognized subject is tagged; from
  /// [askFloor] to here, a `SubjectSuggestion` asks whether it's them.
  final double autoTag;

  RecognitionConfig copyWith({bool? enabled, bool? objects, double? autoTag}) =>
      RecognitionConfig(
        enabled: enabled ?? this.enabled,
        objects: objects ?? this.objects,
        autoTag: (autoTag ?? this.autoTag).clamp(minConfidence, maxConfidence),
      );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'objects': objects,
    'autoTag': autoTag,
  };

  /// Records from before always asking also have an `ask` level; it's
  /// ignored. One left at the [oldDefaultAutoTag] takes the
  /// [defaultAutoTag]; one under [minConfidence] is raised to it.
  factory RecognitionConfig.fromJson(Map<String, Object?> json) {
    final autoTag = _num(json['autoTag']);
    return const RecognitionConfig().copyWith(
      enabled: json['enabled'] is bool ? json['enabled']! as bool : null,
      objects: json['objects'] is bool ? json['objects']! as bool : null,
      autoTag:
          autoTag != null && (autoTag - oldDefaultAutoTag).abs() < 1e-9
          ? defaultAutoTag
          : autoTag,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RecognitionConfig &&
      other.enabled == enabled &&
      other.objects == objects &&
      other.autoTag == autoTag;

  @override
  int get hashCode => Object.hash(enabled, objects, autoTag);
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
  LogConfig get log => _config.log;
  LiveConfig get live => _config.live;
}

Duration _clampDuration(Duration d, Duration min, Duration max) =>
    d < min ? min : (d > max ? max : d);

Duration? _ms(Object? value) =>
    value is num ? Duration(milliseconds: value.round()) : null;

double? _num(Object? value) => value is num ? value.toDouble() : null;

Map<String, Object?> _map(Object? value) =>
    value is Map ? value.cast<String, Object?>() : const {};
