part of 'cloud_sync.dart';

/// What a pass brings down from the bucket: new and changed events with
/// their clips and tagged frames ([fetch]), the clips other devices' events
/// still want ([fetchWanted]), and this device's settings
/// ([fetchSettings]).
class _Fetcher {
  _Fetcher(this._sync);

  final CloudSync _sync;

  /// Objects in the bucket that couldn't be used (not JSON, no ID or time,
  /// an unsafe ID), by object key, with their listed ETag: skipped (and
  /// logged once) until they change, rather than failing every pass.
  final Map<String, String> _damaged = {};

  /// Clips of events that arrived over live sync (or changed in the
  /// bucket) that the device doesn't have, by ID, with their events' times
  /// and a serial number ([want]): the next pass looks for them in the
  /// bucket. One stays wanted until it's fetched or found missing there
  /// (it's wanted again when its event changes, and at each full fetch);
  /// one whose fetch fails is tried again at the next pass, up to
  /// [_maxWantedTries] times.
  final Map<String, ({int time, int serial})> _wantedClips = {};
  int _wantSerial = 0;

  /// Failed fetches of wanted clips, by clip ID, since they were wanted.
  final Map<String, int> _wantedFailures = {};
  static const int _maxWantedTries = 5;

  /// Forgets what was damaged and wanted, as for a new user.
  void reset() {
    _damaged.clear();
    _wantedClips.clear();
    _wantedFailures.clear();
  }

  /// What a pass lists under the user's folder: all of `events/` on the
  /// [first] pass, every day of the [CloudSync.restoreWindow] on a [full] one, and
  /// otherwise today's and yesterday's partitions (UTC).
  List<String> prefixes(
    DateTime now, {
    required bool first,
    required bool full,
  }) {
    if (first) return const ['events/'];
    final days = full ? _sync._window.inDays : 1;
    return [
      for (var d = 0; d <= days; d++)
        _dayPrefix(now.subtract(Duration(days: d))),
    ];
  }

