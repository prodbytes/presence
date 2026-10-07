import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../annotations.dart';
import '../cameras/cameras.dart';
import '../event_flags.dart';
import '../events.dart';
import 'clip_card.dart';

/// A clip around one Clip press, for one camera. Its recordings arrive over
/// time: the "before" part almost at once, the whole clip after the "after"
/// period.
class VideoClip extends ChangeNotifier {
  VideoClip({
    required this.cameraId,
    required this.cameraLabel,
    required this.before,
    required this.after,
    required ClipCapture this.capture,
    this.past,
    this.thumbnail,
    this.supported = true,
    String? id,
  }) : id = id ?? AppEvent.newId(),
       interrupted = false,
       awaitingRemote = false,
       pastDone = past != null {
    // [past] is passed in when it's already recorded, so the clip is
    // playable from the start; otherwise it arrives later.
    if (past == null) {
      capture!.past.then(
        (media) {
          past = media;
          pastDone = true;
          notifyListeners();
        },
        onError: (Object e) {
          pastDone = true;
          error = e;
          notifyListeners();
        },
      );
    }
    capture!.full.then(
      (media) {
        full = media;
        fullDone = true;
        notifyListeners();
      },
      onError: (Object e) {
        fullDone = true;
        error = e;
        notifyListeners();
      },
    );
  }

  /// A clip loaded from storage. If the app closed while it was still
  /// recording, [full] is missing and the clip is marked [interrupted].
  VideoClip.restored({
    required this.id,
    required this.cameraId,
    required this.cameraLabel,
    required this.before,
    required this.after,
    required this.past,
    required this.full,
    this.thumbnail,
    this.supported = true,
    this.error,
  }) : capture = null,
       pastDone = true,
       fullDone = true,
       awaitingRemote = false,
       interrupted = supported && full == null && error == null;

  /// The clip of an event another device of the profile has just saved
  /// (live sync): still recording there, or on its way up to the cloud. Its
  /// record, thumbnail and recording come from the cloud once it's
  /// complete, and the event is shown again with them.
  VideoClip.awaitingRemote({
    required this.id,
    required this.cameraId,
    required this.cameraLabel,
  }) : before = Duration.zero,
       after = Duration.zero,
       capture = null,
       thumbnail = null,
       supported = true,
       pastDone = true,
       fullDone = true,
       interrupted = false,
       awaitingRemote = true;

  final String id;
  final String cameraId;
  final String cameraLabel;
  final Duration before;
  final Duration after;

  /// The recordings still in progress; null for a restored clip.
  final ClipCapture? capture;

  /// The camera frame at the moment of the press.
  final Uint8List? thumbnail;

  /// False when the camera can't record video on this platform.
  final bool supported;

  /// Restored without its "after" part: the app closed while recording it.
  final bool interrupted;

  /// Another device's clip, not here yet ([VideoClip.awaitingRemote]).
  final bool awaitingRemote;

  ClipMedia? past;
  ClipMedia? full;
  bool pastDone;
  bool fullDone = false;
  Object? error;

  /// Set when saving the clip to storage failed (for example, disk full).
  Object? saveError;

  bool get playable => past != null || full != null;

  void markSaveError(Object e) {
    saveError = e;
    notifyListeners();
  }

  String get status {
    final saved = saveError == null ? '' : ' · not saved: $saveError';
    return _recordingStatus + saved;
  }

  String get _recordingStatus {
    if (!supported) return "Video clips aren't supported on this platform";
    if (awaitingRemote) return 'Recording on another device…';
    if (full != null) return '${(before + after).inSeconds} s clip ready';
    if (interrupted) {
      return past == null
          ? 'Not recorded: the app closed while recording'
          : 'Previous ${before.inSeconds} s only: the app closed '
                'before the next ${after.inSeconds} s were recorded';
    }
    if (fullDone) {
      return error == null ? 'No video recorded' : 'Recording failed';
    }
    if (past != null) {
      return 'Previous ${before.inSeconds} s ready · '
          'recording next ${after.inSeconds} s…';
    }
    if (pastDone) return 'Recording next ${after.inSeconds} s…';
    return 'Saving previous ${before.inSeconds} s…';
  }
}

/// What started a clip.
enum ClipTrigger {
  /// The Clip button.
  manual,

  /// Enough motion in the picture (automatic).
  motion,

  /// The timer: one every `ScheduleConfig.every` (automatic).
  scheduled,

  /// The app started (automatic, with scheduled clips on).
  startup,

  /// Capture all: the Clip button pressed with the All grid showing, on
  /// this device or another of the profile ([AppEvent.captureAll]).
  all,
}

/// Published when a clip starts: from the Clip button, or automatically
/// (motion, the schedule, the app's start, or Capture all; see
/// [ClipTrigger]). All behave the same; only the title and icon differ.
class ClipRequested extends AppEvent {
  ClipRequested(
    this.clip, {
    this.trigger = ClipTrigger.manual,
    ClipAnnotations? annotations,
    super.time,
    super.id,
    super.deviceId,
    super.userId,
    super.profileId,
  }) : annotations = annotations ?? ClipAnnotations(),
       super(
         icon: switch (trigger) {
           ClipTrigger.motion => Icons.directions_run,
           ClipTrigger.scheduled => Icons.schedule,
           ClipTrigger.startup => Icons.power_settings_new,
           ClipTrigger.manual => Icons.videocam,
           ClipTrigger.all => Icons.grid_view,
         },
         title: switch (trigger) {
           ClipTrigger.motion => 'Motion detected',
           ClipTrigger.scheduled => 'Scheduled clip',
           ClipTrigger.startup => 'Startup clip',
           ClipTrigger.manual => 'Clip requested',
           ClipTrigger.all => 'Capture all',
         },
         detail: clip.cameraLabel,
         type: clipRequestedType,
         cameraId: clip.cameraId,
       );

  static const String clipRequestedType = 'clip_requested';

  final VideoClip clip;
  final ClipTrigger trigger;

  /// The subjects (people and pets) named in this clip, edited under the
  /// player, and its tags: the objects recognition saw on it.
  final ClipAnnotations annotations;

  /// `partial` while only the "before" part exists, `complete` once the
  /// event has been updated with the full clip.
  String get clipState => clip.full != null ? 'complete' : 'partial';

  @override
  Map<String, Object?> toRecord() => {
    ...super.toRecord(),
    'clipId': clip.id,
    'clipState': clipState,
    'trigger': trigger.name,
    if (!annotations.isEmpty) 'annotations': annotations.toJson(),
    // The clicked frames (JPEG bytes, by id). Kept in the local record;
    // cloud sync uploads them as images next to the clip instead.
    if (!annotations.isEmpty) 'frames': annotations.framesToRecord(),
    // What recognition saw (for search); absent until the clip is searched.
    if (annotations.objects case final objects?)
      'objectTags': [for (final o in objects) o.toJson()],
  };

  @override
  List<EventFlag> get flags => flagsOf(annotations);

  @override
  Widget buildCard(BuildContext context) => ClipEventCard(event: this);
}

/// "0:07.4": a time in the recording.
String formatClipTime(int ms) {
  final d = Duration(milliseconds: ms);
  final seconds = (d.inMilliseconds % 60000) / 1000;
  return '${d.inMinutes}:${seconds.toStringAsFixed(1).padLeft(4, '0')}';
}
