import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_version.dart';
import 'camera_feeds.dart';
import 'config.dart';
import 'identity/device_memory.dart';
import 'location/device_location.dart';
import 'l10n/l10n.dart';
import 'location/location_settings.dart';
import 'recognition/cloud_recognition.dart';
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
    this.blink,
    this.gopro,
    this.location,
    this.tiles,
    this.onMapHeld,
    this.nextClip,
    this.logTabDefault,
    this.liveSync = false,
    this.memory = DeviceMemory.read,
    this.liveAdmin = false,
    this.liveFree = false,
  });

  /// Whether this build has live sync (an IoT endpoint, and cloud sync):
  /// the **Live sync** section, with its **Connect to live sync** slider.
  final bool liveSync;

  /// The user is an admin: live sync is always connected for them
  /// ([LiveConfig.effective]), so the slider shows Always, locked. Others
  /// may pick from Never to every 60 min (every 30 s the most often), and
  /// a saved Always shows as every 30 s.
  final bool liveAdmin;

  /// The user is a free member: live sync connects every 15 min at the
  /// most often ([LiveConfig.freeMinEvery]), so the slider offers Never or
  /// every 15 min and slower, and its note says Premium syncs instantly.
  final bool liveFree;

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

  /// Told while the location map is held, so nothing around it scrolls
  /// away under a drag on it ([LocationSettings.onMapHeld]).
  final ValueChanged<bool>? onMapHeld;

  /// This device's ID, always shown first, at the top ("loading…" until
  /// it's known).
  final String? deviceId;

  /// Reads this device's memory, shown after its ID ([DeviceMemory.read];
  /// tests give their own). Read when Settings opens.
  final Future<DeviceMemory?> Function() memory;

  /// This device's profile ID, always shown at the top beside the device
  /// ID ("none until signed in" until it's known).
  final String? profileId;

  /// A status line under the version (the API, AWS, OIDC and Live).
  final Widget? health;

  /// Above the IDs, at the end: opens a QR code and a Share button, to
  /// open Presence on another device as a new device of the same user.
  final Widget? addDevice;

  /// The last section, **Blink cameras** (`BlinkSettings`): for a premium
  /// profile with cloud sync. None: no section.
  final Widget? blink;

  /// After it, **GoPro cameras** (`GoProSettings`): for a premium profile
  /// with cloud sync. None: no section.
  final Widget? gopro;

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

  /// The device's memory, as Settings opened.
  late final Future<DeviceMemory?> _memory = widget.memory();

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
        final l = context.l10n;
        // How live sync connects for this user (admins: always; others:
        // as saved, at most every 30 s), not just what's saved.
        final live = config.live.effective(
          isAdmin: widget.liveAdmin,
          isPremium: !widget.liveFree,
        );
        final liveMax = widget.liveAdmin
            ? LiveConfig.steps - 1
            : LiveConfig.memberMaxStep;
        void setHistory(HistoryConfig Function(HistoryConfig) f) =>
            config.update((x) => x.copyWith(history: f(x.history)));
        void setRecognition(RecognitionConfig Function(RecognitionConfig) f) =>
            config.update((x) => x.copyWith(recognition: f(x.recognition)));
        const confidenceSteps =
            ((RecognitionConfig.maxConfidence -
                        RecognitionConfig.minConfidence) /
                    RecognitionConfig.step +
                0.5) ~/
            1;
        return ListView(
          key: const Key('settings-page'),
          physics: _mapHeld ? const NeverScrollableScrollPhysics() : null,
          // Edge to edge: the groups span the width, their content 16 dp
          // in.
          padding: const EdgeInsets.only(top: 8, bottom: 24),
          children: [
            // First: where this device is, its position and the map.
            if (location != null)
              SettingsSection(
                title: l.settingsLocationSection,
                children: [
                  LocationSettings(
                    location: location,
                    tiles: widget.tiles,
                    onMapHeld: _onMapHeld,
                  ),
                ],
              ),
            SettingsSection(
              title: l.settingsCameraSection,
              children: [
                _LabeledSlider(
                  key: const Key('brightness-slider'),
                  label: l.settingsBrightness,
                  format: _formatBrightness,
                  value: camera.brightness,
                  min: CameraConfig.minBrightness,
                  max: CameraConfig.maxBrightness,
                  divisions:
                      ((CameraConfig.maxBrightness -
                                  CameraConfig.minBrightness) /
                              CameraConfig.brightnessStep)
                          .round(),
                  onChanged: (ev) =>
                      setCamera((c) => c.copyWith(brightness: ev)),
                ),
                SwitchListTile(
                  key: const Key('night-switch'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(l.settingsNightMode),
                  subtitle: Text(l.settingsNightModeSubtitle),
                  value: camera.night,
                  onChanged: (on) => setCamera((c) => c.copyWith(night: on)),
                ),
              ],
            ),
            SettingsSection(
              title: l.settingsMotionSection,
              children: [
                SwitchListTile(
                  key: const Key('motion-switch'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(l.settingsMotionSwitch),
                  subtitle: Text(l.settingsSameAsClip),
                  value: motion.enabled,
                  onChanged: (on) => setMotion((m) => m.copyWith(enabled: on)),
                ),
                _LabeledSlider(
                  key: const Key('motion-threshold-slider'),
                  label: l.settingsMotionThreshold,
                  format: (v) => l.settingsMotionThresholdValue(v.round()),
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
                  label: l.settingsMotionCooldown,
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
              ],
            ),
            SettingsSection(
              title: l.settingsClipsSection,
              children: [
                // Side by side: before on the left, after on the right.
                Row(
                  key: const Key('clip-sliders'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 8,
                  children: [
                    Expanded(
                      child: _LabeledSlider(
                        key: const Key('clip-before-slider'),
                        label: l.settingsClipBefore,
                        format: (v) => '${v.round()} s',
                        value: clip.before.inSeconds.toDouble(),
                        min: ClipConfig.min.inSeconds.toDouble(),
                        max: ClipConfig.max.inSeconds.toDouble(),
                        divisions:
                            (ClipConfig.max - ClipConfig.min).inSeconds ~/
                            ClipConfig.step.inSeconds,
                        onChanged: (v) => setClip(
                          (c) =>
                              c.copyWith(before: Duration(seconds: v.round())),
                        ),
                      ),
                    ),
                    Expanded(
                      child: _LabeledSlider(
                        key: const Key('clip-after-slider'),
                        label: l.settingsClipAfter,
                        format: (v) => '${v.round()} s',
                        value: clip.after.inSeconds.toDouble(),
                        min: ClipConfig.min.inSeconds.toDouble(),
                        max: ClipConfig.max.inSeconds.toDouble(),
                        divisions:
                            (ClipConfig.max - ClipConfig.min).inSeconds ~/
                            ClipConfig.step.inSeconds,
                        onChanged: (v) => setClip(
                          (c) =>
                              c.copyWith(after: Duration(seconds: v.round())),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  l.settingsClipsNote(clip.total.inSeconds),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            SettingsSection(
              title: l.settingsScheduleSection,
              children: [
                SwitchListTile(
                  key: const Key('schedule-switch'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(l.settingsScheduleSwitch),
                  subtitle: Text(l.settingsSameAsClip),
                  value: schedule.enabled,
                  onChanged: (on) =>
                      setSchedule((x) => x.copyWith(enabled: on)),
                ),
                _LabeledSlider(
                  key: const Key('schedule-every-slider'),
                  label: l.settingsScheduleEvery,
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
                          (x) =>
                              x.copyWith(every: Duration(minutes: v.round())),
                        )
                      : null,
                ),
                if (widget.nextClip case final nextClip? when schedule.enabled)
                  nextClip,
              ],
            ),
            SettingsSection(
              title: l.settingsRecognitionSection,
              children: [
                SwitchListTile(
                  key: const Key('recognition-switch'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(l.settingsRecognitionSwitch),
                  subtitle: Text(
                    _recognitionSupported
                        ? l.settingsRecognitionSubtitle
                        : l.settingsRecognitionUnavailable,
                  ),
                  value: recognition.enabled && _recognitionSupported,
                  onChanged: _recognitionSupported
                      ? (on) => setRecognition((r) => r.copyWith(enabled: on))
                      : null,
                ),
                SwitchListTile(
                  key: const Key('recognition-objects-switch'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(l.settingsObjectsSwitch),
                  subtitle: Text(
                    _recognitionSupported
                        ? l.settingsObjectsSubtitle
                        : l.settingsRecognitionUnavailable,
                  ),
                  value: recognition.objects && _recognitionSupported,
                  onChanged: _recognitionSupported
                      ? (on) => setRecognition((r) => r.copyWith(objects: on))
                      : null,
                ),
                _LabeledSlider(
                  key: const Key('recognition-auto-slider'),
                  label: l.settingsAutoTag,
                  format: (v) =>
                      l.settingsAutoTagValue((_toStep(v) * 100).round()),
                  value: recognition.autoTag,
                  min: RecognitionConfig.minConfidence,
                  max: RecognitionConfig.maxConfidence,
                  divisions: confidenceSteps,
                  onChanged: recognition.enabled && _recognitionSupported
                      ? (v) => setRecognition(
                          (r) => r.copyWith(autoTag: _toStep(v)),
                        )
                      : null,
                ),
                Text(
                  l.settingsAskNote,
                  key: const Key('recognition-ask-note'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const CloudRecognitionTile(),
              ],
            ),
            SettingsSection(
              title: l.settingsHistorySection,
              children: [
                _LabeledSlider(
                  key: const Key('history-keep-slider'),
                  label: l.settingsKeep,
                  format: (v) => formatKeep(Duration(days: v.round()), l),
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
                  l.settingsHistoryNote,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            // The app's language: the device's, or one picked here.
            SettingsSection(
              title: context.l10n.languageSection,
              children: [
                DropdownButtonFormField<String?>(
                  key: const Key('language-picker'),
                  initialValue: config.language.code,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: context.l10n.languageLabel,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    DropdownMenuItem(
                      value: null,
                      child: Text(context.l10n.languageSystem),
                    ),
                    for (final (code, name) in [
                      ('en', context.l10n.languageEnglish),
                      ('es', context.l10n.languageSpanish),
                      ('pt', context.l10n.languagePortuguese),
                    ])
                      DropdownMenuItem(
                        value: code,
                        key: Key('language-$code'),
                        child: Text(name),
                      ),
                  ],
                  onChanged: (code) => widget.config.update(
                    (x) => x.copyWith(language: x.language.withCode(code)),
                  ),
                ),
                Text(
                  context.l10n.languageNote,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            // Under History: how this device hears of the others' events.
            if (widget.liveSync)
              SettingsSection(
                title: l.settingsLiveSection,
                children: [
                  _LabeledSlider(
                    key: const Key('live-connect-slider'),
                    label: l.settingsLiveConnect,
                    format: (v) => _liveLabel(LiveConfig.ofStep(v.round()), l),
                    value: live.step.toDouble(),
                    min: 0,
                    max: liveMax.toDouble(),
                    divisions: liveMax,
                    // Locked for admins: always connected.
                    onChanged: widget.liveAdmin
                        ? null
                        : (v) => config.update(
                            (x) => x.copyWith(
                              live: LiveConfig.ofStep(
                                // Free: nothing faster than every 15 min.
                                widget.liveFree &&
                                        v.round() > 0 &&
                                        v.round() < LiveConfig.freeMinStep
                                    ? LiveConfig.freeMinStep
                                    : v.round(),
                              ),
                            ),
                          ),
                  ),
                  Text(
                    switch (live.mode) {
                      _ when widget.liveAdmin => l.settingsLiveAdminNote,
                      LiveMode.never => l.settingsLiveNeverNote,
                      _ when live.free => l.settingsLiveFreeNote(
                        LiveConfig.formatEvery(live.every),
                      ),
                      LiveMode.always => l.settingsLiveAlwaysNote,
                      LiveMode.scheduled => l.settingsLiveScheduledNote(
                        LiveConfig.formatEvery(live.every),
                      ),
                    },
                    key: const Key('live-connect-note'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            if (widget.logTabDefault case final dev?)
              SettingsSection(
                title: l.settingsAdvancedSection,
                children: [
                  SwitchListTile(
                    key: const Key('show-log-switch'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(l.settingsShowLog),
                    subtitle: Text(l.settingsShowLogSubtitle),
                    value: config.log.showIn(dev: dev),
                    onChanged: (v) => config.update(
                      (x) => x.copyWith(log: x.log.copyWith(show: v)),
                    ),
                  ),
                ],
              ),
            // Last: how much the Subjects screens load.
            SettingsSection(
              title: l.settingsSubjectsSection,
              children: [
                _LabeledSlider(
                  key: const Key('subject-events-slider'),
                  label: l.settingsSubjectEvents,
                  format: (v) => '${v.round()}',
                  value: subjects.mapEvents.toDouble(),
                  min: SubjectsConfig.minMapEvents.toDouble(),
                  max: SubjectsConfig.maxMapEvents.toDouble(),
                  divisions:
                      (SubjectsConfig.maxMapEvents -
                          SubjectsConfig.minMapEvents) ~/
                      SubjectsConfig.mapEventsStep,
                  onChanged: (v) =>
                      setSubjects((s) => s.copyWith(mapEvents: v.round())),
                ),
              ],
            ),
            // Below the groups, in the page's margins: the version, the
            // health line, adding a device and the IDs.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Which build this is, e.g. to check a deploy landed.
                  if (AppVersion.version.isNotEmpty) ...[
                    Text(
                      'Presence ${AppVersion.version}',
                      key: const Key('app-version'),
                      textAlign: TextAlign.center,
                      // bodyMedium, as the IDs at the bottom: read out to check a
                      // deploy landed.
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (health case final health?) ...[
                    if (AppVersion.version.isNotEmpty)
                      const SizedBox(height: 8),
                    health,
                  ],
                  if (widget.addDevice case final addDevice?) ...[
                    const SizedBox(height: 32),
                    addDevice,
                  ],
                  const SizedBox(height: 32),
                ],
              ),
            ),
            // The very last thing: which device and profile this is, as
            // the events and the auth API say (selectable, to copy), one
            // line each. Always shown.
            Padding(
              key: const Key('settings-ids'),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FutureBuilder<DeviceMemory?>(
                    future: _memory,
                    builder: (context, snapshot) => _IdLine(
                      label: l.settingsDevice,
                      id: widget.deviceId,
                      missing: l.settingsDeviceLoading,
                      idKey: const Key('device-id'),
                      // How much memory it has, as its platform says.
                      after: switch (snapshot.data) {
                        DeviceMemory(:final bytes, free: true) =>
                          l.settingsMemoryFree(DeviceMemory.format(bytes)),
                        DeviceMemory(:final bytes) => l.settingsMemoryAbout(
                          DeviceMemory.format(bytes),
                        ),
                        null => null,
                      },
                    ),
                  ),
                  _IdLine(
                    label: l.settingsProfile,
                    id: widget.profileId,
                    // A profile is the signed-in account's.
                    missing: l.settingsProfileNone,
                    idKey: const Key('profile-id'),
                  ),
                ],
              ),
            ),
            // Last: a Linux streamer fetching Blink's cameras.
            if (widget.blink case final blink?)
              SettingsSection(
                key: const Key('blink-section'),
                title: l.settingsBlinkSection,
                children: [blink],
              ),
            // Then a Linux streamer fetching GoPro cameras' videos.
            if (widget.gopro case final gopro?)
              SettingsSection(
                key: const Key('gopro-section'),
                title: l.settingsGoProSection,
                children: [gopro],
              ),
          ],
        );
      },
    );
  }
}

/// A group of settings, as in most phone apps' settings (Strava's): a
/// short bold heading, then its controls on a block a step lighter than the
/// page, edge to edge, with the content 16 dp in; 16 dp below it, before
/// the next group.
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Card(
            margin: EdgeInsets.zero,
            shape: const RoundedRectangleBorder(),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ],
      ),
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
    final l = context.l10n;
    final text = rig.startupClipPending
        ? l.settingsStartupClip
        : left == Duration.zero
        ? l.settingsNextClipDue
        : l.settingsNextClipIn(formatCountdown(left));
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
/// "90 days": whole weeks read as weeks. In [l]'s language when given,
/// else English.
String formatKeep(Duration keep, [AppLocalizations? l]) {
  final loc = l ?? lookupAppLocalizations(const Locale('en'));
  final days = keep.inDays;
  if (days % 7 == 0 && days <= 8 * 7) {
    return loc.settingsKeepWeeks(days ~/ 7);
  }
  return loc.settingsKeepDays(days);
}

/// A live sync step's label: "Never", "Every 30 s", "Every 60 min",
/// "Always" ([LiveConfig.label], in [l]'s language).
String _liveLabel(LiveConfig live, AppLocalizations l) => switch (live.mode) {
  LiveMode.never => l.settingsLiveNever,
  LiveMode.always => l.settingsLiveAlways,
  LiveMode.scheduled => l.settingsLiveEvery(LiveConfig.formatEvery(live.every)),
};

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
                    ? context.l10n.settingsMotionNowWaiting
                    : context.l10n.settingsMotionNow(score.round()),
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

/// "Device automatic_paranoid_gadget": a label and a selectable ID
/// (keyed [idKey]), or [missing] in italics while there's no ID. When the
/// line doesn't fit, the ID wraps under its label.
class _IdLine extends StatelessWidget {
  const _IdLine({
    required this.label,
    required this.id,
    required this.missing,
    required this.idKey,
    this.after,
  });

  final String label;
  final String? id;
  final String missing;
  final Key idKey;

  /// Shown after the ID, in parentheses (the device's memory).
  final String? after;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // bodyMedium, as the version above: IDs get read out and typed on
    // other devices.
    final scheme = theme.colorScheme;
    // The label in the accent color, the value plain, so each reads apart.
    final style = theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface);
    final muted = style?.copyWith(color: scheme.onSurfaceVariant);
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          '$label ',
          style: style?.copyWith(
            color: scheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
        switch (id) {
          final id? => SelectableText(id, key: idKey, style: style),
          null => Text(
            missing,
            key: idKey,
            style: muted?.copyWith(fontStyle: FontStyle.italic),
          ),
        },
        if (after case final after?)
          Text(
            ' ($after)',
            key: Key('${(idKey as ValueKey<String>).value}-after'),
            style: muted,
          ),
      ],
    );
  }
}
