import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:idb_shim/idb_shim.dart';

import '../annotations.dart';
import '../camera_feeds.dart';
import '../cameras/cameras.dart';
import '../clips.dart';
import '../cloud/cloud_sync.dart' show CloudSync, DeviceSettings;
import '../events.dart';
import '../config.dart';
import '../consent/device_consent.dart';
import '../identity/device_id.dart';
import '../location/device_location.dart';
import '../recognition/suggestion.dart';
import 'event_store.dart';
import 'media_platform.dart' as platform;
import 'media_store.dart';

/// Saves everything the app records to IndexedDB, and restores it on launch
/// so the app survives a page refresh:
///
/// - every event published on the bus,
/// - each clip's recordings, first the "before" part and then the full clip
///   (the before-only file is deleted once the full clip is saved),
/// - the cameras clips came from,
/// - the configuration (`PresenceConfig`, one versioned record).
///
/// It subscribes to the bus as soon as it's created, so it doesn't miss
/// events published while the database is still opening.
///
/// Every event it saves gets this device's ID ([deviceId]), who's signed
/// in (the [currentUser] when it's published, or
/// [AppEvent.anonymousUserId]), the profile it belongs to (the
/// [currentProfile], or none signed out) and the [currentLocation] when
/// it's published.
class Persistence implements DeviceSettings {
  Persistence({
    required Future<IdbFactory> factory,
    required AppEventBus bus,
    required this.config,
    this.currentUser,
    this.currentProfile,
    this.currentLocation,
    DateTime Function()? now,
    MediaStore Function(EventStore store)? mediaStore,
  }) : _store = factory.then(EventStore.open),
       _now = now ?? DateTime.now {
    _media = _store.then(mediaStore ?? platform.newDefaultMediaStore);
    _media.ignore();
    _deviceId = _store.then((store) => store.deviceId(DeviceId.generate));
    _deviceId.ignore();
    _subscription = bus.stream.listen(_onEvent);
    // Errors surface through the operations that await the store.
    _store.ignore();
  }

  final ConfigController config;
  final DateTime Function() _now;

  /// When the settings were last changed, ms since the epoch: by the user,
  /// or by taking on newer ones from the cloud. 0 for the defaults.
  int _configUpdatedAt = 0;

  /// Completes once the saved settings are loaded (cloud sync waits for it,
  /// to compare them with the cloud's).
  final _configLoaded = Completer<void>();

  /// Completes once the saved settings are loaded (or failed to load), so
  /// the cameras open with them: the camera picked last time, paused or not.
  Future<void> get configLoaded => _configLoaded.future;

  /// Set while settings from the cloud are applied, which isn't a change
  /// by the user.
  bool _applyingRemote = false;

  /// The profile the settings were last synced with, or null before the
  /// first sync. A sign-in to another profile restores that profile's
  /// settings for this device (see `CloudSync`).
  String? _settingsProfile;

  /// Shows a location set on the map that came from the cloud (null: none
  /// is set there, so the device's own position is used). Set by the app
  /// to `LocationController.applyRemote`.
  void Function(DeviceLocation? onMap)? onRemoteLocation;

  /// Downloads the recording [mediaId] of clip [clipId] into the media
  /// store when a clip is played and it isn't there (a clip fetched from
  /// the cloud whose recording hasn't come down yet), and says whether it
  /// did. Set by the app to `CloudSync.fetchRecording`.
  Future<bool> Function(String clipId, String mediaId)? fetchMissingMedia;

  /// The signed-in user's ID, or null when nobody is signed in.
  final String? Function()? currentUser;

  /// The signed-in account's profile, or null when nobody is signed in
  /// (or the auth API hasn't answered the sign-in yet).
  final String? Function()? currentProfile;

  /// This device's location, or null while it's unknown.
  final DeviceLocation? Function()? currentLocation;

  final Future<EventStore> _store;
  late final Future<MediaStore> _media;
  late final Future<String> _deviceId;
  EventLog? _log;
  Future<void>? _restoring;
  late final StreamSubscription<AppEvent> _subscription;
  final Set<Future<void>> _pending = {};
  final StreamController<Set<String>> _changes =
      StreamController<Set<String>>.broadcast();
  final Set<String> _watched = {};

  /// Events whose annotations are being replaced by `updateFromRemote`.
  final Set<String> _updating = {};
  CameraRig? _rig;
  List<CameraDevice>? _saved;
  bool _disposed = false;

