part of 'cloud_sync.dart';

/// Fetched clips' recordings: noted as pending by a fetch, they come down
/// only when wanted: when played ([fetchRecording]), or when another
/// device asks for a copy ([fetchPending]). Never all of them in the
/// background: each device downloading every other device's recordings
/// was most of a profile's AWS bill (S3 data transfer out).
class _Recordings {
  _Recordings(this._sync);

  final CloudSync _sync;

  /// Recordings being downloaded now, by object key: one download each.
  final Map<String, Future<bool>> _inFlight = {};

  /// Downloads the recording at [key] into the `MediaStore` as [mediaId],
  /// and marks it as synced and no longer pending. Once at a time per key.
  Future<bool> _download(CloudSession session, String key, String mediaId) {
    final objectKey = '${session.prefix}/$key';
    return _inFlight[objectKey] ??= () async {
      try {
        final store = await _sync._store;
        final bytes = await session.get(key);
        try {
          await (await _sync._media).saveBytes(mediaId, bytes);
        } on SealBroken {
          // Not sealed (an older version's): never taken, nor asked again.
          debugPrint('Presence: skipped $key: not sealed');
          await store.unmarkSynced(_fetchKey(objectKey));
          _sync._synced?.remove(_fetchKey(objectKey));
          return false;
        }
        await _sync._markSynced(store, objectKey, mediaId);
        await store.unmarkSynced(_fetchKey(objectKey));
        _sync._synced?.remove(_fetchKey(objectKey));
        // Its event is held here now.
        if (_recordingKey.firstMatch(key)?[1] case final clipId?) {
          if ((await store.getClip(clipId))?['eventId'] case final String id) {
            _sync._copyTracker.note({id}).ignore();
          }
        }
        return true;
      } finally {
        _inFlight.remove(objectKey);
      }
    }();
  }

  /// Downloads the recording [mediaId] of clip [clipId] from the signed-in
  /// profile's folder into the `MediaStore`, for playing a clip fetched
  /// from the cloud whose recording isn't here yet. Returns whether it's
  /// stored now; false when signed out, or it isn't in the cloud, or the
  /// download failed.
  Future<bool> fetchRecording(String clipId, String mediaId) async {
    final idToken = _sync.auth.idToken;
    if (_sync._owner == null ||
        idToken == null ||
        _sync.stopped ||
        _sync._disposed) {
      return false;
    }
    try {
      var session = await _sync.backend.connect(idToken);
      if (!Records.isSafeId(clipId)) return false;
      final candidates = _recordingKeys(clipId);
      final synced = _sync._synced ??= await (await _sync._store).syncedKeys();
      final key =
          candidates
              .where(
                (k) => synced.containsKey(_fetchKey('${session.prefix}/$k')),
              )
              .firstOrNull ??
          (await session.list('media/$clipId.'))
              .where(candidates.contains)
              .firstOrNull;
      if (key == null) return false;
      try {
        return await _download(session, key, mediaId);
      } on S3Exception catch (e) {
        if (!e.credentialsRejected && !e.clockSkewed) rethrow;
        if (e.credentialsRejected) _sync.backend.reset();
        session = await _sync.backend.connect(idToken);
        return await _download(session, key, mediaId);
      }
    } catch (e) {
      debugPrint('Presence: could not download recording of $clipId: $e');
      return false;
    }
  }

  /// Downloads clip [clipId]'s recording if it's pending here (its clip
  /// fetched, the recording not yet): another device asked for a copy.
  Future<void> fetchPending(String clipId) async {
    final prefix = _sync._identity;
    if (prefix == null) return;
    final synced = _sync._synced ??= await (await _sync._store).syncedKeys();
    for (final key in _recordingKeys(clipId)) {
      final value = synced[_fetchKey('$prefix/$key')];
      if (value == null) continue;
      await fetchRecording(clipId, value.substring(value.indexOf(':') + 1));
      return;
    }
  }
}
