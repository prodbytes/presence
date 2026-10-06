import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:idb_shim/idb_io.dart';
import 'package:path_provider/path_provider.dart';

import '../cameras/camera_source.dart';
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

/// Recordings as MP4 files in the app's private storage.
class FileMediaStore implements MediaStore {
  FileMediaStore(this._store);

  final EventStore _store;

  static Future<Directory>? _dir;

  static Future<Directory> _clipsDir() => _dir ??= () async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/clips').create(recursive: true);
  }();

  /// The file of recording [id]. The ID names a file, so one that could
  /// reach outside the folder (from a damaged or hostile record) is
  /// refused ([Records.isSafeMediaId]).
  Future<File> _file(String id) async {
    if (!Records.isSafeMediaId(id)) {
      throw ArgumentError.value(id, 'id', 'not a safe recording ID');
    }
    return File('${(await _clipsDir()).path}/$id.mp4');
  }

  @override
  Future<void> save(String id, ClipMedia media) async {
    final path = media.liveUrl;
    if (path == null) return;
    await File(path).copy((await _file(id)).path);
  }

  @override
  Future<String> load(String id, String mimeType) async {
    final file = await _file(id);
    if (!await file.exists()) throw StateError('Recording $id is missing');
    return file.path;
  }

  @override
  Future<void> saveBytes(String id, Uint8List bytes) async {
    await (await _file(id)).writeAsBytes(bytes, flush: true);
  }

  @override
  Future<MediaBytes> read(String id) async {
    final file = await _file(id);
    if (!await file.exists()) throw StateError('Recording $id is missing');
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
      if (entity is File && name.endsWith('.mp4')) {
        found.add(name.substring(0, name.length - '.mp4'.length));
      }
    }
    return found;
  }
}

Future<Uint8List> readMediaBytes(String url) => File(url).readAsBytes();

String createMediaUrl(Uint8List bytes, String mimeType) =>
    throw UnsupportedError('Android plays recordings from files');

Future<bool> requestPersistentStorage() async => true;
