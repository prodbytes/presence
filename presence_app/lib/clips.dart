import 'dart:typed_data';

import 'package:flutter/material.dart';

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

/// Published once per camera when the user presses Clip.
class ClipRequested extends AppEvent {
  ClipRequested(this.clip, {super.time, super.id})
    : super(
        icon: Icons.videocam,
        title: 'Clip requested',
        detail: clip.cameraLabel,
        type: clipRequestedType,
        cameraId: clip.cameraId,
      );

  static const String clipRequestedType = 'clip_requested';

  final VideoClip clip;

  /// `partial` while only the "before" part exists, `complete` once the
  /// event has been updated with the full clip.
  String get clipState => clip.full != null ? 'complete' : 'partial';

  @override
  Map<String, Object?> toRecord() => {
    ...super.toRecord(),
    'clipId': clip.id,
    'clipState': clipState,
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              title: Text(
                '${event.clip.cameraLabel} · '
                '${formatEventTime(event.time)}',
              ),
              trailing: IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipPlayerView(clip: event.clip),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: ListenableBuilder(
                listenable: event.clip,
                builder: (context, _) => Text(event.clip.status),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
