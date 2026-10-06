import 'dart:typed_data';

import 'vision.dart';

/// One reference picture of a subject: what they looked like on a tag
/// someone made or confirmed.
class GalleryEntry {
  const GalleryEntry({
    required this.subjectId,
    required this.name,
    required this.kind,
    required this.look,
    this.face,
  });

  final String subjectId;

  /// As written on the tag.
  final String name;
  final SeenKind kind;
  final Float32List look;
  final Float32List? face;
}

/// A subject recognized on a frame.
class Match {
  const Match(this.entry, this.seen, this.confidence, {required this.byFace});

  /// The reference that matched best.
  final GalleryEntry entry;
  final Seen seen;

  /// From 0 to 1 ([faceConfidence] or [lookConfidence]).
  final double confidence;

  /// Whether faces were compared (otherwise looks).
  final bool byFace;

  String get subjectId => entry.subjectId;
}

/// How sure two faces are the same person, from their cosine similarity
/// (MobileFaceNet, aligned faces): 0 at 0.30 or less, 1 at 0.65 or more.
/// On LFW's pairs (faces 10 px or more between the eyes) different people
/// score under 0.44 (99.9 %), the same person 0.62 to 0.75 typically.
double faceConfidence(double cosine) => ((cosine - 0.30) / 0.35).clamp(0, 1);

/// How sure two looks are the same subject, from their cosine similarity:
/// for people (OSNet), 0 at 0.53 or less, 1 at 0.82 or more (on
/// Market-1501, 1 % of different people's pairs score over 0.60, 0.1 %
/// over 0.72; the same person 0.80 typically); for pets (MobileNetV3, a
/// generic embedder), 0 at 0.45, 1 at 0.90. Looks change with clothes and
/// light, so faces are compared first when they can be.
double lookConfidence(double cosine, {SeenKind kind = SeenKind.person}) =>
    kind == SeenKind.person
    ? ((cosine - 0.53) / 0.29).clamp(0, 1)
    : ((cosine - 0.45) / 0.45).clamp(0, 1);

/// How sure [seen] is the subject of [entry]: by face when both show one,
/// otherwise by look. Null when they can't be the same (a person and a
/// pet).
Match? compare(Seen seen, GalleryEntry entry) {
  if (!seen.detection.kind.sameAs(entry.kind)) return null;
  final face = seen.faceVector;
  final reference = entry.face;
  if (face != null && reference != null) {
    return Match(
      entry,
      seen,
      faceConfidence(cosine(face, reference)),
      byFace: true,
    );
  }
  final look = seen.lookVector;
  if (look == null) return null;
  return Match(
    entry,
    seen,
    lookConfidence(cosine(look, entry.look), kind: entry.kind),
    byFace: false,
  );
}

/// The subjects on one frame: each one seen matched to the subject it's
/// most like, at most one subject per person or pet and one person or pet
/// per subject, the surest pairs first. Subjects in [skip] (already
/// found) are left out, and so are pairs under [minConfidence].
List<Match> matchFrame(
  List<Seen> seen,
  List<GalleryEntry> gallery, {
  Set<String> skip = const {},
  double minConfidence = 0,
}) {
  // Each subject's best reference for each one seen.
  final best = <(int, String), Match>{};
  for (var i = 0; i < seen.length; i++) {
    for (final entry in gallery) {
      if (skip.contains(entry.subjectId)) continue;
      final match = compare(seen[i], entry);
      if (match == null || match.confidence < minConfidence) continue;
      final key = (i, entry.subjectId);
      if ((best[key]?.confidence ?? -1) < match.confidence) best[key] = match;
    }
  }
  final pairs = best.entries.toList()
    ..sort((a, b) => b.value.confidence.compareTo(a.value.confidence));
  final usedSeen = <int>{};
  final usedSubjects = <String>{};
  final matches = <Match>[];
  for (final MapEntry(key: (i, subject), :value) in pairs) {
    if (usedSeen.contains(i) || usedSubjects.contains(subject)) continue;
    usedSeen.add(i);
    usedSubjects.add(subject);
    matches.add(value);
  }
  return matches;
}
