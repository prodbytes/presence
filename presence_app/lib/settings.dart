import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_version.dart';
import 'camera_feeds.dart';
import 'config.dart';
import 'location/device_location.dart';
import 'location/location_settings.dart';
import 'recognition/runtime.dart';

/// The Settings screen (the Settings tab), full width.
class SettingsView extends StatefulWidget {
  const SettingsView({
    super.key,
    required this.config,
    this.motionLevel,
    this.deviceId,
    this.profileId,
    this.health,
    this.addDevice,
    this.location,
    this.tiles,
    this.onMapHeld,
    this.nextClip,
    this.logTabDefault,
    this.liveSync = false,
    this.liveAdmin = false,
  });

  /// Whether this build has live sync (an IoT endpoint, and cloud sync):
  /// the **Live sync** section, with its **Connect to live sync** slider.
  final bool liveSync;

  /// The user is an admin: live sync is always connected for them
  /// ([LiveConfig.effective]), so the slider shows Always, locked. Others
  /// may pick from Never to every 60 min (every 30 s the most often), and
  /// a saved Always shows as every 30 s.
  final bool liveAdmin;

  /// For admins, an **Advanced** section with a **Show the Log tab** switch, on by default when this is
  /// true (DEV); null hides the switch.
  final bool? logTabDefault;

  /// Under the scheduled clips' interval while they're on: when the next
  /// one is taken ([ScheduledClipCountdown]).
  final Widget? nextClip;

  /// Where this device is: the **Location** section and its map, when
  /// given.
  final LocationController? location;

  /// The location map's tiles; defaults to OpenStreetMap.
  final Widget? tiles;

  /// Told while the location map is held, so the tabs don't swipe away
  /// under a drag on it ([LocationSettings.onMapHeld]).
  final ValueChanged<bool>? onMapHeld;

  /// This device's ID, always shown first, at the top ("loading…" until
  /// it's known).
  final String? deviceId;

  /// This device's profile ID, always shown at the top beside the device
  /// ID ("none until signed in" until it's known).
  final String? profileId;

  /// A status line under the version (the API, AWS, OIDC and Live).
  final Widget? health;

