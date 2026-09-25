import 'dart:typed_data';

import '../cameras/camera_source.dart';
import 'event_store.dart';
import 'media_platform.dart' as platform;

/// Where clip recordings live. The web keeps them inside IndexedDB; Android
/// keeps them as files (see `media_platform_native.dart`).
abstract class MediaStore {
  /// Saves a live recording under [id].
  Future<void> save(String id, ClipMedia media);

  /// A playable URL (web) or file path (Android) for a saved recording.
  Future<String> load(String id, String mimeType);

  /// Saves [clip] and deletes the recordings in [deleteIds], atomically
  /// where the backend allows it.
  Future<void> commitClip(
    Map<String, Object?> clip,
    Iterable<String> deleteIds,
  );
}

/// Moves recordings between playable URLs and stored bytes. Replaceable in
/// tests; defaults to the platform implementation.
class MediaIo {
  const MediaIo({
    this.readBytes = platform.readMediaBytes,
    this.createUrl = platform.createMediaUrl,
  });

  final Future<Uint8List> Function(String url) readBytes;
  final String Function(Uint8List bytes, String mimeType) createUrl;
}

/// Recordings stored as bytes in the IndexedDB `media` store.
class IdbMediaStore implements MediaStore {
  IdbMediaStore(this._store, [this._io = const MediaIo()]);

  final EventStore _store;
  final MediaIo _io;

  @override
  Future<void> save(String id, ClipMedia media) async {
    final url = media.liveUrl;
    if (url == null) return;
    await _store.putMedia(id, await _io.readBytes(url));
  }

  @override
  Future<String> load(String id, String mimeType) async {
    final bytes = await _store.getMedia(id);
    if (bytes == null) throw StateError('Recording $id is missing');
    return _io.createUrl(bytes, mimeType);
  }

  @override
  Future<void> commitClip(
    Map<String, Object?> clip,
    Iterable<String> deleteIds,
  ) => _store.putClipAndDeleteMedia(clip, deleteIds);
}
