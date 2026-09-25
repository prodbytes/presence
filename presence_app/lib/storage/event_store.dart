import 'dart:typed_data';

import 'package:idb_shim/idb_shim.dart';

/// The app's IndexedDB database. Stores plain records; the domain mapping
/// lives in `persistence.dart`.
///
/// | Store      | Key               | Holds                                   |
/// |------------|-------------------|-----------------------------------------|
/// | `cameras`  | `id` (device ID)  | label, last seen                        |
/// | `events`   | `id`, index `time`| type, title, time, camera ID, clip ID   |
/// | `clips`    | `id`, index `eventId` | camera, window, media IDs, thumbnail |
/// | `media`    | media ID          | recording bytes                         |
/// | `settings` | name              | settings record                         |
class EventStore {
  EventStore._(this._db);

  static const String dbName = 'presence';
  static const int _version = 1;

  static const String cameras = 'cameras';
  static const String events = 'events';
  static const String clips = 'clips';
  static const String media = 'media';
  static const String settings = 'settings';

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

  void close() => _db.close();

  Future<void> _put(String store, Map<String, Object?> record) async {
    final txn = _db.transaction(store, idbModeReadWrite);
    await txn.objectStore(store).put(_compact(record));
    await txn.completed;
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