  /// Settings-store keys: the config record, and the flat record it
  /// replaced (read once, for upgrades).
  static const String _configKey = 'config';
  static const String _legacyKey = 'clip';

  /// Settings-store key of this device's location (`DeviceLocation`).
  static const String _locationKey = 'location';

  /// The saved location of this device, if any.
  Future<Map<String, Object?>?> loadLocation() async =>
      (await _store).getSettings(_locationKey);

  /// Saves this device's location. Setting it on the map, or going back
  /// to the device's own position from there, changes the settings (which
  /// sync to the cloud); a new reading of the device's position doesn't.
  Future<void> saveLocation(Map<String, Object?> json) {
    final write = () async {
      final store = await _store;
      final before = _onMap(await store.getSettings(_locationKey));
      await store.putSettings(_locationKey, json);
      if (mapEquals(before, _onMap(json))) return;
      // Not over the saved settings before they're loaded.
      await _configLoaded.future;
      if (!_disposed) _saveConfig();
    }();
    _track(write);
    return write;
  }

  /// [json] if it's a location set on the map, otherwise null.
  static Map<String, Object?>? _onMap(Map<String, Object?>? json) {
    final location = DeviceLocation.fromJson(json);
    return location?.source == LocationSource.map ? location!.toJson() : null;
  }

  /// Loads saved settings and history into [log]. Settings are saved on
  /// every change from then on.
  Future<void> restore(EventLog log) {
    _log = log;
    return _restoring = _restore(log);
  }

  Future<void> _restore(EventLog log) async {
    final store = await _store;

    // The whole configuration is one record, with when it last changed.
    // Older versions stored a flat "clip" settings record: read that if
    // there's no config yet. With neither, the defaults stand.
    try {
      final saved = await store.getSettings(_configKey);
      final legacy = saved == null ? await store.getSettings(_legacyKey) : null;
      if (!_disposed) {
        if (saved != null) {
          config.config = PresenceConfig.fromJson(saved);
          if (saved['updatedAt'] case final int at) _configUpdatedAt = at;
          if (saved['profileId'] case final String id) _settingsProfile = id;
        } else if (legacy != null) {
          config.config = PresenceConfig.fromLegacy(legacy);
        }
      }
      if (_disposed) return;
      config.addListener(_saveConfig);
    } finally {
      if (!_configLoaded.isCompleted) _configLoaded.complete();
    }

    final records = await store.allEvents();
    final history = await _loadHistory(store, records);
    if (_disposed) return;
    log.addHistory(history);

    // Keep the motion cooldown across restarts: it runs from the last
    // automatic clip (records are newest first).
    final lastMotion = records.firstWhere(
      (r) =>
          r['type'] == ClipRequested.clipRequestedType &&
          r['trigger'] == ClipTrigger.motion.name,
      orElse: () => const {},
    )['time'];
    if (lastMotion is int) {
      _rig?.restoreMotionCooldown(
        DateTime.fromMillisecondsSinceEpoch(lastMotion),
      );
    }
  }

  /// Saves the cameras the rig opens, so stored clips keep their camera.
  void attachRig(CameraRig rig) {
    _rig = rig..addListener(_saveCameras);
  }

  /// This device's ID, generated on its first launch and kept from then on.
  @override
  Future<String> get deviceId => _deviceId;

  /// Settings-store key of this device's recording consent.
  static const String _consentKey = 'consent';

  /// Whether this device has a valid recording consent
  /// ([DeviceConsent.isValid]): for its own ID, to the current text, with a
  /// matching verification hash.
  Future<bool> hasConsent() async {
    final store = await _store;
    final id = await _deviceId;
    return DeviceConsent.isValid(await store.getSettings(_consentKey), id);
  }

  /// Saves the recording consent given on this device at [at].
  Future<void> giveConsent(DateTime at) async {
    final store = await _store;
    final id = await _deviceId;
    await store.putSettings(_consentKey, DeviceConsent.record(id, at));
  }

