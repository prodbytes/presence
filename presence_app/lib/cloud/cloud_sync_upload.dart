part of 'cloud_sync.dart';

/// What a pass sends up to the bucket ([syncAll]), and the events it
/// publishes over live sync as they go up.
class _Uploader {
  _Uploader(this._sync);

  final CloudSync _sync;

  /// Events whose upload (frames and JSON) runs now, by ID: an event
  /// arriving over live sync meanwhile waits for it
  /// ([_LiveBridge._onLive]).
  final Map<String, Future<void>> _eventUploads = {};

  /// The upload of event [id] running now, if any.
  Future<void>? uploadOf(String id) => _eventUploads[id];

  /// Uploads what isn't in the cloud yet: the settings, and of the
  /// profile's events either those in [only] (the ones saved since the
  /// last pass) or, when null, all of them (a reconciliation), with the
  /// clips (recording, thumbnail, details) and tagged frames they show.
  ///
  /// Only while [pass] is current: each upload checks first, so a pass
  /// that outlives its profile (signed out, another profile) uploads
  /// nothing more. A stored record that can't be read is skipped.
  Future<void> syncAll(_Pass pass, Set<String>? only) async {
    final session = pass.session;
    final store = pass.store;
    final owner = pass.owner;
    final media = await _sync._media;
    final synced = _sync._synced ??= await store.syncedKeys();

    // Uploads [key] unless it's in the cloud already; returns the ETag of
    // what it uploaded (null for none, or a recording).
    Future<String?> upload(
      String key,
      String fingerprint,
      Future<Uint8List> Function()? bytes,
      String contentType, {
      String? mediaId,
      String? was,
      bool keepETag = false,
    }) async {
      pass.check();
      final objectKey = pass.objectKey(key);
      if (synced[objectKey] == fingerprint) return null;
      // Uploaded before under the old layout ([was]): not again, so what
      // was deleted from the bucket stays deleted.
      if (was != null && synced['${session.prefix}/$was'] == fingerprint) {
        await _sync._markSynced(store, objectKey, fingerprint);
        return null;
      }
      String? etag;
      if (mediaId != null) {
        // A recording: streamed from storage, not held or hashed whole.
        final recording = await media.read(mediaId);
        await session.putStream(
          key,
          recording.stream,
          recording.length,
          contentType,
        );
      } else {
        final body = await bytes!();
        await session.put(key, body, contentType);
        etag = CloudSync.etagOf(body);
        if (keepETag) await _sync._markSynced(store, _etagKey(objectKey), etag);
      }
      await _sync._markSynced(store, objectKey, fingerprint);
      _sync._countUpload();
      return etag;
    }

    // This device's settings (tiny, and whenever they changed).
    if (_sync.settings case final settings?) {
      final record = await settings.settingsRecord();
      final json = _json(record);
      await upload(
        CloudSync.settingsKey(record['deviceId']! as String),
        _fingerprint(json),
        () async => json,
        'application/json',
      );
    }

    // Only the profile's events, and the clips they show.
    final events = <Map<String, Object?>>[];
    final clips = <Map<String, Object?>>[];
    if (only == null) {
      for (final record in await store.allEvents()) {
        if (record['id'] is String && AppEvent.profileOf(record) == owner) {
          events.add(record);
        }
      }
      final eventIds = {for (final e in events) e['id']};
      for (final clip in await store.allClips()) {
        if (eventIds.contains(clip['eventId'])) clips.add(clip);
      }
    } else {
      for (final id in only) {
        final record = await store.getEvent(id);
        if (record == null || AppEvent.profileOf(record) != owner) continue;
        events.add(record);
        clips.addAll(await store.clipsOfEvent(id));
      }
    }
    // A clip's record goes in its event's day partition, where a fetch
    // looks for it.
    final eventTimes = {
      for (final e in events)
        if (e['time'] case final int time) e['id']: time,
    };

    // Clips first: recordings matter most.
    for (final clip in clips) {
      await _sync._breathe();
      // Read through the codec (a damaged record is skipped); uploaded as
      // stored.
      final parsed = Records.tryParseClip(clip, safeIds: true);
      if (parsed == null) continue;
      final id = parsed['id']! as String;
      if (parsed['state'] != 'complete') continue;
      final ref = parsed['full'] ?? parsed['past'];
      if (ref is Map) {
        final mediaId = ref['mediaId']! as String;
        final mimeType = ref['mimeType'] as String? ?? 'video/webm';
        final ext = _extOf(mimeType);
        // Sealed: its type is in the clip's record, not on the object.
        try {
          await upload(
            'media/$id.$ext',
            mediaId,
            null,
            CloudSync.sealedType,
            mediaId: mediaId,
            was: 'clips/$id.$ext',
          );
        } on SealBroken {
          // Never up unsealed ([MediaStore.read] refuses it).
          debugPrint('Presence: not uploading recording $mediaId: unsealed');
        }
      }
      final thumbnail = clip['thumbnail'];
      if (thumbnail is List && thumbnail.isNotEmpty) {
        final bytes = thumbnail is Uint8List
            ? thumbnail
            : Uint8List.fromList(thumbnail.cast<int>());
        // Images only ever go up sealed.
        if (SealFormat.isSealed(bytes)) {
          await upload(
            'media/$id.jpg',
            'thumbnail',
            () async => bytes,
            CloudSync.sealedType,
            was: 'clips/$id.jpg',
          );
        }
      }
      final details = _json({
        for (final MapEntry(:key, :value) in clip.entries)
          if (key != 'thumbnail') key: value,
      });
      final requestedAt = clip['requestedAt'];
      await upload(
        CloudSync.clipRecordKey(
          id,
          eventTimes[clip['eventId']] ?? (requestedAt is int ? requestedAt : 0),
        ),
        _fingerprint(details),
        () async => details,
        'application/json',
        was: 'clips/$id.json',
      );
    }

    // Events uploaded now: the cloud holds them.
    final uploadedEvents = <String>{};
    for (final snapshot in events) {
      await _sync._breathe();
      pass.check();
      final id = snapshot['id']! as String;
      // While it goes up, an event arriving over live sync waits for it.
      final uploading = Completer<void>();
      _eventUploads[id] = uploading.future;
      Map<String, Object?>? published;
      Map<String, Object?>? publishedClip;
      String? publishedKey;
      String? etag;
      try {
        // As stored now, not as listed when the pass started: the clips
        // took time, and live sync may have taken a newer version from
        // another device meanwhile (and marked it as synced). Uploading
        // the listed one would put the older version back.
        final record = await store.getEvent(id);
        if (record == null || AppEvent.profileOf(record) != owner) continue;
        // Tagged frames go up as images next to the clip; the event's
        // JSON keeps the tags (name, position, frame id and time) without
        // them.
        final frames = record['frames'];
        if (frames is Map) {
          for (final MapEntry(:key, :value) in frames.entries) {
            final jpeg = value is Uint8List
                ? value
                : (value is List
                      ? Uint8List.fromList(value.cast<int>())
                      : null);
            // Images only ever go up sealed.
            if (jpeg == null || !SealFormat.isSealed(jpeg)) continue;
            await upload(
              CloudSync.frameKeyOf('${record['clipId']}', '$key'),
              '$key',
              () async => jpeg,
              CloudSync.sealedType,
              was: 'clips/${record['clipId']}/frames/$key.jpg',
            );
          }
        }
        final json = _eventJson(record);
        final key = CloudSync.eventKey(record);
        etag = await upload(
          key,
          _fingerprint(json),
          () async => json,
          'application/json',
          keepETag: true,
        );
        if (etag != null) uploadedEvents.add(id);
        // Then the profile's other devices hear of it at once (live
        // sync): recent events only, not a reconciliation's old ones.
        final time = record['time'];
        if (etag != null &&
            time is int &&
            _sync._now().millisecondsSinceEpoch - time <
                _sync._window.inMilliseconds) {
          published = (jsonDecode(utf8.decode(json)) as Map)
              .cast<String, Object?>();
          publishedKey = key;
          // Its clip goes along, for the profile's devices without the
          // bucket (an account linked to a free owner's profile).
          if (record['clipId'] case final String clipId) {
            publishedClip = await store.getClip(clipId);
          }
        }
      } finally {
        if (_eventUploads[id] == uploading.future) _eventUploads.remove(id);
        uploading.complete();
      }
      // Not holding up received events: a scheduled connection may take
      // a while to send it.
      if ((_sync.live, published, publishedKey, etag)
          case (final live?, final event?, final key?, final etag?)
          when pass.current) {
        await live.publishEvent(
          event,
          key: key,
          etag: etag,
          clip: publishedClip,
        );
      }
    }
    _sync._copyTracker.note(uploadedEvents).ignore();
  }
}
