import 'dart:typed_data';

import 'package:idb_shim/idb_shim.dart';

/// The app's IndexedDB database. Stores plain records; the domain mapping
/// lives in `persistence.dart`.
///
/// | Store      | Key               | Holds                                   |
/// |------------|-------------------|-----------------------------------------|
/// | `cameras`  | `id` (camera ID)  | label, last seen                        |
/// | `events`   | `id`, index `time`| type, title, time, camera ID, clip ID, device ID, user ID, location |
/// | `clips`    | `id`, index `eventId` | camera, window, media IDs, thumbnail |
/// | `media`    | media ID          | recording bytes                         |
/// | `settings` | name              | the config; `device`: this device's ID; `location`: its location |
/// | `synced`   | object key        | fingerprint of what was uploaded (v2)   |
class EventStore {
  EventStore._(this._db);

  static const String dbName = 'presence';
  static const int _version = 2;

  static const String cameras = 'cameras';
  static const String events = 'events';
  static const String clips = 'clips';
  static const String media = 'media';
  static const String settings = 'settings';
  static const String synced = 'synced';

  final Database _db;

  static Future<EventStore> open(IdbFactory factory) async {
    final db = await factory.open(
      dbName,
      version: _version,
      onUpgradeNeeded: (VersionChangeEvent e) {
        final db = e.database;
        if (e.oldVersion < 1) {
          db.createObjectStore(cameras, keyPath: 'id');
          db
              .createObjectStore(events, keyPath: 'id')
              .createIndex('time', 'time');
          db
              .createObjectStore(clips, keyPath: 'id')
              .createIndex('eventId', 'eventId');
          db.createObjectStore(media);
          db.createObjectStore(settings);
        }
        if (e.oldVersion < 2) {
          db.createObjectStore(synced);
        }
      },
    );
    return EventStore._(db);
  }

  Future<void> putCamera(Map<String, Object?> record) => _put(cameras, record);

  Future<void> putEvent(Map<String, Object?> record) => _put(events, record);

  Future<void> putClip(Map<String, Object?> record) => _put(clips, record);

  /// Saves a clip record and deletes media it no longer uses, atomically.
  Future<void> putClipAndDeleteMedia(
    Map<String, Object?> record,
    Iterable<String> mediaIds,
  ) async {
    final txn = _db.transactionList([clips, media], idbModeReadWrite);
    await txn.objectStore(clips).put(_compact(record));
    for (final id in mediaIds) {
      await txn.objectStore(media).delete(id);
    }
    await txn.completed;
  }

  Future<void> putMedia(String id, Uint8List bytes) async {
    final txn = _db.transaction(media, idbModeReadWrite);
    await txn.objectStore(media).put(bytes, id);
    await txn.completed;
  }

  Future<Uint8List?> getMedia(String id) async {
    final txn = _db.transaction(media, idbModeReadOnly);
    final value = await txn.objectStore(media).getObject(id);
    await txn.completed;
    return value is Uint8List
        ? value
        : (value is List ? Uint8List.fromList(value.cast<int>()) : null);
  }

  Future<List<String>> mediaIds() async {
    final txn = _db.transaction(media, idbModeReadOnly);
    final keys = await txn.objectStore(media).getAllKeys();
    await txn.completed;
    return keys.cast<String>();
  }

  Future<void> deleteMedia(String id) async {
    final txn = _db.transaction(media, idbModeReadWrite);
    await txn.objectStore(media).delete(id);
    await txn.completed;
  }

  /// Deletes the events [eventIds] and the clip records [clipIds] in one
  /// transaction. Their recordings are the `MediaStore`'s to delete.
  Future<void> deleteEvents(
    Iterable<String> eventIds,
    Iterable<String> clipIds,
  ) async {
    final txn = _db.transactionList([events, clips], idbModeReadWrite);
    for (final id in eventIds) {
      await txn.objectStore(events).delete(id);
    }
    for (final id in clipIds) {
      await txn.objectStore(clips).delete(id);
    }
    await txn.completed;
  }

  /// All events, newest first.
  Future<List<Map<String, Object?>>> allEvents() async {
    final txn = _db.transaction(events, idbModeReadOnly);
    final records = <Map<String, Object?>>[];
    await txn
        .objectStore(events)
        .index('time')
        .openCursor(direction: idbDirectionPrev, autoAdvance: true)
        .forEach((cursor) => records.add(_map(cursor.value)));
    await txn.completed;
    return records;
  }

  /// The event [id], or null if there's none.
  Future<Map<String, Object?>?> getEvent(String id) async {
    final txn = _db.transaction(events, idbModeReadOnly);
    final value = await txn.objectStore(events).getObject(id);
    await txn.completed;
    return value == null ? null : _map(value);
  }

