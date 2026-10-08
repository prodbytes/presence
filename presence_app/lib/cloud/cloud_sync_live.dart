part of 'cloud_sync.dart';

/// Bridges [CloudSync] and [CloudSync.live]: starts and stops live sync for
/// the profile's identity, and takes the events other devices publish
/// ([_onLive]).
class _LiveBridge {
  _LiveBridge(this._sync);

  final CloudSync _sync;

  /// The identity [CloudSync.live] was started for; null while it's
  /// stopped.
  String? _liveFor;

  void stop() {
    _liveFor = null;
    _sync.live?.stop();
  }

  /// Starts [CloudSync.live] for [session]'s identity, unless it runs for
  /// it already.
  Future<void> start(CloudSession session, String owner) async {
    final live = _sync.live;
    if (live == null || !live.enabled || _liveFor == session.prefix) return;
    if (session.credentials == null) return;
    _liveFor = session.prefix;
    final deviceId = await _sync._deviceId;
    if (_sync._disposed ||
        _sync._owner != owner ||
        _liveFor != session.prefix) {
      return;
    }
    live.start(
      LiveLink(
        identityId: session.prefix,
        deviceId: deviceId,
        credentials: () async {
          final idToken = _sync.auth.idToken;
          if (idToken == null || _sync._owner != owner) {
            throw StateError('signed out');
          }
          final credentials = (await _sync.backend.connect(idToken))
              .credentials;
          if (credentials == null) throw StateError('no credentials');
          return credentials;
        },
        onEvent: (event) => _onLive(event, owner),
        onCopied: _sync._copyTracker.onCopied,
      ),
    );
  }

  /// Takes an event another device of [owner]'s profile published (live
  /// sync): a new one is handed to [CloudSync.onRemote] at once, an update to one the
  /// device has replaces its tags (unless it changed here too and that
  /// isn't uploaded yet: this version wins, as with the bucket). Either is
  /// marked as synced, with the ETag the sender uploaded, so it's neither
  /// uploaded back nor downloaded again. Its clip and tagged frames come
  /// from the bucket: a pass starts for them. A free profile has no
  /// bucket: nothing is marked, its clip comes from the message
  /// ([LiveEvent.clip]) when the sender put it there, and its tagged
  /// frames stay on the device that made them.
  ///
  /// It waits for an upload of the same event a pass is making
  /// ([_Uploader.uploadOf]), so the pass can't put this device's older version
  /// back over it; and once the profile changes, or syncing stops, while
  /// it waits on storage or the network, it takes nothing.
  Future<void> _onLive(LiveEvent message, String owner) async {
    bool current() =>
        !_sync._disposed && _sync._owner == owner && !_sync.stopped;
    if (!current()) return;
    final event = Map.of(message.event);
    // Another profile's: not for this folder.
    if (event['profileId'] case final String profile when profile != owner) {
      return;
    }
    event['profileId'] = owner;
    final time = event['time']! as int;
    final since = _sync._now().toUtc().subtract(_sync._window);
    if (DateTime.fromMillisecondsSinceEpoch(
      time,
      isUtc: true,
    ).isBefore(since)) {
      return;
    }
    final id = event['id']! as String;
    final store = await _sync._store;
    final key = CloudSync.eventKey(event);
    final objectKey = '${message.identityId}/$key';
    for (
      var up = _sync._uploader.uploadOf(id);
      up != null;
      up = _sync._uploader.uploadOf(id)
    ) {
      await up;
    }
    if (!current()) return;
    final synced = _sync._synced ??= await store.syncedKeys();
    final local = await store.getEvent(id);

    final premium = _sync.premium;

    Future<void> settle() async {
      // Free: the bucket holds nothing, so nothing is marked as there.
      if (!premium || !current()) return;
      final stored = await store.getEvent(id);
      if (stored == null || CloudSync.eventKey(stored) != key || !current()) {
        return;
      }
      await _sync._markSynced(
        store,
        objectKey,
        _fingerprint(_eventJson(stored)),
      );
      if (message.etag case final etag?) {
        await _sync._markSynced(store, _etagKey(objectKey), etag);
      }
    }

    final clipId = event['clipId'];
    // A deleted event's clip isn't shown: not wanted.
    final wantsClip =
        clipId is String &&
        !AppEvent.isDeletedRecord(event) &&
        !(await store.clipIds()).contains(clipId);
    if (local == null) {
      if (_sync._handedOver.contains(id)) return;
      // The frames its tags use, if it has any yet.
      final frames = premium
          ? await _liveFrames(event, const {})
          : const <String, Uint8List>{};
      if (frames.isNotEmpty) event['frames'] = frames;
      if (!current()) return;
      await _sync._deliver(RemoteRecords(events: [event], live: true));
      await settle();
    } else {
      if (CloudSync.eventKey(local) != key) return;
      final localJson = _eventJson(local);
      if (_fingerprint(localJson) != _fingerprint(_eventJson(event))) {
        // Changed here, and not uploaded yet: this version goes up; unless
        // the other deletes it, which wins.
        if (synced[objectKey] != _fingerprint(localJson) &&
            !_deletes(event, local)) {
          return;
        }
        final frames = premium
            ? await _liveFrames(event, local)
            : const <String, Uint8List>{};
        if (frames.isNotEmpty) event['frames'] = frames;
        if (!current()) return;
        await _sync._deliver(RemoteRecords(updated: [event], live: true));
      }
      if (_undeletes(event, local)) {
        // A copy that isn't deleted, of an event deleted here: it stays
        // deleted ([Persistence.updateFromRemote]), and goes up again so.
        if (message.etag case final etag?) {
          await _sync._markSynced(store, _etagKey(objectKey), etag);
        }
        await _sync._forgetSynced(store, objectKey);
        _sync._dirty.add(id);
        _sync._schedule();
      } else {
        await settle();
      }
    }
    if (clipId is String && wantsClip && current()) {
      if (premium) {
        _sync._fetcher.want(clipId, time);
        _sync._schedule(immediately: true);
      } else if (message.clip case final clip?) {
        // Free: the clip as the sender put it in the message.
        await _sync._deliver(RemoteRecords(clips: [clip], live: true));
      }
    }
    if (current()) _sync._copyTracker.note({id}).ignore();
  }

