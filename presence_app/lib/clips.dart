import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'annotations.dart';
import 'cameras/cameras.dart';
import 'event_flags.dart';
import 'events.dart';
import 'recognition/recognizer.dart';
import 'subjects.dart';

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

/// Published when a clip starts: from the Clip button, or automatically on
/// motion. Both behave the same; only the title differs.
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

class ClipEventCard extends StatelessWidget {
  const ClipEventCard({super.key, required this.event});

  final ClipRequested event;

  /// From this width on, the thumbnail sits beside the details instead of
  /// above them, so a wide timeline doesn't blow it up.
  static const double sideBySideWidth = 600;

  /// The thumbnail's width beside the details.
  static const double sideThumbnailWidth = 320;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final clip = event.clip;
    return ListenableBuilder(
      listenable: clip,
      builder: (context, _) {
        // A label opens the player paused where it was seen.
        final openAt = clip.playable
            ? (Duration? at) => showClipPlayer(context, event, at: at)
            : null;
        final thumbnail = AspectRatio(
          key: const Key('clip-card-thumbnail'),
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _Thumbnail(bytes: clip.thumbnail),
              if (clip.playable)
                Center(
                  child: Icon(
                    Icons.play_circle_fill,
                    key: const Key('clip-play'),
                    size: 48,
                    color: scheme.primary,
                  ),
                ),
            ],
          ),
        );
        final details = Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(event.icon, size: 20, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(event.title, style: theme.textTheme.titleSmall),
                  ),
                  Text(
                    formatEventTime(event.time),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                clip.cameraLabel,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              Text(
                clip.status,
                key: const Key('clip-status'),
                style: theme.textTheme.bodySmall,
              ),
              EventSubjects(event: event, onOpenAt: openAt),
              ClipObjectTags(annotations: event.annotations, onOpenAt: openAt),
              EventFlags(
                annotations: event.annotations,
                onIdentify: clip.playable
                    ? (at) =>
                          showClipPlayer(context, event, at: at, identify: true)
                    : null,
              ),
            ],
          ),
        );
        return Card.filled(
          margin: EdgeInsets.zero,
          color: scheme.surfaceContainerHighest,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: clip.playable ? () => showClipPlayer(context, event) : null,
            child: LayoutBuilder(
              builder: (context, box) => box.maxWidth >= sideBySideWidth
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: sideThumbnailWidth, child: thumbnail),
                        Expanded(child: details),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [thumbnail, details],
                    ),
            ),
          ),
        );
      },
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.bytes});

  final Uint8List? bytes;

  @override
  Widget build(BuildContext context) {
    final image = bytes;
    final scheme = Theme.of(context).colorScheme;
    if (image == null) {
      return ColoredBox(
        color: scheme.surfaceContainerLowest,
        child: Icon(Icons.videocam, size: 40, color: scheme.onSurfaceVariant),
      );
    }
    return Image.memory(
      image,
      key: const Key('clip-thumbnail'),
      fit: BoxFit.cover,
      gaplessPlayback: true,
    );
  }
}

/// Opens [event]'s clip in the player: playing from the start, or paused
/// [at] a point of the recording (a tag's frame). [identify]: opened from
/// the card's unidentified flag, to name who's there.
Future<void> showClipPlayer(
  BuildContext context,
  ClipRequested event, {
  Duration? at,
  bool identify = false,
}) {
  // Opened from a timeline's card: its tags and subjects filter that
  // timeline's search too.
  final search = EventSearchScope.peek(context);
  final player = ClipPlayerDialog(
    event: event,
    startAt: at,
    identify: identify,
  );
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: search == null
            ? player
            : EventSearchScope(search: search, child: player),
      ),
    ),
  );
}

/// The clip player (the event's details), with two sections under it:
/// **Subjects**, the people and pets named in it, and **Tags**, the things
/// recognition saw on it (`bottle`, `bicycle`…). "Name subject" pauses the
/// clip and grabs the frame it shows; clicking the frame names a person or
/// pet at that spot (as many as needed). Each subject's tag keeps its
/// frame, the clicked position and the name, stored with the event.
///
/// Opened from a card in the timeline ([EventSearchScope]), a tapped
/// subject or tag filters the events by it ([EventSearchScope.toggle]) and
/// closes the player, back to the filtered list; the one searched for shows
/// selected. A subject is then renamed with a long press (or a right
/// click). Opened elsewhere, a tapped subject is renamed.
class ClipPlayerDialog extends StatefulWidget {
  const ClipPlayerDialog({
    super.key,
    required this.event,
    this.startAt,
    this.identify = false,
  });