  /// Downloads the events under [prefixes] that the device doesn't have,
  /// from the last [CloudSync.restoreWindow] and at most [CloudSync.maxFetch] of them (the
  /// newest first), with their clips (recording and thumbnail) and tagged
  /// frames, marks them as synced, and hands them to [CloudSync.onRemote]. Event keys
  /// are partitioned by day, so older events aren't even read.
  ///
  /// Events the device has that another device changed since (their ETag
  /// isn't the one this device last uploaded or downloaded) are downloaded
  /// again, within the same [CloudSync.maxFetch], and handed over as
  /// [RemoteRecords.updated]; unless they changed here too and that isn't
  /// uploaded yet: then this device's version goes up over the other.
  ///
  /// An object that can't be used (not JSON, no ID or time, an unsafe ID,
  /// or another ID than its key's) is skipped and logged, and not read
  /// again until it changes ([_damaged]); the rest go on.
  Future<void> fetch(_Pass pass, List<String> prefixes) async {
    final session = pass.session;
    final store = pass.store;
    final listed = <String, String>{
      for (final under in prefixes) ...await session.listETags(under),
    };
    pass.check();
    // Only the IDs: records are read one by one, when needed.
    final localEvents = await store.eventIds();
    final localClips = await store.clipIds();
    final syncedKeys = _sync._synced ??= await store.syncedKeys();
    final since = _sync._now().toUtc().subtract(_sync._window);
    bool damaged(String key) {
      final etag = _damaged[pass.objectKey(key)];
      return etag != null && etag == listed[key];
    }

    // Partitioned keys (events/year=YYYY/day=DDD/<id>.json), and flat ones
    // from before partitioning (events/<id>.json). The newest day first:
    // the zero-padded partitions sort by date.
    final missing = [
      for (final key in listed.keys)
        if (_eventIdOf(key) case final id?
            when !localEvents.contains(id) &&
                _partitionMayBeSince(key, since) &&
                !damaged(key))
          key,
    ]..sort((a, b) => b.compareTo(a));

    // Changed elsewhere: only at the key this device uploads the event to
    // (not a copy left under the layout from before partitioning).
    final changed = <String>[];
    // Of those, the ones changed here too and not uploaded yet: taken only
    // if the other copy deletes them (deletion wins).
    final changedHereToo = <String>{};
    for (final MapEntry(:key, value: etag) in listed.entries) {
      await _sync._breathe(200);
      final id = _eventIdOf(key);
      if (id == null || !localEvents.contains(id)) continue;
      if (!_partitionMayBeSince(key, since) || damaged(key)) continue;
      final objectKey = pass.objectKey(key);
      if (syncedKeys[_etagKey(objectKey)] == etag) continue;
      final local = await store.getEvent(id);
      if (local == null || CloudSync.eventKey(local) != key) continue;
      final json = _eventJson(local);
      if (CloudSync.etagOf(json) == etag) {
        // The same bytes (uploaded before ETags were kept).
        await pass.keepETag(key, etag);
        continue;
      }
      // Changed here and not uploaded yet: this version wins, unless the
      // other deletes it (an event deleted here needs nothing from it).
      if (syncedKeys[objectKey] != _fingerprint(json)) {
        if (AppEvent.isDeletedRecord(local)) continue;
        changedHereToo.add(key);
      }
      changed.add(key);
    }
    changed.sort((a, b) => b.compareTo(a));

    // Hands a batch over, and counts it; who holds them is checked once
    // they're all in (and marked as synced).
    final delivered = <String>{};
    Future<void> deliver(RemoteRecords records) {
      for (final e in [...records.events, ...records.updated]) {
        if (e['id'] case final String id) delivered.add(id);
      }
      return _sync._deliver(records, pass);
    }

    // The new events, a batch at a time, newest first.
    var kept = 0;
    final todo = missing.take(_sync.maxFetch).toList();
    for (var i = 0; i < todo.length; i += _sync.fetchBatch) {
      pass.check();
      final batch = todo.sublist(i, min(i + _sync.fetchBatch, todo.length));
      final (events, clips) = await _fetchNew(
        pass,
        batch,
        listed,
        since: since,
        localClips: localClips,
      );
      kept += events.length;
      await deliver(RemoteRecords(events: events, clips: clips));
    }

    // Then the changed ones, with the frames their tags use that the
    // device doesn't have.
    final changedTodo = changed.take(max(0, _sync.maxFetch - kept)).toList();
    for (var i = 0; i < changedTodo.length; i += _sync.fetchBatch) {
      pass.check();
      final updated = <Map<String, Object?>>[];
      final updatedETags = <String, String>{};
      // Those that aren't deleted there.
      final notDeleted = <String>{};
      for (final key in changedTodo.sublist(
        i,
        min(i + _sync.fetchBatch, changedTodo.length),
      )) {
        pass.check();
        final bytes = await _getOrSkip(session, key);
        if (bytes == null) continue;
        final event = _eventFrom(bytes, key);
        if (event == null) {
          _damaged[pass.objectKey(key)] = listed[key] ?? '';
          continue;
        }
        final deleted = AppEvent.isDeletedRecord(event);
        if (changedHereToo.contains(key) && !deleted) continue;
        if (!deleted) notDeleted.add(key);
        event['profileId'] = pass.owner;
        final local = await store.getEvent(event['id']! as String);
        final have = local?['frames'] is Map ? local!['frames']! as Map : {};
        final frames = <String, Uint8List>{};
        final clipId = event['clipId'];
        for (final frameId in _frameIds(event)) {
          if (have.containsKey(frameId) || clipId is! String) continue;
          final frameKey = CloudSync.frameKeyOf(clipId, frameId);
          if (!(await pass.mediaKeys(clipId)).contains(frameKey)) continue;
          if (await _getOrSkip(session, frameKey) case final frame?) {
            frames[frameId] = frame;
            await pass.synced(frameKey, frameId);
          }
        }
        if (frames.isNotEmpty) event['frames'] = frames;
        updated.add(event);
        updatedETags[key] = CloudSync.etagOf(bytes);
        // Its clip, if it has completed since (not a deleted event's).
        if ((clipId, event['time']) case (final String id, final int time)
            when !localClips.contains(id) && !deleted) {
          want(id, time);
        }
      }
      if (updated.isEmpty) continue;
      await deliver(RemoteRecords(updated: updated));
      // The changed events as the device keeps them now are in sync: not
      // uploaded back, nor downloaded again.
      for (final MapEntry(:key, value: etag) in updatedETags.entries) {
        final id = _eventIdOf(key);
        final record = id == null ? null : await store.getEvent(id);
        if (record == null || CloudSync.eventKey(record) != key) continue;
        await pass.keepETag(key, etag);
        if (AppEvent.isDeletedRecord(record) && notDeleted.contains(key)) {
          // Deleted here, not there: it stays deleted
          // (`Persistence.updateFromRemote`), and goes up again so.
          await _sync._forgetSynced(store, pass.objectKey(key));
          _sync._dirty.add(id!);
          continue;
        }
        await pass.synced(key, _fingerprint(_eventJson(record)));
      }
    }
    _sync._copyTracker.note(delivered).ignore();
  }

