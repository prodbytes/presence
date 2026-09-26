import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:idb_shim/idb_io.dart';
import 'package:path_provider/path_provider.dart';

import '../cameras/camera_source.dart';
import 'event_store.dart';
import 'media_store.dart';

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

  Future<File> _file(String id) async =>
      File('${(await _clipsDir()).path}/$id.mp4');

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
  Future<Uint8List> bytes(String id) async {
    final file = await _file(id);
    if (!await file.exists()) throw StateError('Recording $id is missing');
    return file.readAsBytes();
  }

  @override
  Future<void> commitClip(
    Map<String, Object?> clip,
    Iterable<String> deleteIds,
  ) async {
    await _store.putClip(clip);
    for (final id in deleteIds) {
      final file = await _file(id);
      if (await file.exists()) await file.delete();
    }
  }
}

Future<Uint8List> readMediaBytes(String url) => File(url).readAsBytes();

String createMediaUrl(Uint8List bytes, String mimeType) =>
    throw UnsupportedError('Android plays recordings from files');

Future<bool> requestPersistentStorage() async => true;
