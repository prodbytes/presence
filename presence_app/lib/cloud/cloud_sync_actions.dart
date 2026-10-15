part of 'cloud_sync.dart';

/// What tapping an event's indicators asks of cloud sync, for one event
/// ([EventCopyActions]): put it in the cloud ([put]), delete it from the
/// cloud ([delete]), or have the other devices take a copy ([share]).
class _EventActions {
  _EventActions(this._sync);

  final CloudSync _sync;

  /// Events whose upload is to be published over live sync even when
  /// they're not recent ([share] put them in the cloud first).
  final Set<String> _publishOnUpload = {};

  /// The synced-store key that marks event [id] as deleted from the cloud
  /// here: this device doesn't upload it again until it's put back.
  static String offCloudKey(String id) => 'offcloud:$id';

  /// Whether event [id] was deleted from the cloud here, and not put back.
  static bool isOffCloud(Map<String, String> synced, Object? id) =>
      synced.containsKey(offCloudKey('$id'));

  /// The keys in the folder (not under its prefix) the event [record] may
  /// have objects at, or have had under the old layout: its JSON, its
  /// clip's record, recording and thumbnail, and its tagged [frames].
  static List<String> keysOf(
    Map<String, Object?> record, {
    Iterable<String> frames = const [],
  }) {
    final time = record['time'];
    final clipId = record['clipId'];
    return [
      CloudSync.eventKey(record),
      if (clipId is String) ...[
        CloudSync.clipRecordKey(clipId, time is int ? time : 0),
        ..._recordingKeys(clipId),
        'media/$clipId.jpg',
        for (final f in frames) CloudSync.frameKeyOf(clipId, f),
        // The old layout's, which an upload would take as sent.
        'clips/$clipId.json',
        'clips/$clipId.webm',
        'clips/$clipId.mp4',
        'clips/$clipId.jpg',
        for (final f in frames) 'clips/$clipId/frames/$f.jpg',
      ],
    ];
  }

  /// The signed-in profile's event [id] as stored here, with its clip's
  /// record; null when there's none, or it's another profile's or
  /// deleted.
  Future<(Map<String, Object?>, Map<String, Object?>?)?> _event(
    String id,
  ) async {
    final owner = _sync._owner;
    if (owner == null || !LiveSync.isSafeId(id)) return null;
    final store = await _sync._store;
    final record = await store.getEvent(id);
    if (record == null ||
        AppEvent.profileOf(record) != owner ||
        AppEvent.isDeletedRecord(record)) {
      return null;
    }
    final clipId = record['clipId'];
    return (record, clipId is String ? await store.getClip(clipId) : null);
  }

  /// A session for the signed-in profile's folder; null without one (signed
  /// out, a free profile, syncing stopped).
  Future<CloudSession?> _session() async {
    final idToken = _sync.auth.idToken;
    if (!_sync.premium ||
        idToken == null ||
        _sync.stopped ||
        _sync._halted ||
        _sync._disposed) {
      return null;
    }
    return _sync.backend.connect(idToken);
  }

  /// Forgets what was sent of event [record] so the next pass sends it
  /// all again, and starts one at once. Only for an event this device
  /// holds in full: what isn't here can't go up.
  Future<bool> put(String id) async {
    try {
      final event = await _event(id);
      final session = await _session();
      if (event == null || session == null) return false;
      final (record, clip) = event;
      final store = await _sync._store;
      final synced = _sync._synced ??= await store.syncedKeys();
      final (:self, cloud: _) = _CopyTracker.copyOf(
        record,
        clip: clip,
        synced: synced,
        prefix: session.prefix,
        deviceId: await _sync._deviceId,
      );
      if (!self) return false;
      await _sync._forgetSynced(store, offCloudKey(id));
      for (final key in keysOf(record, frames: _frameIds(record))) {
        final objectKey = '${session.prefix}/$key';
        await _sync._forgetSynced(store, objectKey);
        await _sync._forgetSynced(store, _etagKey(objectKey));
      }
      _sync._onChanged({id});
      return true;
    } catch (e) {
      debugPrint('Presence: could not put $id in the cloud: $e');
      return false;
    }
  }

  /// Deletes event [id]'s objects from the bucket, and marks it as kept
  /// out of it ([offCloudKey]) first, so no pass puts it back meanwhile.
  Future<bool> delete(String id) async {
    try {
      final event = await _event(id);
      final session = await _session();
      if (event == null || session == null) return false;
      final (record, _) = event;
      final store = await _sync._store;
      await _sync._markSynced(store, offCloudKey(id), '1');
      // An upload of it under way finishes first.
      for (
        var up = _sync._uploader.uploadOf(id);
        up != null;
        up = _sync._uploader.uploadOf(id)
      ) {
        await up;
      }
      final clipId = record['clipId'];
      // Every tagged frame in the bucket, even of tags since removed.
      final frames = {
        ..._frameIds(record),
        if (clipId is String)
          for (final k in await session.list('media/$clipId/'))
            if (k.startsWith('media/$clipId/frames/') && k.endsWith('.jpg'))
              k.substring(
                'media/$clipId/frames/'.length,
                k.length - '.jpg'.length,
              ),
      };
      for (final key in keysOf(record, frames: frames)) {
        await session.delete(key);
        final objectKey = '${session.prefix}/$key';
        await _sync._forgetSynced(store, objectKey);
        await _sync._forgetSynced(store, _etagKey(objectKey));
        await _sync._forgetSynced(store, _fetchKey(objectKey));
      }
      await _sync._copyTracker.note({id});
      return true;
    } catch (e) {
      debugPrint('Presence: could not delete $id from the cloud: $e');
      return false;
    }
  }

  /// Publishes event [id] again over live sync, for the other devices to
  /// take: with the ETag it has in the bucket, or once it's uploaded when
  /// it isn't there yet and this device holds it.
  Future<bool> share(String id) async {
    final live = _sync.live;
    if (live == null || !live.enabled) return false;
    try {
      final event = await _event(id);
      if (event == null) return false;
      final (record, clip) = event;
      final store = await _sync._store;
      String? etag;
      if (_sync.premium) {
        final session = await _session();
        if (session == null) return false;
        final synced = _sync._synced ??= await store.syncedKeys();
        final (:self, :cloud) = _CopyTracker.copyOf(
          record,
          clip: clip,
          synced: synced,
          prefix: session.prefix,
          deviceId: await _sync._deviceId,
        );
        if (!cloud) {
          // Up first; the upload publishes it.
          if (!self) return false;
          _publishOnUpload.add(id);
          final put = await this.put(id);
          if (!put) _publishOnUpload.remove(id);
          return put;
        }
        final objectKey = '${session.prefix}/${CloudSync.eventKey(record)}';
        etag = synced[_etagKey(objectKey)];
      }
      return await live.publishEvent(
        (jsonDecode(utf8.decode(_eventJson(record))) as Map)
            .cast<String, Object?>(),
        key: CloudSync.eventKey(record),
        etag: etag,
        // A premium profile's devices take it from the bucket.
        clip: _sync.profilePremium ? null : clip,
      );
    } catch (e) {
      debugPrint('Presence: could not share $id with the other devices: $e');
      return false;
    }
  }
}
