import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Reading stored and downloaded records (events, clips, settings) without
/// trusting them: one damaged record, here or in the bucket, is skipped
/// (and logged), never the whole history or sync pass with it.
///
/// Each `tryParse…` returns the record cleaned up for the rest of the app
/// (fields of the wrong type dropped, integral doubles made ints), or null
/// when a field it can't do without is missing or wrong. The rest of the
/// record is kept as it was, so nothing a newer version added is lost.
abstract final class Records {
  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_.:-]{1,128}$');

  /// Whether [id] is safe as an event, clip, frame or device ID: it goes
  /// into object keys in the bucket and messages of live sync.
  static bool isSafeId(Object? id) =>
      id is String && _idPattern.hasMatch(id) && !id.contains('..');

  static final RegExp _mediaIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  /// Whether [id] is safe as a recording's ID: it names a file on Android
  /// (`<id>.mp4`) and a key in IndexedDB.
  static bool isSafeMediaId(Object? id) =>
      id is String && _mediaIdPattern.hasMatch(id);

  /// [value] as an int: an int, or a double with an integral value (JSON
  /// written by another runtime); otherwise null.
  static int? intOf(Object? value) => switch (value) {
    final int i => i,
    final double d when d.isFinite && d == d.truncateToDouble() => d.toInt(),
    _ => null,
  };

  /// The JSON object in [bytes]; null (logged, naming [what]) when they
  /// aren't UTF-8 JSON, or not an object.
  static Map<String, Object?>? decode(Uint8List bytes, {String? what}) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map) return decoded.cast<String, Object?>();
    } catch (_) {}
    _skip(what ?? 'record', 'not a JSON object');
    return null;
  }

  /// Text fields of events: dropped when they aren't text.
  static const _eventStrings = {
    'type',
    'title',
    'detail',
    'cameraId',
    'deviceId',
    'userId',
    'profileId',
    'os',
    'clipId',
    'trigger',
    'clipEventId',
    'annotationId',
    'subjectName',
  };

  /// An event record: it needs a string `id` and an integer `time` (ms
  /// since the epoch). With [safeIds] (records from the bucket, whose IDs
  /// go into keys), the ID and clip ID must be [isSafeId].
  static Map<String, Object?>? tryParseEvent(
    Map<String, Object?> record, {
    bool safeIds = false,
  }) {
    final id = record['id'];
    final time = intOf(record['time']);
    if (id is! String || id.isEmpty || time == null) {
      _skip('event ${id is String ? id : '?'}', 'no id or time');
      return null;
    }
    if (safeIds && !isSafeId(id)) {
      _skip('event', 'unsafe id');
      return null;
    }
    final clean = <String, Object?>{
      for (final MapEntry(:key, :value) in record.entries)
        if (!_eventStrings.contains(key) || value == null || value is String)
          key: value,
      'time': time,
    };
    final clipId = clean['clipId'];
    if (safeIds && clipId != null && !isSafeId(clipId)) {
      _skip('event $id', 'unsafe clip id');
      return null;
    }
    if (record.containsKey('deletedAt')) {
      final at = intOf(record['deletedAt']);
      if (at == null) {
        clean.remove('deletedAt');
      } else {
        clean['deletedAt'] = at;
      }
    }
    return clean;
  }

  /// A clip record: it needs a string `id` ([isSafeId] with [safeIds]).
  /// Its recordings' references (`past`, `full`) need a [isSafeMediaId]
  /// `mediaId`, or they're dropped (the clip shows without that part).
  /// Durations default to 0, the camera to none.
  static Map<String, Object?>? tryParseClip(
    Map<String, Object?> record, {
    bool safeIds = false,
  }) {
    final id = record['id'];
    if (id is! String || id.isEmpty || (safeIds && !isSafeId(id))) {
      _skip('clip ${id is String ? id : '?'}', 'no usable id');
      return null;
    }
    final clean = Map<String, Object?>.of(record);
    for (final key in const ['eventId', 'cameraId', 'cameraLabel', 'state']) {
      if (clean[key] != null && clean[key] is! String) clean.remove(key);
    }
    for (final key in const ['beforeMs', 'afterMs', 'requestedAt']) {
      if (!clean.containsKey(key)) continue;
      final value = intOf(clean[key]);
      if (value == null) {
        clean.remove(key);
      } else {
        clean[key] = value;
      }
    }
    if (clean['supported'] != null && clean['supported'] is! bool) {
      clean.remove('supported');
    }
    final thumbnail = clean['thumbnail'];
    if (thumbnail != null &&
        thumbnail is! Uint8List &&
        !(thumbnail is List && thumbnail.every((b) => b is int))) {
      clean.remove('thumbnail');
    }
    for (final part in const ['past', 'full']) {
      if (!clean.containsKey(part)) continue;
      final ref = mediaRefOf(clean[part]);
      if (ref == null) {
        if (clean[part] != null) _skip('clip $id', 'damaged $part recording');
        clean.remove(part);
      } else {
        clean[part] = ref;
      }
    }
    return clean;
  }

  /// A clip's reference to a recording (`{mediaId, startMs, endMs,
  /// mimeType}`), cleaned up; null without a safe media ID.
  static Map<String, Object?>? mediaRefOf(Object? ref) {
    if (ref is! Map) return null;
    final mediaId = ref['mediaId'];
    if (!isSafeMediaId(mediaId)) return null;
    final clean = {
      ...ref.cast<String, Object?>(),
      'mediaId': mediaId,
      'startMs': intOf(ref['startMs']) ?? 0,
      'endMs': intOf(ref['endMs']) ?? 0,
    };
    if (clean['mimeType'] is! String) clean.remove('mimeType');
    return clean;
  }

  /// A camera record (`{id, label, lastSeen}`): null without a string ID.
  static ({String id, String? label})? tryParseCamera(
    Map<String, Object?> record,
  ) {
    final id = record['id'];
    if (id is! String) return null;
    final label = record['label'];
    return (id: id, label: label is String ? label : null);
  }

  /// A device's settings record as synced (`{deviceId, profileId,
  /// updatedAt, config, location}`): it needs a string `deviceId` and a
  /// `config` object; `updatedAt` counts as 0 when it isn't an integer.
  static Map<String, Object?>? tryParseSettings(Object? record) {
    if (record is! Map) {
      _skip('settings', 'not a JSON object');
      return null;
    }
    final clean = record.cast<String, Object?>();
    if (clean['deviceId'] is! String || clean['config'] is! Map) {
      _skip('settings', 'no device ID or config');
      return null;
    }
    return {...clean, 'updatedAt': intOf(clean['updatedAt']) ?? 0};
  }

  static void _skip(String what, String why) =>
      debugPrint('Presence: skipped a damaged record ($what): $why');
}
