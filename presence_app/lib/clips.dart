import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

import 'annotations.dart';
import 'cameras/cameras.dart';
import 'events.dart';

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
  }) : annotations = annotations ?? ClipAnnotations(),
       super(
         icon: trigger == ClipTrigger.motion
             ? Icons.directions_run
             : Icons.videocam,
         title: trigger == ClipTrigger.motion
             ? 'Motion detected'
             : 'Clip requested',
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
  };

  @override
  Widget buildCard(BuildContext context) => ClipEventCard(event: this);
}

class ClipEventCard extends StatelessWidget {
  const ClipEventCard({super.key, required this.event});

  final ClipRequested event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final clip = event.clip;
    return ListenableBuilder(
      listenable: clip,
      builder: (context, _) => Card.filled(
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerHighest,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: clip.playable ? () => showClipPlayer(context, event) : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
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
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(event.icon, size: 20, color: scheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            event.title,
                            style: theme.textTheme.titleSmall,
                          ),
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
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
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

/// The clip player, with the people and pets named in it: markers over the
/// video, and the list of names (add, rename, remove) below it. "Add a name"
/// switches to marking: the next tap on the video places the marker, then
/// asks who it is.
class ClipPlayerDialog extends StatefulWidget {
  const ClipPlayerDialog({super.key, required this.event});

  final ClipRequested event;

  @override
  State<ClipPlayerDialog> createState() => _ClipPlayerDialogState();
}

class _ClipPlayerDialogState extends State<ClipPlayerDialog> {
  bool _marking = false;

  ClipRequested get _event => widget.event;
  ClipAnnotations get _annotations => _event.annotations;

  Future<void> _mark(Offset at, Size size) async {
    setState(() => _marking = false);
    final name = await _askName(context, title: 'Who is this?');
    if (name == null || !mounted) return;
    _annotations.add(name, at.dx / size.width, at.dy / size.height);
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
    return SingleChildScrollView(
      child: Column(
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
            child: LayoutBuilder(
              builder: (context, box) => Stack(
                fit: StackFit.expand,
                children: [
                  ClipPlayerView(clip: _event.clip),
                  // Markers never take taps: the video's controls stay usable.
                  IgnorePointer(
                    child: ListenableBuilder(
                      listenable: _annotations,
                      builder: (context, _) => Stack(
                        children: [
                          for (final a in _annotations.items)
                            _Marker(
                              key: Key('marker-${a.id}'),
                              annotation: a,
                              box: box.biggest,
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (_marking)
                    // Over the web's <video> element, only a pointer
                    // interceptor lets Flutter see the tap.
                    PointerInterceptor(
                      child: GestureDetector(
                        key: const Key('mark-surface'),
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (d) => _mark(d.localPosition, box.biggest),
                        child: ColoredBox(
                          color: Colors.black26,
                          child: Center(
                            child: Chip(
                              avatar: const Icon(Icons.touch_app, size: 18),
                              label: const Text(
                                'Tap where the person or pet is',
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
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
            child: ListenableBuilder(
              listenable: _annotations,
              builder: (context, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'People and pets',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      _marking
                          ? TextButton(
                              key: const Key('cancel-marking'),
                              onPressed: () => setState(() => _marking = false),
                              child: const Text('Cancel'),
                            )
                          : FilledButton.tonalIcon(
                              key: const Key('add-name'),
                              icon: const Icon(Icons.person_add_alt),
                              label: const Text('Add a name'),
                              onPressed: () => setState(() => _marking = true),
                            ),
                    ],
                  ),
                  if (_annotations.isEmpty)
                    Text(
                      'Nobody named yet. Add a name, then tap them on the '
                      'video.',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final a in _annotations.items)
                          InputChip(
                            key: Key('annotation-${a.id}'),
                            avatar: const Icon(Icons.place, size: 18),
                            label: Text(a.name),
                            tooltip: 'Rename',
                            onPressed: () => _rename(a),
                            deleteButtonTooltipMessage: 'Remove',
                            onDeleted: () => _annotations.remove(a.id),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
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
