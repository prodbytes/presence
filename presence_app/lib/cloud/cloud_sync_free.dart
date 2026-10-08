part of 'cloud_sync.dart';

/// Syncing a free profile ([CloudSync.premium] false): no bucket, only live
/// sync. Each event the profile saves here is published to its other
/// devices with its clip's record and thumbnail ([LiveSync.publishEvent]),
/// once per version of the event and of its clip (`live/<event id>` in the
/// synced store), and those devices store it as if fetched. Recordings,
/// tagged frames, settings and history stay on the device that made them:
/// a device only hears what's published while it's connected (or what its
/// persistent session kept, on a schedule).
class _LivePublisher {
  _LivePublisher(this._sync);

  final CloudSync _sync;

  /// How far back a reconciliation (the first pass for a profile, or a
  /// change notification that doesn't say what changed) publishes events
  /// not published yet: other devices only take what they'd show as new.
  static const Duration reconcileWindow = Duration(days: 1);

  /// The synced-store key remembering what was published of event [id].
  static String keyOf(String id) => 'live/$id';

  /// Publishes the profile's events [only] names (all of the last
  /// [reconcileWindow] when null) that changed since they were published:
  /// new ones, and those whose clip completed since. One that can't be sent
  /// now (live sync off, or not connected in time) is tried again at the
  /// next pass.
  Future<void> publish(String owner, int epoch, Iterable<String>? only) async {
    final live = _sync.live;
    if (live == null || !live.enabled) return;
    final store = await _sync._store;
    final synced = _sync._synced ??= await store.syncedKeys();
    final now = _sync._now().toUtc().millisecondsSinceEpoch;
    final List<Map<String, Object?>> events;
    if (only == null) {
      events = [
        for (final record in await store.allEvents())
          if (record['id'] is String &&
              AppEvent.profileOf(record) == owner &&
              record['time'] is int &&
              now - (record['time']! as int) < reconcileWindow.inMilliseconds)
            record,
      ];
    } else {
      events = [];
      for (final id in only) {
        final record = await store.getEvent(id);
        if (record != null && AppEvent.profileOf(record) == owner) {
          events.add(record);
        }
      }
    }
    for (final record in events) {
      await _sync._breathe();
      if (epoch != _sync._epoch || _sync._disposed) return;
      final id = record['id']! as String;
      final time = record['time'];
      // Recent events only, as with the bucket's uploads.
      if (time is! int || now - time >= _sync._window.inMilliseconds) {
        continue;
      }
      final clipId = record['clipId'];
      final clip = clipId is String ? await store.getClip(clipId) : null;
      final json = _eventJson(record);
      // Published again when the event changes, or its clip completes.
      final version =
          '${_fingerprint(json)}:${clip?['state'] == 'complete' ? clipId : ''}';
      if (synced[keyOf(id)] == version) continue;
      final sent = await live.publishEvent(
        (jsonDecode(utf8.decode(json)) as Map).cast<String, Object?>(),
        key: CloudSync.eventKey(record),
        clip: clip,
      );
      if (!sent || epoch != _sync._epoch) continue;
      await _sync._markSynced(store, keyOf(id), version);
    }
  }
}