  /// Gives [profileId], the profile the auth API answered [userId]'s
  /// sign-in with, the events on this device that have no profile yet:
  /// those recorded while nobody was signed in, while the sign-in was being
  /// answered, and before events had profiles. A sign-in loses none of
  /// them: they show and sync as the profile's from then on. Another
  /// user's events without a profile stay as they are. Runs after the
  /// history is restored and pending saves are done.
  Future<void> claimForProfile(String profileId, String userId) {
    final pending = List.of(_pending);
    final restoring = _restoring;
    final claim = () async {
      await restoring?.then((_) {}, onError: (Object _) {});
      await Future.wait(pending);
      if (_disposed) return;
      final store = await _store;
      bool anonymous(String? user) =>
          user == null || user == AppEvent.anonymousUserId;
      bool unclaimed(String? profile, String? user) =>
          profile == null && (anonymous(user) || user == userId);
      // The events in memory first: their records are the freshest, and
      // later saves of them (a clip completing, a tag) must keep the owner.
      final claimed = <String>{};
      for (final event in _log?.events ?? const <AppEvent>[]) {
        if (!unclaimed(event.profileId, event.userId)) continue;
        event.profileId = profileId;
        if (anonymous(event.userId)) event.userId = userId;
        claimed.add(event.id);
        await store.putEvent(event.toRecord());
      }
      // Then any stored ones that aren't in memory.
      for (final record in await store.allEvents()) {
        final user = AppEvent.ownerOf(record);
        if (claimed.contains(record['id']) ||
            !unclaimed(AppEvent.profileOf(record), user)) {
          continue;
        }
        await store.putEvent({
          ...record,
          'userId': anonymous(user) ? userId : user,
          'profileId': profileId,
        });
        claimed.add(record['id']! as String);
      }
      _changed(claimed);
    }();
    _track(claim);
    return claim;
  }

  /// Deletes every event from before [cutoff] from the device: its record,
  /// its clip (details and recordings), and the suggestions about that
  /// clip, then takes them out of the event log. Runs after the history is
  /// restored and pending saves are done. Returns how many events went.
  Future<int> deleteEventsBefore(DateTime cutoff) {
    final pending = List.of(_pending);
    final restoring = _restoring;
    final delete = () async {
      await restoring?.then((_) {}, onError: (Object _) {});
      await Future.wait(pending);
      if (_disposed) return 0;
      final store = await _store;
      final records = await store.allEvents();
      final before = cutoff.millisecondsSinceEpoch;
      final old = {
        for (final r in records)
          if (r['time'] case final int time when time < before)
            r['id']! as String,
      };
      if (old.isEmpty) return 0;
      // A suggestion goes with the clip it asks about.
      final ids = {
        ...old,
        for (final r in records)
          if (r['type'] == SubjectSuggestion.suggestionType &&
              old.contains(r['clipEventId']))
            r['id']! as String,
      };
      final clips = [
        for (final c in await store.allClips())
          if (ids.contains(c['eventId'])) c,
      ];
      final clipIds = {for (final c in clips) c['id']! as String};
      await store.deleteEvents(ids, clipIds);
      // What cloud sync remembers of them (uploads, ETags) goes too, so
      // its store doesn't grow forever.
      await store.deleteSynced(
        (key) => CloudSync.isSyncedKeyOf(key, ids, clipIds),
      );
      await (await _media).delete([
        for (final c in clips)
          for (final ref in [c['past'], c['full']])
            if (ref is Map && ref['mediaId'] is String)
              ref['mediaId']! as String,
      ]);
      _watched.removeAll(ids);
      _log?.remove(ids);
      return ids.length;
    }();
    _track(delete);
    return delete;
  }

  /// The open database and recordings, for readers such as `CloudSync`.
  Future<EventStore> get store => _store;
  Future<MediaStore> get media => _media;

  /// Fires with the IDs of the events saved (so uploads can follow, of
  /// just those): after an event is saved, again when its clip's recording
  /// is complete, when its tags change, and for the events a sign-in
  /// claims. Empty after a settings change.
  Stream<Set<String>> get changes => _changes.stream;

  /// Saves records downloaded from the cloud (another device's clips and
  /// events) without publishing them, and returns their events, ready for
  /// `EventLog.addHistory`. Their recordings are already stored (cloud
  /// sync saves each as it's downloaded).
  Future<List<AppEvent>> importRemote({
    required List<Map<String, Object?>> events,
    required List<Map<String, Object?>> clips,
  }) async {
    final store = await _store;
    for (final clip in clips) {
      await store.putClip(clip);
    }
    for (final event in events) {
      await store.putEvent(event);
    }
    if (events.isEmpty) return const [];
    return _loadHistory(store, events);
  }

