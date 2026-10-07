part of 'cloud_sync.dart';

/// Thrown when a pass is no longer [_Pass.current]: it ends quietly.
class _Abandoned implements Exception {
  const _Abandoned();
}

/// One pass of [CloudSync]: the session it connected with, the store, and
/// the profile ([owner]) it syncs, all as they were when it started. Every
/// step stamps, uploads and imports for [owner] only, and checks [current]
/// first ([check]): once the account signs out, moves to another profile or
/// reconnects, or syncing stops, the pass ends at its next step instead of
/// mixing that profile's data with the next one's.
class _Pass {
  _Pass(this._sync, this.session, this.store, this.owner, this._epoch);

  final CloudSync _sync;
  final CloudSession session;
  final EventStore store;
  final String owner;
  final int _epoch;

  /// Each clip's media keys, as listed once by this pass.
  final Map<String, Set<String>> _mediaKeys = {};

  /// Whether the pass may still go on: its profile still syncs, from the
  /// same start ([CloudSync._epoch]), not stopped, not disposed.
  bool get current =>
      _epoch == _sync._epoch && !_sync.stopped && !_sync._disposed;

  /// Throws [_Abandoned] unless [current].
  void check() {
    if (!current) throw const _Abandoned();
  }

  /// [key], under the profile's folder.
  String objectKey(String key) => '${session.prefix}/$key';

  /// Marks [key] (in the folder) as synced, with [fingerprint].
  Future<void> synced(String key, String fingerprint) {
    check();
    return _sync._markSynced(store, objectKey(key), fingerprint);
  }

  /// Keeps [etag] as [key]'s, as this device last uploaded or downloaded
  /// it.
  Future<void> keepETag(String key, String etag) {
    check();
    return _sync._markSynced(store, _etagKey(objectKey(key)), etag);
  }

  /// A recording in the cloud ([key]): synced (never uploaded back), and
  /// pending here, as [mediaId] of an event at [time], until it's
  /// downloaded.
  Future<void> pending(String key, String mediaId, int time) async {
    await synced(key, mediaId);
    await _sync._markSynced(store, _fetchKey(objectKey(key)), '$time:$mediaId');
  }

  /// Clip [clipId]'s media in the bucket (recording, thumbnail, tagged
  /// frames), listed once per pass.
  Future<Set<String>> mediaKeys(String clipId) async => _mediaKeys[clipId] ??= {
    for (final k in await session.list('media/$clipId'))
      if (k.startsWith('media/$clipId.') || k.startsWith('media/$clipId/')) k,
  };

  /// Lists clips' media afresh from now on.
  void forgetMediaKeys() => _mediaKeys.clear();
}
