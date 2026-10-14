import 'dart:async';

import 'package:flutter/material.dart';

import '../camera_feeds.dart';
import '../l10n/l10n.dart';
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
  /// grey and not pressable.
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

  /// The state of [rig], worded in [l] (English by default).
  static ClipButtonStatus of(CameraRig rig, [AppLocalizations? l]) {
    l ??= lookupAppLocalizations(const Locale('en'));
    final readiness = rig.readiness;
    switch (readiness.state) {
      case ClipReadinessState.paused:
        return ClipButtonStatus(
          ClipTone.disabled,
          status: l.cameraClipCameraOff,
        );
      case ClipReadinessState.unavailable:
        return ClipButtonStatus(
          ClipTone.disabled,
          status: rig.error != null
              ? l.cameraClipUnavailable
              : rig.busy
              ? l.cameraClipStarting
              : rig.devices.isEmpty
              ? l.cameraClipNoCamera
              : l.cameraClipNotReady,
        );
      case ClipReadinessState.ready:
        return readiness.recording
            ? ClipButtonStatus(ClipTone.recording, status: l.cameraClipSaving)
            : ClipButtonStatus(ClipTone.ready, status: l.cameraClipReady);
      case ClipReadinessState.cooldown:
        final countdown = formatCountdown(readiness.remaining);
        final next = l.cameraClipNextIn(countdown);
        return readiness.recording
            ? ClipButtonStatus(
                ClipTone.recording,
                countdown: countdown,
                status: l.cameraClipSavingNext(next),
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
/// in a dark or light theme. The background is the same quiet neutral for
/// every tone but one, which shows only in the label and icon, in muted
/// colors, so the button stays discreet; while a clip is being taken (its
/// "after" seconds, [ClipTone.recording]) the whole button is red, so it's
/// plain that it's recording. Each pair has a contrast of at least 4.5:1.
abstract final class ClipButtonColors {
  /// The background, whatever the tone: a step darker than the Flip
  /// button's on dark themes, Gruvbox's palest on light ones.
  static Color background(Brightness brightness) =>
      brightness == Brightness.dark ? Gruvbox.bg1 : const Color(0xFFF9F5D7);

  /// The recording button's: Gruvbox's red (its deeper shade on light
  /// themes), with its palest cream on it.
  static (Color, Color) recording(Brightness brightness) => (
    brightness == Brightness.dark
        ? const Color(0xFFCC241D)
        : const Color(0xFF9D0006),
    const Color(0xFFFBF1C7),
  );

  static (Color background, Color foreground) of(
    ClipTone tone,
    Brightness brightness,
  ) => tone == ClipTone.recording
      ? recording(brightness)
      : (
          background(brightness),
          switch ((tone, brightness)) {
            // Gruvbox Material's muted green and amber, a soft red, and a warm
            // grey, on dark themes; their deeper shades on light ones.
            (ClipTone.ready, Brightness.dark) => const Color(0xFFA9B665),
            (ClipTone.cooldown, Brightness.dark) => const Color(0xFFD8A657),
            (ClipTone.recording, Brightness.dark) => const Color(0xFFEC8F82),
            (ClipTone.disabled, Brightness.dark) => const Color(0xFFB0A08A),
            (ClipTone.ready, Brightness.light) => const Color(0xFF5F6A28),
            (ClipTone.cooldown, Brightness.light) => const Color(0xFF8F5902),
            (ClipTone.recording, Brightness.light) => const Color(0xFFA6453F),
            (ClipTone.disabled, Brightness.light) => const Color(0xFF6F6359),
          },
        );
}

/// The Clip button, which also shows whether an automatic clip can be
/// taken, by the color of its label and icon on a neutral background
/// ([ClipButtonColors]): green and "Clip" when ready; amber with the
/// cooldown's time left ("Clip · 4:59", or "4:59" where that's too wide)
/// after a clip; filled red while that clip's "after" part is still being
/// taken; grey
/// and disabled when no clip can be taken (camera off, none, starting,
/// failed or lost). A press during the cooldown or
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
      final status = ClipButtonStatus.of(widget.rig, context.l10n);
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
    final l = context.l10n;
    final status = ClipButtonStatus.of(widget.rig, l);
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
      null => [l.cameraClip],
      final time => [l.cameraClipCountdown(time), time],
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