  final ClipRequested event;

  /// Opened to identify an unidentified person or pet: says so, while
  /// they're still unidentified.
  final bool identify;

  /// Opens paused here (a point of the recording), not playing.
  final Duration? startAt;

  @override
  State<ClipPlayerDialog> createState() => _ClipPlayerDialogState();
}

class _ClipPlayerDialogState extends State<ClipPlayerDialog> {
  final _player = ClipPlayerController();

  /// The frame being tagged, if any.
  TagFrame? _frame;
  bool _grabbing = false;

  /// Whether Auto is searching the clip, and what it last found.
  bool _recognizing = false;
  String? _autoResult;

  ClipRequested get _event => widget.event;
  ClipAnnotations get _annotations => _event.annotations;

  @override
  void initState() {
    super.initState();
    _player.onPictureTap = _tagOnVideo;
  }

  /// Pauses, grabs the shown frame and puts it over the player for tagging.
  Future<TagFrame?> _grabFrame() async {
    if (_grabbing) return null;
    setState(() => _grabbing = true);
    final captured = await _player.captureFrame();
    if (!mounted) return null;
    setState(() {
      _grabbing = false;
      if (captured != null) {
        _frame = _annotations.newFrame(
          captured.jpeg,
          captured.position.inMilliseconds,
        );
      }
    });
    if (captured == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text("Couldn't grab this frame; try again")),
      );
    }
    return _frame;
  }

  /// A click on the playing video: that frame goes over the player, and the
  /// name asked is tagged where the click was.
  Future<void> _tagOnVideo(Offset fraction) async {
    if (_frame != null) return;
    final frame = await _grabFrame();
    if (frame == null || !mounted) return;
    await _tag(frame, fraction);
    // Nothing named: back to the video.
    if (mounted && _frame == frame && _annotations.on(frame.id).isEmpty) {
      setState(() => _frame = null);
    }
  }

  Future<void> _tag(TagFrame frame, Offset fraction) async {
    final name = await _askName(context, title: 'Who is this?');
    if (name == null || !mounted) return;
    _annotations.add(name, fraction.dx, fraction.dy, frame: frame);
  }

  /// Auto: looks for the known subjects on the clip, on this device, and
  /// tags the ones recognized surely (see `recognition/recognizer.dart`).
  Future<void> _autoTag(SubjectRecognizer recognizer) async {
    setState(() {
      _recognizing = true;
      _autoResult = null;
    });
    String message;
    try {
      message = autoTagMessage(await recognizer.recognizeNow(_event));
    } catch (e) {
      debugPrint('Presence: Auto failed on ${_event.id}: $e');
      message = "Couldn't run recognition; try again.";
    }
    if (!mounted) return;
    setState(() {
      _recognizing = false;
      _autoResult = message;
    });
  }

  Future<void> _rename(Annotation annotation) async {
    final name = await _askName(
      context,
      title: 'Rename subject',
      initial: annotation.name,
    );
    if (name != null) _annotations.rename(annotation.id, name);
  }

  /// A tapped subject, opened from the timeline: filters the events by
  /// [name] (or clears the filter) and closes the player, back to the list.
  void _filter(ValueNotifier<String> search, String name) {
    EventSearchScope.toggle(search, name);
    Navigator.of(context).pop();
  }

  /// [chip], a subject's, with renaming on a long press (or a right click)
  /// while a tap filters the events ([search] set); as is otherwise.
  Widget _subjectChip(
    ValueNotifier<String>? search,
    Annotation a,
    Widget chip,
  ) {
    if (search == null) return chip;
    final active = EventSearchScope.isActive(search.value, a.name);
    return Tooltip(
      // Shown on hover; a long press renames.
      triggerMode: TooltipTriggerMode.manual,
      message: active
          ? 'Show every event (hold to rename)'
          : 'Show only events with ${a.name} (hold to rename)',
      child: GestureDetector(
        key: Key('annotation-rename-${a.id}'),
        onLongPress: () => _rename(a),
        onSecondaryTap: () => _rename(a),
        child: chip,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final recognizer = SubjectRecognizerScope.maybeOf(context);
    final search = EventSearchScope.maybeOf(context);
    return SingleChildScrollView(
      child: ListenableBuilder(
        listenable: _annotations,
        builder: (context, _) {
          final frame = _frame;
          final frames = _annotations.tagFrames.values.toList()
            ..sort((a, b) => a.ms.compareTo(b.ms));
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                title: Text(
                  '${_event.clip.cameraLabel} · '
                  '${formatEventTime(_event.time)}',
                ),
                trailing: IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Hidden, not disposed, while a frame is tagged in its
                    // place: on the web a hidden `<video>` leaves the page,
                    // so it can't take the clicks meant for the frame.
                    Visibility(
                      visible: frame == null,
                      maintainState: true,
                      child: ClipPlayerView(
                        clip: _event.clip,
                        controller: _player,
                        startAt: widget.startAt,
                      ),
                    ),
                    if (frame != null)
                      ColoredBox(
                        color: Colors.black,
                        child: Center(
                          child: _FrameTagger(
                            key: const Key('frame-tagger'),
                            frame: frame,
                            tags: _annotations.on(frame.id),
                            onTap: (fraction) => _tag(frame, fraction),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: ListenableBuilder(
                  listenable: _event.clip,
                  builder: (context, _) => Text(_event.clip.status),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 8,
                  children: [
                    // The buttons go under the title when they don't fit
                    // beside it.
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      runSpacing: 8,
                      children: [
                        _SectionHeading(
                          key: const Key('subjects-heading'),
                          icon: Icons.face,
                          title: 'Subjects',
                        ),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (frame == null && recognizer != null)
                              Tooltip(
                                message: recognizer.supported
                                    ? 'Find the subjects named before, and tag '
                                          'the things seen, on this device'
                                    : 'Not available on this device yet',
                                child: FilledButton.tonalIcon(
                                  key: const Key('auto-tag'),
                                  icon: _recognizing
                                      ? const SizedBox.square(
                                          dimension: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Icon(Icons.auto_awesome),
                                  label: const Text('Auto'),
                                  onPressed:
                                      _recognizing || !recognizer.supported
                                      ? null
                                      : () => _autoTag(recognizer),
                                ),
                              ),
                            if (frame == null)
                              FilledButton.tonalIcon(
                                key: const Key('tag-frame'),
                                icon: _grabbing
                                    ? const SizedBox.square(
                                        dimension: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.crop_free),
                                label: const Text('Name subject'),
                                onPressed: _grabbing ? null : _grabFrame,
                              )
                            else
                              FilledButton(
                                key: const Key('done-tagging'),
                                onPressed: () => setState(() => _frame = null),
                                child: const Text('Done'),
                              ),
                          ],
                        ),
                      ],
                    ),
                    if (frame != null)
                      Text(
                        'Click each person or pet on the video to name '
                        'them as a subject (frame at '
                        '${formatClipTime(frame.ms)}).',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    if (_recognizing)
                      Text(
                        _event.clip.fullDone
                            ? 'Looking for the subjects named before…'
                            : 'Waiting for the clip to finish recording…',
                        key: const Key('auto-tag-status'),
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      )
                    else if (_autoResult case final result?)
                      Text(
                        result,
                        key: const Key('auto-tag-result'),
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    if (widget.identify && frame == null)
                      if (unidentifiedOf(_annotations) case final u?)
                        Row(
                          key: const Key('identify-hint'),
                          crossAxisAlignment: CrossAxisAlignment.start,
                          spacing: 6,
                          children: [
                            Icon(
                              Icons.flag,
                              size: 18,
                              color: EventFlag.unidentified.color,
                            ),
                            Expanded(
                              child: Text(
                                '${u.label}: click them on the video to '
                                'name them, or try Auto.',
                              ),
                            ),
                          ],
                        ),
                    if (_annotations.tags.isEmpty && frame == null)
                      Text(
                        'No subjects yet. Click a person or pet on the '
                        'video to name them.',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    for (final f in frames)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 12,
                        children: [
                          Tooltip(
                            message: 'Name more subjects on this frame',
                            child: InkWell(
                              key: Key('frame-${f.id}'),
                              onTap: () => setState(() => _frame = f),
                              child: Column(
                                spacing: 2,
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: Image.memory(
                                      f.jpeg,
                                      width: 96,
                                      height: 54,
                                      fit: BoxFit.cover,
                                      gaplessPlayback: true,
                                    ),
                                  ),
                                  Text(
                                    formatClipTime(f.ms),
                                    style: textTheme.labelSmall,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Expanded(
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final a in _annotations.on(f.id))
                                  _subjectChip(
                                    search,
                                    a,
                                    InputChip(
                                      key: Key('annotation-${a.id}'),
                                      // Recognized ones show how sure.
                                      avatar: Icon(
                                        a.source == TagSource.detected
                                            ? Icons.auto_awesome
                                            : Icons.place,
                                        size: 18,
                                      ),
                                      label: Text(
                                        a.source == TagSource.detected &&
                                                a.confidence != null
                                            ? '${a.name} · '
                                                  '${(a.confidence! * 100).round()} %'
                                            : a.name,
                                      ),
                                      tooltip: search == null
                                          ? 'Rename subject'
                                          : null,
                                      selected:
                                          search != null &&
                                          EventSearchScope.isActive(
                                            search.value,
                                            a.name,
                                          ),
                                      showCheckmark: false,
                                      onPressed: search == null
                                          ? () => _rename(a)
                                          : () => _filter(search, a.name),
                                      deleteButtonTooltipMessage:
                                          'Remove subject',
                                      onDeleted: () {
                                        _annotations.remove(a.id);
                                        if (_frame?.id == f.id &&
                                            _annotations.on(f.id).isEmpty) {
                                          setState(() => _frame = null);
                                        }
                                      },
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    // Tags: the things seen, apart from the subjects.
                    const Divider(height: 16),
                    _SectionHeading(
                      key: const Key('tags-heading'),
                      icon: Icons.sell_outlined,
                      title: 'Tags',
                    ),
                    if (_annotations.objects?.isNotEmpty ?? false)
                      ClipObjectTags(
                        annotations: _annotations,
                        keyPrefix: 'player-object',
                        onFiltered: () => Navigator.of(context).pop(),
                      )
                    else
                      Text(
                        _annotations.objects == null
                            ? 'No tags yet. Things seen on the clip, like '
                                  'bottle or bicycle, show here once it has '
                                  'been searched'
                                  '${(recognizer?.supported ?? false) ? ' (try Auto)' : ''}.'
                            : 'No tags: nothing was seen on this clip.',
                        key: const Key('tags-empty'),
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A section's heading under the player: an icon and a title, so Subjects
/// and Tags read apart.
class _SectionHeading extends StatelessWidget {
  const _SectionHeading({super.key, required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          Text(title, style: theme.textTheme.titleSmall),
        ],
      ),
    );
  }
}

/// What Auto says it did, from [result].
String autoTagMessage(RecognitionResult result) {
  String names(List<String> n) => n.length == 1
      ? n.single
      : '${n.sublist(0, n.length - 1).join(', ')} and ${n.last}';
  final subjects = switch (result) {
    RecognitionResult(outcome: RecognitionOutcome.unsupported) =>
      'Recognition is not available on this device yet.',
    RecognitionResult(outcome: RecognitionOutcome.noReferences) =>
      'No subjects to look for yet: name someone on another clip first.',
    RecognitionResult(outcome: RecognitionOutcome.allTagged) =>
      'Every subject named before is already on this clip.',
    RecognitionResult(outcome: RecognitionOutcome.deferred) =>
      'The phone is low on memory: try again in a moment.',
    RecognitionResult(tagged: [], asked: []) => 'No subjects recognized.',
    RecognitionResult(:final tagged, :final asked) => [
      if (tagged.isNotEmpty) 'Found ${names(tagged)}.',
      if (asked.isNotEmpty)
        'Not sure about ${names(asked)}: answer '
            '${asked.length == 1 ? '"Is this ${asked.single}?"' : 'the questions'}'
            ' in the events.',
    ].join(' '),
  };
  if (result.objects.isEmpty) return subjects;
  return '$subjects Tags: ${result.objects.join(', ')}.';
}

/// A clip's **Tags**: the things recognition saw on it (`human`, `cat`,
/// `bicycle`, `bottle`…), as small outlined chips, by first sighting;
/// nothing until it's been searched, or if nothing was seen. In a timeline
/// ([EventSearchScope]) a click on one filters the events by it (again,
/// clears the filter) and it shows highlighted while it's the search, a
/// long press calling [onOpenAt]; elsewhere a click calls [onOpenAt] with
/// where it was first seen. Its x removes it from the clip.
class ClipObjectTags extends StatelessWidget {
  const ClipObjectTags({
    super.key,
    required this.annotations,
    this.onOpenAt,
    this.onFiltered,
    this.keyPrefix = 'clip-object',
  });

  final ClipAnnotations annotations;
  final void Function(Duration? at)? onOpenAt;

  /// Called once a click filtered the events (the player closes).
  final VoidCallback? onFiltered;

  /// Starts the chips' keys, so the player's and the card's differ.
  final String keyPrefix;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: annotations,
    builder: (context, _) {
      final objects = annotations.objects ?? const [];
      if (objects.isEmpty) return const SizedBox.shrink();
      final theme = Theme.of(context);
      final scheme = theme.colorScheme;
      final search = EventSearchScope.maybeOf(context);
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Wrap(
          key: Key('${keyPrefix}s'),
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final o in objects)
              if (search != null &&
                      EventSearchScope.isActive(search.value, o.label)
                      // Whether it's the search: highlighted.
                      case final active)
                Semantics(
                  key: Key('$keyPrefix-chip-${o.label}'),
                  selected: search == null ? null : active,
                  child: Container(
                    decoration: BoxDecoration(
                      color: active ? scheme.primaryContainer : null,
                      border: Border.all(
                        color: active ? scheme.primary : scheme.outlineVariant,
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        OpenAtLabel(
                          key: Key('$keyPrefix-${o.label}'),
                          ms: o.ms,
                          onOpenAt: onOpenAt,
                          filter: o.label,
                          onFiltered: onFiltered,
                          borderRadius: const BorderRadius.horizontal(
                            left: Radius.circular(12),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(8, 2, 2, 2),
                            child: Text(
                              o.label,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: active
                                    ? scheme.onPrimaryContainer
                                    : scheme.onSurfaceVariant,
                                fontWeight: active ? FontWeight.bold : null,
                              ),
                            ),
                          ),
                        ),
                        RemoveLabelButton(
                          key: Key('$keyPrefix-remove-${o.label}'),
                          label: o.label,
                          kind: 'tag',
                          onRemove: () => annotations.removeObject(o.label),
                        ),
                      ],
                    ),
                  ),
                ),
          ],
        ),
      );
    },
  );
}

/// A label on a clip's card that, clicked, opens the player paused [ms] into
/// the recording (or, without [ms], playing from the start); just the label
/// when the clip can't be played ([onOpenAt] null).
///
/// With a [filter] (the tag or subject it shows) and in a timeline
/// ([EventSearchScope]), a click filters the events by it instead (again,
/// clears the filter), then calls [onFiltered]; a long press opens the
/// player.
class OpenAtLabel extends StatelessWidget {
  const OpenAtLabel({
    super.key,
    required this.ms,
    required this.onOpenAt,
    required this.child,
    this.filter,
    this.onFiltered,
    this.borderRadius,
  });

  final int? ms;
  final void Function(Duration? at)? onOpenAt;
  final Widget child;
  final BorderRadius? borderRadius;

  /// What a click searches the events for, in a timeline.
  final String? filter;
  final VoidCallback? onFiltered;

  @override
  Widget build(BuildContext context) {
    final open = onOpenAt;
    final at = ms == null ? null : Duration(milliseconds: ms!);
    final search = filter == null ? null : EventSearchScope.maybeOf(context);
    if (search != null) {
      final label = filter!;
      final active = EventSearchScope.isActive(search.value, label);
      return Tooltip(
        // Shown on hover; a long press opens the player.
        triggerMode: TooltipTriggerMode.manual,
        message: active ? 'Show every event' : 'Show only events with $label',
        child: InkWell(
          borderRadius: borderRadius,
          onTap: () {
            EventSearchScope.toggle(search, label);
            onFiltered?.call();
          },
          onLongPress: open == null ? null : () => open(at),
          child: child,
        ),
      );
    }
    if (open == null) return child;
    return Tooltip(
      message: at == null
          ? 'Play the clip'
          : 'Show at ${formatClipTime(at.inMilliseconds)}',
      child: InkWell(
        borderRadius: borderRadius,
        onTap: () => open(at),
        child: child,
      ),
    );
  }
}

/// The small x beside a label on a clip's card: removes the [kind]
/// (`subject` or `tag`) [label] from the clip ([onRemove]).
class RemoveLabelButton extends StatelessWidget {
  const RemoveLabelButton({
    super.key,
    required this.label,
    required this.kind,
    required this.onRemove,
  });

  final String label;
  final String kind;
  final VoidCallback onRemove;

  String get _message => 'Remove $kind $label from this event';

  @override
  Widget build(BuildContext context) => Tooltip(
    message: _message,
    child: Semantics(
      button: true,
      label: _message,
      excludeSemantics: true,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onRemove,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            Icons.close,
            size: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ),
  );
}

/// A grabbed frame, with markers for its tags; a click anywhere on it
/// reports where, as fractions (0 to 1) of the frame's width and height.
class _FrameTagger extends StatelessWidget {
  const _FrameTagger({
    super.key,
    required this.frame,
    required this.tags,
    required this.onTap,
  });

  final TagFrame frame;
  final List<Annotation> tags;
  final void Function(Offset fraction) onTap;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Size>(
      // The frame's own proportions, so clicks map onto the image exactly.
      future: _frameSize(frame.jpeg),
      builder: (context, size) {
        final ratio = size.data == null
            ? 16 / 9
            : size.data!.width / size.data!.height;
        return AspectRatio(
          aspectRatio: ratio,
          child: LayoutBuilder(
            builder: (context, box) => Semantics(
              label:
                  'Frame to name subjects on: click a person or pet to '
                  'name them',
              child: GestureDetector(
                key: const Key('tag-surface'),
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) => onTap(
                  Offset(
                    d.localPosition.dx / box.maxWidth,
                    d.localPosition.dy / box.maxHeight,
                  ),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(
                      frame.jpeg,
                      fit: BoxFit.fill,
                      gaplessPlayback: true,
                    ),
                    for (final a in tags)
                      _Marker(
                        key: Key('marker-${a.id}'),
                        annotation: a,
                        box: box.biggest,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static final _sizes = Expando<Future<Size>>();

  static Future<Size> _frameSize(Uint8List jpeg) => _sizes[jpeg] ??= () async {
    final codec = await ui.instantiateImageCodec(jpeg);
    final image = (await codec.getNextFrame()).image;
    final size = Size(image.width.toDouble(), image.height.toDouble());
    image.dispose();
    codec.dispose();
    return size;
  }();
}

/// "0:07.4": a time in the recording.
String formatClipTime(int ms) {
  final d = Duration(milliseconds: ms);
  final seconds = (d.inMilliseconds % 60000) / 1000;
  return '${d.inMinutes}:${seconds.toStringAsFixed(1).padLeft(4, '0')}';
}

/// A named dot at an annotation's spot.
class _Marker extends StatelessWidget {
  const _Marker({super.key, required this.annotation, required this.box});

  final Annotation annotation;
  final Size box;

  static const double _dot = 12;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: annotation.x * box.width - _dot / 2,
      top: annotation.y * box.height - _dot / 2,
      child: IgnorePointer(
        child: Row(
          spacing: 4,
          children: [
            Container(
              width: _dot,
              height: _dot,
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Text(
                  annotation.name,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Asks for a name; null when cancelled or left blank.
Future<String?> _askName(
  BuildContext context, {
  required String title,
  String initial = '',
}) async {
  final name = await showDialog<String>(
    context: context,
    builder: (context) => _NameDialog(title: title, initial: initial),
  );
  final trimmed = name?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

/// The name prompt. Owns its text controller, so the controller outlives
/// the dialog's closing animation.
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: const Key('annotation-name'),
      controller: _controller,
      autofocus: true,
      textCapitalization: TextCapitalization.words,
      decoration: const InputDecoration(hintText: 'Name'),
      onSubmitted: (value) => Navigator.of(context).pop(value),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('save-name'),
        onPressed: () => Navigator.of(context).pop(_controller.text),
        child: const Text('Save'),
      ),
    ],
  );
}
