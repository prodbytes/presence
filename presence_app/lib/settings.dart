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
  const SettingsView({super.key, required this.settings});

  final ClipSettings settings;

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
