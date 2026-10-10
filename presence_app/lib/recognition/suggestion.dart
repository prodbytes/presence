import 'package:flutter/material.dart';

import '../crypto/sealed_image.dart';
import '../annotations.dart';
import '../clips.dart';
import '../events.dart';
import '../subjects.dart';

/// Recognition thinks [subjectName] is on a clip, but isn't sure enough to
/// tag them: it added a suggestion to the clip ([annotationId], a
/// [TagSource.suggested] entry with its frame), and this event asks
/// whether it's them. Yes makes it a tag; No removes it.
class SubjectSuggestion extends AppEvent {
  SubjectSuggestion({
    required this.clipEventId,
    required this.annotationId,
    required this.subjectName,
    required this.confidence,
    this.clip,
    super.cameraId,
    super.deviceId,
    super.userId,
    super.profileId,
    super.time,
    super.id,
  }) : super(
         icon: Icons.person_search,
         title: 'Is this $subjectName?',
         detail: '${(confidence * 100).round()} % sure',
         type: suggestionType,
       );

  static const String suggestionType = 'subject_suggestion';

  final String clipEventId;
  final String annotationId;
  final String subjectName;
  final double confidence;

  /// The clip it's about, once known (linked when history is restored).
  ClipRequested? clip;

  @override
  Map<String, Object?> toRecord() => {
    ...super.toRecord(),
    'clipEventId': clipEventId,
    'annotationId': annotationId,
    'subjectName': subjectName,
    'confidence': confidence,
  };

  /// Null if [record] isn't a well-formed suggestion.
  static SubjectSuggestion? fromRecord(Map<String, Object?> record) {
    final clipEventId = record['clipEventId'];
    final annotationId = record['annotationId'];
    final name = record['subjectName'];
    final confidence = record['confidence'];
    if (clipEventId is! String ||
        annotationId is! String ||
        name is! String ||
        confidence is! num) {
      return null;
    }
    return SubjectSuggestion(
      clipEventId: clipEventId,
      annotationId: annotationId,
      subjectName: name,
      confidence: confidence.toDouble(),
      cameraId: record['cameraId'] as String?,
      deviceId: record['deviceId'] as String?,
      userId: AppEvent.ownerOf(record),
      time: DateTime.fromMillisecondsSinceEpoch(record['time']! as int),
      id: record['id']! as String,
    );
  }

  @override
  Widget buildCard(BuildContext context) => SuggestionCard(suggestion: this);
}

/// The question, with the frame and a dot where recognition saw them, and
/// Yes / No; once answered, the answer.
class SuggestionCard extends StatelessWidget {
  const SuggestionCard({super.key, required this.suggestion});

  final SubjectSuggestion suggestion;

  @override
  Widget build(BuildContext context) {
    final clip = suggestion.clip;
    if (clip == null) return _card(context, null, null);
    return ListenableBuilder(
      listenable: clip.annotations,
      builder: (context, _) {
        final annotation = clip.annotations.byId(suggestion.annotationId);
        final frame = annotation?.frameId == null
            ? null
            : clip.annotations.frames[annotation!.frameId];
        return _card(context, annotation, frame, clip);
      },
    );
  }

  Widget _card(
    BuildContext context,
    Annotation? annotation,
    TagFrame? frame, [
    ClipRequested? clip,
  ]) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = suggestion.subjectName;
    final pending = annotation?.source == TagSource.suggested;
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final color = Subject.colorOf(Subject.idOf(name));
    final Widget answer;
    if (clip == null) {
      answer = Text('The clip is missing', style: quiet);
    } else if (pending) {
      answer = Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          FilledButton.tonal(
            key: const Key('suggestion-yes'),
            onPressed: () => clip.annotations.confirm(annotation!.id),
            child: Text("Yes, it's $name"),
          ),
          TextButton(
            key: const Key('suggestion-no'),
            onPressed: () => clip.annotations.remove(annotation!.id),
            child: const Text('No'),
          ),
        ],
      );
    } else {
      final tagged = annotation != null;
      answer = Row(
        key: const Key('suggestion-answer'),
        spacing: 6,
        children: [
          Icon(
            tagged ? Icons.check_circle : Icons.cancel,
            size: 18,
            color: tagged ? scheme.primary : scheme.onSurfaceVariant,
          ),
          Text(tagged ? 'Tagged as $name' : 'Not $name', style: quiet),
        ],
      );
    }
    return Card.filled(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            if (frame != null && annotation != null)
              _Frame(frame: frame, annotation: annotation, color: color),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  Row(
                    spacing: 8,
                    children: [
                      Icon(suggestion.icon, size: 20, color: scheme.primary),
                      SubjectSwatch(color: color, size: 12),
                      Expanded(
                        child: Text(
                          suggestion.title,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      Text(
                        formatEventTime(suggestion.time),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    [
                      suggestion.detail!,
                      if (clip != null) clip.clip.cameraLabel,
                    ].join(' · '),
                    style: quiet,
                  ),
                  answer,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The frame, with a dot where the subject was seen.
class _Frame extends StatelessWidget {
  const _Frame({
    required this.frame,
    required this.annotation,
    required this.color,
  });

  final TagFrame frame;
  final Annotation annotation;
  final Color color;

  static const double width = 120;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(4),
    child: SizedBox(
      width: width,
      child: Stack(
        children: [
          SealedImage(
            frame.sealed,
            key: const Key('suggestion-frame'),
            width: width,
          ),
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, box) => Stack(
                children: [
                  Positioned(
                    left: annotation.x * box.maxWidth - 5,
                    top: annotation.y * box.maxHeight - 5,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