  /// Takes on events another device changed ([records], fetched again by
  /// cloud sync): their tags, suggestions, object tags and the frames they
  /// use replace the ones here, on screen ([shown], the app's events) and
  /// in storage. The rest of the event stays as it is here.
  Future<void> updateFromRemote(
    List<Map<String, Object?>> records,
    Iterable<AppEvent> shown,
  ) async {
    if (records.isEmpty) return;
    final store = await _store;
    final byId = {for (final e in shown) e.id: e};
    for (final record in records) {
      final id = record['id'];
      final local = id is String ? await store.getEvent(id) : null;
      if (local == null) continue;
      final frames = {
        if (local['frames'] case final Map frames) ...frames,
        if (record['frames'] case final Map frames) ...frames,
      };
      final remote = ClipAnnotations.fromJson(
        record['annotations'],
        frames,
        record['objectTags'],
      );
      if (byId[record['id']] case final ClipRequested event) {
        // Not saved again by its listener: it's saved here, as it is now.
        _updating.add(event.id);
        try {
          event.annotations.replaceWith(remote);
        } finally {
          _updating.remove(event.id);
        }
        await store.putEvent(event.toRecord());
      } else {
        await store.putEvent({
          for (final MapEntry(:key, :value) in local.entries)
            if (!const {'annotations', 'frames', 'objectTags'}.contains(key))
              key: value,
          if (!remote.isEmpty) 'annotations': remote.toJson(),
          if (!remote.isEmpty) 'frames': remote.framesToRecord(),
          if (remote.objects case final objects?)
            'objectTags': [for (final o in objects) o.toJson()],
        });
      }
    }
  }

  /// Completes when all writes issued so far have finished (for tests).
  Future<void> flush() => Future.wait(List.of(_pending));

  void dispose() {
    _disposed = true;
    _subscription.cancel();
    config.removeListener(_saveConfig);
    _rig?.removeListener(_saveCameras);
    _changes.close();
    // Let in-flight writes finish before closing the database.
    Future.wait(List.of(_pending))
        .then((_) => _store)
        .then((store) => store.close())
        .ignore();
  }

  void _track(Future<void> write) {
    _pending.add(write);
    write.whenComplete(() => _pending.remove(write)).ignore();
  }

  void _onEvent(AppEvent event) {
    // Who's signed in now, not once the database is open.
    event.userId ??= currentUser?.call() ?? AppEvent.anonymousUserId;
    event.profileId ??= currentProfile?.call();
    event.location ??= currentLocation?.call();
    _track(() async {
      final store = await _store;
      try {
        event.deviceId ??= await _deviceId;
        await store.putEvent(event.toRecord());
        _changed({event.id});
      } catch (e) {
        debugPrint('Presence: could not save event ${event.id}: $e');
      }
      if (event is ClipRequested) _watchAnnotations(event);
      if (event is ClipRequested && event.clip.capture != null) {
        await _ClipWriter(store, await _media, event).run();
        _changed({event.id});
      }
    }());
  }

  /// Saves [event] again whenever its annotations change (names added,
  /// renamed or removed under the player), which also queues it for cloud
  /// sync.
  ClipRequested _watchAnnotations(ClipRequested event) {
    if (_watched.add(event.id)) {
      event.annotations.addListener(() {
        // Not once it's deleted (`deleteEventsBefore`).
        if (_disposed || !_watched.contains(event.id)) return;
        // Taken on from the cloud (`updateFromRemote`), which saves it.
        if (_updating.contains(event.id)) return;
        _track(() async {
          final store = await _store;
          await store.putEvent(event.toRecord());
          _changed({event.id});
        }());
      });
    }
    return event;
  }

  void _changed(Set<String> eventIds) {
    if (!_changes.isClosed) _changes.add(eventIds);
  }

  /// The user changed a setting.
  void _saveConfig() {
    if (_applyingRemote) return;
    _configUpdatedAt = _now().millisecondsSinceEpoch;
    _writeConfig();
  }

  void _writeConfig() {
    final json = {
      ...config.config.toJson(),
      'updatedAt': _configUpdatedAt,
      'profileId': ?_settingsProfile,
    };
    _track(() async {
      final store = await _store;
      await store.putSettings(_configKey, json);
      // Cloud sync uploads the new settings.
      _changed(const {});
    }());
  }

  @override
  Future<Map<String, Object?>> settingsRecord() async {
    await _configLoaded.future;
    final location = (await _store).getSettings(_locationKey);
    return {
      'deviceId': await _deviceId,
      'profileId': ?_settingsProfile,
      'updatedAt': _configUpdatedAt,
      'config': config.config.toJson(),
      'location': _onMap(await location),
    };
  }

