import 'package:flutter/material.dart';

import '../annotations.dart';
import '../cameras/cameras.dart';
import '../copies_badge.dart';
import '../device_events.dart';
import '../event_details.dart';
import '../event_flags.dart';
import '../events.dart';
import '../recognition/recognizer.dart';
import 'clip_labels.dart';
import 'clip_model.dart';
import 'frame_tagger.dart';

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
  // Its device's name shows the device's events ([ShowDeviceEvents]).
  final scoped = ShowDeviceEvents.capture(
    context,
    search == null ? player : EventSearchScope(search: search, child: player),
  );
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: scoped,
      ),
    ),
  );
}

/// The clip player (the event's details), with sections under it:
/// **Subjects**, the people and pets named in it, **Tags**, the things
/// recognition saw on it (`bottle`, `bicycle`…), and at the end where it
/// was, the device that recorded it and a Delete event button
/// ([EventDetailsFooter]). "Name subject" pauses the
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
    CapturedFrame? captured;
    try {
      captured = await _player.captureFrame();
    } catch (e) {
      // A failed grab is no frame: the button must come back either way.
      debugPrint('Presence: could not grab the frame: $e');
    }
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

  /// Removes subject [a] from frame [f]; the frame being tagged goes back to
  /// the video once nobody is named on it.
  void _removeSubject(TagFrame f, Annotation a) {
    _annotations.remove(a.id);
    if (_frame?.id == f.id && _annotations.on(f.id).isEmpty) {
      setState(() => _frame = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final recognizer = SubjectRecognizerScope.maybeOf(context);
    final search = EventSearchScope.maybeOf(context);
    return SingleChildScrollView(
      child: ListenableBuilder(
        listenable: _annotations,
        builder: (context, _) {
          final frame = _frame;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                title: Text(
                  '${_event.clip.cameraLabel} · '
                  '${formatEventTime(_event.time)}',
                ),
                // Who holds a copy of it.
                subtitle: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: EventCopiesBadge(
                    key: const Key('clip-copies'),
                    event: _event,
                  ),
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
                          child: FrameTagger(
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
                    _SubjectsSection(
                      clip: _event.clip,
                      annotations: _annotations,
                      frame: frame,
                      search: search,
                      recognizer: recognizer,
                      recognizing: _recognizing,
                      autoResult: _autoResult,
                      grabbing: _grabbing,
                      identify: widget.identify,
                      onAuto: () => _autoTag(recognizer!),
                      onGrab: _grabFrame,
                      onDone: () => setState(() => _frame = null),
                      onOpenFrame: (f) => setState(() => _frame = f),
                      onRename: _rename,
                      onFilter: (name) => _filter(search!, name),
                      onRemove: _removeSubject,
                    ),
                    // Tags: the things seen, apart from the subjects.
                    const Divider(height: 16),
                    _TagsSection(
                      annotations: _annotations,
                      recognizer: recognizer,
                      onFiltered: () => Navigator.of(context).pop(),
                    ),
                    // Where it was, the device, and deleting it.
                    const Divider(height: 16),
                    EventDetailsFooter(
                      event: _event,
                      onDeleted: () {
                        if (mounted) Navigator.of(context).pop();
                      },
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

/// The player's **Subjects** section: its heading with the Auto and Name
/// subject buttons (Done while a frame is tagged), what Auto is doing or
/// found, the identify hint, and each tagged frame with its subjects
/// ([_FrameRow]).
class _SubjectsSection extends StatelessWidget {
  const _SubjectsSection({
    required this.clip,
    required this.annotations,
    required this.frame,
    required this.search,
    required this.recognizer,
    required this.recognizing,
    required this.autoResult,
    required this.grabbing,
    required this.identify,
    required this.onAuto,
    required this.onGrab,
    required this.onDone,
    required this.onOpenFrame,
    required this.onRename,
    required this.onFilter,
    required this.onRemove,
  });

  final VideoClip clip;
  final ClipAnnotations annotations;

  /// The frame being tagged, if any.
  final TagFrame? frame;
  final ValueNotifier<String>? search;
  final SubjectRecognizer? recognizer;
  final bool recognizing;
  final String? autoResult;
  final bool grabbing;
  final bool identify;
  final VoidCallback onAuto;
  final VoidCallback onGrab;
  final VoidCallback onDone;
  final void Function(TagFrame frame) onOpenFrame;
  final void Function(Annotation annotation) onRename;
  final void Function(String name) onFilter;
  final void Function(TagFrame frame, Annotation annotation) onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final frame = this.frame;
    final recognizer = this.recognizer;
    final frames = annotations.tagFrames.values.toList()
      ..sort((a, b) => a.ms.compareTo(b.ms));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        // The buttons go under the title when they don't fit beside it.
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 8,
          children: [
            const _SectionHeading(
              key: Key('subjects-heading'),
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
                      icon: recognizing
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.auto_awesome),
                      label: const Text('Auto'),
                      onPressed: recognizing || !recognizer.supported
                          ? null
                          : onAuto,
                    ),
                  ),
                if (frame == null)
                  FilledButton.tonalIcon(
                    key: const Key('tag-frame'),
                    icon: grabbing
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.crop_free),
                    label: const Text('Name subject'),
                    onPressed: grabbing ? null : onGrab,
                  )
                else
                  FilledButton(
                    key: const Key('done-tagging'),
                    onPressed: onDone,
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
        if (recognizing)
          Text(
            clip.fullDone
                ? 'Looking for the subjects named before…'
                : 'Waiting for the clip to finish recording…',
            key: const Key('auto-tag-status'),
            style: TextStyle(color: scheme.onSurfaceVariant),
          )
        else if (autoResult case final result?)
          Text(
            result,
            key: const Key('auto-tag-result'),
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        if (identify && frame == null)
          if (unidentifiedOf(annotations) case final u?)
            Row(
              key: const Key('identify-hint'),
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 6,
              children: [
                Icon(Icons.flag, size: 18, color: EventFlag.unidentified.color),
                Expanded(
                  child: Text(
                    '${u.label}: click them on the video to '
                    'name them, or try Auto.',
                  ),
                ),
              ],
            ),
        if (annotations.tags.isEmpty && frame == null)
          Text(
            'No subjects yet. Click a person or pet on the '
            'video to name them.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        for (final f in frames)
          _FrameRow(
            frame: f,
            subjects: annotations.on(f.id),
            search: search,
            onOpen: () => onOpenFrame(f),
            onRename: onRename,
            onFilter: onFilter,
            onRemove: (a) => onRemove(f, a),
          ),
      ],
    );
  }
}

/// A tagged frame's thumbnail (tapped, it's tagged again) beside the chips
/// of the subjects named on it ([_SubjectChip]).
class _FrameRow extends StatelessWidget {
  const _FrameRow({
    required this.frame,
    required this.subjects,
    required this.search,
    required this.onOpen,
    required this.onRename,
    required this.onFilter,
    required this.onRemove,
  });

  final TagFrame frame;
  final List<Annotation> subjects;
  final ValueNotifier<String>? search;
  final VoidCallback onOpen;
  final void Function(Annotation annotation) onRename;
  final void Function(String name) onFilter;
  final void Function(Annotation annotation) onRemove;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 12,
      children: [
        Tooltip(
          message: 'Name more subjects on this frame',
          child: InkWell(
            key: Key('frame-${frame.id}'),
            onTap: onOpen,
            child: Column(
              spacing: 2,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.memory(
                    frame.jpeg,
                    width: 96,
                    height: 54,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  ),
                ),
                Text(formatClipTime(frame.ms), style: textTheme.labelSmall),
              ],
            ),
          ),
        ),
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final a in subjects)
                _SubjectChip(
                  annotation: a,
                  search: search,
                  onRename: () => onRename(a),
                  onFilter: () => onFilter(a.name),
                  onRemove: () => onRemove(a),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A subject's chip: recognized ones show how sure. Opened from a timeline
/// ([search] set), a tap filters the events by it and a long press (or a
/// right click) renames it; otherwise a tap renames it. Its x removes it.
class _SubjectChip extends StatelessWidget {
  const _SubjectChip({
    required this.annotation,
    required this.search,
    required this.onRename,
    required this.onFilter,
    required this.onRemove,
  });

  final Annotation annotation;
  final ValueNotifier<String>? search;
  final VoidCallback onRename;
  final VoidCallback onFilter;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final a = annotation;
    final search = this.search;
    final chip = InputChip(
      key: Key('annotation-${a.id}'),
      // Recognized ones show how sure.
      avatar: Icon(
        a.source == TagSource.detected ? Icons.auto_awesome : Icons.place,
        size: 18,
      ),
      label: Text(
        a.source == TagSource.detected && a.confidence != null
            ? '${a.name} · '
                  '${(a.confidence! * 100).round()} %'
            : a.name,
      ),
      tooltip: search == null ? 'Rename subject' : null,
      selected:
          search != null && EventSearchScope.isActive(search.value, a.name),
      showCheckmark: false,
      onPressed: search == null ? onRename : onFilter,
      deleteButtonTooltipMessage: 'Remove subject',
      onDeleted: onRemove,
    );
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
        onLongPress: onRename,
        onSecondaryTap: onRename,
        child: chip,
      ),
    );
  }
}

/// The player's **Tags** section: the things recognition saw on the clip
/// ([ClipObjectTags]), or why there are none.
class _TagsSection extends StatelessWidget {
  const _TagsSection({
    required this.annotations,
    required this.recognizer,
    required this.onFiltered,
  });

  final ClipAnnotations annotations;
  final SubjectRecognizer? recognizer;
  final VoidCallback onFiltered;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        const _SectionHeading(
          key: Key('tags-heading'),
          icon: Icons.sell_outlined,
          title: 'Tags',
        ),
        if (annotations.objects?.isNotEmpty ?? false)
          ClipObjectTags(
            annotations: annotations,
            keyPrefix: 'player-object',
            onFiltered: onFiltered,
          )
        else
          Text(
            annotations.objects == null
                ? 'No tags yet. Things seen on the clip, like '
                      'bottle or bicycle, show here once it has '
                      'been searched'
                      '${(recognizer?.supported ?? false) ? ' (try Auto)' : ''}.'
                : 'No tags: nothing was seen on this clip.',
            key: const Key('tags-empty'),
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
      ],
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
