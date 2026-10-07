/// When the automatic clips (motion, scheduled, startup) may be taken: the
/// cooldown, the schedule and the motion trigger, as pure decisions of
/// time and settings. [CameraRig] keeps the state (the latest clip, the
/// open camera, the timers) and asks these.
library;

import '../clips.dart' show ClipTrigger;
import '../config.dart';

/// Whether an automatic clip (motion, the schedule) can be taken now, shown
/// beside the Clip button. Every clip, whatever took it, starts the
/// cooldown; the Clip button is never blocked by it.
enum ClipReadinessState {
  /// No open camera.
  unavailable,

  /// The user switched the camera off (None): nothing is recorded.
  paused,

  /// Automatic clips can be taken (and the Clip button always can).
  ready,

  /// A clip was taken (any trigger): counts down the cooldown
  /// ([MotionConfig.cooldown]), after which automatic clips can be taken
  /// again. (The Clip button always works, and restarts it.)
  cooldown,
}

class ClipReadiness {
  const ClipReadiness(
    this.state, {
    this.remaining = Duration.zero,
    this.recording = false,
  });

  /// During [ClipReadinessState.cooldown]: the latest clip's "after" part
  /// is still being recorded.
  final bool recording;

  final ClipReadinessState state;

  /// Time left until an automatic clip can be taken again (cooldown).
  final Duration remaining;
}

/// The cooldown and the schedule, as functions of time and settings.
abstract final class AutoClipPolicy {
  /// Whether any automatic clip is on (motion or scheduled clips): with
  /// both off there's no cooldown to wait for.
  static bool automaticClips(MotionConfig motion, ScheduleConfig schedule) =>
      motion.enabled || schedule.enabled;

  /// A clip time later than [now] (another clock, or this one set back)
  /// counts as now, so the cooldown never runs longer than its length.
  static DateTime clampToNow(DateTime time, DateTime now) =>
      time.isAfter(now) ? now : time;

  /// When automatic clips may be taken again after the latest clip at
  /// [lastClip] ([MotionConfig.cooldown] later), or null if they may now.
  static DateTime? cooldownEnds({
    required DateTime lastClip,
    required DateTime now,
    required Duration cooldown,
  }) {
    final ends = clampToNow(lastClip, now).add(cooldown);
    return now.isBefore(ends) ? ends : null;
  }

  /// When the next scheduled clip is due: [ScheduleConfig.every] after
  /// [lastScheduled], or after [scheduleFrom] (app start) before the
  /// first; null when scheduled clips are off.
  static DateTime? nextScheduledClip(
    ScheduleConfig schedule, {
    required DateTime? lastScheduled,
    required DateTime scheduleFrom,
  }) => schedule.enabled
      ? (lastScheduled ?? scheduleFrom).add(schedule.every)
      : null;

  /// Time left until the next scheduled clip ([due]): to the end of the
  /// cooldown ([cooldownEnds]) if it's due before then, zero once it's due,
  /// null when there's none ([due] null).
  static Duration? untilScheduledClip({
    required DateTime? due,
    required DateTime? cooldownEnds,
    required DateTime now,
  }) {
    if (due == null) return null;
    if (cooldownEnds != null && cooldownEnds.isAfter(due)) due = cooldownEnds;
    final left = due.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// The scheduled clip to take now, once the camera (open since
  /// [openedAt]) has a full [before] part: the startup clip until it's
  /// taken ([startupTaken]), then a scheduled one once [due]. Null: none
  /// yet. The caller checks the rest (an open camera, no cooldown).
  static ClipTrigger? scheduledClip({
    required DateTime due,
    required DateTime openedAt,
    required DateTime now,
    required bool startupTaken,
    required Duration before,
  }) {
    final startup = !startupTaken;
    if ((!startup && now.isBefore(due)) || now.difference(openedAt) < before) {
      return null;
    }
    return startup ? ClipTrigger.startup : ClipTrigger.scheduled;
  }
}

/// Counts the motion frames in a row over [MotionConfig.threshold]: enough
/// of them ([framesToTrigger]) call for a motion clip.
class MotionTrigger {
  /// Three frames in a row over the threshold (0.6 s at 5 per second). A
  /// one-frame glitch changes two frames (appearing, then disappearing), so
  /// it doesn't trigger a clip; real movement easily lasts longer.
  static const int framesToTrigger = 3;

  int _framesOver = 0;

  /// Adds a frame's motion [score] (null while warming up): whether there
  /// have now been [framesToTrigger] or more in a row over the threshold,
  /// with motion clips on. The count goes on until [reset], so a trigger
  /// held back (e.g. by the cooldown) fires on the next frame over it.
  bool add(double? score, MotionConfig motion) {
    if (score == null || !motion.enabled) {
      _framesOver = 0;
      return false;
    }
    _framesOver = score >= motion.threshold ? _framesOver + 1 : 0;
    return _framesOver >= framesToTrigger;
  }

  /// Starts counting again (a clip was taken, or a new camera opened).
  void reset() => _framesOver = 0;
}