  @override
  Future<void> applySettings(Map<String, Object?> record) async {
    await _configLoaded.future;
    final json = record['config'];
    final at = record['updatedAt'];
    if (_disposed || json is! Map || at is! int) return;
    _applyingRemote = true;
    try {
      config.config = PresenceConfig.fromJson(json.cast<String, Object?>());
    } finally {
      _applyingRemote = false;
    }
    _configUpdatedAt = at;
    _writeConfig();
    // Records from before the location synced have no `location`: leave
    // this device's alone.
    if (record.containsKey('location')) await _applyLocation(record);
  }

  /// Takes on the cloud's location set on the map, or its absence.
  Future<void> _applyLocation(Map<String, Object?> record) async {
    final remote = DeviceLocation.fromJson(record['location']);
    if (record['location'] != null && remote == null) return; // Damaged.
    final onMap = remote?.source == LocationSource.map ? remote : null;
    final store = await _store;
    final local = DeviceLocation.fromJson(
      await store.getSettings(_locationKey),
    );
    if (_disposed) return;
    if (onMap != null) {
      await store.putSettings(_locationKey, onMap.toJson());
    } else if (local?.source == LocationSource.map) {
      // None on the map there: until the device answers, the last point
      // stands as a reading, not a setting.
      await store.putSettings(_locationKey, {
        ...local!.toJson(),
        'source': LocationSource.device.name,
      });
    } else {
      return;
    }
    onRemoteLocation?.call(onMap);
  }

  @override
  Future<void> claimSettings(String profileId) async {
    await _configLoaded.future;
    if (_disposed || _settingsProfile == profileId) return;
    _settingsProfile = profileId;
    _writeConfig();
  }

  void _saveCameras() {
    final sources = _rig?.devices;
    // The rig notifies on every change; the device list rarely changes.
    if (sources == null || sources.isEmpty || identical(sources, _saved)) {
      return;
    }
    _saved = sources;
    final now = DateTime.now().millisecondsSinceEpoch;
    _track(() async {
      final store = await _store;
      for (final camera in sources) {
        await store.putCamera({
          'id': camera.id,
          'label': camera.label,
          'lastSeen': now,
        });
      }
    }());
  }

  Future<List<AppEvent>> _loadHistory(
    EventStore store,
    List<Map<String, Object?>> records,
  ) async {
    final media = await _media;
    final cameraLabels = {
      for (final c in await store.allCameras())
        c['id']! as String: c['label']! as String,
    };
    final clips = {
      for (final c in await store.allClips())
        c['id']! as String: _restoreClip(media, c, cameraLabels),
    };

    final events = [for (final record in records) _restoreEvent(record, clips)];
    // Suggestions point at their clips' events.
    final clipEvents = {
      for (final e in [...?_log?.events, ...events])
        if (e is ClipRequested) e.id: e,
    };
    for (final e in events.whereType<SubjectSuggestion>()) {
      e.clip ??= clipEvents[e.clipEventId];
    }
    return events;
  }

  AppEvent _restoreEvent(
    Map<String, Object?> record,
    Map<String, VideoClip> clips,
  ) => _restoreEventOnly(record, clips)
    ..location ??= DeviceLocation.fromJson(record['location'])
    ..profileId ??= AppEvent.profileOf(record);

  AppEvent _restoreEventOnly(
    Map<String, Object?> record,
    Map<String, VideoClip> clips,
  ) {
    if (record['type'] == ClipRequested.clipRequestedType) {
      final clip = clips[record['clipId']];
      if (clip != null) {
        return _watchAnnotations(
          ClipRequested(
            clip,
            trigger:
                ClipTrigger.values.asNameMap()[record['trigger']] ??
                ClipTrigger.manual,
            annotations: ClipAnnotations.fromJson(
              record['annotations'],
              record['frames'],
              record['objectTags'],
            ),
            id: record['id']! as String,
            time: DateTime.fromMillisecondsSinceEpoch(record['time']! as int),
            deviceId: record['deviceId'] as String?,
            userId: AppEvent.ownerOf(record),
          ),
        );
      }
    }
    if (record['type'] == SubjectSuggestion.suggestionType) {
      if (SubjectSuggestion.fromRecord(record) case final suggestion?) {
        return suggestion;
      }
    }
    return AppEvent.fromRecord(record) ??
        AppEvent(
          icon: Icons.help_outline,
          title: record['title'] as String? ?? 'Event',
          detail: record['type'] == ClipRequested.clipRequestedType
              ? 'Clip recording missing'
              : record['detail'] as String?,
          cameraId: record['cameraId'] as String?,
          deviceId: record['deviceId'] as String?,
          userId: AppEvent.ownerOf(record),
          time: DateTime.fromMillisecondsSinceEpoch(record['time']! as int),
          id: record['id']! as String,
        );
  }

