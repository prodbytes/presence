import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// User-adjustable clip settings. Kept in memory for the session.
class ClipSettings extends ChangeNotifier {
  static const Duration min = Duration(seconds: 5);
  static const Duration max = Duration(seconds: 60);
  static const Duration step = Duration(seconds: 5);
  static const Duration defaultLength = Duration(seconds: 15);

  Duration _before = defaultLength;
  Duration _after = defaultLength;

  /// How much video from before the Clip press each clip includes. Also how
  /// much history the cameras keep recording.
  Duration get before => _before;
  set before(Duration value) {
    _before = _clamp(value);
    notifyListeners();
  }

  /// How much video from after the Clip press each clip includes.
  Duration get after => _after;
  set after(Duration value) {
    _after = _clamp(value);
    notifyListeners();
  }

  static Duration _clamp(Duration d) => d < min ? min : (d > max ? max : d);

  static const double minBrightness = -2;
  static const double maxBrightness = 2;
  static const double brightnessStep = 0.5;

  /// Brighter by default: small phone sensors run dark indoors.
  static const double defaultBrightness = 1;

  double _brightness = defaultBrightness;

  static const double minMotionThreshold = 1;
  static const double maxMotionThreshold = 50;
  static const double defaultMotionThreshold = 10;
  static const Duration minMotionCooldown = Duration(minutes: 1);
  static const Duration maxMotionCooldown = Duration(minutes: 60);
  static const Duration defaultMotionCooldown = Duration(minutes: 5);

  bool _motionEnabled = true;
  double _motionThreshold = defaultMotionThreshold;
  Duration _motionCooldown = defaultMotionCooldown;

  /// Whether enough motion takes a clip automatically.
  bool get motionEnabled => _motionEnabled;
  set motionEnabled(bool value) {
    _motionEnabled = value;
    notifyListeners();
  }

  /// How much of the picture (percent of pixels) must change to count as
  /// motion.
  double get motionThreshold => _motionThreshold;
  set motionThreshold(double percent) {
    _motionThreshold = percent
        .clamp(minMotionThreshold, maxMotionThreshold)
        .toDouble();
    notifyListeners();
  }

  /// At most one automatic clip per this period. Manual clips aren't
  /// limited.
  Duration get motionCooldown => _motionCooldown;
  set motionCooldown(Duration value) {
    _motionCooldown = value < minMotionCooldown
        ? minMotionCooldown
        : (value > maxMotionCooldown ? maxMotionCooldown : value);
    notifyListeners();
  }

  /// Camera brightness as exposure compensation, in EV. Applied live to the
  /// open camera, where the camera supports it.
  double get brightness => _brightness;
  set brightness(double ev) {
    _brightness = ev.clamp(minBrightness, maxBrightness).toDouble();
    notifyListeners();
  }
}

/// The Settings screen (the Settings tab).
class SettingsView extends StatelessWidget {
  const SettingsView({super.key, required this.settings, this.motionLevel});

  final ClipSettings settings;

  /// The open camera's live motion score, shown to help set the threshold.
  final ValueListenable<double?>? motionLevel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => ListView(
        key: const Key('settings-page'),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          Text('Camera', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          _BrightnessSlider(
            key: const Key('brightness-slider'),
            value: settings.brightness,
            onChanged: (ev) => settings.brightness = ev,
          ),
          const SizedBox(height: 16),
          Text('Motion', style: theme.textTheme.titleMedium),
          SwitchListTile(
            key: const Key('motion-switch'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Clip automatically on motion'),
            subtitle: const Text('Same as pressing Clip'),
            value: settings.motionEnabled,
            onChanged: (on) => settings.motionEnabled = on,
          ),
          _LabeledSlider(
            key: const Key('motion-threshold-slider'),
            label: 'Motion threshold',
            valueLabel: '${settings.motionThreshold.round()} % of the picture',
            value: settings.motionThreshold,
            min: ClipSettings.minMotionThreshold,
            max: ClipSettings.maxMotionThreshold,
            divisions: 49,
            onChanged: settings.motionEnabled
                ? (v) => settings.motionThreshold = v.roundToDouble()
                : null,
          ),
          if (motionLevel case final level?)
            _MotionMeter(level: level, threshold: settings.motionThreshold),
          _LabeledSlider(
            key: const Key('motion-cooldown-slider'),
            label: 'At most one automatic clip every',
            valueLabel: '${settings.motionCooldown.inMinutes} min',
            value: settings.motionCooldown.inMinutes.toDouble(),
            min: ClipSettings.minMotionCooldown.inMinutes.toDouble(),
            max: ClipSettings.maxMotionCooldown.inMinutes.toDouble(),
            divisions:
                ClipSettings.maxMotionCooldown.inMinutes -
                ClipSettings.minMotionCooldown.inMinutes,
            onChanged: settings.motionEnabled
                ? (v) => settings.motionCooldown = Duration(minutes: v.round())
                : null,
          ),
          const SizedBox(height: 16),
          Text('Clips', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          _DurationSlider(
            key: const Key('clip-before-slider'),
            label: 'Before the press',
            value: settings.before,
            onChanged: (d) => settings.before = d,
          ),
          _DurationSlider(
            key: const Key('clip-after-slider'),
            label: 'After the press',
            value: settings.after,
            onChanged: (d) => settings.after = d,
          ),
          const SizedBox(height: 8),
          Text(
            'Clips play ${(settings.before + settings.after).inSeconds} s '
            'in total. Changing "Before" takes up to that long to apply, '
            'while the cameras build up enough history.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
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
        final max = ClipSettings.maxMotionThreshold;
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
          min: ClipSettings.minBrightness,
          max: ClipSettings.maxBrightness,
          divisions:
              ((ClipSettings.maxBrightness - ClipSettings.minBrightness) /
                      ClipSettings.brightnessStep)
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
          min: ClipSettings.min.inSeconds.toDouble(),
          max: ClipSettings.max.inSeconds.toDouble(),
          divisions:
              (ClipSettings.max - ClipSettings.min).inSeconds ~/
              ClipSettings.step.inSeconds,
          label: '$seconds s',
          onChanged: (v) => onChanged(Duration(seconds: v.round())),
        ),
      ],
    );
  }
}
