import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../cameras/cameras.dart';
import '../clips.dart';
import '../config.dart';
import '../events.dart';
import '../motion.dart';
import 'auto_clip_policy.dart';
import 'capture_all.dart';

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
  final _motionTrigger = MotionTrigger();
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
  DateTime? get nextScheduledClip => AutoClipPolicy.nextScheduledClip(
    config.schedule,
    lastScheduled: _lastScheduledClip,
    scheduleFrom: _scheduleFrom,
  );

  /// Whether the startup clip is still to come (scheduled clips on).
  bool get startupClipPending => config.schedule.enabled && !_startupClipTaken;

  /// Time left until the next scheduled clip, for the Settings countdown:
  /// to the end of the cooldown if it's due before then, zero once it's
  /// due (it waits for an open camera), null when they're off.
  Duration? get untilScheduledClip {
    final due = nextScheduledClip;
    if (due == null) return null;
    return AutoClipPolicy.untilScheduledClip(
      due: due,
      cooldownEnds: cooldownEnds,
      now: _now(),
    );
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
    final trigger = AutoClipPolicy.scheduledClip(
      due: due,
      openedAt: opened,
      now: now,
      startupTaken: _startupClipTaken,
      before: config.clip.before,
    );
    if (trigger == null) return false;
    _startupClipTaken = true;
    _lastScheduledClip = now;
    _scheduledClipStarting = true;
    requestClips(target, trigger: trigger)
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
    // The latest clip's "after" part is still being saved.
    final recording = !(_latestClip?.fullDone ?? true);
    // After any clip: the cooldown, when automatic clips may come again.
    final ends = cooldownEnds;
    if (ends != null) {
      return ClipReadiness(
        ClipReadinessState.cooldown,
        remaining: ends.difference(now),
        recording: recording,
      );
    }
    return ClipReadiness(ClipReadinessState.ready, recording: recording);
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
  /// both off: there's no automatic clip to wait for. The automatic
  /// triggers wait for it; the Clip button counts it down but is never
  /// held back by it.
  DateTime? get cooldownEnds {
    final last = _lastClip;
    if (last == null ||
        !AutoClipPolicy.automaticClips(config.motion, config.schedule)) {
      return null;
    }
    final now = _now();
    // The clock was set back past the latest clip: it counts as now, so
    // the cooldown never runs longer than its length.
    final clamped = _lastClip = AutoClipPolicy.clampToNow(last, now);
    return AutoClipPolicy.cooldownEnds(
      lastClip: clamped,
      now: now,
      cooldown: config.motion.cooldown,
    );
  }

  /// The latest motion score of the open camera (0–100 % of the picture
  /// changing), or null when there's no score (warming up, no camera).
  final ValueNotifier<double?> motionLevel = ValueNotifier(null);

  /// Motion frames in a row over the threshold that take a motion clip
  /// ([MotionTrigger.framesToTrigger]).
  static const int motionFramesToTrigger = MotionTrigger.framesToTrigger;

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
    _motionTrigger.reset();
    motionLevel.value = null;
    _motionFrames = source.motionFrames?.listen(_onMotionFrame);
  }

  void _onMotionFrame(Uint8List luma) {
    final score = _motion.add(luma);
    motionLevel.value = score;
    if (!_motionTrigger.add(score, config.motion)) return;

    // No automatic clip during the cooldown after any clip: only once its
    // countdown has reached zero.
    if (cooldownEnds != null) return;
    final target = bus;
    if (target == null || !canClip || _motionClipStarting) return;

    _motionTrigger.reset();
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
    if (trigger == ClipTrigger.all) _captureAll.tookClip(requestedAt);
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

  /// Capture all's rate limits and seen requests.
  final _captureAll = CaptureAll();

  /// See [CaptureAll.captureAllWithin].
  static const Duration captureAllWithin = CaptureAll.captureAllWithin;

  /// See [CaptureAll.askAllEvery].
  static const Duration askAllEvery = CaptureAll.askAllEvery;

  /// See [CaptureAll.pressAllEvery].
  static const Duration pressAllEvery = CaptureAll.pressAllEvery;

  /// See [CaptureAll.answerAllEvery].
  static const Duration answerAllEvery = CaptureAll.answerAllEvery;

  /// Publishes a Capture all request ([AppEvent.captureAll]), which cloud
  /// sync (and live sync, within a second, when connected) takes to the
  /// profile's other devices so each takes a fresh grab
  /// ([answerCaptureAll]); unless this device asked within [askAllEvery]
  /// (opening the grid), or within [pressAllEvery] when [pressed] (the Clip
  /// button). Returns the request, or null when it wasn't sent.
  AppEvent? askAll(AppEventBus bus, {bool pressed = false}) {
    final now = _now();
    if (!_captureAll.ask(now, pressed: pressed)) return null;
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
  /// which is fresh enough ([CaptureAll.shouldAnswer]). Its event uploads
  /// with the next pass, so the asking device's All grid gets this
  /// camera's picture.
  void answerCaptureAll(
    Iterable<AppEvent> events, {
    required String? deviceId,
  }) {
    final target = bus;
    if (target == null || deviceId == null) return;
    if (!_captureAll.shouldAnswer(events, deviceId: deviceId, now: _now())) {
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