  /// Downloads [key], or null when it's gone (deleted since it was
  /// listed): skipped, not a failed pass.
  static Future<Uint8List?> _getOrSkip(CloudSession session, String key) async {
    try {
      return await session.get(key);
    } on S3Exception catch (e) {
      if (e.statusCode != 404) rethrow;
      debugPrint('Presence: $key is gone from the cloud; skipped');
      return null;
    }
  }

  /// The event in [bytes], downloaded from [key]: null (logged) when it
  /// can't be used ([Records.tryParseEvent] with safe IDs), or names
  /// another event than its key.
  static Map<String, Object?>? _eventFrom(Uint8List bytes, String key) {
    final decoded = Records.decode(bytes, what: key);
    if (decoded == null) return null;
    final event = Records.tryParseEvent(decoded, safeIds: true);
    if (event == null) return null;
    if (event['id'] != _eventIdOf(key)) {
      debugPrint('Presence: skipped $key: it holds another event');
      return null;
    }
    return event;
  }

  /// Downloads the events at [keys] (missing here; with their ETags in
  /// [listed]) that are from [since] on, with their tagged frames and
  /// their clips (records and thumbnails). Their recordings are only noted
  /// as pending ([_Pass.pending]): they come down later, so the batch is
  /// handed over without waiting for them.
  Future<(List<Map<String, Object?>>, List<Map<String, Object?>>)> _fetchNew(
    _Pass pass,
    List<String> keys,
    Map<String, String> listed, {
    required DateTime since,
    required Set<String> localClips,
  }) async {
    final store = pass.store;
    final session = pass.session;
    final events = <Map<String, Object?>>[];
    for (final key in keys) {
      pass.check();
      // Arrived over live sync since the listing.
      if (_eventIdOf(key) case final id?
          when await store.getEvent(id) != null) {
        continue;
      }
      final bytes = await _getOrSkip(session, key);
      if (bytes == null) continue;
      final event = _eventFrom(bytes, key);
      if (event == null) {
        _damaged[pass.objectKey(key)] = listed[key] ?? '';
        continue;
      }
      final time = event['time']! as int;
      if (DateTime.fromMillisecondsSinceEpoch(
        time,
        isUtc: true,
      ).isBefore(since)) {
        continue;
      }
      // Events in the profile's folder are the profile's, even from before
      // events had profiles.
      event['profileId'] = pass.owner;
      await pass.synced(key, _fingerprint(_json(event)));
      await pass.keepETag(key, CloudSync.etagOf(bytes));
      // The frames its tags were clicked on come back as images.
      final frames = <String, Uint8List>{};
      final clipId = event['clipId'];
      if (clipId is String) {
        final ofClip = await pass.mediaKeys(clipId);
        for (final frameId in _frameIds(event)) {
          final frameKey = CloudSync.frameKeyOf(clipId, frameId);
          if (!ofClip.contains(frameKey)) continue;
          if (await _getOrSkip(session, frameKey) case final frame?) {
            frames[frameId] = frame;
            await pass.synced(frameKey, frameId);
          }
        }
      }
      if (frames.isNotEmpty) event['frames'] = frames;
      events.add(event);
    }

    // Only the clips those events show. Each clip's record is in its
    // event's day partition (both are timed when the clip was requested).
    final clipTimes = <String, int>{
      for (final e in events)
        if ((e['clipId'], e['time']) case (final String id, final int time)
            when !AppEvent.isDeletedRecord(e))
          id: time,
    };
    final clips = await _fetchClips(pass, clipTimes, localClips: localClips);
    return (events, clips);
  }

