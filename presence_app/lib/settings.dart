import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_version.dart';
import 'config.dart';
import 'location/device_location.dart';
import 'location/location_settings.dart';

/// The Settings screen (the Settings tab), full width.
class SettingsView extends StatefulWidget {
  const SettingsView({
    super.key,
    required this.config,
    this.motionLevel,
    this.deviceId,
    this.health,
    this.location,
    this.tiles,
    this.onMapHeld,
  });

  /// Where this device is: the **Location** section and its map, when
  /// given.
  final LocationController? location;

  /// The location map's tiles; defaults to OpenStreetMap.
  final Widget? tiles;

  /// Told while the location map is held, so the tabs don't swipe away
  /// under a drag on it ([LocationSettings.onMapHeld]).
  final ValueChanged<bool>? onMapHeld;

  /// This device's ID, shown under the version once it's loaded.
  final String? deviceId;

  /// A status line under the device ID (the API, AWS and OIDC).
  final Widget? health;

  /// The app's configuration; every control edits it.
  final ConfigController config;

  /// The open camera's live motion score, shown to help set the threshold.
  final ValueListenable<double?>? motionLevel;

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  /// The location map is held: the list holds still, so a drag on the map
  /// moves the map.
  bool _mapHeld = false;

  void _onMapHeld(bool held) {
    setState(() => _mapHeld = held);
    widget.onMapHeld?.call(held);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final config = widget.config;
    final motionLevel = widget.motionLevel;
    final deviceId = widget.deviceId;
    final health = widget.health;
    final location = widget.location;
    return ListenableBuilder(
      listenable: config,
      builder: (context, _) {
        final clip = config.clip;
        final camera = config.camera;
        final motion = config.motion;
        final subjects = config.subjects;
        // Each change applies to the *current* config, not the one this
        // build saw: two changes before the next rebuild must both stick.
        void setClip(ClipConfig Function(ClipConfig) f) =>
            config.update((x) => x.copyWith(clip: f(x.clip)));
        void setCamera(CameraConfig Function(CameraConfig) f) =>
            config.update((x) => x.copyWith(camera: f(x.camera)));
        void setMotion(MotionConfig Function(MotionConfig) f) =>
            config.update((x) => x.copyWith(motion: f(x.motion)));
        void setSchedule(ScheduleConfig Function(ScheduleConfig) f) =>
            config.update((x) => x.copyWith(schedule: f(x.schedule)));
        final schedule = config.schedule;
        void setSubjects(SubjectsConfig Function(SubjectsConfig) f) =>
            config.update((x) => x.copyWith(subjects: f(x.subjects)));
        return ListView(
          key: const Key('settings-page'),
          physics: _mapHeld ? const NeverScrollableScrollPhysics() : null,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          children: [
            Text('Camera', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _BrightnessSlider(
              key: const Key('brightness-slider'),
              value: camera.brightness,
              onChanged: (ev) => setCamera((c) => c.copyWith(brightness: ev)),
            ),
            const SizedBox(height: 16),
            Text('Motion', style: theme.textTheme.titleMedium),
            SwitchListTile(
              key: const Key('motion-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Clip automatically on motion'),
              subtitle: const Text('Same as pressing Clip'),
              value: motion.enabled,
              onChanged: (on) => setMotion((m) => m.copyWith(enabled: on)),
            ),
            _LabeledSlider(
              key: const Key('motion-threshold-slider'),
              label: 'Motion threshold',
              valueLabel: '${motion.threshold.round()} % of the picture',
              value: motion.threshold,
              min: MotionConfig.minThreshold,
              max: MotionConfig.maxThreshold,
              divisions: 49,
              onChanged: motion.enabled
                  ? (v) => setMotion(
                      (m) => m.copyWith(threshold: v.roundToDouble()),
                    )
                  : null,
            ),
            if (motionLevel case final level?)
              _MotionMeter(level: level, threshold: motion.threshold),
            _LabeledSlider(
              key: const Key('motion-cooldown-slider'),
              label: 'At most one automatic clip every',
              valueLabel: '${motion.cooldown.inMinutes} min',
              value: motion.cooldown.inMinutes.toDouble(),
              min: MotionConfig.minCooldown.inMinutes.toDouble(),
              max: MotionConfig.maxCooldown.inMinutes.toDouble(),
              divisions:
                  MotionConfig.maxCooldown.inMinutes -
                  MotionConfig.minCooldown.inMinutes,
              onChanged: motion.enabled
                  ? (v) => setMotion(
                      (m) => m.copyWith(cooldown: Duration(minutes: v.round())),
                    )
                  : null,
            ),
            const SizedBox(height: 16),
            Text('Clips', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _DurationSlider(
              key: const Key('clip-before-slider'),
              label: 'Before the press',
              value: clip.before,
              onChanged: (d) => setClip((c) => c.copyWith(before: d)),
            ),
            _DurationSlider(
              key: const Key('clip-after-slider'),
              label: 'After the press',
              value: clip.after,
              onChanged: (d) => setClip((c) => c.copyWith(after: d)),
            ),
            const SizedBox(height: 8),
            Text(
              'Clips play ${clip.total.inSeconds} s in total. Changing '
              '"Before" takes up to that long to apply, while the cameras '
              'build up enough history.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Text('Scheduled clips', style: theme.textTheme.titleMedium),
            SwitchListTile(
              key: const Key('schedule-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Clip at start and on a timer'),
              subtitle: const Text('Same as pressing Clip'),
              value: schedule.enabled,
              onChanged: (on) => setSchedule((x) => x.copyWith(enabled: on)),
            ),
            _LabeledSlider(
              key: const Key('schedule-every-slider'),
              label: 'One clip every',
              valueLabel: formatEvery(schedule.every),
              value: schedule.every.inMinutes.toDouble(),
              min: ScheduleConfig.minEvery.inMinutes.toDouble(),
              max: ScheduleConfig.maxEvery.inMinutes.toDouble(),
              divisions:
                  (ScheduleConfig.maxEvery - ScheduleConfig.minEvery)
                      .inMinutes ~/
                  ScheduleConfig.everyStep.inMinutes,
              onChanged: schedule.enabled
                  ? (v) => setSchedule(
                      (x) => x.copyWith(every: Duration(minutes: v.round())),
                    )
                  : null,
            ),
            const SizedBox(height: 16),
            Text('Subjects', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _LabeledSlider(
              key: const Key('subject-events-slider'),
              label: "Latest events on a subject's map",
              valueLabel: '${subjects.mapEvents}',
              value: subjects.mapEvents.toDouble(),
              min: SubjectsConfig.minMapEvents.toDouble(),
              max: SubjectsConfig.maxMapEvents.toDouble(),
              divisions:
                  (SubjectsConfig.maxMapEvents - SubjectsConfig.minMapEvents) ~/
                  SubjectsConfig.mapEventsStep,
              onChanged: (v) =>
                  setSubjects((s) => s.copyWith(mapEvents: v.round())),
            ),
            if (location != null) ...[
              const SizedBox(height: 16),
              Text('Location', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              LocationSettings(
                location: location,
                tiles: widget.tiles,
                onMapHeld: _onMapHeld,
              ),
            ],
            // Which build this is, e.g. to check a deploy landed.
            if (AppVersion.version.isNotEmpty) ...[
              const SizedBox(height: 32),
              Text(
                'Presence ${AppVersion.version}',
                key: const Key('app-version'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            // Which device this is, as its events say (selectable, to copy).
            if (deviceId case final deviceId?) ...[
              SizedBox(height: AppVersion.version.isEmpty ? 32 : 4),
              SelectableText(
                deviceId,
                key: const Key('device-id'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (health case final health?) ...[
              SizedBox(
                height: AppVersion.version.isEmpty && deviceId == null ? 32 : 8,
              ),
              health,
            ],
          ],
        );
      },
    );
  }
}

/// A schedule interval, as "30 min", "4 h", "1 h 30 min" or "24 h".
String formatEvery(Duration every) {
  final hours = every.inHours;
  final minutes = every.inMinutes % 60;
  if (hours == 0) return '$minutes min';
  return minutes == 0 ? '$hours h' : '$hours h $minutes min';
}

class _LabeledSlider extends StatelessWidget {
  const _LabeledSlider({
    super.key,
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label)),
            Text(valueLabel),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: valueLabel,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

/// Live motion score against the threshold, to help pick a threshold.
class _MotionMeter extends StatelessWidget {
  const _MotionMeter({required this.level, required this.threshold});

  final ValueListenable<double?> level;
  final double threshold;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ValueListenableBuilder<double?>(
      valueListenable: level,
      builder: (context, score, _) {
        final max = MotionConfig.maxThreshold;
        final over = score != null && score >= threshold;
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LayoutBuilder(
                builder: (context, c) => Stack(
                  clipBehavior: Clip.none,
                  children: [
                    LinearProgressIndicator(
                      key: const Key('motion-meter'),
                      value: ((score ?? 0) / max).clamp(0, 1),
                      minHeight: 6,
                      borderRadius: BorderRadius.circular(3),
                      color: over ? scheme.error : scheme.secondary,
                    ),
                    // Threshold marker.
                    Positioned(
                      left: (c.maxWidth * threshold / max).clamp(
                        0,
                        c.maxWidth - 2,
                      ),
                      top: -3,
                      child: Container(
                        width: 2,
                        height: 12,
                        color: scheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                score == null
                    ? 'Motion now: waiting for the camera…'
                    : 'Motion now: ${score.round()} %',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _BrightnessSlider extends StatelessWidget {
  const _BrightnessSlider({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final double value;
  final ValueChanged<double> onChanged;

  static String format(double ev) =>
      ev == 0 ? '0 EV' : '${ev > 0 ? '+' : ''}${ev.toStringAsFixed(1)} EV';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: Text('Brightness')),
            Text(format(value)),
          ],
        ),
        Slider(
          value: value,
          min: CameraConfig.minBrightness,
          max: CameraConfig.maxBrightness,
          divisions:
              ((CameraConfig.maxBrightness - CameraConfig.minBrightness) /
                      CameraConfig.brightnessStep)
                  .round(),
          label: format(value),
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _DurationSlider extends StatelessWidget {
  const _DurationSlider({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final Duration value;
  final ValueChanged<Duration> onChanged;

  @override
  Widget build(BuildContext context) {
    final seconds = value.inSeconds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label)),
            Text('$seconds s'),
          ],
        ),
        Slider(
          value: seconds.toDouble(),
          min: ClipConfig.min.inSeconds.toDouble(),
          max: ClipConfig.max.inSeconds.toDouble(),
          divisions:
              (ClipConfig.max - ClipConfig.min).inSeconds ~/
              ClipConfig.step.inSeconds,
          label: '$seconds s',
          onChanged: (v) => onChanged(Duration(seconds: v.round())),
        ),
      ],
    );
  }
}
