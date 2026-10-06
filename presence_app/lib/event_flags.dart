import 'package:flutter/material.dart';

import 'annotations.dart';
import 'subjects.dart';
import 'theme.dart';

/// Something about an event that wants attention, shown on its card beside
/// what was detected on it. Flags are worked out from the event's data each
/// time (`AppEvent.flags`), never stored: they change as the event does.
enum EventFlag {
  /// A person or pet was seen on the clip and isn't identified as a known
  /// subject: someone should name them.
  unidentified;

  /// The flag's color on the card.
  Color get color => switch (this) {
    unidentified => Gruvbox.yellow,
  };

  /// Its tooltip and screen-reader label.
  String get tooltip => switch (this) {
    unidentified => 'Unidentified person/pet — identify',
  };
}

/// The sorts of subject recognition tells apart: people, and pets.
enum SubjectSort { person, pet }

/// The object tags that are a person: the detector's `person` class.
const Set<String> personLabels = {'human'};

/// The object tags that are a pet: the detector's household pets, cats and
/// dogs (the sorts recognition matches pets of). Birds, horses, cows and
/// the other animals it knows aren't pets here.
const Set<String> petLabels = {'cat', 'dog'};

/// The sort of subject an object tag [label] is, or null for anything else.
SubjectSort? sortOfLabel(String label) => personLabels.contains(label)
    ? SubjectSort.person
    : petLabels.contains(label)
    ? SubjectSort.pet
    : null;

/// What a clip's [EventFlag.unidentified] is about: the sorts of subject
/// seen on it, how many subjects are named on it, and where the first
/// person or pet was seen ([ms] into the recording).
@immutable
class Unidentified {
  const Unidentified({
    required this.sorts,
    required this.named,
    required this.ms,
  });

  final Set<SubjectSort> sorts;
  final int named;
  final int ms;

  /// "Unidentified person", "Unidentified pet", "Unidentified person and
  /// pet", or "Unidentified person or pet" when one of the two is named
  /// but it isn't known which.
  String get label {
    if (sorts.length == 1) {
      return sorts.single == SubjectSort.person
          ? 'Unidentified person'
          : 'Unidentified pet';
    }
    return named == 0
        ? 'Unidentified person and pet'
        : 'Unidentified person or pet';
  }
}

/// Whether [annotations] leave a person or pet unidentified, and about
/// what; null when not.
///
/// Recognition keeps which kinds of object it saw on a clip (its object
/// tags), not how many of each, and a name tagged on a clip doesn't say
/// whether it's a person or a pet. So a clip is unidentified while it has
/// fewer subjects named on it (tagged by someone, recognized, or a
/// suggestion someone confirmed; not one still waiting) than sorts of
/// subject seen on it: a person, a pet, or both.
Unidentified? unidentifiedOf(ClipAnnotations annotations) {
  final sorts = <SubjectSort>{};
  int? first;
  for (final o in annotations.objects ?? const <ObjectTag>[]) {
    if (sortOfLabel(o.label) case final sort?) {
      sorts.add(sort);
      if (first == null || o.ms < first) first = o.ms;
    }
  }
  if (sorts.isEmpty) return null;
  final named = {for (final tag in annotations.tags) Subject.idOf(tag.name)}
    ..remove('');
  if (named.length >= sorts.length) return null;
  return Unidentified(sorts: sorts, named: named.length, ms: first ?? 0);
}

/// A clip's flags, from its [annotations].
List<EventFlag> flagsOf(ClipAnnotations annotations) => [
  if (unidentifiedOf(annotations) != null) EventFlag.unidentified,
];

/// A clip's flags on its card: for an unidentified person or pet, a yellow
/// flag with what's unidentified and "Identify", which calls [onIdentify]
/// with where they were first seen (to name them there). Nothing without
/// flags. Follows the tags as they change.
class EventFlags extends StatelessWidget {
  const EventFlags({super.key, required this.annotations, this.onIdentify});

  final ClipAnnotations annotations;

  /// Opens the clip to name who's there; null when it can't be played.
  final void Function(Duration at)? onIdentify;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: annotations,
    builder: (context, _) {
      final unidentified = unidentifiedOf(annotations);
      if (unidentified == null) return const SizedBox.shrink();
      const flag = EventFlag.unidentified;
      final theme = Theme.of(context);
      final identify = onIdentify;
      final content = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            Icon(Icons.flag, size: 16, color: flag.color),
            Flexible(
              child: Text(
                identify == null
                    ? unidentified.label
                    : '${unidentified.label} · Identify',
                style: theme.textTheme.labelMedium?.copyWith(color: flag.color),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Tooltip(
          message: flag.tooltip,
          child: Semantics(
            button: identify != null,
            label: flag.tooltip,
            excludeSemantics: true,
            child: Container(
              key: const Key('event-flag-unidentified'),
              decoration: BoxDecoration(
                border: Border.all(color: flag.color),
                borderRadius: BorderRadius.circular(12),
              ),
              child: identify == null
                  ? content
                  : InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () =>
                          identify(Duration(milliseconds: unidentified.ms)),
                      child: content,
                    ),
            ),
          ),
        ),
      );
    },
  );
}