  /// The IDs of every event (without reading their records).
  Future<Set<String>> eventIds() => _keys(events);

  /// The IDs of every clip (without reading their records).
  Future<Set<String>> clipIds() => _keys(clips);

  /// The clips of the event [eventId] (through the `eventId` index).
  Future<List<Map<String, Object?>>> clipsOfEvent(String eventId) async {
    final txn = _db.transaction(clips, idbModeReadOnly);
    final values = await txn
        .objectStore(clips)
        .index('eventId')
        .getAll(eventId);
    await txn.completed;
    return values.map(_map).toList();
  }

  Future<List<Map<String, Object?>>> allClips() => _all(clips);

  Future<List<Map<String, Object?>>> allCameras() => _all(cameras);

  Future<Map<String, Object?>?> getSettings(String name) async {
    final txn = _db.transaction(settings, idbModeReadOnly);
    final value = await txn.objectStore(settings).getObject(name);
    await txn.completed;
    return value == null ? null : _map(value);
  }

  Future<void> putSettings(String name, Map<String, Object?> record) async {
    final txn = _db.transaction(settings, idbModeReadWrite);
    await txn.objectStore(settings).put(_compact(record), name);
    await txn.completed;
  }

  /// This device's ID (the `device` settings record), made with [generate]
  /// and saved the first time. Read and written in one transaction, so two
  /// tabs opening at once agree on it.
  Future<String> deviceId(String Function() generate) =>
      _generatedId(_deviceKey, generate);

  static const String _deviceKey = 'device';

  /// The `{id}` settings record [key], made with [generate] and saved the
  /// first time. Read and written in one transaction, so two tabs opening
  /// at once agree on it.
  Future<String> _generatedId(String key, String Function() generate) async {
    final txn = _db.transaction(settings, idbModeReadWrite);
    final store = txn.objectStore(settings);
    final saved = await store.getObject(key);
    var id = saved is Map ? saved['id'] : null;
    if (id is! String || id.isEmpty) {
      id = generate();
      await store.put({'id': id}, key);
    }
    await txn.completed;
    return id;
  }

  /// What's already uploaded to the cloud (see `CloudSync`): each object
  /// key with a fingerprint of the content uploaded under it.
  Future<Map<String, String>> syncedKeys() async {
    final txn = _db.transaction(synced, idbModeReadOnly);
    final result = <String, String>{};
    await txn
        .objectStore(synced)
        .openCursor(autoAdvance: true)
        .forEach((cursor) => result['${cursor.key}'] = '${cursor.value}');
    await txn.completed;
    return result;
  }

  Future<void> markSynced(String key, String fingerprint) async {
    final txn = _db.transaction(synced, idbModeReadWrite);
    await txn.objectStore(synced).put(fingerprint, key);
    await txn.completed;
  }

  /// Forgets the synced-store entry [key], if there is one.
  Future<void> unmarkSynced(String key) async {
    final txn = _db.transaction(synced, idbModeReadWrite);
    await txn.objectStore(synced).delete(key);
    await txn.completed;
  }

  /// Forgets the synced-store entries whose key [test] accepts (those of
  /// deleted events and clips), in one transaction. Returns how many went.
  Future<int> deleteSynced(bool Function(String key) test) async {
    final txn = _db.transaction(synced, idbModeReadWrite);
    final store = txn.objectStore(synced);
    final doomed = <Object>[];
    await store.openCursor(autoAdvance: true).forEach((cursor) {
      if (test('${cursor.key}')) doomed.add(cursor.key);
    });
    for (final key in doomed) {
      await store.delete(key);
    }
    await txn.completed;
    return doomed.length;
  }

  void close() => _db.close();

  Future<void> _put(String store, Map<String, Object?> record) async {
    final txn = _db.transaction(store, idbModeReadWrite);
    await txn.objectStore(store).put(_compact(record));
    await txn.completed;
  }

  Future<Set<String>> _keys(String store) async {
    final txn = _db.transaction(store, idbModeReadOnly);
    final keys = await txn.objectStore(store).getAllKeys();
    await txn.completed;
    return {for (final key in keys) '$key'};
  }

  Future<List<Map<String, Object?>>> _all(String store) async {
    final txn = _db.transaction(store, idbModeReadOnly);
    final values = await txn.objectStore(store).getAll();
    await txn.completed;
    return values.map(_map).toList();
  }

  /// Drops null fields: not every backend stores nulls the same way.
  static Map<String, Object> _compact(Map<String, Object?> record) => {
    for (final MapEntry(:key, :value) in record.entries)
      if (value != null)
        key: value is Map<String, Object?> ? _compact(value) : value,
  };

  static Map<String, Object?> _map(Object value) =>
      (value as Map).cast<String, Object?>();
}