  /// Downloads the clips [clipTimes] (by ID, with their events' times)
  /// that the device doesn't have and that are in the bucket: their
  /// records and thumbnails, marked as synced. Their recordings are only
  /// noted as pending ([_Pass.pending]). A clip record that can't be used
  /// ([Records.tryParseClip] with safe IDs, or another clip's) is skipped.
  Future<List<Map<String, Object?>>> _fetchClips(
    _Pass pass,
    Map<String, int> clipTimes, {
    required Set<String> localClips,
  }) async {
    final session = pass.session;
    final clips = <Map<String, Object?>>[];
    for (final MapEntry(key: id, value: time) in clipTimes.entries) {
      pass.check();
      if (localClips.contains(id) || !Records.isSafeId(id)) continue;
      final key = CloudSync.clipRecordKey(id, time);
      if (_damaged.containsKey(pass.objectKey(key))) continue;
      if (!(await session.list(key)).contains(key)) continue;
      final ofClip = await pass.mediaKeys(id);
      final bytes = await _getOrSkip(session, key);
      if (bytes == null) continue;
      final decoded = Records.decode(bytes, what: key);
      final clip = decoded == null
          ? null
          : Records.tryParseClip(decoded, safeIds: true);
      if (clip == null || clip['id'] != id) {
        if (clip != null) debugPrint('Presence: skipped $key: another clip');
        _damaged[pass.objectKey(key)] = CloudSync.etagOf(bytes);
        continue;
      }
      await pass.synced(key, _fingerprint(_json(clip)));
      final ref = clip['full'] ?? clip['past'];
      if (ref is Map) {
        // Safe: [Records.tryParseClip] checked it.
        final mediaId = ref['mediaId']! as String;
        // Where it is, or, for a complete clip whose recording is still
        // going up from its device, where it'll be.
        final video =
            _recordingKeys(id).where(ofClip.contains).firstOrNull ??
            (clip['state'] == 'complete'
                ? 'media/$id.${_extOf(ref['mimeType'] as String?)}'
                : null);
        if (video != null) await pass.pending(video, mediaId, time);
      }
      if (ofClip.contains('media/$id.jpg')) {
        if (await _getOrSkip(session, 'media/$id.jpg') case final jpeg?) {
          clip['thumbnail'] = jpeg;
          await pass.synced('media/$id.jpg', 'thumbnail');
        }
      }
      clips.add(clip);
    }
    return clips;
  }

  /// Wants clip [clipId] (of an event at [time]): the next pass looks for
  /// it ([fetchWanted]). Wanting it again gives it a new serial, so a pass
  /// that found it missing meanwhile doesn't drop the new want.
  void want(String clipId, int time) {
    _wantedClips[clipId] = (time: time, serial: ++_wantSerial);
    _wantedFailures.remove(clipId);
  }

  /// At a full fetch (the first pass for a user, after a restart, and
  /// every [CloudSync.fullFetchEvery]): wants the clips of the profile's events from
  /// the window that the device has no record of (another device's, whose
  /// clip hadn't come when the app closed or a fetch failed), the newest
  /// [CloudSync.maxRewanted]. The device stores its own clips' records as soon as
  /// they're requested, so these are other devices'.
  Future<void> rewantClips(String owner) async {
    final store = await _sync._store;
    final localClips = await store.clipIds();
    final since = _sync
        ._now()
        .toUtc()
        .subtract(_sync._window)
        .millisecondsSinceEpoch;
    final found = <(int, String)>[];
    for (final record in await store.allEvents()) {
      await _sync._breathe(200);
      final clipId = record['clipId'];
      final time = record['time'];
      if (clipId is! String || time is! int || time < since) continue;
      if (localClips.contains(clipId) || _wantedClips.containsKey(clipId)) {
        continue;
      }
      if (AppEvent.profileOf(record) != owner) continue;
      if (AppEvent.isDeletedRecord(record)) continue;
      found.add((time, clipId));
    }
    found.sort((a, b) => b.$1.compareTo(a.$1));
    for (final (time, clipId) in found.take(CloudSync.maxRewanted)) {
      want(clipId, time);
    }
  }

