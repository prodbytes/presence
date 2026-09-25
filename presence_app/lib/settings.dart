import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'config.dart';

/// The Settings screen (the Settings tab).
class SettingsView extends StatelessWidget {
  const SettingsView({super.key, required this.config, this.motionLevel});

  /// The app's configuration; every control edits it.
  final ConfigController config;

  /// The open camera's live motion score, shown to help set the threshold.
  final ValueListenable<double?>? motionLevel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: config,
      builder: (context, _) {
        final clip = config.clip;
        final camera = config.camera;
        final motion = config.motion;
        // Each change applies to the *current* config, not the one this
        // build saw: two changes before the next rebuild must both stick.
        void setClip(ClipConfig Function(ClipConfig) f) =>
            config.update((x) => x.copyWith(clip: f(x.clip)));
        void setCamera(CameraConfig Function(CameraConfig) f) =>
            config.update((x) => x.copyWith(camera: f(x.camera)));
        void setMotion(MotionConfig Function(MotionConfig) f) =>
            config.update((x) => x.copyWith(motion: f(x.motion)));
        return ListView(
          key: const Key('settings-page'),
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
          ],
        );
      },
    );
  }
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