  /// Whether [remote], a copy of the event [local] stored here, deletes it.
  static bool _deletes(
    Map<String, Object?> remote,
    Map<String, Object?> local,
  ) => AppEvent.isDeletedRecord(remote) && !AppEvent.isDeletedRecord(local);

  /// Whether [remote] is a copy that isn't deleted of the event [local],
  /// deleted here.
  static bool _undeletes(
    Map<String, Object?> remote,
    Map<String, Object?> local,
  ) => _deletes(local, remote);

  /// The frames [event]'s tags use that [local] (its record here) lacks,
  /// from the bucket; none that aren't there yet.
  Future<Map<String, Uint8List>> _liveFrames(
    Map<String, Object?> event,
    Map<String, Object?> local,
  ) async {
    final have = local['frames'] is Map ? local['frames']! as Map : const {};
    final missing = [
      for (final frameId in _frameIds(event))
        if (!have.containsKey(frameId) && LiveSync.isSafeId(frameId)) frameId,
    ];
    final idToken = _sync.auth.idToken;
    if (missing.isEmpty || idToken == null) return const {};
    final frames = <String, Uint8List>{};
    try {
      final session = await _sync.backend.connect(idToken);
      final store = await _sync._store;
      for (final frameId in missing) {
        final frameKey = CloudSync.frameKeyOf('${event['clipId']}', frameId);
        try {
          frames[frameId] = await session.get(frameKey);
          await _sync._markSynced(
            store,
            '${session.prefix}/$frameKey',
            frameId,
          );
        } catch (e) {
          debugPrint('Presence: live sync could not get frame $frameId: $e');
        }
      }
    } catch (e) {
      debugPrint('Presence: live sync could not get frames: $e');
    }
    return frames;
  }
}
