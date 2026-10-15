import 'package:flutter/material.dart';

import '../clips.dart';
import '../crypto/sealed_image.dart';
import '../event_flags.dart';
import '../events.dart';
import '../l10n/l10n.dart';
import '../subjects.dart';

/// Recognition saw a person or pet on a clip ([sorts], first at [ms] into
/// the recording) and couldn't name them: this event asks who it is.
/// Identify opens the clip there, to tag them; once everyone on the clip
/// is named, the card says who.
class SubjectRequest extends AppEvent {
  SubjectRequest({
    required this.clipEventId,
    required this.sorts,
    required this.ms,
    this.clip,
    super.cameraId,
    super.deviceId,
    super.userId,
    super.profileId,
    super.time,
    super.id,
  }) : super(
         icon: Icons.person_add_alt_1,
         title: 'Who is this?',
         detail: _seenEnglish(sorts),
         type: requestType,
       );

  static const String requestType = 'subject_request';

  final String clipEventId;

  /// What was seen and isn't named: a person, a pet, or both.
  final Set<SubjectSort> sorts;

  /// Where the first of them was seen, into the recording.
  final int ms;

  /// The clip it's about, once known (linked when history is restored).
  ClipRequested? clip;

  static String _seenEnglish(Set<SubjectSort> sorts) =>
      _seenIn(lookupAppLocalizations(const Locale('en')), sorts);

  static String _seenIn(AppLocalizations l, Set<SubjectSort> sorts) =>
      sorts.length > 1
      ? l.eventRequestSeenBoth
      : sorts.contains(SubjectSort.pet)
      ? l.eventRequestSeenPet
      : l.eventRequestSeenPerson;

  @override
  Map<String, Object?> toRecord() => {
    ...super.toRecord(),
    'clipEventId': clipEventId,
    'sorts': [
      for (final s in SubjectSort.values)
        if (sorts.contains(s)) s.name,
    ],
    'ms': ms,
  };

  /// Null if [record] isn't a well-formed request.
  static SubjectRequest? fromRecord(Map<String, Object?> record) {
    final clipEventId = record['clipEventId'];
    final names = record['sorts'];
    final ms = record['ms'];
    if (clipEventId is! String || names is! List || ms is! int) return null;
    final sorts = {
      for (final s in SubjectSort.values)
        if (names.contains(s.name)) s,
    };
    if (sorts.isEmpty) return null;
    return SubjectRequest(
      clipEventId: clipEventId,
      sorts: sorts,
      ms: ms,
      cameraId: record['cameraId'] as String?,
      deviceId: record['deviceId'] as String?,
      userId: AppEvent.ownerOf(record),
      time: DateTime.fromMillisecondsSinceEpoch(record['time']! as int),
      id: record['id']! as String,
    );
  }

  @override
  String displayTitle(AppLocalizations l) => l.eventTitleWhoIsThis;

  @override
  String? displayDetail(AppLocalizations l) => _seenIn(l, sorts);

  @override
  Widget buildCard(BuildContext context) => SubjectRequestCard(request: this);
}

/// "Who is this?", with the clip's picture and Identify; once everyone on
/// the clip is named, who they are instead.
class SubjectRequestCard extends StatelessWidget {
  const SubjectRequestCard({super.key, required this.request});

  final SubjectRequest request;

  static const double thumbnailWidth = 180;

  @override
  Widget build(BuildContext context) {
    final clip = request.clip;
    if (clip == null) return _card(context, null);
    return ListenableBuilder(
      listenable: Listenable.merge([clip.clip, clip.annotations]),
      builder: (context, _) => _card(context, clip),
    );
  }

  Widget _card(BuildContext context, ClipRequested? clip) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l = context.l10n;
    final quiet = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    // Answered once nobody on the clip is left to name.
    final answered = clip != null && unidentifiedOf(clip.annotations) == null;
    final names = <String, String>{
      if (clip != null)
        for (final tag in clip.annotations.tags)
          if (Subject.idOf(tag.name).isNotEmpty)
            Subject.idOf(tag.name): tag.name,
    };
    final identify = clip != null && clip.clip.playable && !answered
        ? () => showClipPlayer(
            context,
            clip,
            at: Duration(milliseconds: request.ms),
            identify: true,
          )
        : null;
    final Widget? answer;
    if (clip == null) {
      answer = Text(l.eventSuggestionClipMissing, style: quiet);
    } else if (answered) {
      answer = null;
    } else if (identify == null) {
      answer = Text(l.eventRequestClipNotHere, style: quiet);
    } else {
      answer = FilledButton.tonal(
        key: const Key('request-identify'),
        onPressed: identify,
        child: Text(l.eventRequestIdentify),
      );
    }
    final thumbnail = clip?.clip.thumbnail;
    return Card.filled(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: [
            if (thumbnail != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: InkWell(
                  onTap: identify,
                  child: SizedBox(
                    width: thumbnailWidth,
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: SealedImage(
                        thumbnail,
                        key: const Key('request-thumbnail'),
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
            ],
            Row(
              key: Key(answered ? 'request-answer' : 'request-question'),
              spacing: 8,
              children: [
                Icon(
                  answered ? Icons.check_circle : request.icon,
                  size: 20,
                  color: scheme.primary,
                ),
                if (answered)
                  for (final id in names.keys)
                    SubjectSwatch(color: Subject.colorOf(id), size: 12),
                Expanded(
                  child: Text(
                    answered
                        ? l.eventRequestNamed(names.values.join(', '))
                        : request.displayTitle(l),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            Text(
              [
                request.displayDetail(l)!,
                if (clip != null) clip.clip.cameraLabel,
                formatEventTime(request.time),
              ].join(' · '),
              style: quiet,
            ),
            ?answer,
          ],
        ),
      ),
    );
  }
}
