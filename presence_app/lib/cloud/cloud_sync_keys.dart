part of 'cloud_sync.dart';

// Object keys, JSON and fingerprints: the helpers [CloudSync]'s parts
// share.

/// The frames [event]'s tags use, by ID: only safe ones
/// ([Records.isSafeId]), since they go into object keys.
Iterable<String> _frameIds(Map<String, Object?> event) sync* {
  final annotations = event['annotations'];
  if (annotations is! List) return;
  final seen = <String>{};
  for (final a in annotations) {
    final id = a is Map ? a['frameId'] : null;
    if (id is String && Records.isSafeId(id) && seen.add(id)) yield id;
  }
}

/// Event keys, partitioned (`events/year=YYYY/day=DDD/<id>.json`) or
/// flat, from before partitioning (`events/<id>.json`).
final RegExp _eventKey = RegExp(r'^events/(?:.+/)?([^/]+)\.json$');

/// The ID of the event at [key] (see [_eventKey]); null for other keys.
String? _eventIdOf(String key) => _eventKey.firstMatch(key)?[1];

/// Recording keys (`media/<clipId>.webm` or `.mp4`): the clip's ID.
final RegExp _recordingKey = RegExp(r'^media/(.+)\.(?:webm|mp4)$');

/// Where clip [clipId]'s recording may be: WebM (the web) or MP4.
List<String> _recordingKeys(String clipId) => [
  'media/$clipId.webm',
  'media/$clipId.mp4',
];

DateTime _utc(int ms) => DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

/// The partition of [root] (`events` or `clips`) holding [at]'s UTC day:
/// `events/year=2026/day=269/`.
String _dayPrefix(DateTime at, [String root = 'events']) {
  final utc = at.toUtc();
  final day =
      DateTime.utc(
        utc.year,
        utc.month,
        utc.day,
      ).difference(DateTime.utc(utc.year)).inDays +
      1;
  return '$root/year=${utc.year}/day=${day.toString().padLeft(3, '0')}/';
}

/// An event's JSON as uploaded: its record without the frames (they go
/// up as images).
Uint8List _eventJson(Map<String, Object?> record) => _json({
  for (final MapEntry(:key, :value) in record.entries)
    if (key != 'frames') key: value,
});

/// Where the synced-keys store keeps the ETag of [objectKey] as this
/// device last uploaded or downloaded it.
String _etagKey(String objectKey) => 'etag:$objectKey';

/// Where the synced-keys store notes that the recording at [objectKey]
/// is in the cloud but not downloaded yet, as `<time>:<mediaId>` (the
/// time of its event, ms since the epoch, to take the newest first).
String _fetchKey(String objectKey) => 'fetch:$objectKey';

Uint8List _json(Map<String, Object?> record) =>
    Uint8List.fromList(utf8.encode(jsonEncode(record)));

String _fingerprint(Uint8List bytes) => sha256.convert(bytes).toString();

/// Whether an event key's day partition (see [CloudSync.eventKey]) can hold events
/// at or after [since]: false only for a partition that ends before it.
/// Flat keys, from before partitioning, have no day and are read.
bool _partitionMayBeSince(String key, DateTime since) {
  final m = RegExp(r'^events/year=(\d{4})/day=(\d{3})/').firstMatch(key);
  if (m == null) return true;
  final dayStart = DateTime.utc(int.parse(m[1]!))
      .add(Duration(days: int.parse(m[2]!) - 1));
  return !dayStart.add(const Duration(days: 1)).isBefore(since);
}

/// A recording's file extension in the cloud, from its MIME type.
String _extOf(String? mimeType) =>
    (mimeType ?? '').contains('mp4') ? 'mp4' : 'webm';
