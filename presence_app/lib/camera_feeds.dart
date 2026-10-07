import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;

import 'cameras/cameras.dart';
import 'clips.dart';
import 'events.dart';
import 'motion.dart';
import 'config.dart';
import 'cloud/live_sync.dart';
import 'device_presence.dart';
import 'theme.dart';

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
    _scheduleFrom = _now();
    _appliedPaused = config.camera.paused;
    config.addListener(_onConfigChanged);
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
  bool _motionClipStarting = false;

  /// When the latest clip (any trigger) was taken: the cooldown runs from
  /// it.
  DateTime? _lastClip;

  /// The latest clip: while its "after" part records, the cooldown shows
  /// as recording.
  VideoClip? _latestClip;

  /// Scheduled clips count from the last one (the startup clip first), or
  /// from app start until it's taken.
  late final DateTime _scheduleFrom;
  DateTime? _lastScheduledClip;
  bool _startupClipTaken = false;
  bool _scheduledClipStarting = false;
  Timer? _scheduleTimer;

  /// When the open camera opened: a scheduled clip waits until it has a
  /// full "before" part.
  DateTime? _openedAt;

  /// How often the schedule is checked.
  static const Duration scheduleCheck = Duration(seconds: 5);

  /// When the next scheduled clip is due ([ScheduleConfig.every] after the
  /// last one, or after app start), or null when they're off.
  DateTime? get nextScheduledClip => config.schedule.enabled
      ? (_lastScheduledClip ?? _scheduleFrom).add(config.schedule.every)
      : null;

  /// Whether the startup clip is still to come (scheduled clips on).
  bool get startupClipPending => config.schedule.enabled && !_startupClipTaken;

  /// Time left until the next scheduled clip, for the Settings countdown:
  /// to the end of the cooldown if it's due before then, zero once it's
  /// due (it waits for an open camera), null when they're off.
  Duration? get untilScheduledClip {
    var due = nextScheduledClip;
    if (due == null) return null;
    final held = cooldownEnds;
    if (held != null && held.isAfter(due)) due = held;
    final left = due.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Takes the startup clip, then a scheduled clip whenever one is due,
  /// once the camera is open and its "before" history is full: the same
  /// path as the Clip button. One due during the cooldown is taken when the
  /// cooldown ends (and the next one counts from then): a one-shot timer
  /// wakes this check then, and it goes before a motion clip. Returns
  /// whether it took a clip.
  bool _checkSchedule() {
    final due = nextScheduledClip;
    final target = bus;
    final opened = _openedAt;
    if (due == null ||
        target == null ||
        opened == null ||
        !canClip ||
        _scheduledClipStarting ||
        cooldownEnds != null) {
      return false;
    }
    final now = _now();
    final startup = !_startupClipTaken;
    if ((!startup && now.isBefore(due)) ||
        now.difference(opened) < config.clip.before) {
      return false;
    }
    _startupClipTaken = true;
    _lastScheduledClip = now;
    _scheduledClipStarting = true;
    requestClips(
          target,
          trigger: startup ? ClipTrigger.startup : ClipTrigger.scheduled,
        )
        .catchError(
          (Object e) => debugPrint('Presence: scheduled clip failed: $e'),
        )
        .whenComplete(() => _scheduledClipStarting = false);
    return true;
  }

  /// Wakes [_checkSchedule] when the cooldown ends, so a scheduled or
  /// startup clip held back by it is taken then, not up to [scheduleCheck]
  /// later (when steady motion would take a motion clip first).
  Timer? _cooldownWake;

  /// (Re)arms [_cooldownWake] for the current cooldown, if scheduled clips
  /// are on.
  void _armCooldownWake() {
    _cooldownWake?.cancel();
    _cooldownWake = null;
    final ends = cooldownEnds;
    if (_disposed || ends == null || !config.schedule.enabled) return;
    _cooldownWake = Timer(ends.difference(_now()), () {
      _cooldownWake = null;
      // A clock a little behind the timer: wait for the rest.
      if (cooldownEnds != null) {
        _armCooldownWake();
      } else {
        _checkSchedule();
      }
    });
  }

  /// Whether a clip taken now would be complete. It changes with time, so
  /// callers showing it should also refresh on a timer.
  ClipReadiness get readiness {
    if (paused) return const ClipReadiness(ClipReadinessState.paused);
    if (_active == null || _busy) {
      return const ClipReadiness(ClipReadinessState.unavailable);
    }
    final now = _now();
    // After any clip: the cooldown, when automatic clips may come again.
    final ends = cooldownEnds;
    if (ends != null) {
      return ClipReadiness(
        ClipReadinessState.cooldown,
        remaining: ends.difference(now),
        recording: !(_latestClip?.fullDone ?? true),
      );
    }
    return const ClipReadiness(ClipReadinessState.ready);
  }

  /// Restores the cooldown after a restart, from this device's last clip
  /// (any trigger) in the stored history, so a relaunch doesn't reset it
  /// (keeps the later of this and any clip taken since launch).
  /// A stored time later than now (another clock, or this one set back)
  /// counts as now, so the cooldown never runs longer than its length.
  void restoreCooldown(DateTime lastClip) {
    final now = _now();
    if (lastClip.isAfter(now)) lastClip = now;
    final current = _lastClip;
    if (current != null && !lastClip.isAfter(current)) return;
    _lastClip = lastClip;
    _armCooldownWake();
    notifyListeners();
  }

  /// When automatic clips (motion, scheduled, startup) may be taken again,
  /// or null if they may now: [MotionConfig.cooldown] after the latest
  /// clip, whatever took it. Null too when motion and scheduled clips are
  /// both off: there's no automatic clip to wait for. The readiness
  /// countdown and the automatic triggers use this; the Clip button
  /// ignores it.
  DateTime? get cooldownEnds {
    var last = _lastClip;
    if (last == null) return null;
    if (!config.motion.enabled && !config.schedule.enabled) return null;
    final now = _now();
    // The clock was set back past the latest clip: it counts as now, so
    // the cooldown never runs longer than its length.
    if (last.isAfter(now)) _lastClip = last = now;
    final ends = last.add(config.motion.cooldown);
    return now.isBefore(ends) ? ends : null;
  }

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

  bool get canFlip => _devices.length > 1 && !_busy && !paused;

  /// The user switched the camera off (the view button's None,
  /// [CameraConfig.paused]): it's closed and records nothing (no motion or
  /// scheduled clips) until switched on.
  bool get paused => config.camera.paused;

  /// Pauses (closes) or resumes (reopens) the camera; kept in the settings,
  /// so it lasts across restarts.
  void setPaused(bool paused) => config.update(
    (c) => c.copyWith(camera: c.camera.copyWith(paused: paused)),
  );

  /// The pause state the camera was last opened or closed for.
  bool _appliedPaused = false;

  /// Pause and resume transitions, one after the other: a resume waits for
  /// the pause before it to finish closing the camera (phones allow one
  /// open camera). A pause doesn't wait for a resume's open: that open is
  /// stale once the pause closes the camera, and releases what it opened.
  Future<void> _pauseTransitions = Future.value();

  void _queuePaused() {
    _pauseTransitions = _pauseTransitions
        .then((_) => _applyPaused())
        .catchError(
          (Object e) => debugPrint('Presence: could not pause/resume: $e'),
        );
  }

  Future<void> _applyPaused() async {
    if (_disposed || _appliedPaused == paused) return;
    _appliedPaused = paused;
    if (paused) {
      debugPrint('Presence: camera paused');
      _lostRetry?.cancel();
      _brightnessRestart?.cancel();
      await _closeActive();
      // Still paused: a resume queued meanwhile reports its own state.
      if (!_disposed && paused) _set(busy: false, error: null);
    } else {
      debugPrint('Presence: camera resumed');
      // Not awaited: a pause queued behind it needn't wait for the camera
      // to open (a browser's permission prompt can wait forever); it makes
      // this open stale instead ([_openGeneration]).
      unawaited(_devices.isEmpty ? load() : _openCurrent());
    }
  }

  /// The camera to open at launch: the one last picked with Flip
  /// ([CameraConfig.chosen]) if the device still has it, else the default
  /// camera ([defaultCamera]); null with no cameras.
  ///
  /// The remembered camera is found by its ID, else (the ID changed, e.g.
  /// a browser that forgot its device IDs) by its label and facing, else by
  /// its facing where known (another front camera for a lost front one).
  static CameraDevice? startCamera(
    List<CameraDevice> devices,
    ChosenCamera? chosen,
  ) {
    if (devices.isEmpty) return null;
    if (chosen != null) {
      final facing = CameraFacing.values.asNameMap()[chosen.facing];
      for (final match in <bool Function(CameraDevice)>[
        (d) => d.id == chosen.id,
        (d) =>
            chosen.label.isNotEmpty &&
            d.label == chosen.label &&
            d.facing == facing,
        (d) =>
            facing != null &&
            facing != CameraFacing.unknown &&
            d.facing == facing,
      ]) {
        for (final d in devices) {
          if (match(d)) return d;
        }
      }
    }
    return defaultCamera(devices);
  }

  /// The first back camera, or else the first camera (on web, the
  /// browser's default, which it lists first).
  static CameraDevice defaultCamera(List<CameraDevice> devices) =>
      devices.firstWhere(
        (d) => d.facing == CameraFacing.back,
        orElse: () => devices.first,
      );

  /// The remembered camera the rig last opened for, so a new one in the
  /// settings (restored late, or from the cloud) switches to it.
  ChosenCamera? _appliedChosen;

  /// Opens the remembered camera when the settings name a different one
  /// than the rig last applied (e.g. restored after the cameras opened).
  Future<void> _applyChosen() async {
    final chosen = config.camera.chosen;
    if (chosen == _appliedChosen || _devices.isEmpty) return;
    _appliedChosen = chosen;
    final device = startCamera(_devices, chosen);
    if (device == null || device == _current) return;
    debugPrint('Presence: opening the remembered camera ${device.label}');
    _current = device;
    await _closeActive();
    await _openCurrent();
  }

  /// Lists the cameras and opens the one last picked with Flip, or else the
  /// default one: the first back camera, or else the first camera (on web,
  /// the browser's default). See [startCamera].
  Future<void> load() async {
    _scheduleTimer ??= Timer.periodic(scheduleCheck, (_) => _checkSchedule());
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
    _appliedChosen = config.camera.chosen;
    _current = startCamera(_devices, _appliedChosen);
    await _openCurrent();
    // The settings named another camera while this one opened.
    if (!_disposed && !_busy) await _applyChosen();
  }

  /// Switches to the next camera: the other facing where the device knows
  /// it (back ↔ front), otherwise the next one in the list. The choice is
  /// kept in the settings ([CameraConfig.chosen]), so a restart reopens it.
  Future<void> flip() async {
    final current = _current;
    if (!canFlip || current == null) return;
    final start = _devices.indexOf(current);
    final ordered = [
      for (var i = 1; i < _devices.length; i++)
        _devices[(start + i) % _devices.length],
    ];
    final next = current.facing == CameraFacing.unknown
        ? ordered.first
        : ordered.firstWhere(
            (d) => d.facing != current.facing,
            orElse: () => ordered.first,
          );
    _current = next;
    final chosen = ChosenCamera(
      id: next.id,
      label: next.label,
      facing: next.facing.name,
    );
    _appliedChosen = chosen;
    config.update((c) => c.copyWith(camera: c.camera.copyWith(chosen: chosen)));
    await _closeActive();
    await _openCurrent();
    if (!_disposed && !_busy) await _applyChosen();
  }

  /// Counts opens and closes: an open finishing after a newer open or a
  /// close ([_closeActive]) began is stale, and its camera is released.
  int _openGeneration = 0;

  Future<void> _openCurrent() async {
    final generation = ++_openGeneration;
    final device = _current;
    if (device == null || paused) {
      _set(busy: false, error: null);
      return;
    }
    _set(busy: true, error: null);
    try {
      final source = await _backend.open(device, () => config.clip.before);
      if (_disposed ||
          generation != _openGeneration ||
          _current != device ||
          paused) {
        await source.dispose();
        // Paused while it opened: nothing else will clear the spinner.
        if (!_disposed && paused && generation == _openGeneration) {
          _set(busy: false, error: null);
        }
        return;
      }
      _active = source;
      _openedAt = _now();
      _appliedBrightness = null;
      _applyBrightness();
      _watchMotion(source);
      source.lost.then((reason) => _onLost(source, reason)).ignore();
      _set(busy: false, error: null);
    } catch (e) {
      // A newer open or a close owns the state now.
      if (!_disposed && generation == _openGeneration) {
        _set(busy: false, error: e);
      }
    }
  }

  /// How long after losing the camera, or failing to get it back, the rig
  /// tries to reopen it.
  static const Duration lostRetryDelay = Duration(seconds: 10);
  Timer? _lostRetry;

  /// The platform took the running camera away (on Android, e.g. while the
  /// screen was off): close it and keep trying to reopen it, so capture
  /// goes on without anyone touching the phone.
  Future<void> _onLost(CameraSource source, String reason) async {
    if (_disposed || !identical(_active, source)) return;
    debugPrint('Presence: lost the camera ($reason); reopening');
    await _closeActive();
    if (_disposed) return;
    _set(busy: false, error: CameraUnavailable(reason));
    _reopenLost();
  }

  void _reopenLost() {
    _lostRetry?.cancel();
    _lostRetry = Timer(lostRetryDelay, () async {
      // Something else (a resume, Retry, Flip) may have reopened it.
      if (_disposed || _active != null || _busy || _error == null) return;
      await _openCurrent();
      if (!_disposed && _active == null && _error != null) _reopenLost();
    });
  }

  double? _appliedBrightness;
  Timer? _brightnessRestart;

  /// How long the brightness setting must stay unchanged before the camera
  /// restarts with it, so dragging the slider restarts it once.
  static const Duration brightnessRestartDelay = Duration(milliseconds: 800);

  /// A new brightness setting restarts the open camera with it (after
  /// [brightnessRestartDelay]); it's applied live meanwhile.
  void _onConfigChanged() {
    // The cooldown's length, or whether scheduled clips are on, may have
    // changed.
    _armCooldownWake();
    _queuePaused();
    // While a camera opens, [load] or [flip] applies it once it's open.
    if (!_busy) _applyChosen();
    final ev = config.camera.brightness;
    if (_active == null || ev == _appliedBrightness) return;
    _applyBrightness();
    _brightnessRestart?.cancel();
    _brightnessRestart = Timer(brightnessRestartDelay, _restartCamera);
  }

  /// Closes and reopens the selected camera, which opens with the current
  /// brightness. Skipped while a camera is opening or switching: that one
  /// gets the current value anyway.
  Future<void> _restartCamera() async {
    if (_disposed || _busy || _active == null) return;
    await _closeActive();
    if (_disposed) return;
    await _openCurrent();
  }

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

    // No automatic clip during the cooldown after any clip: only once its
    // countdown has reached zero.
    if (cooldownEnds != null) return;
    final target = bus;
    if (target == null || !canClip || _motionClipStarting) return;

    _framesOverThreshold = 0;
    // A scheduled or startup clip that's due goes first (it starts the
    // cooldown like any clip), so steady motion can't hold it back.
    if (_checkSchedule()) return;
    _motionClipStarting = true;
    requestClips(target, trigger: ClipTrigger.motion)
        .catchError(
          (Object e) => debugPrint('Presence: motion clip failed: $e'),
        )
        .whenComplete(() => _motionClipStarting = false);
  }

  Future<void> _closeActive() async {
    // An open still in flight is stale now.
    _openGeneration++;
    _openedAt = null;
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
  /// with the camera's current frame as its thumbnail. Whatever the
  /// [trigger], it (re)starts the cooldown ([cooldownEnds]) from now; it
  /// doesn't check it (the automatic triggers do, the Clip button doesn't).
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
    // The cooldown runs from when the clip is grabbed, before the awaits
    // below, so motion in the meantime doesn't take a second one.
    _lastClip = requestedAt;
    if (trigger == ClipTrigger.all) _lastAllClip = requestedAt;
    _armCooldownWake();
    notifyListeners();
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
    // The cooldown shows as recording until the clip's full recording is
    // saved.
    _latestClip?.removeListener(notifyListeners);
    _latestClip = clip..addListener(notifyListeners);
    notifyListeners();
    bus.publish(ClipRequested(clip, trigger: trigger, time: requestedAt));
  }

  /// How old a Capture all request from another device may be and still be
  /// answered: one fetched later (a device that was off or offline) is
  /// past, and its clip wouldn't show the moment it asked for. One dated
  /// further than this ahead (a clock far off) isn't answered either.
  static const Duration captureAllWithin = Duration(minutes: 5);

  /// The least time between two Capture all requests from this device
  /// when the All grid opens ([askAll]): opening it again within it asks
  /// nothing more of the other devices.
  static const Duration askAllEvery = Duration(minutes: 1);

  /// The least time between a Capture all request and one from pressing
  /// Clip in the All grid ([askAll] `pressed`): a press always asks, unless
  /// a request went out this recently (a double tap, or the grid just
  /// opened).
  static const Duration pressAllEvery = Duration(seconds: 5);

  /// The least time between two Capture all clips on this device
  /// ([answerCaptureAll]): requests from several devices at once make one
  /// clip (one arriving both over live sync and from the bucket is
  /// answered once anyway). Short, so a press of Clip in another device's
  /// All grid soon after it opened still gets a new clip.
  static const Duration answerAllEvery = Duration(seconds: 10);

  /// When this device last asked the others for a grab ([askAll]).
  DateTime? _askedAll;

  /// When this device last took a Capture all clip (asked or answered).
  DateTime? _lastAllClip;

  /// The Capture all requests already seen ([answerCaptureAll]), by
  /// event ID, so one is never answered twice; the latest
  /// [_maxSeenRequests].
  final _seenRequests = <String>{};
  static const int _maxSeenRequests = 200;

  /// Publishes a Capture all request ([AppEvent.captureAll]), which cloud
  /// sync (and live sync, within a second, when connected) takes to the
  /// profile's other devices so each takes a fresh grab
  /// ([answerCaptureAll]); unless this device asked within [askAllEvery]
  /// (opening the grid), or within [pressAllEvery] when [pressed] (the Clip
  /// button). Returns the request, or null when it wasn't sent.
  AppEvent? askAll(AppEventBus bus, {bool pressed = false}) {
    final now = _now();
    final last = _askedAll;
    if (last != null &&
        !now.isBefore(last) &&
        now.difference(last) < (pressed ? pressAllEvery : askAllEvery)) {
      return null;
    }
    _askedAll = now;
    final request = AppEvent.captureAll(time: now);
    bus.publish(request);
    return request;
  }

  /// Answers the Capture all requests ([AppEvent.captureAll]) among
  /// [events], just fetched from the cloud or received over live sync:
  /// one clip on the open camera however many arrived, if any is from
  /// another device than [deviceId], within [captureAllWithin] of now, and
  /// not seen before (one that arrives both ways is answered once); and
  /// not within [answerAllEvery] of this device's last Capture all clip,
  /// which is fresh enough. Its event uploads with the next pass, so the
  /// asking device's All grid gets this camera's picture.
  void answerCaptureAll(
    Iterable<AppEvent> events, {
    required String? deviceId,
  }) {
    final target = bus;
    if (target == null || deviceId == null) return;
    final now = _now();
    var asked = false;
    for (final e in events) {
      if (e.type != AppEvent.captureAllType || e.deviceId == deviceId) {
        continue;
      }
      final age = now.difference(e.time);
      if (age >= captureAllWithin || age <= -captureAllWithin) continue;
      if (!_seenRequests.add(e.id)) continue;
      if (_seenRequests.length > _maxSeenRequests) {
        _seenRequests.remove(_seenRequests.first);
      }
      asked = true;
    }
    if (!asked) return;
    final last = _lastAllClip;
    if (last != null &&
        !now.isBefore(last) &&
        now.difference(last) < answerAllEvery) {
      return;
    }
    requestClips(target, trigger: ClipTrigger.all).catchError(
      (Object e) => debugPrint('Presence: Capture all clip failed: $e'),
    );
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
    _scheduleTimer?.cancel();
    _cooldownWake?.cancel();
    _brightnessRestart?.cancel();
    _lostRetry?.cancel();
    _latestClip?.removeListener(notifyListeners);
    _motionFrames?.cancel();
    motionLevel.dispose();
    config.removeListener(_onConfigChanged);
    _lifecycle.dispose();
    _active?.dispose();
    _active = null;
    super.dispose();
  }
}