  /// Fetches the clips live sync (or a changed event, or a full fetch)
  /// asked for ([_wantedClips]). One stays wanted until it's here: fetched
  /// now, or found missing in the bucket (still recording on its device;
  /// it's wanted again when its event changes). One whose fetch fails is
  /// tried again at the next pass, at most [_maxWantedTries] times (then at
  /// the next full fetch); its failure doesn't fail the pass, unless the
  /// credentials were rejected (the pass renews them and tries again).
  Future<void> fetchWanted(_Pass pass) async {
    if (_wantedClips.isEmpty) return;
    pass.check();
    final wanted = Map.of(_wantedClips);
    final store = pass.store;
    final localClips = await store.clipIds();
    // Done with one: unless it was wanted again meanwhile.
    void done(String id) {
      if (_wantedClips[id]?.serial == wanted[id]?.serial) {
        _wantedClips.remove(id);
        _wantedFailures.remove(id);
      }
    }

    for (final id in wanted.keys) {
      if (localClips.contains(id)) done(id);
    }
    wanted.removeWhere((id, _) => localClips.contains(id));
    if (wanted.isEmpty) return;
    // Listed afresh: what the fetch listed may have come since.
    pass.forgetMediaKeys();
    final clips = <Map<String, Object?>>[];
    final fetched = <String>[];
    for (final MapEntry(key: id, value: (:time, serial: _)) in wanted.entries) {
      pass.check();
      try {
        clips.addAll(
          await _fetchClips(pass, {id: time}, localClips: localClips),
        );
        // Here now, or not in the bucket (yet), or damaged there.
        fetched.add(id);
      } on _Abandoned {
        rethrow;
      } on S3Exception catch (e) {
        if (e.credentialsRejected || e.clockSkewed) rethrow;
        _wantedFailed(id, e);
      } catch (e) {
        _wantedFailed(id, e);
      }
    }
    await _sync._deliver(RemoteRecords(clips: clips, live: true), pass);
    fetched.forEach(done);
    // Their events may be held here now (or once their recordings come).
    _sync._copyTracker.note([
      for (final c in clips)
        if (c['eventId'] case final String id) id,
    ]).ignore();
  }

  void _wantedFailed(String id, Object e) {
    final failures = _wantedFailures[id] = (_wantedFailures[id] ?? 0) + 1;
    debugPrint('Presence: could not fetch clip $id ($failures tries): $e');
    if (failures >= _maxWantedTries) {
      _wantedClips.remove(id);
      _wantedFailures.remove(id);
    }
  }

  /// Fetches this device's settings, if the cloud has them, and hands them
  /// to [CloudSync.settings] when they're newer than the local ones, or when the
  /// local ones are another profile's: a sign-in restores what the
  /// profile last had on this device. Then the local settings are the
  /// profile's.
  ///
  /// Settings in the cloud that can't be read (not JSON, no config) count
  /// as none: the local ones are uploaded over them.
  Future<void> fetchSettings(_Pass pass) async {
    final settings = _sync.settings;
    if (settings == null) return;
    final session = pass.session;
    final owner = pass.owner;
    final id = await settings.deviceId;
    final key = CloudSync.settingsKey(id);
    // Listed first: a new device has none, and a missing key is an error.
    if ((await session.list('devices/$id/')).contains(key)) {
      final bytes = await _getOrSkip(session, key);
      pass.check();
      if (bytes != null) {
        // Remember what the cloud holds, so local settings that differ
        // from it (older there, or damaged) are uploaded over it.
        await pass.synced(key, _fingerprint(bytes));
        final decoded = Records.decode(bytes, what: key);
        final remote = decoded == null
            ? null
            : Records.tryParseSettings(decoded);
        if (remote != null && remote['deviceId'] == id) {
          final local = await settings.settingsRecord();
          final mine = local['profileId'];
          if ((mine != null && mine != owner) ||
              _updatedAt(remote) > _updatedAt(local)) {
            pass.check();
            await settings.applySettings(remote);
          }
        }
      }
    }
    pass.check();
    await settings.claimSettings(owner);
  }

  static int _updatedAt(Map<String, Object?> record) =>
      Records.intOf(record['updatedAt']) ?? 0;
}
