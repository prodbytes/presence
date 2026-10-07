import 'dart:async';

import 'package:flutter/material.dart';

import '../camera_feeds.dart';
import '../theme.dart';
import '../time_format.dart';

/// What the Clip button shows: its color, whether it can be pressed, and
/// why.
enum ClipTone {
  /// Automatic clips can be taken: green.
  ready,

  /// Counting down the cooldown after the latest clip: amber, with the
  /// time left. Still pressable.
  cooldown,

  /// The latest clip's "after" part is still being saved: red. Still
  /// pressable (a press starts another clip, as it always has).
  recording,

  /// No clip can be taken (camera off, none, starting, failed or lost):
  /// red-tinted and not pressable.
  disabled,
}

/// The Clip button's state, from the rig: [tone], the countdown shown in
/// the label during the cooldown, and the [status] for the tooltip and
/// screen readers.
class ClipButtonStatus {
  const ClipButtonStatus(this.tone, {required this.status, this.countdown});

  final ClipTone tone;

  /// The cooldown's time left ("4:59", "45 s"), when there's one.
  final String? countdown;

  /// The state spelled out ("Ready", "Next automatic clip in 4:28", "Clip
  /// saving…", "Camera off").
  final String status;

  bool get enabled => tone != ClipTone.disabled;

  /// Minutes and seconds for the cooldown ("4:59"), seconds below a minute
  /// ("45 s").
  static String formatCountdown(Duration remaining) {
    final seconds = (remaining.inMilliseconds / 1000).ceil();
    return seconds >= 60 ? formatMinutesSeconds(seconds) : '$seconds s';
  }

  static ClipButtonStatus of(CameraRig rig) {
    final readiness = rig.readiness;
    switch (readiness.state) {
      case ClipReadinessState.paused:
        return const ClipButtonStatus(ClipTone.disabled, status: 'Camera off');
      case ClipReadinessState.unavailable:
        return ClipButtonStatus(
          ClipTone.disabled,
          status: rig.error != null
              ? 'Camera unavailable'
              : rig.busy
              ? 'Camera starting…'
              : rig.devices.isEmpty
              ? 'No camera'
              : 'Camera not ready',
        );
      case ClipReadinessState.ready:
        return readiness.recording
            ? const ClipButtonStatus(ClipTone.recording, status: 'Clip saving…')
            : const ClipButtonStatus(ClipTone.ready, status: 'Ready');
      case ClipReadinessState.cooldown:
        final countdown = formatCountdown(readiness.remaining);
        final next = 'Next automatic clip in $countdown';
        return readiness.recording
            ? ClipButtonStatus(
                ClipTone.recording,
                countdown: countdown,
                status: 'Clip saving… $next',
              )
            : ClipButtonStatus(
                ClipTone.cooldown,
                countdown: countdown,
                status: next,
              );
    }
  }
}

/// The Clip button's colors: background and foreground for a [ClipTone],
/// in a dark or light theme. Each pair has a contrast of at least 4.5:1.
abstract final class ClipButtonColors {
  static (Color background, Color foreground) of(
    ClipTone tone,
    Brightness brightness,
  ) => switch ((tone, brightness)) {
    // Gruvbox's bright colors with its darkest background on dark themes,
    // its faded ones with white on light themes.
    (ClipTone.ready, Brightness.dark) => (Gruvbox.green, Gruvbox.bg0Hard),
    (ClipTone.cooldown, Brightness.dark) => (Gruvbox.yellow, Gruvbox.bg0Hard),
    (ClipTone.recording, Brightness.dark) => (Gruvbox.red, Gruvbox.bg0Hard),
    (ClipTone.disabled, Brightness.dark) => (
      Color(0xFF4A2B28),
      Color(0xFFF2A39A),
    ),
    (ClipTone.ready, Brightness.light) => (Color(0xFF79740E), Colors.white),
    (ClipTone.cooldown, Brightness.light) => (Color(0xFF8F5902), Colors.white),
    (ClipTone.recording, Brightness.light) => (Color(0xFF9D0006), Colors.white),
    (ClipTone.disabled, Brightness.light) => (
      Color(0xFFF6DCD8),
      Color(0xFF8A1C12),
    ),
  };
}

/// The Clip button, which also shows whether an automatic clip can be
/// taken: green and "Clip" when ready; amber with the cooldown's time left
/// ("Clip · 4:59", or "4:59" where that's too wide) after a clip; red while that clip's "after" part is
/// still saving; red-tinted and disabled when no clip can be taken (camera
/// off, none, starting, failed or lost). A press during the cooldown or
/// the saving still takes a clip, and restarts the cooldown. The tooltip
/// and screen readers spell the state out.
class ClipButton extends StatefulWidget {
  const ClipButton({
    super.key,
    required this.rig,
    required this.onPressed,
    required this.maxWidth,
  });

  final CameraRig rig;
  final VoidCallback onPressed;

  /// The room it has: narrower than "Clip · 4:59", the label is the time
  /// alone, and narrower than that, there's only the icon.
  final double maxWidth;

  /// The extended button's room around its label: the padding (16 + 20)
  /// and the icon with its gap (24 + 8).
  static const double chrome = 16 + 24 + 8 + 20;

  @override
  State<ClipButton> createState() => _ClipButtonState();
}

class _ClipButtonState extends State<ClipButton> {
  Timer? _ticker;

  /// What was last shown: rebuilt on a tick only when it changes, so a
  /// ready button schedules no frames.
  String? _shown;

  @override
  void initState() {
    super.initState();
    // The countdown moves with time.
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final status = ClipButtonStatus.of(widget.rig);
      if (_key(status) != _shown) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  static String _key(ClipButtonStatus s) =>
      '${s.tone.name}|${s.countdown}|${s.status}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = ClipButtonStatus.of(widget.rig);
    _shown = _key(status);
    final (background, foreground) = ClipButtonColors.of(
      status.tone,
      theme.brightness,
    );
    final style = (theme.textTheme.labelLarge ?? const TextStyle()).copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    // The longest label that fits: "Clip · 4:59", then the time alone;
    // with none (very large text), the icon alone, the tooltip saying it.
    final label = switch (status.countdown) {
      null => ['Clip'],
      final time => ['Clip · $time', time],
    }.where((text) => _fits(text, style)).firstOrNull;
    return FloatingActionButton.extended(
      key: const Key('clip'),
      heroTag: 'clip',
      tooltip: status.status,
      backgroundColor: background,
      foregroundColor: foreground,
      // Flat when it can't be pressed.
      disabledElevation: 0,
      extendedTextStyle: style,
      icon: const Icon(Icons.camera),
      isExtended: label != null,
      label: Text(label ?? '', maxLines: 1, softWrap: false),
      onPressed: status.enabled ? widget.onPressed : null,
    );
  }

  bool _fits(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return ClipButton.chrome + width <= widget.maxWidth;
  }
}
