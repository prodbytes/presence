part of 'cloud_sync.dart';

/// Syncing a free profile ([CloudSync.premium] false): no bucket, only live
/// sync, every 15 min. Live sync's scheduled connections (at start, at
/// sign-in, then every 15 min; `LiveLink.onShare`) publish the events the
/// profile saved here since the last one to its other devices, each
/// **once** (`live/<event id>` in the synced store), when it's final: its
/// clip complete (or failed), with the clip's record and a thumbnail of at
/// most 12 KB ([LiveSync.publishEvent]); those devices store it as if
/// fetched. A later change to an event isn't sent again. Recordings,
/// tagged frames, settings and history stay on the device that made them:
/// a device hears what its persistent session kept while it was away (1 h
/// at AWS IoT's default) at its next connection.
class _LivePublisher {
  _LivePublisher(this._sync);

  final CloudSync _sync;

  /// How far back a reconciliation (the first pass for a profile, or a
  /// change notification that doesn't say what changed) publishes events
  /// not published yet: other devices only take what they'd show as new.
  static const Duration reconcileWindow = Duration(days: 1);

  /// The synced-store key remembering what was published of event [id].
  static String keyOf(String id) => 'live/$id';

  /// An event whose clip has no record yet is final after this (its clip
  /// was never saved, or deleted).
  static const Duration clipGrace = Duration(minutes: 10);

  /// Publishes the profile's events [only] names (all of the last
  /// [reconcileWindow] when null) not published yet that are final (no
  /// clip, or its clip complete or failed). One that can't be sent now
  /// (live sync off, or not connected) is tried at the next connection.
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
      // Once: never again, whatever changes.
      if (synced[keyOf(id)] != null) continue;
      final clipId = record['clipId'];
      final clip = clipId is String ? await store.getClip(clipId) : null;
      // Final only: a clip still recording waits for the next connection.
      if (clipId is String) {
        final state = clip?['state'];
        final waiting = clip == null
            ? now - time < clipGrace.inMilliseconds
            : state != 'complete' && state != 'failed';
        if (waiting) continue;
      }
      final json = _eventJson(record);
      final sent = await live.publishEvent(
        (jsonDecode(utf8.decode(json)) as Map).cast<String, Object?>(),
        key: CloudSync.eventKey(record),
        clip: clip,
      );
      if (!sent || epoch != _sync._epoch) continue;
      await _sync._markSynced(store, keyOf(id), 'sent');
    }
  }
}
