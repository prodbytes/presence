import 'dart:typed_data';

import '../crypto/sealed_image.dart';

import 'package:flutter/material.dart';

import '../event_flags.dart';
import '../annotations.dart';
import '../events.dart';
import '../l10n/l10n.dart';
import '../subjects.dart';
import 'clip_labels.dart';
import 'clip_model.dart';
import 'clip_player_dialog.dart';
import 'frame_tagger.dart';

/// A clip event's card in the timeline: its thumbnail (tapped, the player
/// opens), title, camera, status, subjects, tags and flags.
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
    final l = context.l10n;
    return ListenableBuilder(
      // The annotations too: a subject tagged later shows on the thumbnail.
      listenable: Listenable.merge([clip, event.annotations]),
      builder: (context, _) {
        final subject = firstSubject(event.annotations);
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
              if (subject case (final frame, final tag))
                // The first subject seen, on their frame, with their name
                // where they were tagged: the frame whole (on black), so
                // the spot is exact.
                ColoredBox(
                  color: Colors.black,
                  child: Center(
                    child: FrameTagger(
                      key: const Key('clip-card-subject-frame'),
                      frame: frame,
                      tags: [tag],
                    ),
                  ),
                )
              else
                // Missing or black: a placeholder, never a black box.
                _Thumbnail(
                  bytes: clip.thumbnailPlaceholder ? null : clip.thumbnail,
                ),
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
                    child: Text(
                      event.displayTitle(l),
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
                clip.statusIn(l),
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

/// The subject a clip's card shows on its thumbnail: of the tags with a
/// frame (not suggestions), the one seen first in the clip (its frame's
/// time; then the first tagged), with that frame; null when there's none.
(TagFrame, Annotation)? firstSubject(ClipAnnotations annotations) {
  (TagFrame, Annotation)? first;
  for (final tag in annotations.tags) {
    final frame = annotations.frames[tag.frameId];
    if (frame == null) continue;
    if (first == null || frame.ms < first.$1.ms) first = (frame, tag);
  }
  return first;
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
        key: const Key('clip-thumbnail-placeholder'),
        color: scheme.surfaceContainerLowest,
        child: Icon(Icons.videocam, size: 40, color: scheme.onSurfaceVariant),
      );
    }
    return SealedImage(
      image,
      key: const Key('clip-thumbnail'),
      fit: BoxFit.cover,
    );
  }
}
