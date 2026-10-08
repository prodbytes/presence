part of 'cloud_sync.dart';

/// Fetched clips' recordings: noted as pending by a fetch, they come down
/// after it, in the background ([start], with
/// [CloudSync.prefetchRecordings]) or when played ([fetchRecording]).
class _Recordings {
  _Recordings(this._sync);

  final CloudSync _sync;

  /// The background download of pending recordings, while it runs.
  Future<void>? _prefetching;

  /// The background download, while it runs; null otherwise.
  Future<void>? get running => _prefetching;

  /// Recordings being downloaded now, by object key: one download each,
  /// whether in the background or for playing.
  final Map<String, Future<bool>> _inFlight = {};

  /// Recordings the background download failed to get: not tried again
  /// until the next full fetch (one may not be uploaded yet).
  final Set<String> _prefetchFailed = {};

  /// Gives the recordings that failed another try (at a full fetch, or
  /// when syncing starts over).
  void forgetFailures() => _prefetchFailed.clear();

  /// Starts the background download of pending recordings, unless it's
  /// running already or this platform downloads them only when played.
  void start() {
    if (!_sync.prefetchRecordings || _prefetching != null || _sync._disposed) {
      return;
    }
    final owner = _sync._owner;
    if (owner == null) return;
    // Nothing pending (as this sync knows): not even a connection.
    if (!_hasPending(_sync._synced)) return;
    _prefetching = _prefetch(owner)
        .catchError((Object e) {
          debugPrint('Presence: recordings download stopped: $e');
        })
        .whenComplete(() => _prefetching = null);
  }

  /// Downloads the recordings pending for [owner]'s folder, newest first,
  /// one at a time, while [owner] is still the one syncing. One that fails
  /// is skipped (until the next full fetch); a few failures in a row (the
  /// network is down) stop it until the next pass.
  Future<void> _prefetch(String owner) async {
    bool current() =>
        !_sync._disposed && !_sync.stopped && _sync._owner == owner;
    final idToken = _sync.auth.idToken;
    if (idToken == null || !current()) return;
    // Read afresh: entries of events deleted since are gone.
    final synced = await (await _sync._store).syncedKeys();
    if (!_hasPending(synced)) return;
    var session = await _sync.backend.connect(idToken);
    final todo = _pendingIn(synced, session.prefix)
        .where(
          (p) => !_prefetchFailed.contains(
            _fetchKey('${session.prefix}/${p.key}'),
          ),
        )
        .toList();
    var failuresInRow = 0;
    for (final (:key, :mediaId) in todo) {
      if (!current()) return;
      try {
        try {
          await _download(session, key, mediaId);
        } on S3Exception catch (e) {
          if (!e.credentialsRejected && !e.clockSkewed) rethrow;
          // Expired while downloading (or signed at the wrong time, now
          // corrected): new credentials, and this one again with them.
          if (e.credentialsRejected) _sync.backend.reset();
          final token = _sync.auth.idToken;
          if (token == null || !current()) return;
          session = await _sync.backend.connect(token);
          await _download(session, key, mediaId);
        }
        failuresInRow = 0;
      } catch (e) {
        _prefetchFailed.add(_fetchKey('${session.prefix}/$key'));
        debugPrint('Presence: could not download recording $key: $e');
        if (++failuresInRow >= 3) return;
      }
    }
  }

  /// Whether [synced] (all of it when null, not read yet) has recordings
  /// pending download that haven't failed since the last full fetch.
  bool _hasPending(Map<String, String>? synced) =>
      synced == null ||
      synced.keys.any(
        (k) => k.startsWith('fetch:') && !_prefetchFailed.contains(k),
      );

  /// The recordings pending download into [prefix]'s folder (`fetch:`
  /// entries of [synced]), newest first: their keys relative to the
  /// folder, and their media IDs.
  static List<({String key, String mediaId})> _pendingIn(
    Map<String, String> synced,
    String prefix,
  ) {
    final start = _fetchKey('$prefix/');
    final found = <(int, String, String)>[];
    for (final MapEntry(:key, :value) in synced.entries) {
      if (!key.startsWith(start)) continue;
      final colon = value.indexOf(':');
      if (colon < 0) continue;
      found.add((
        int.tryParse(value.substring(0, colon)) ?? 0,
        key.substring(start.length),
        value.substring(colon + 1),
      ));
    }
    found.sort((a, b) => b.$1.compareTo(a.$1));
    return [
      for (final (_, key, mediaId) in found) (key: key, mediaId: mediaId),
    ];
  }

  /// Downloads the recording at [key] into the `MediaStore` as [mediaId],
  /// and marks it as synced and no longer pending. Once at a time per key.
  Future<bool> _download(CloudSession session, String key, String mediaId) {
    final objectKey = '${session.prefix}/$key';
    return _inFlight[objectKey] ??= () async {
      try {
        final store = await _sync._store;
        final bytes = await session.get(key);
        await (await _sync._media).saveBytes(mediaId, bytes);
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
}
