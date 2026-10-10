import '../events.dart';

/// The rate limits and the seen requests behind Capture all: when this
/// device asks the others for a grab ([CameraRig.askAll]), and when it
/// answers their requests ([CameraRig.answerCaptureAll]). Pure decisions
/// of time; the rig publishes and takes the clips.
class CaptureAll {
  /// How old a Capture all request from another device may be and still be
  /// answered: one fetched later (a device that was off or offline) is
  /// past, and its clip wouldn't show the moment it asked for. One dated
  /// further than this ahead (a clock far off) isn't answered either.
  static const Duration captureAllWithin = Duration(minutes: 5);

  /// The least time between two Capture all requests from this device
  /// when the All grid opens ([CameraRig.askAll]): opening it again within
  /// it asks nothing more of the other devices.
  static const Duration askAllEvery = Duration(minutes: 1);

  /// The least time between a Capture all request and one from pressing
  /// Clip in the All grid ([CameraRig.askAll] `pressed`): a press always
  /// asks, unless a request went out this recently (a double tap, or the
  /// grid just opened).
  static const Duration pressAllEvery = Duration(seconds: 5);

  /// The least time between two Capture all clips on this device
  /// ([CameraRig.answerCaptureAll]): requests from several devices at once
  /// make one clip (one arriving both over live sync and from the bucket is
  /// answered once anyway). Short, so a press of Clip in another device's
  /// All grid soon after it opened still gets a new clip.
  static const Duration answerAllEvery = Duration(seconds: 10);

  /// When this device last asked the others for a grab ([ask]).
  DateTime? _askedAll;

  /// When this device last took a Capture all clip (asked or answered).
  DateTime? _lastAllClip;

  /// The Capture all requests already seen ([shouldAnswer]), by event ID,
  /// so one is never answered twice; the latest [_maxSeenRequests].
  final _seenRequests = <String>{};
  static const int _maxSeenRequests = 200;

  /// Whether to ask the others for a grab at [now], and if so notes it:
  /// not when this device asked within [askAllEvery] (opening the grid),
  /// or within [pressAllEvery] when [pressed] (the Clip button).
  bool ask(DateTime now, {bool pressed = false}) {
    final last = _askedAll;
    if (last != null &&
        !now.isBefore(last) &&
        now.difference(last) < (pressed ? pressAllEvery : askAllEvery)) {
      return false;
    }
    _askedAll = now;
    return true;
  }

  /// Notes a Capture all clip (trigger `all`) taken at [at].
  void tookClip(DateTime at) => _lastAllClip = at;

  /// Whether the Capture all requests ([AppEvent.captureAll]) among
  /// [events] call for a clip at [now]: any from another device than
  /// [deviceId], within [captureAllWithin] of now, and not seen before
  /// (each such request is noted as seen); and not within [answerAllEvery]
  /// of this device's last Capture all clip, which is fresh enough.
  bool shouldAnswer(
    Iterable<AppEvent> events, {
    required String deviceId,
    required DateTime now,
  }) {
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
    if (!asked) return false;
    final last = _lastAllClip;
    return last == null ||
        now.isBefore(last) ||
        now.difference(last) >= answerAllEvery;
  }
}
