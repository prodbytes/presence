import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:idb_shim/idb_io.dart';
import 'package:path_provider/path_provider.dart';

import '../cameras/camera_source.dart';
import '../crypto/media_seal.dart';
import '../crypto/seal_files_io.dart' show readHead;
import 'event_store.dart';
import 'media_store.dart';
import 'records.dart';

/// A sembast-backed database in the app's private storage. Recordings are
/// kept out of it (sembast holds its whole database in memory); see
/// [FileMediaStore]. Falls back to memory if storage isn't available.
Future<IdbFactory> newDefaultIdbFactory() async {
  try {
    final dir = await getApplicationSupportDirectory();
    return getIdbFactorySembastIo('${dir.path}/db');
  } catch (e) {
    debugPrint('Presence: no persistent storage, keeping data in memory: $e');
    return newIdbFactoryMemory();
  }
}

MediaStore newDefaultMediaStore(EventStore store) => FileMediaStore(store);

/// Recordings as sealed files in the app's private storage
/// (`clips/<id>.sealed`), opened into temporary files to be played or
/// searched (`open/` in the cache), which are deleted once nothing uses
/// them (`MediaUrls`).
class FileMediaStore implements MediaStore {
  FileMediaStore(this._store, {MediaSeal? seal, this._root, this._cache})
    : _seal = seal ?? MediaSeal.instance;

  final EventStore _store;
  final MediaSeal _seal;
  final Directory? _root;
  final Directory? _cache;

  /// The extension of sealed recordings.
  static const String extension = '.sealed';

  Future<Directory>? _dir;
  Future<Directory>? _openDir;

  Future<Directory> _clipsDir() => _dir ??= () async {
    final base = _root ?? await getApplicationSupportDirectory();
    final dir = await Directory('${base.path}/clips').create(recursive: true);
    await _sweep(dir);
    return dir;
  }();

  Future<Directory> _openedDir() => _openDir ??= () async {
    final base = _cache ?? await getTemporaryDirectory();
    final dir = Directory('${base.path}/open');
    // Opened copies left by an earlier run (it stopped while one played).
    if (await dir.exists()) await dir.delete(recursive: true);
    return dir.create(recursive: true);
  }();

  /// When this run started: live recordings older than it were left by an
  /// earlier run.
  static final DateTime _started = DateTime.now();

  /// Deletes what's stored unsealed: recordings an older version kept
  /// (`<id>.mp4`), and live recordings an earlier run left in the cache
  /// (`clip-*.mp4`, made before this run started) that never got sealed.
  Future<void> _sweep(Directory clips) async {
    Future<void> sweep(
      Directory dir,
      bool Function(String name) unsealed,
    ) async {
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (!unsealed(name)) continue;
        try {
          await entity.delete();
        } catch (e) {
          debugPrint('Presence: could not delete unsealed $name: $e');
        }
      }
    }

    await sweep(clips, (name) => name.endsWith('.mp4'));
    try {
      final cache = _cache ?? await getTemporaryDirectory();
      bool leftover(String name) =>
          name.startsWith('clip-') && name.endsWith('.mp4');
      for (final dir in [cache, Directory('${cache.path}/clips')]) {
        if (!await dir.exists()) continue;
        await for (final entity in dir.list()) {
          if (entity is! File) continue;
          final name = entity.uri.pathSegments.last;
          if (!leftover(name)) continue;
          if ((await entity.lastModified()).isAfter(_started)) continue;
          await entity.delete().then<void>((_) {}, onError: (Object _) {});
        }
      }
    } catch (e) {
      debugPrint('Presence: could not sweep old live recordings: $e');
    }
  }

  /// The file of recording [id]. The ID names a file, so one that could
  /// reach outside the folder (from a damaged or hostile record) is
  /// refused ([Records.isSafeMediaId]).
  Future<File> _file(String id) async {
    if (!Records.isSafeMediaId(id)) {
      throw ArgumentError.value(id, 'id', 'not a safe recording ID');
    }
    return File('${(await _clipsDir()).path}/$id$extension');
  }

  @override
  Future<void> save(String id, ClipMedia media) async {
    final path = media.liveUrl;
    if (path == null) return;
    final file = await _file(id);
    // Sealed beside it, then moved into place: never half written.
    final writing = '${file.path}.part';
    try {
      await _seal.sealFile(path, writing);
      await File(writing).rename(file.path);
    } catch (_) {
      await File(writing).delete().then<void>((_) {}, onError: (Object _) {});
      rethrow;
    }
    // From now on it plays from the sealed file, and the unsealed one is
    // deleted once nothing plays it.
    media.persisted(() => load(id, media.mimeType));
  }

  int _opened = 0;

  @override
  Future<String> load(String id, String mimeType) async {
    final file = await _file(id);
    if (!await file.exists()) throw StateError('Recording $id is missing');
    final to = '${(await _openedDir()).path}/$id-${_opened++}.mp4';
    await _seal.openFile(file.path, to);
    return to;
  }

  @override
  Future<void> saveBytes(String id, Uint8List bytes) async {
    if (!SealFormat.isSealed(bytes)) throw const SealBroken('not sealed');
    await (await _file(id)).writeAsBytes(bytes, flush: true);
  }

  @override
  Future<MediaBytes> read(String id) async {
    final file = await _file(id);
    if (!await file.exists()) throw StateError('Recording $id is missing');
    if (!SealFormat.isSealed(await readHead(file.path))) {
      throw const SealBroken('not sealed');
    }
    // Read in chunks as the upload sends them, not into memory at once.
    return (stream: file.openRead(), length: await file.length());
  }

  @override
  Future<void> commitClip(
    Map<String, Object?> clip,
    Iterable<String> deleteIds,
  ) async {
    await _store.putClip(clip);
    await delete(deleteIds);
  }

  @override
  Future<void> delete(Iterable<String> ids) async {
    for (final id in ids) {
      if (!Records.isSafeMediaId(id)) continue;
      final file = await _file(id);
      if (await file.exists()) await file.delete();
    }
  }

  @override
  Future<List<String>> ids() async {
    final found = <String>[];
    await for (final entity in (await _clipsDir()).list()) {
      final name = entity.uri.pathSegments.last;
      if (entity is File && name.endsWith(extension)) {
        found.add(name.substring(0, name.length - extension.length));
      }
    }
    return found;
  }
}

Future<Uint8List> readMediaBytes(String url) => File(url).readAsBytes();

String createMediaUrl(Uint8List bytes, String mimeType) =>
    throw UnsupportedError('Android plays recordings from files');

Future<bool> requestPersistentStorage() async => true;