/// The open camera, full screen and without overlays; or, with [showAll],
/// in the top-left cell of a grid whose other cells hold the latest image
/// of each of the profile's other devices ([latestByDevice]).
class CameraFeedsView extends StatefulWidget {
  const CameraFeedsView({
    super.key,
    required this.rig,
    this.log,
    this.deviceId,
    this.profileId,
    this.showAll = false,
    this.refreshingSince,
    this.onDeleteDevice,
    this.live,
    this.active = true,
  });

  /// Asks to delete another device (the delete button on its cell in the
  /// grid, top left): its events are hidden on every device, and its cell
  /// goes. None: no delete buttons.
  final ValueChanged<String>? onDeleteDevice;

  final CameraRig rig;

  /// The events the other devices' images come from (for [showAll]).
  final EventLog? log;

  /// This device's ID: its own events aren't another device's.
  final String? deviceId;

  /// Only this profile's events count, when set (signed in).
  final String? profileId;

  /// The grid of every device instead of the camera alone.
  final bool showAll;

  /// When this device asked the others for a fresh grab
  /// ([CameraRig.askAll]), while it waits for them: a cell whose image is
  /// older shows a small spinner until a newer one arrives. Null: none.
  final DateTime? refreshingSince;

  /// Live sync, for each device's presence dot in the grid
  /// ([DevicePresence]); the grid pings the devices ([LiveSync.ping]) when
  /// it shows and every 30 s while it does and [active].
  final LiveSync? live;

