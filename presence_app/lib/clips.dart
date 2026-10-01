import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'annotations.dart';
import 'cameras/cameras.dart';
import 'events.dart';
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
       interrupted = supported && full == null && error == null;

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
  }) : annotations = annotations ?? ClipAnnotations(),
       super(
         icon: switch (trigger) {
           ClipTrigger.motion => Icons.directions_run,
           ClipTrigger.scheduled => Icons.schedule,
           ClipTrigger.startup => Icons.power_settings_new,
           ClipTrigger.manual => Icons.videocam,
         },
         title: switch (trigger) {
           ClipTrigger.motion => 'Motion detected',
           ClipTrigger.scheduled => 'Scheduled clip',
           ClipTrigger.startup => 'Startup clip',
           ClipTrigger.manual => 'Clip requested',
         },
         detail: clip.cameraLabel,
         type: clipRequestedType,
         cameraId: clip.cameraId,
       );

  static const String clipRequestedType = 'clip_requested';

  final VideoClip clip;
  final ClipTrigger trigger;

  /// The people and pets named in this clip (edited under the player).
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
  };

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
              EventSubjects(event: event),
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

Future<void> showClipPlayer(BuildContext context, ClipRequested event) {
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: ClipPlayerDialog(event: event),
      ),
    ),
  );
}

/// The clip player, with the people and pets named in it. "Tag this frame"
/// pauses the clip and grabs the frame it shows; clicking the frame names a
/// person or pet at that spot (as many as needed). Each tag keeps its
/// frame, the clicked position and the name, stored with the event.
class ClipPlayerDialog extends StatefulWidget {
  const ClipPlayerDialog({super.key, required this.event});

  final ClipRequested event;

  @override
  State<ClipPlayerDialog> createState() => _ClipPlayerDialogState();
}

class _ClipPlayerDialogState extends State<ClipPlayerDialog> {
  final _player = ClipPlayerController();

  /// The frame being tagged, if any.
  TagFrame? _frame;
  bool _grabbing = false;

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

  Future<void> _rename(Annotation annotation) async {
    final name = await _askName(
      context,
      title: 'Rename',
      initial: annotation.name,
    );
    if (name != null) _annotations.rename(annotation.id, name);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return SingleChildScrollView(
      child: ListenableBuilder(
        listenable: _annotations,
        builder: (context, _) {
          final frame = _frame;
          final frames = _annotations.frames.values.toList()
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
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'People and pets',
                            style: textTheme.titleSmall,
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
                            label: const Text('Tag this frame'),
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
                    if (frame != null)
                      Text(
                        'Click each person or pet on the video to name '
                        'them (frame at ${formatClipTime(frame.ms)}).',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    if (_annotations.isEmpty && frame == null)
                      Text(
                        'Nobody tagged yet. Click someone on the video to '
                        'name them.',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    for (final f in frames)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 12,
                        children: [
                          Tooltip(
                            message: 'Tag more on this frame',
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
                                  InputChip(
                                    key: Key('annotation-${a.id}'),
                                    avatar: const Icon(Icons.place, size: 18),
                                    label: Text(a.name),
                                    tooltip: 'Rename',
                                    onPressed: () => _rename(a),
                                    deleteButtonTooltipMessage: 'Remove',
                                    onDeleted: () {
                                      _annotations.remove(a.id);
                                      if (_frame?.id == f.id &&
                                          _annotations.on(f.id).isEmpty) {
                                        setState(() => _frame = null);
                                      }
                                    },
                                  ),
                              ],
                            ),
                          ),
                        ],
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
              label: 'Frame to tag: click a person or pet to name them',
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