  VideoClip _restoreClip(
    MediaStore media,
    Map<String, Object?> record,
    Map<String, String> cameraLabels,
  ) {
    final cameraId = record['cameraId']! as String;
    return VideoClip.restored(
      id: record['id']! as String,
      cameraId: cameraId,
      cameraLabel:
          cameraLabels[cameraId] ??
          record['cameraLabel'] as String? ??
          'Camera',
      before: Duration(milliseconds: record['beforeMs']! as int),
      after: Duration(milliseconds: record['afterMs']! as int),
      past: _restoreMedia(media, record['id']! as String, record['past']),
      full: _restoreMedia(media, record['id']! as String, record['full']),
      thumbnail: _bytes(record['thumbnail']),
      supported: record['supported'] as bool? ?? true,
      error: record['state'] == _ClipWriter.failed ? 'Recording failed' : null,
    );
  }

  ClipMedia? _restoreMedia(MediaStore media, String clipId, Object? ref) {
    if (ref is! Map) return null;
    final mediaId = ref['mediaId']! as String;
    final mimeType = ref['mimeType'] as String? ?? ClipMedia.defaultMimeType;
    return ClipMedia.stored(
      // Not here yet (fetched from the cloud without it): downloaded now.
      load: () async {
        try {
          return await media.load(mediaId, mimeType);
        } catch (_) {
          final fetch = fetchMissingMedia;
          if (fetch == null || !await fetch(clipId, mediaId)) rethrow;
          return media.load(mediaId, mimeType);
        }
      },
      start: Duration(milliseconds: ref['startMs']! as int),
      end: Duration(milliseconds: ref['endMs']! as int),
      mimeType: mimeType,
    );
  }

  static Uint8List? _bytes(Object? value) => value is Uint8List
      ? value
      : (value is List ? Uint8List.fromList(value.cast<int>()) : null);
}

/// Follows one live clip's recordings into storage.
class _ClipWriter {
  _ClipWriter(this._store, this._media, this._event);

  static const String recording = 'recording';
  static const String complete = 'complete';
  static const String failed = 'failed';

  final EventStore _store;
  final MediaStore _media;
  final ClipRequested _event;

  VideoClip get _clip => _event.clip;

  late final Map<String, Object?> _record = {
    'id': _clip.id,
    'eventId': _event.id,
    'cameraId': _clip.cameraId,
    'cameraLabel': _clip.cameraLabel,
    'requestedAt': _event.time.millisecondsSinceEpoch,
    'beforeMs': _clip.before.inMilliseconds,
    'afterMs': _clip.after.inMilliseconds,
    'supported': _clip.supported,
    'thumbnail': _clip.thumbnail,
    'state': recording,
  };

  Future<void> run() async {
    final capture = _clip.capture!;
    try {
      await _store.putClip(_record);

      // Save the before part as soon as it exists, so it survives even if
      // the page closes during the after part.
      final past = await _orNull(capture.past);
      String? pastId;
      if (past != null) {
        pastId = '${_clip.id}-past';
        await _saveMedia(pastId, past);
        _record['past'] = _ref(pastId, past);
        await _store.putClip(_record);
      }

      final full = await _orNull(capture.full);
      if (full == null) {
        _record['state'] = past == null ? failed : complete;
        await _store.putClip(_record);
        return;
      }
      final fullId = '${_clip.id}-full';
      await _saveMedia(fullId, full);
      _record
        ..['full'] = _ref(fullId, full)
        ..remove('past')
        ..['state'] = complete;
      // The full clip contains the before part: drop the separate file.
      await _media.commitClip(_record, [?pastId]);
      // Update the stored event too: it now refers to the full clip.
      await _store.putEvent(_event.toRecord());
    } catch (e) {
      _clip.markSaveError(_describe(e));
    }
  }

  Future<void> _saveMedia(String id, ClipMedia media) => _media.save(id, media);

  static Map<String, Object?> _ref(String mediaId, ClipMedia media) => {
    'mediaId': mediaId,
    'startMs': media.start.inMilliseconds,
    'endMs': media.end.inMilliseconds,
    'mimeType': media.mimeType,
  };

  static Future<ClipMedia?> _orNull(Future<ClipMedia?> f) =>
      f.then<ClipMedia?>((m) => m, onError: (Object _) => null);

  static String _describe(Object e) {
    final text = e.toString();
    return text.contains('Quota') ? 'storage is full' : 'storage error';
  }
}
