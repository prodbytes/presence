import 'dart:typed_data';

import '../crypto/sealed_image.dart';

import 'package:flutter/material.dart';

import '../event_flags.dart';
import '../events.dart';
import '../subjects.dart';
import 'clip_labels.dart';
import 'clip_model.dart';
import 'clip_player_dialog.dart';

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
    return SealedImage(
      image,
      key: const Key('clip-thumbnail'),
      fit: BoxFit.cover,
    );
  }
}
