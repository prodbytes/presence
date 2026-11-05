import 'dart:convert';
import 'dart:typed_data';

import '../crypto/media_seal.dart';
import '../events.dart';
import 'event_store.dart';
import 'media_store.dart';
import 'records.dart';

/// One event in a file of its own (the event card's Download, the events
/// list's Upload): its record, its clip's record and the clip's media,
/// opened, so the file reads anywhere (another profile, another app); an
/// upload seals the media again with this device's key.
///
/// JSON: `{format, version, exportedAt, event, clip?, media}`. Bytes are
/// base64: the event's `frames` (JPEG by frame ID), the clip's `thumbnail`
/// (JPEG) and `media` (each recording by its `mediaId`).
abstract final class EventFile {
  static const String format = 'presence-event';
  static const int version = 1;
  static const String mimeType = 'application/json';
  static const String extension = 'json';

  /// The file's name: `presence-event-<id>.json`.
  static String nameOf(String eventId) => 'presence-event-$eventId.$extension';

  /// Event [eventId] as a file. Its recordings that aren't here are
  /// fetched with [fetchMissing] (from the cloud) first; one that still
  /// isn't is left out (the clip keeps its thumbnail and tags). Throws
  /// [EventFileException] when the event isn't here or is deleted,
  /// [SealKeyMissing] when its media doesn't open on this device.
  static Future<Uint8List> export({
    required EventStore store,
    required MediaStore media,
    required MediaSeal seal,
    required String eventId,
    required DateTime now,
    Future<void> Function(String clipId, String mediaId)? fetchMissing,
  }) async {
    final stored = await store.getEvent(eventId);
    if (stored == null || AppEvent.isDeletedRecord(stored)) {
      throw EventFileException('event $eventId is not here');
    }
    final event = Map<String, Object?>.of(stored);
    if (event['frames'] case final Map frames) {
      event['frames'] = {
        for (final MapEntry(:key, :value) in frames.entries)
          if (_bytes(value) case final sealed?)
            '$key': base64Encode(await seal.open(sealed)),
      };
    }
    Map<String, Object?>? clip;
    final recordings = <String, String>{};
    if (event['clipId'] case final String clipId) {
      if (await store.getClip(clipId) case final stored?) {
        clip = Map<String, Object?>.of(stored)
          ..remove('thumbnailCheck')
          ..remove('thumbnailRedone');
        if (_bytes(clip['thumbnail']) case final sealed?) {
          clip['thumbnail'] = base64Encode(await seal.open(sealed));
        } else {
          clip.remove('thumbnail');
        }
        for (final part in const ['past', 'full']) {
          final ref = Records.mediaRefOf(clip[part]);
          if (ref == null) {
            clip.remove(part);
            continue;
          }
          final mediaId = ref['mediaId']! as String;
          final sealed = await _read(media, clipId, mediaId, fetchMissing);
          if (sealed == null) {
            clip.remove(part);
            continue;
          }
          recordings[mediaId] = base64Encode(await seal.open(sealed));
        }
      }
    }
    return utf8.encode(
      jsonEncode({
        'format': format,
        'version': version,
        'exportedAt': now.millisecondsSinceEpoch,
        'event': event,
        'clip': ?clip,
        'media': recordings,
      }),
    );
  }

  /// Takes in a file made by [export]: seals its media with this device's
  /// key, saves the recordings in [media], and gives the event and clip
  /// records to store (`Persistence.importRemote`). The event joins
  /// [profileId] (the signed-in profile; none signed out), undeleted.
  /// Throws [EventFileException] when [bytes] isn't such a file or its
  /// IDs aren't safe.
  static Future<({Map<String, Object?> event, Map<String, Object?>? clip})>
  import({
    required Uint8List bytes,
    required MediaStore media,
    required MediaSeal seal,
    required String? profileId,
  }) async {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const EventFileException('not a Presence event file');
    }
    if (json is! Map ||
        json['format'] != format ||
        json['version'] is! int ||
        (json['version'] as int) > version) {
      throw const EventFileException('not a Presence event file');
    }
    final rawEvent = json['event'];
    if (rawEvent is! Map) {
      throw const EventFileException('the file has no event');
    }
    final event = Map<String, Object?>.of(rawEvent.cast<String, Object?>());
    final eventId = event['id'];
    if (!Records.isSafeId(eventId) || event['time'] is! int) {
      throw const EventFileException('the event has no usable id or time');
    }
    event.remove('deletedAt');
    if (profileId == null) {
      event.remove('profileId');
    } else {
      event['profileId'] = profileId;
    }
    if (event['frames'] case final Map frames) {
      event['frames'] = {
        for (final MapEntry(:key, :value) in frames.entries)
          if (_base64(value) case final jpeg?) '$key': await seal.seal(jpeg),
      };
    }

    Map<String, Object?>? clip;
    final rawClip = json['clip'];
    final recordings = json['media'];
    if (rawClip is Map && event['clipId'] is String) {
      clip = Map<String, Object?>.of(rawClip.cast<String, Object?>());
      if (clip['id'] != event['clipId'] || !Records.isSafeId(clip['id'])) {
        throw const EventFileException('the clip is not the event\'s');
      }
      clip['eventId'] = eventId;
      if (_base64(clip['thumbnail']) case final jpeg?) {
        clip['thumbnail'] = await seal.seal(jpeg);
      } else {
        clip.remove('thumbnail');
      }
      for (final part in const ['past', 'full']) {
        final ref = Records.mediaRefOf(clip[part]);
        final mediaId = ref?['mediaId'];
        final plain = recordings is Map ? _base64(recordings[mediaId]) : null;
        if (ref == null || mediaId is! String || plain == null) {
          clip.remove(part);
          continue;
        }
        await media.saveBytes(mediaId, await seal.seal(plain));
        clip[part] = ref;
      }
    }
    return (event: event, clip: clip);
  }

  /// [mediaId]'s sealed bytes, fetched first if they aren't here; null
  /// when they can't be had.
  static Future<Uint8List?> _read(
    MediaStore media,
    String clipId,
    String mediaId,
    Future<void> Function(String clipId, String mediaId)? fetchMissing,
  ) async {
    Future<Uint8List> read() async {
      final bytes = await media.read(mediaId);
      final builder = BytesBuilder(copy: false);
      await for (final chunk in bytes.stream) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    }

    try {
      return await read();
    } catch (_) {
      if (fetchMissing == null) return null;
      try {
        await fetchMissing(clipId, mediaId);
        return await read();
      } catch (_) {
        return null;
      }
    }
  }

  static Uint8List? _bytes(Object? value) => switch (value) {
    final Uint8List b => b,
    final List l when l.every((b) => b is int) => Uint8List.fromList(
      l.cast<int>(),
    ),
    _ => null,
  };

  static Uint8List? _base64(Object? value) {
    if (value is! String) return null;
    try {
      return base64Decode(value);
    } on FormatException {
      return null;
    }
  }
}

/// A file [EventFile] can't make or take in, and why.
class EventFileException implements Exception {
  const EventFileException(this.message);

  final String message;

  @override
  String toString() => 'EventFileException: $message';
}