  /// Whether the page is on screen (the Camera tab): the grid pings only
  /// then.
  final bool active;

  /// Room kept clear under the grid for the status pills, Flip and Clip.
  static const double bottomInset = 88;

  @override
  State<CameraFeedsView> createState() => _CameraFeedsViewState();
}

class _CameraFeedsViewState extends State<CameraFeedsView> {
  /// Refreshes the images' ages while the grid shows.
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _tick();
  }

  @override
  void didUpdateWidget(CameraFeedsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _tick();
  }

  /// Whether the grid pinged since it last showed.
  bool _pinging = false;

  void _tick() {
    if (widget.showAll) {
      _ticker ??= Timer.periodic(const Duration(seconds: 30), (_) {
        if (widget.active) widget.live?.ping().ignore();
        setState(() {});
      });
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
    // Shown (or back on screen): ask who's there now.
    final pinging = widget.showAll && widget.active;
    if (pinging && !_pinging) widget.live?.ping().ignore();
    _pinging = pinging;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rig = widget.rig;
    final log = widget.log;
    return ColoredBox(
      color: Gruvbox.bg0Hard,
      child: ListenableBuilder(
        listenable: Listenable.merge([rig, ?log, ?widget.live]),
        builder: (context, _) {
          final all = widget.showAll;
          final live = widget.live;
          final available = liveAvailable(live);
          final lastEvents = all
              ? lastEventByDevice(
                  log?.events ?? const [],
                  profileId: widget.profileId,
                )
              : const <String, DateTime>{};
          final others = all
              ? latestByDevice(
                  log?.events ?? const [],
                  thisDevice: widget.deviceId,
                  profileId: widget.profileId,
                )
              : const <DeviceLatest>[];
          final padding = MediaQuery.paddingOf(context);
          // The same tree with or without the grid, so switching doesn't
          // rebuild the camera's preview.
          return Padding(
            // The grid stays clear of the app bar above and the buttons
            // below; the camera alone fills the screen.
            padding: all
                ? EdgeInsets.only(
                    top: padding.top + kToolbarHeight,
                    bottom: padding.bottom + CameraFeedsView.bottomInset,
                  )
                : EdgeInsets.zero,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = constraints.biggest;
                final columns = gridColumns(others.length + 1, size);
                final rows = ((others.length + 1) / columns).ceil();
                final cell = Size(size.width / columns, size.height / rows);
                Rect rectOf(int i) =>
                    Offset(
                      (i % columns) * cell.width,
                      (i ~/ columns) * cell.height,
                    ) &
                    cell;
                final now = DateTime.now();
                return Stack(
                  children: [
                    // This device, live: top left in the grid.
                    Positioned.fromRect(
                      rect: all ? rectOf(0).deflate(1) : Offset.zero & size,
                      child: _Cell(
                        label: all
                            ? '${widget.deviceId ?? 'This device'} · live'
                            : null,
                        presence: all
                            ? PresenceDot(
                                key: const Key('presence-this-device'),
                                presence: DevicePresence.of(
                                  now: now,
                                  liveAvailable: available,
                                  thisDevice: true,
                                  connected:
                                      live?.state == LiveSyncState.connected,
                                ),
                              )
                            : null,
                        child: _camera(context),
                      ),
                    ),
                    for (final (i, latest) in others.indexed)
                      Positioned.fromRect(
                        key: ValueKey(latest.deviceId),
                        rect: rectOf(i + 1).deflate(1),
                        child: _Cell(
                          label:
                              '${latest.deviceId} · '
                              '${describeAge(now.difference(latest.time))}',
                          onTap: switch (latest.clip) {
                            final clip? when clip.clip.playable =>
                              () => showClipPlayer(context, clip),
                            _ => null,
                          },
                          refreshing: switch (widget.refreshingSince) {
                            final since? => latest.time.isBefore(since),
                            null => false,
                          },
                          refreshingKey: Key('refreshing-${latest.deviceId}'),
                          onDelete: switch (widget.onDeleteDevice) {
                            final delete? => () => delete(latest.deviceId),
                            null => null,
                          },
                          deleteTooltip: 'Delete ${latest.deviceId}',
                          deleteKey: Key('device-delete-${latest.deviceId}'),
                          presence: PresenceDot(
                            key: Key('presence-${latest.deviceId}'),
                            presence: DevicePresence.of(
                              answeredAt: live?.seenOf(latest.deviceId),
                              lastEvent: lastEvents[latest.deviceId],
                              now: now,
                              liveAvailable: available,
                            ),
                          ),
                          child: _DeviceImage(latest: latest),
                        ),
                      ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }

  /// The open camera's preview, or why there isn't one.
  Widget _camera(BuildContext context) {
    final rig = widget.rig;
    if (rig.paused) {
      return FeedMessage(
        key: const Key('camera-paused'),
        icon: Icons.videocam_off_outlined,
        message: 'Camera off\nNothing is recorded until you turn it on.',
        action: TextButton(
          onPressed: () => rig.setPaused(false),
          child: const Text('Turn on'),
        ),
      );
    }
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
        message: 'Could not open the camera\n${describeCameraError(error)}',
        action: TextButton(onPressed: rig.retry, child: const Text('Retry')),
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
  }
}

/// Another device's latest event, and its latest image, for the grid.
class DeviceLatest {
  const DeviceLatest({required this.deviceId, required this.time, this.clip});

  final String deviceId;

  /// When the device's image was taken, or (without one) its latest event.
  final DateTime time;

  /// The device's newest clip with a thumbnail, if it has one.
  final ClipRequested? clip;

  Uint8List? get image => clip?.clip.thumbnail;
}

/// Each other device in [events] (newest first, as in [EventLog]) with its
/// newest clip thumbnail, sorted by device ID so cells don't move. Events of
/// [thisDevice], without a device, or (when [profileId] is set) of another
/// profile are left out: the rest are the profile's devices, synced from
/// its cloud folder.
List<DeviceLatest> latestByDevice(
  Iterable<AppEvent> events, {
  String? thisDevice,
  String? profileId,
}) {
  final latest = <String, DeviceLatest>{};
  for (final event in events) {
    final device = event.deviceId;
    if (device == null || device == thisDevice) continue;
    if (profileId != null && event.profileId != profileId) continue;
    final known = latest[device];
    if (known?.clip != null) continue;
    final clip = event is ClipRequested && event.clip.thumbnail != null
        ? event
        : null;
    if (known == null || clip != null) {
      latest[device] = DeviceLatest(
        deviceId: device,
        time: clip != null ? event.time : known?.time ?? event.time,
        clip: clip,
      );
    }
  }
  return latest.values.toList()
    ..sort((a, b) => a.deviceId.compareTo(b.deviceId));
}

/// How many columns fit [count] cells in [size] with the biggest 16:9
/// pictures.
int gridColumns(int count, Size size) {
  var best = 1;
  var bestScale = 0.0;
  for (var columns = 1; columns <= count; columns++) {
    final rows = (count / columns).ceil();
    final scale = min(size.width / columns / 16, size.height / rows / 9);
    if (scale > bestScale) {
      best = columns;
      bestScale = scale;
    }
  }
  return best;
}

/// "just now", "5 min ago", "3 h ago", "2 d ago".
String describeAge(Duration age) {
  if (age.inMinutes < 1) return 'just now';
  if (age.inHours < 1) return '${age.inMinutes} min ago';
  if (age.inDays < 1) return '${age.inHours} h ago';
  return '${age.inDays} d ago';
}

/// A grid cell: its picture, with a label at the bottom left.
class _Cell extends StatelessWidget {
  const _Cell({
    required this.label,
    required this.child,
    this.onTap,
    this.refreshing = false,
    this.refreshingKey,
    this.onDelete,
    this.deleteTooltip,
    this.deleteKey,
    this.presence,
  });

  /// Deletes the device shown: a small button, top left.
  final VoidCallback? onDelete;
  final String? deleteTooltip;
  final Key? deleteKey;

  /// The device's presence dot, before the label.
  final Widget? presence;

  /// Null: no label (the camera alone, full screen).
  final String? label;
  final Widget child;
  final VoidCallback? onTap;

  /// A fresh grab was asked for and hasn't come: a small spinner, top
  /// right.
  final bool refreshing;
  final Key? refreshingKey;

  /// The smallest cell that shows the delete button: room for it (top
  /// left) beside the spinner (top right) and above the label. A smaller
  /// cell leaves it out; the account sheet's device list still deletes.
  static const Size deleteRoom = Size(96, 84);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => _build(
      context,
      roomy:
          constraints.maxWidth >= deleteRoom.width &&
          constraints.maxHeight >= deleteRoom.height,
    ),
  );

  Widget _build(BuildContext context, {required bool roomy}) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          child,
          if (onTap != null)
            Material(
              type: MaterialType.transparency,
              child: InkWell(onTap: onTap),
            ),
          if (onDelete case final onDelete? when roomy)
            Positioned(
              top: 2,
              left: 2,
              child: IconButton(
                key: deleteKey,
                tooltip: deleteTooltip,
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                style: IconButton.styleFrom(
                  backgroundColor: scheme.surfaceContainerHigh.withValues(
                    alpha: 0.85,
                  ),
                ),
                icon: const Icon(Icons.delete_outline),
                onPressed: onDelete,
              ),
            ),
          if (refreshing)
            Positioned(
              top: 6,
              right: 6,
              child: Tooltip(
                key: refreshingKey,
                message: 'Asked for a fresh grab',
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh.withValues(alpha: 0.85),
                    shape: BoxShape.circle,
                  ),
                  child: const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            ),
          if (label case final label?)
            Positioned(
              left: 6,
              right: 6,
              bottom: 6,
              child: Align(
                alignment: Alignment.bottomLeft,
                // The label lets taps through to the cell; the presence
                // dot takes them, for its tooltip.
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 4,
                    children: [
                      ?presence,
                      Flexible(
                        child: IgnorePointer(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Another device's latest image, whole, or an icon when it has none.
class _DeviceImage extends StatelessWidget {
  const _DeviceImage({required this.latest});

  final DeviceLatest latest;

  @override
  Widget build(BuildContext context) {
    final image = latest.image;
    if (image == null) {
      return Icon(
        Icons.videocam_off_outlined,
        size: 32,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      );
    }
    return Image.memory(
      image,
      key: Key('device-image-${latest.deviceId}'),
      fit: BoxFit.contain,
      gaplessPlayback: true,
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

/// A sentence for the user about why the camera didn't open. Backends
/// throw [CameraUnavailable] with one; native plugin errors carry their own
/// message. Anything else (a bug, an unexpected browser error) gets a
/// generic sentence, and the details go to the log instead of the screen.
String describeCameraError(Object error) {
  switch (error) {
    case CameraUnavailable(:final message):
      return message;
    case PlatformException(:final message?) when message.trim().isNotEmpty:
      return message;
  }
  debugPrint('Presence: could not open the camera: $error');
  return 'Something went wrong while starting the camera.';
}
