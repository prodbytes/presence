part of 'cloud_sync.dart';

/// Keeps [CloudSync.copies] up to date: whether this device and the cloud
/// hold each event ([note]), and other devices' `copied` acks over live
/// sync ([onCopied]).
class _CopyTracker {
  _CopyTracker(this._sync);

  final CloudSync _sync;

  /// Copy checks ([note]), one after another.
  Future<void> _checks = Future.value();

  /// Completes when the copy checks asked for so far are done.
  Future<void> get checks => _checks;

  /// Another device holds copies of events.
  void onCopied(CopiedMessage ack) {
    for (final id in ack.eventIds) {
      _sync.copies.addDevice(id, ack.deviceId, ack.sentAt);
    }
  }

  /// Finds out again whether this device and the cloud hold the events
  /// [ids] ([_check]; all of the window's with null), after the ones
  /// asked before.
  Future<void> note(Iterable<String>? ids) {
    final todo = ids == null
        ? null
        : {
            for (final id in ids)
              if (LiveSync.isSafeId(id)) id,
          };
    if ((todo != null && todo.isEmpty) || _sync._disposed) return _checks;
    return _checks = _checks.then((_) => _check(todo)).catchError((Object e) {
      debugPrint('Presence: could not check event copies: $e');
    });
  }

  /// Records whether this device and the cloud hold each of the events
  /// [ids] ([copyOf]), or with [ids] null each of the profile's events
  /// from the window (at a full fetch). Events this device now holds that
  /// another device recorded, and that it hasn't said so of yet, are acked
  /// over [CloudSync.live] ([LiveSync.ackCopied]).
  Future<void> _check(Set<String>? ids) async {
    if (_sync._disposed) return;
    final store = await _sync._store;
    final synced = _sync._synced ??= await store.syncedKeys();
    final me = await _sync._deviceId;
    final prefix = _sync._identity;
    final owner = _sync._owner;
    final records = <Map<String, Object?>>[];
    if (ids == null) {
      final since = _sync
          ._now()
          .toUtc()
          .subtract(_sync._window)
          .millisecondsSinceEpoch;
      for (final record in await store.allEvents()) {
        final time = record['time'];
        if (time is! int || time < since) continue;
        // Settled already: held here and in the cloud, and acked (or
        // recorded here). Its clip isn't read again.
        final known = _sync.copies.of('${record['id']}');
        if (known != null &&
            known.self &&
            known.cloud &&
            (known.acked || record['deviceId'] == me) &&
            !AppEvent.isDeletedRecord(record)) {
          continue;
        }
        records.add(record);
      }
    } else {
      for (final id in ids) {
        if (await store.getEvent(id) case final record?) records.add(record);
      }
    }
    final toAck = <String>[];
    for (final record in records) {
      await _sync._breathe(50);
      if (_sync._disposed) return;
      final id = record['id'];
      if (id is! String) continue;
      // Deleted (hidden): neither counted nor acked.
      if (AppEvent.isDeletedRecord(record)) {
        _sync.copies.forget(id);
        continue;
      }
      final clipId = record['clipId'];
      final clip = clipId is String ? await store.getClip(clipId) : null;
      final (:self, :cloud) = copyOf(
        record,
        clip: clip,
        synced: synced,
        prefix: prefix,
        deviceId: me,
      );
      _sync.copies.setLocal(id, self: self, cloud: cloud);
      final origin = record['deviceId'];
      if (self &&
          origin is String &&
          origin != me &&
          owner != null &&
          AppEvent.profileOf(record) == owner &&
          !(_sync.copies.of(id)?.acked ?? false)) {
        toAck.add(id);
      }
    }
    final live = _sync.live;
    if (toAck.isEmpty || live == null) return;
    // Not holding up the next checks: a scheduled connection may take a
    // while to send them.
    live.ackCopied(toAck).then((sent) {
      if (sent && !_sync._disposed) _sync.copies.markAcked(toAck);
    }).ignore();
  }

  /// Whether this device ([self]) and the cloud hold a full copy of the
  /// event [record]: the event, the frames its tags use, and its clip
  /// ([clip], its record here) with the recording. An event without a clip
  /// is held with its record (and frames). [synced] is the synced-keys
  /// store, [prefix] the profile's folder, [deviceId] this device's.
  ///
  /// - This device: an event it recorded is always held here (its clip,
  ///   even while recording, is all there is of it). Another device's is
  ///   held once its frames are here and its clip's record is, with the
  ///   recording downloaded (not pending, `fetch:`), unless the clip failed
  ///   there (then there's no recording to have).
  /// - The cloud: the event's JSON is in the bucket (uploaded or fetched),
  ///   with its frames and, for a clip, its recording (uploaded, or seen
  ///   there by a fetch). Not while the clip is still recording.
  static ({bool self, bool cloud}) copyOf(
    Map<String, Object?> record, {
    Map<String, Object?>? clip,
    required Map<String, String> synced,
    required String? prefix,
    required String deviceId,
  }) {
    final mine = record['deviceId'] == deviceId;
    final clipId = record['clipId'];
    final frames = record['frames'];
    final frameIds = _frameIds(record).toList();
    bool inCloud(String key) =>
        prefix != null && synced.containsKey('$prefix/$key');
    final framesHere = frameIds.every(
      (f) => frames is Map && frames.containsKey(f),
    );
    final framesUp =
        clipId is! String ||
        frameIds.every((f) => inCloud(CloudSync.frameKeyOf(clipId, f)));
    final eventUp = inCloud(CloudSync.eventKey(record));
    if (clipId is! String) {
      return (self: mine || framesHere, cloud: eventUp && framesUp);
    }
    final recordings = _recordingKeys(clipId);
    final recordingUp = recordings.any(inCloud);
    final state = clip?['state'];
    if (state == 'failed') {
      return (self: mine || framesHere, cloud: eventUp && framesUp);
    }
    if (mine) {
      return (
        self: true,
        cloud: state == 'complete' && eventUp && framesUp && recordingUp,
      );
    }
    final cloud = eventUp && framesUp && recordingUp;
    if (clip == null || state != 'complete') return (self: false, cloud: cloud);
    final ref = clip['full'] ?? clip['past'];
    final recordingHere =
        ref is! Map ||
        (recordingUp &&
            !recordings.any(
              (k) => prefix != null && synced.containsKey('fetch:$prefix/$k'),
            ));
    return (self: framesHere && recordingHere, cloud: cloud);
  }
}
