import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'cameras/cameras.dart';
import 'clips.dart';
import 'events.dart';
import 'motion.dart';
import 'config.dart';
import 'theme.dart';

/// Whether a clip taken now would be complete, shown beside the Clip button.
enum ClipReadinessState {
  /// No open camera.
  unavailable,

  /// The camera hasn't recorded a full "before" period yet (just opened,
  /// flipped, or "before" was raised): a clip now would have less history.
  buffering,

  /// A clip now gets its full "before" part.
  ready,

  /// A clip's "after" part is being recorded; counts down until it's saved.
  saving,

  /// A motion clip was taken: counts down the motion cooldown, after which
  /// motion can take another clip. (The Clip button always works.)
  cooldown,
}

class ClipReadiness {
  const ClipReadiness(
    this.state, {
    this.remaining = Duration.zero,
    this.progress = 1,
    this.recording = false,
  });

  /// During [ClipReadinessState.cooldown]: the motion clip's "after" part
  /// is still being recorded.
  final bool recording;

  final ClipReadinessState state;

  /// Time left: until buffered (buffering), until the clip is saved
  /// (saving), or until motion can clip again (cooldown).
  final Duration remaining;

  /// 0–1 while buffering.
  final double progress;
}

/// The camera being shown and recorded: one at a time, starting with the
/// device's default camera, switchable with [flip]. Owned by the app so the
/// camera (and its rolling recording) stays open across rebuilds.
class CameraRig extends ChangeNotifier {
  CameraRig({
    required this._backend,
    required this.config,
    this.bus,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _motion = MotionDetector(now: now) {
    config.addListener(_applyBrightness);
    // Android refuses cameras while the screen is off or the app is in the
    // background: when the app comes back, reopen the camera if it failed.
    _lifecycle = AppLifecycleListener(onResume: _retryFailed);
  }

  late final AppLifecycleListener _lifecycle;

  final CameraBackend _backend;
  final ConfigController config;

  /// Where automatic (motion) clips are published.
  final AppEventBus? bus;

  final DateTime Function() _now;
  final MotionDetector _motion;
  StreamSubscription<Uint8List>? _motionFrames;
  int _framesOverThreshold = 0;
  DateTime? _lastMotionClip;
  bool _motionClipStarting = false;

  DateTime? _openedAt;
  VideoClip? _latestClip;
  DateTime? _latestClipEnds;

  /// Whether a clip taken now would be complete. It changes with time, so
  /// callers showing it should also refresh on a timer.
  ClipReadiness get readiness {
    final opened = _openedAt;
    if (_active == null || _busy || opened == null) {
      return const ClipReadiness(ClipReadinessState.unavailable);
    }
    final now = _now();
    final clip = _latestClip;
    final ends = _latestClipEnds;
    final saving = clip != null && ends != null && !clip.fullDone;

    // A manual clip shows its own short countdown, even during a cooldown.
    if (saving && _latestClipTrigger == ClipTrigger.manual) {
      return ClipReadiness(
        ClipReadinessState.saving,
        remaining: _left(ends, now),
      );
    }
    // After a motion clip: the cooldown, which is when motion may clip again.
    final cooldownEnds = motionCooldownEnds;
    if (cooldownEnds != null && now.isBefore(cooldownEnds)) {
      return ClipReadiness(
        ClipReadinessState.cooldown,
        remaining: cooldownEnds.difference(now),
        recording: saving,
      );
    }
    if (saving) {
      return ClipReadiness(
        ClipReadinessState.saving,
        remaining: _left(ends, now),
      );
    }
    final buffered = now.difference(opened);
    final needed = config.clip.before;
    if (buffered < needed) {
      return ClipReadiness(
        ClipReadinessState.buffering,
        remaining: needed - buffered,
        progress: buffered.inMilliseconds / needed.inMilliseconds,
      );
    }
    return const ClipReadiness(ClipReadinessState.ready);
  }

  static Duration _left(DateTime ends, DateTime now) {
    final left = ends.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// When motion may take its next clip, or null if it may now (or motion
  /// clips are off). Both the readiness countdown and the trigger use this.
  DateTime? get motionCooldownEnds {
    final last = _lastMotionClip;
    if (last == null || !config.motion.enabled) return null;
    final ends = last.add(config.motion.cooldown);
    return _now().isBefore(ends) ? ends : null;
  }

  ClipTrigger? _latestClipTrigger;

  /// The latest motion score of the open camera (0–100 % of the picture
  /// changing), or null when there's no score (warming up, no camera).
  final ValueNotifier<double?> motionLevel = ValueNotifier(null);

  /// Three frames in a row over the threshold (0.6 s at 5 per second). A
  /// one-frame glitch changes two frames (appearing, then disappearing), so
  /// it doesn't trigger a clip; real movement easily lasts longer.
  static const int motionFramesToTrigger = 3;

  List<CameraDevice> _devices = const [];
  CameraDevice? _current;
  CameraSource? _active;
  Object? _error;
  bool _busy = true;
  bool _disposed = false;

  /// Every camera the device has.
  List<CameraDevice> get devices => _devices;

  /// The camera selected for display (open, opening, or failed to open).
  CameraDevice? get current => _current;

  /// The open camera, or null while opening or after a failure.
  CameraSource? get active => _active;

  Object? get error => _error;

  /// True while listing, opening or switching cameras.
  bool get busy => _busy;

  bool get canClip => _active != null && !_busy;

  bool get canFlip => _devices.length > 1 && !_busy;

  /// Lists the cameras and opens the default one: the first back camera, or
  /// else the first camera (on web, the browser's default).
  Future<void> load() async {
    await _closeActive();
    _set(busy: true, error: null);
    try {
      _devices = await _backend.listCameras();
    } catch (e) {
      _devices = const [];
      _current = null;
      if (!_disposed) _set(busy: false, error: e);
      return;
    }
    if (_disposed) return;
    _current = _devices.isEmpty
        ? null
        : _devices.firstWhere(
            (d) => d.facing == CameraFacing.back,
            orElse: () => _devices.first,
          );
    await _openCurrent();
  }

  /// Switches to the next camera: the other facing where the device knows
  /// it (back ↔ front), otherwise the next one in the list.
  Future<void> flip() async {
    final current = _current;
    if (!canFlip || current == null) return;
    final start = _devices.indexOf(current);
    final ordered = [
      for (var i = 1; i < _devices.length; i++)
        _devices[(start + i) % _devices.length],
    ];
    _current = current.facing == CameraFacing.unknown
        ? ordered.first
        : ordered.firstWhere(
            (d) => d.facing != current.facing,
            orElse: () => ordered.first,
          );
    await _closeActive();
    await _openCurrent();
  }

  Future<void> _openCurrent() async {
    final device = _current;
    if (device == null) {
      _set(busy: false, error: null);
      return;
    }
    _set(busy: true, error: null);
    try {
      final source = await _backend.open(device, () => config.clip.before);
      if (_disposed || _current != device) {
        await source.dispose();
        return;
      }
      _active = source;
      _openedAt = _now();
      _appliedBrightness = null;
      _applyBrightness();
      _watchMotion(source);
      _set(busy: false, error: null);
    } catch (e) {
      if (!_disposed) _set(busy: false, error: e);
    }
  }

  double? _appliedBrightness;

  /// Sends the brightness setting to the open camera when it changes.
  void _applyBrightness() {
    final source = _active;
    final ev = config.camera.brightness;
    if (source == null || ev == _appliedBrightness) return;
    _appliedBrightness = ev;
    source.setBrightness(ev).ignore();
  }

  void _watchMotion(CameraSource source) {
    _motionFrames?.cancel();
    _motion.reset();
    _framesOverThreshold = 0;
    motionLevel.value = null;
    _motionFrames = source.motionFrames?.listen(_onMotionFrame);
  }

  void _onMotionFrame(Uint8List luma) {
    final score = _motion.add(luma);
    motionLevel.value = score;
    if (score == null || !config.motion.enabled) {
      _framesOverThreshold = 0;
      return;
    }
    _framesOverThreshold = score >= config.motion.threshold
        ? _framesOverThreshold + 1
        : 0;
    if (_framesOverThreshold < motionFramesToTrigger) return;

    // At most one automatic clip per cooldown: only once its countdown has
    // reached zero.
    if (motionCooldownEnds != null) return;
    final now = _now();
    final target = bus;
    if (target == null || !canClip || _motionClipStarting) return;

    _lastMotionClip = now;
    _framesOverThreshold = 0;
    _motionClipStarting = true;
    requestClips(
      target,
      trigger: ClipTrigger.motion,
    ).whenComplete(() => _motionClipStarting = false);
  }

  Future<void> _closeActive() async {
    _motionFrames?.cancel();
    _motionFrames = null;
    motionLevel.value = null;
    final source = _active;
    _active = null;
    if (source != null) {
      notifyListeners();
      await source.dispose();
    }
  }

  void _set({required bool busy, required Object? error}) {
    _busy = busy;
    _error = error;
    notifyListeners();
  }

  /// How long a Clip press waits for the camera's "before" recording before
  /// publishing its event anyway (it then becomes playable when it arrives).
  static const Duration pastWait = Duration(seconds: 2);

  /// Starts a clip on the open camera and publishes a [ClipRequested] event,
  /// with the camera's current frame as its thumbnail.
  ///
  /// The event is published once the "before" recording is ready (normally
  /// a few milliseconds), so it's playable the moment it appears. The same
  /// event is later updated with the full clip.
  Future<void> requestClips(
    AppEventBus bus, {
    ClipTrigger trigger = ClipTrigger.manual,
  }) async {
    final camera = _active;
    if (camera == null) return;
    final before = config.clip.before;
    final after = config.clip.after;
    final requestedAt = _now();
    final capture = camera.requestClip(before: before, after: after);
    final (thumbnail, past) = await (
      camera.captureFrame(),
      capture.past
          .timeout(pastWait, onTimeout: () => null)
          .then<ClipMedia?>((m) => m, onError: (Object _) => null),
    ).wait;
    final clip = VideoClip(
      cameraId: camera.id,
      cameraLabel: camera.label,
      before: before,
      after: after,
      capture: capture,
      past: past,
      thumbnail: thumbnail,
      supported: camera.supportsVideo,
    );
    // Readiness shows this clip's countdown until its full clip is saved.
    _latestClip?.removeListener(notifyListeners);
    _latestClip = clip..addListener(notifyListeners);
    _latestClipEnds = requestedAt.add(after);
    _latestClipTrigger = trigger;
    notifyListeners();
    bus.publish(ClipRequested(clip, trigger: trigger, time: requestedAt));
  }

  void _retryFailed() {
    if (_error == null || _busy) return;
    if (_devices.isEmpty) {
      load();
    } else {
      _openCurrent();
    }
  }

  /// Retries after a failure: reopens the selected camera, or relists.
  Future<void> retry() => _devices.isEmpty ? load() : _openCurrent();

  @override
  void dispose() {
    _disposed = true;
    _latestClip?.removeListener(notifyListeners);
    _motionFrames?.cancel();
    motionLevel.dispose();
    config.removeListener(_applyBrightness);
    _lifecycle.dispose();
    _active?.dispose();
    _active = null;
    super.dispose();
  }
}

/// The open camera, full screen and without overlays.
class CameraFeedsView extends StatelessWidget {
  const CameraFeedsView({super.key, required this.rig});

  final CameraRig rig;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Gruvbox.bg0Hard,
      child: ListenableBuilder(
        listenable: rig,
        builder: (context, _) {
          final active = rig.active;
          if (active != null) {
            return SizedBox.expand(
              key: ObjectKey(active),
              child: active.buildPreview(context),
            );
          }
          final error = rig.error;
          if (error != null) {
            return FeedMessage(
              icon: Icons.error_outline,
              message:
                  'Could not open the camera\n${describeCameraError(error)}',
              action: TextButton(
                onPressed: rig.retry,
                child: const Text('Retry'),
              ),
            );
          }
          if (rig.busy) {
            return const Center(child: CircularProgressIndicator());
          }
          return FeedMessage(
            icon: Icons.videocam_off_outlined,
            message: 'No camera found',
            action: TextButton(onPressed: rig.load, child: const Text('Retry')),
          );
        },
      ),
    );
  }
}

class FeedMessage extends StatelessWidget {
  const FeedMessage({
    super.key,
    required this.icon,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: color),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: color),
            ),
            if (action != null) ...[const SizedBox(height: 8), action!],
          ],
        ),
      ),
    );
  }
}

String describeCameraError(Object error) {
  // Browser errors (DOMException) carry a readable message in toString.
  final text = error.toString();
  return text.startsWith('Exception: ') ? text.substring(11) : text;
}
