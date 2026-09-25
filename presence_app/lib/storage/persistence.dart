import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:idb_shim/idb_shim.dart';

import '../camera_feeds.dart';
import '../cameras/cameras.dart';
import '../clips.dart';
import '../events.dart';
import '../settings.dart';
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
/// - the clip settings.
///
/// It subscribes to the bus as soon as it's created, so it doesn't miss
/// events published while the database is still opening.
class Persistence {
  Persistence({
    required Future<IdbFactory> factory,
    required AppEventBus bus,
    required this.settings,
    MediaStore Function(EventStore store)? mediaStore,
  }) : _store = factory.then(EventStore.open) {
    _media = _store.then(mediaStore ?? platform.newDefaultMediaStore);
    _media.ignore();
    _subscription = bus.stream.listen(_onEvent);
    // Errors surface through the operations that await the store.
    _store.ignore();
  }

  final ClipSettings settings;
  final Future<EventStore> _store;
  late final Future<MediaStore> _media;
  late final StreamSubscription<AppEvent> _subscription;
  final Set<Future<void>> _pending = {};
  CameraRig? _rig;
  List<CameraDevice>? _saved;
  bool _disposed = false;

  static const String _clipSettings = 'clip';

  /// Loads saved settings and history into [log]. Settings are saved on
  /// every change from then on.
  Future<void> restore(EventLog log) async {
    final store = await _store;

    final saved = await store.getSettings(_clipSettings);
    if (saved != null && !_disposed) {
      settings
        ..before = Duration(milliseconds: saved['beforeMs']! as int)
        ..after = Duration(milliseconds: saved['afterMs']! as int);
    }
    if (_disposed) return;
    settings.addListener(_saveSettings);

    final history = await _loadHistory(store);
    if (!_disposed) log.addHistory(history);
  }

  /// Saves the cameras the rig opens, so stored clips keep their camera.
  void attachRig(CameraRig rig) {
    _rig = rig..addListener(_saveCameras);
  }

  /// Completes when all writes issued so far have finished (for tests).
  Future<void> flush() => Future.wait(List.of(_pending));

  void dispose() {
    _disposed = true;
    _subscription.cancel();
    settings.removeListener(_saveSettings);
    _rig?.removeListener(_saveCameras);
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
    _track(() async {
      final store = await _store;
      try {
        await store.putEvent(event.toRecord());
      } catch (e) {
        debugPrint('Presence: could not save event ${event.id}: $e');
      }
      if (event is ClipRequested && event.clip.capture != null) {
        await _ClipWriter(store, await _media, event).run();
      }
    }());
  }

  void _saveSettings() {
    _track(() async {
      final store = await _store;
      await store.putSettings(_clipSettings, {
        'beforeMs': settings.before.inMilliseconds,
        'afterMs': settings.after.inMilliseconds,
      });
    }());
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

  Future<List<AppEvent>> _loadHistory(EventStore store) async {
    final media = await _media;
    final cameraLabels = {
      for (final c in await store.allCameras())
        c['id']! as String: c['label']! as String,
    };
    final clips = {
      for (final c in await store.allClips())
        c['id']! as String: _restoreClip(media, c, cameraLabels),
    };

    return [
      for (final record in await store.allEvents())
        _restoreEvent(record, clips),
    ];
  }

  AppEvent _restoreEvent(
    Map<String, Object?> record,
    Map<String, VideoClip> clips,
  ) {
    if (record['type'] == ClipRequested.clipRequestedType) {
      final clip = clips[record['clipId']];
      if (clip != null) {
        return ClipRequested(
          clip,
          id: record['id']! as String,
          time: DateTime.fromMillisecondsSinceEpoch(record['time']! as int),
        );
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
      past: _restoreMedia(media, record['past']),
      full: _restoreMedia(media, record['full']),
      thumbnail: _bytes(record['thumbnail']),
      supported: record['supported'] as bool? ?? true,
      error: record['state'] == _ClipWriter.failed ? 'Recording failed' : null,
    );
  }

  ClipMedia? _restoreMedia(MediaStore media, Object? ref) {
    if (ref is! Map) return null;
    final mediaId = ref['mediaId']! as String;
    final mimeType = ref['mimeType'] as String? ?? ClipMedia.defaultMimeType;
    return ClipMedia.stored(
      load: () => media.load(mediaId, mimeType),
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