  /// The last thing: opens a QR code and a Share button, to open Presence
  /// on another device as a new device of the same user.
  final Widget? addDevice;

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
        final recognition = config.recognition;
        // How live sync connects for this user (admins: always; others:
        // as saved, at most every 30 s), not just what's saved.
        final live = config.live.effective(isAdmin: widget.liveAdmin);
        final liveMax = widget.liveAdmin
            ? LiveConfig.steps - 1
            : LiveConfig.memberMaxStep;
        void setHistory(HistoryConfig Function(HistoryConfig) f) =>
            config.update((x) => x.copyWith(history: f(x.history)));
        void setRecognition(RecognitionConfig Function(RecognitionConfig) f) =>
            config.update((x) => x.copyWith(recognition: f(x.recognition)));
        String percent(double v) => '${(v * 100).round()} %';
        const confidenceSteps =
            ((RecognitionConfig.maxConfidence -
                        RecognitionConfig.minConfidence) /
                    RecognitionConfig.step +
                0.5) ~/
            1;
        return ListView(
          key: const Key('settings-page'),
          physics: _mapHeld ? const NeverScrollableScrollPhysics() : null,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          children: [
            // The very first thing: which device and profile this is, as
            // the events and the auth API say (selectable, to copy).
            // Always shown.
            _Ids(deviceId: widget.deviceId, profileId: widget.profileId),
            const SizedBox(height: 16),
            // Then where this device is, its position and the map.
            if (location != null) ...[
              Text('Location', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              LocationSettings(
                location: location,
                tiles: widget.tiles,
                onMapHeld: _onMapHeld,
              ),
              const SizedBox(height: 16),
            ],
            Text('Camera', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _LabeledSlider(
              key: const Key('brightness-slider'),
              label: 'Brightness',
              format: _formatBrightness,
              value: camera.brightness,
              min: CameraConfig.minBrightness,
              max: CameraConfig.maxBrightness,
              divisions:
                  ((CameraConfig.maxBrightness - CameraConfig.minBrightness) /
                          CameraConfig.brightnessStep)
                      .round(),
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
              format: (v) => '${v.round()} % of the picture',
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
              format: (v) => '${v.round()} min',
              value: motion.cooldown.inMinutes.toDouble(),
              min: MotionConfig.minCooldown.inMinutes.toDouble(),
              max: MotionConfig.maxCooldown.inMinutes.toDouble(),
              divisions:
                  MotionConfig.maxCooldown.inMinutes -
                  MotionConfig.minCooldown.inMinutes,
              // After any clip, motion's or not: it holds scheduled clips
              // back too, so it's set even with motion off.
              onChanged: (v) => setMotion(
                (m) => m.copyWith(cooldown: Duration(minutes: v.round())),
              ),
            ),
            const SizedBox(height: 16),
            Text('Clips', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            // Side by side: before on the left, after on the right.
            Row(
              key: const Key('clip-sliders'),
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Expanded(
                  child: _LabeledSlider(
                    key: const Key('clip-before-slider'),
                    label: 'Before press',
                    format: (v) => '${v.round()} s',
                    value: clip.before.inSeconds.toDouble(),
                    min: ClipConfig.min.inSeconds.toDouble(),
                    max: ClipConfig.max.inSeconds.toDouble(),
                    divisions:
                        (ClipConfig.max - ClipConfig.min).inSeconds ~/
                        ClipConfig.step.inSeconds,
                    onChanged: (v) => setClip(
                      (c) => c.copyWith(before: Duration(seconds: v.round())),
                    ),
                  ),
                ),
                Expanded(
                  child: _LabeledSlider(
                    key: const Key('clip-after-slider'),
                    label: 'After press',
                    format: (v) => '${v.round()} s',
                    value: clip.after.inSeconds.toDouble(),
                    min: ClipConfig.min.inSeconds.toDouble(),
                    max: ClipConfig.max.inSeconds.toDouble(),
                    divisions:
                        (ClipConfig.max - ClipConfig.min).inSeconds ~/
                        ClipConfig.step.inSeconds,
                    onChanged: (v) => setClip(
                      (c) => c.copyWith(after: Duration(seconds: v.round())),
                    ),
                  ),
                ),
              ],
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
              format: (v) => formatEvery(Duration(minutes: v.round())),
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
            if (widget.nextClip case final nextClip? when schedule.enabled)
              nextClip,
            const SizedBox(height: 16),
            Text('Recognition', style: theme.textTheme.titleMedium),
            SwitchListTile(
              key: const Key('recognition-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Recognize subjects in new clips'),
              subtitle: Text(
                _recognitionSupported
                    ? 'People and pets tagged before, found on this device'
                    : 'Not available on this device yet',
              ),
              value: recognition.enabled && _recognitionSupported,
              onChanged: _recognitionSupported
                  ? (on) => setRecognition((r) => r.copyWith(enabled: on))
                  : null,
            ),
            SwitchListTile(
              key: const Key('recognition-objects-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Tag objects in new clips'),
              subtitle: Text(
                _recognitionSupported
                    ? 'Human, cat, dog, bicycle, bottle… for search'
                    : 'Not available on this device yet',
              ),
              value: recognition.objects && _recognitionSupported,
              onChanged: _recognitionSupported
                  ? (on) => setRecognition((r) => r.copyWith(objects: on))
                  : null,
            ),
            _LabeledSlider(
              key: const Key('recognition-auto-slider'),
              label: 'Tag automatically when at least',
              format: (v) => '${percent(_toStep(v))} sure',
              value: recognition.autoTag,
              min: RecognitionConfig.minConfidence,
              max: RecognitionConfig.maxConfidence,
              divisions: confidenceSteps,
              onChanged: recognition.enabled && _recognitionSupported
                  ? (v) =>
                        setRecognition((r) => r.copyWith(autoTag: _toStep(v)))
                  : null,
            ),
            Text(
              'Less sure than that, it asks you whether it\'s them.',
              key: const Key('recognition-ask-note'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Text('History', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _LabeledSlider(
              key: const Key('history-keep-slider'),
              label: 'Keep events for',
              format: (v) => formatKeep(Duration(days: v.round())),
              value: config.history.keep.inDays.toDouble(),
              min: HistoryConfig.minKeep.inDays.toDouble(),
              max: HistoryConfig.maxKeep.inDays.toDouble(),
              divisions:
                  (HistoryConfig.maxKeep - HistoryConfig.minKeep).inDays ~/
                  HistoryConfig.keepStep.inDays,
              onChanged: (v) => setHistory(
                (h) => h.copyWith(keep: Duration(days: v.round())),
              ),
            ),
            Text(
              'Older events and their clips are deleted from this device '
              'when the app starts and every 3 hours.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            // Under History: how this device hears of the others' events.
            if (widget.liveSync) ...[
              const SizedBox(height: 16),
              Text('Live sync', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              _LabeledSlider(
                key: const Key('live-connect-slider'),
                label: 'Connect to live sync',
                format: (v) => LiveConfig.ofStep(v.round()).label,
                value: live.step.toDouble(),
                min: 0,
                max: liveMax.toDouble(),
                divisions: liveMax,
                // Locked for admins: always connected.
                onChanged: widget.liveAdmin
                    ? null
                    : (v) => config.update(
                        (x) => x.copyWith(live: LiveConfig.ofStep(v.round())),
                      ),
              ),
              Text(
                switch (live.mode) {
                  _ when widget.liveAdmin =>
                    'Always connected for admins, so this device is always '
                        'reachable: other devices\' events arrive within a '
                        'second.',
                  LiveMode.never =>
                    'Other devices\' events arrive with each sync (15 s), '
                        'and this device\'s reach them the same way.',
                  LiveMode.always =>
                    'Stays connected: other devices\' events arrive within '
                        'a second.',
                  LiveMode.scheduled =>
                    'Connects about every '
                        '${LiveConfig.formatEvery(live.every)} for what '
                        'other devices sent meanwhile, and at once to send '
                        'this device\'s events.',
                },
                key: const Key('live-connect-note'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (widget.logTabDefault case final dev?) ...[
              const SizedBox(height: 16),
              Text('Advanced', style: theme.textTheme.titleMedium),
              SwitchListTile(
                key: const Key('show-log-switch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Show the Log tab'),
                subtitle: const Text('The app\'s latest messages and health'),
                value: config.log.showIn(dev: dev),
                onChanged: (v) => config.update(
                  (x) => x.copyWith(log: x.log.copyWith(show: v)),
                ),
              ),
            ],
            // Last: how much the Subjects screens load.
            const SizedBox(height: 16),
            Text('Subjects', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _LabeledSlider(
              key: const Key('subject-events-slider'),
              label: 'How many events to load at once',
              format: (v) => '${v.round()}',
              value: subjects.mapEvents.toDouble(),
              min: SubjectsConfig.minMapEvents.toDouble(),
              max: SubjectsConfig.maxMapEvents.toDouble(),
              divisions:
                  (SubjectsConfig.maxMapEvents - SubjectsConfig.minMapEvents) ~/
                  SubjectsConfig.mapEventsStep,
              onChanged: (v) =>
                  setSubjects((s) => s.copyWith(mapEvents: v.round())),
            ),
            // Which build this is, e.g. to check a deploy landed.
            if (AppVersion.version.isNotEmpty) ...[
              const SizedBox(height: 32),
              Text(
                'Presence ${AppVersion.version}',
                key: const Key('app-version'),
                textAlign: TextAlign.center,
                // bodyMedium, as the IDs at the top: read out to check a
                // deploy landed.
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (health case final health?) ...[
              SizedBox(height: AppVersion.version.isEmpty ? 32 : 8),
              health,
            ],
            if (widget.addDevice case final addDevice?) ...[
              const SizedBox(height: 32),
              addDevice,
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

/// Time left, as "2 h 59 min 58 s", "4 min 0 s" or "12 s", rounded up to
/// the second so it reads 1 s, not 0 s, until it's over.
String formatCountdown(Duration left) {
  final seconds = (left.inMilliseconds + 999) ~/ 1000;
  final h = seconds ~/ 3600;
  final m = seconds % 3600 ~/ 60;
  final s = seconds % 60;
  if (h > 0) return '$h h $m min $s s';
  if (m > 0) return '$m min $s s';
  return '$s s';
}

/// When the next scheduled clip is taken, from [rig], refreshed every
/// second: the startup clip once the camera is ready, then a countdown to
/// the next one.
class ScheduledClipCountdown extends StatefulWidget {
  const ScheduledClipCountdown({super.key, required this.rig});

  final CameraRig rig;

  @override
  State<ScheduledClipCountdown> createState() => _ScheduledClipCountdownState();
}

class _ScheduledClipCountdownState extends State<ScheduledClipCountdown> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rig = widget.rig;
    final left = rig.untilScheduledClip;
    if (left == null) return const SizedBox.shrink();
    final text = rig.startupClipPending
        ? 'Startup clip: once the camera is ready'
        : left == Duration.zero
        ? 'Next clip: due, once a camera is open'
        : 'Next clip in ${formatCountdown(left)}';
    return Row(
      key: const Key('schedule-countdown'),
      children: [
        Icon(Icons.schedule, size: 16, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
      ],
    );
  }
}

/// How long events are kept, as "1 day", "10 days", "2 weeks" or
/// "90 days": whole weeks read as weeks.
String formatKeep(Duration keep) {
  final days = keep.inDays;
  if (days == 1) return '1 day';
  if (days % 7 == 0 && days <= 8 * 7) {
    final weeks = days ~/ 7;
    return weeks == 1 ? '1 week' : '$weeks weeks';
  }
  return '$days days';
}

/// Whether subject recognition can run here (see `recognition/`).
final bool _recognitionSupported = TfliteRuntime().supported;

/// [v] rounded to the confidence sliders' 5 % steps.
double _toStep(double v) =>
    (v / RecognitionConfig.step).round() * RecognitionConfig.step;

/// A setting's slider, with its name and value above it. While it's
/// dragged, only the slider and its value follow the finger; the setting
/// changes ([onChanged]) once it's let go, so a drag saves (and syncs) the
/// settings once, not on every frame.
class _LabeledSlider extends StatefulWidget {
  const _LabeledSlider({
    super.key,
    required this.label,
    required this.format,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;

  /// The value as shown beside the label and over the thumb.
  final String Function(double value) format;
  final double value;
  final double min;
  final double max;
  final int divisions;

  /// The new value, once the slider is let go; null disables it.
  final ValueChanged<double>? onChanged;

  @override
  State<_LabeledSlider> createState() => _LabeledSliderState();
}

class _LabeledSliderState extends State<_LabeledSlider> {
  /// Where the thumb is while it's dragged; null otherwise.
  double? _dragged;

  @override
  Widget build(BuildContext context) {
    final value = _dragged ?? widget.value;
    final valueLabel = widget.format(value);
    final commit = widget.onChanged;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(widget.label)),
            Text(valueLabel),
          ],
        ),
        Slider(
          value: value,
          min: widget.min,
          max: widget.max,
          divisions: widget.divisions,
          label: valueLabel,
          onChanged: commit == null
              ? null
              : (v) => setState(() => _dragged = v),
          onChangeEnd: commit == null
              ? null
              : (v) {
                  commit(v);
                  if (mounted) setState(() => _dragged = null);
                },
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

/// The brightness as "+0.5 EV", "0 EV" or "-1.0 EV".
String _formatBrightness(double ev) =>
    ev == 0 ? '0 EV' : '${ev > 0 ? '+' : ''}${ev.toStringAsFixed(1)} EV';

/// The device and profile IDs, side by side in two columns (Device left,
/// Profile right), or stacked when a column would be narrower than
/// [_Ids.minColumn] dp at 1x text (scaled with the text: 240 dp at 2x).
/// At 320 dp the columns are 136 dp: two columns at 1x, stacked at 2x.
class _Ids extends StatelessWidget {
  const _Ids({required this.deviceId, required this.profileId});

  final String? deviceId;
  final String? profileId;

  /// The narrowest readable column at 1x text, about 16 characters of
  /// `bodyMedium`.
  static const minColumn = 120.0;

  static const _gap = 16.0;

  @override
  Widget build(BuildContext context) {
    final device = _IdLine(
      label: 'Device',
      id: deviceId,
      missing: 'loading…',
      idKey: const Key('device-id'),
    );
    final profile = _IdLine(
      label: 'Profile',
      id: profileId,
      // A profile is the signed-in account's.
      missing: 'none until signed in',
      idKey: const Key('profile-id'),
    );
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return LayoutBuilder(
      key: const Key('settings-ids'),
      builder: (context, constraints) {
        final column = (constraints.maxWidth - _gap) / 2;
        if (column < minColumn * scale) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [device, const SizedBox(height: 8), profile],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: device),
            const SizedBox(width: _gap),
            Expanded(child: profile),
          ],
        );
      },
    );
  }
}

/// "Device" over a selectable ID (keyed [idKey]), or [missing] in
/// italics while there's no ID. The ID wraps within its column.
class _IdLine extends StatelessWidget {
  const _IdLine({
    required this.label,
    required this.id,
    required this.missing,
    required this.idKey,
  });

  final String label;
  final String? id;
  final String missing;
  final Key idKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // bodyMedium, as the version at the bottom: IDs get read out and typed
    // on other devices.
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: style?.copyWith(fontWeight: FontWeight.w600)),
        switch (id) {
          final id? => SelectableText(id, key: idKey, style: style),
          null => Text(
            missing,
            key: idKey,
            style: style?.copyWith(fontStyle: FontStyle.italic),
          ),
        },
      ],
    );
  }
}
