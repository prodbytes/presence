import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../auth/auth_service.dart';
import '../storage/event_store.dart';
import '../storage/media_store.dart';
import 'cognito.dart';
import 's3.dart';

/// A signed-in user's connection to their cloud storage.
abstract class CloudSession {
  /// The user's folder in the bucket (their Cognito identity ID).
  String get prefix;

  /// Uploads [bytes] to [key], relative to [prefix].
  Future<void> put(String key, Uint8List bytes, String contentType);
}

/// Opens [CloudSession]s from a Google ID token. [AwsCloudBackend] in the
/// app; a fake in tests.
abstract class CloudBackend {
  Future<CloudSession> connect(String idToken);

  /// Drops cached credentials (after a sign-out, or when AWS rejects them).
  void reset();
}

/// Cognito identity pool credentials + direct S3 uploads.
class AwsCloudBackend implements CloudBackend {
  AwsCloudBackend({required this._cognito, required this._bucket});

  final CognitoCredentials _cognito;
  final S3Bucket _bucket;

  @override
  Future<CloudSession> connect(String idToken) async =>
      _AwsSession(await _cognito.session(idToken), _bucket);

  @override
  void reset() => _cognito.clear();
}

class _AwsSession implements CloudSession {
  _AwsSession(this._session, this._bucket);

  final CognitoSession _session;
  final S3Bucket _bucket;

  @override
  String get prefix => _session.identityId;

  @override
  Future<void> put(String key, Uint8List bytes, String contentType) =>
      _bucket.put(
        '$prefix/$key',
        bytes,
        contentType: contentType,
        credentials: _session.credentials,
      );
}

enum CloudSyncState { off, syncing, synced, error }

/// Uploads the signed-in user's clips (videos, thumbnails, details) and
/// events to their folder in the cloud, straight from the device.
///
/// - Signed out, nothing is uploaded.
/// - On sign-in, everything stored and not yet uploaded goes up.
/// - While signed in, each new event, and each clip once its recording is
///   complete, goes up as soon as it's saved.
///
/// What's been uploaded is remembered per object key with a fingerprint of
/// its content, so nothing is sent twice and a changed event (a clip's
/// event is updated when the clip completes) is sent again.
class CloudSync extends ChangeNotifier {
  CloudSync({
    required this.auth,
    required this.backend,
    required this._store,
    required this._media,
    required Stream<void> changes,
    this.debounce = const Duration(milliseconds: 500),
  }) {
    auth.addListener(_onAuthChanged);
    _changes = changes.listen((_) => _schedule());
    _onAuthChanged();
  }

  final AuthService auth;
  final CloudBackend backend;
  final Duration debounce;
  final Future<EventStore> _store;
  final Future<MediaStore> _media;
  late final StreamSubscription<void> _changes;

  CloudSyncState _state = CloudSyncState.off;
  String? _error;
  int _uploaded = 0;
  String? _user;
  Timer? _timer;
  Future<void>? _running;
  bool _again = false;
  bool _disposed = false;

  CloudSyncState get state => _state;

  /// Why the last sync failed, when [state] is [CloudSyncState.error].
  String? get error => _error;

  /// Objects uploaded since the app started.
  int get uploaded => _uploaded;

  /// Completes when the current sync (if any) has finished (for tests).
  Future<void> idle() async {
    // Let pending change notifications reach the listener first.
    await Future<void>.delayed(Duration.zero);
    while (_running != null || (_timer?.isActive ?? false)) {
      if (_timer?.isActive ?? false) {
        _timer!.cancel();
        _startNow();
      }
      await _running;
      await Future<void>.delayed(Duration.zero);
    }
  }

  void _onAuthChanged() {
    final user = auth.user?.id;
    if (user == _user) return;
    _user = user;
    backend.reset();
    if (user == null) {
      _timer?.cancel();
      _set(CloudSyncState.off);
    } else {
      _schedule(immediately: true);
    }
  }

  void _schedule({bool immediately = false}) {
    if (_disposed || auth.user == null) return;
    _timer?.cancel();
    _timer = Timer(immediately ? Duration.zero : debounce, _startNow);
  }

  void _startNow() {
    if (_running != null) {
      _again = true;
      return;
    }
    _running = _run().whenComplete(() {
      _running = null;
      if (_again && !_disposed) {
        _again = false;
        _startNow();
      }
    });
  }

  Future<void> _run() async {
    final idToken = auth.idToken;
    if (auth.user == null || idToken == null) {
      _set(CloudSyncState.off);
      return;
    }
    _set(CloudSyncState.syncing);
    try {
      try {
        await _syncAll(await backend.connect(idToken));
      } on S3Exception catch (e) {
        if (!e.credentialsRejected) rethrow;
        // Credentials expired mid-sync: get new ones and go on.
        backend.reset();
        await _syncAll(await backend.connect(idToken));
      }
      _set(CloudSyncState.synced);
    } on CognitoException catch (e) {
      _set(
        CloudSyncState.error,
        e.needsSignIn ? 'Sign in again to resume uploads' : e.message,
      );
    } catch (e) {
      debugPrint('Presence: cloud sync failed: $e');
      _set(CloudSyncState.error, _describe(e));
    }
  }

  Future<void> _syncAll(CloudSession session) async {
    final store = await _store;
    final media = await _media;
    final synced = await store.syncedKeys();

    Future<void> upload(
      String key,
      String fingerprint,
      Future<Uint8List> Function() bytes,
      String contentType,
    ) async {
      final objectKey = '${session.prefix}/$key';
      if (synced[objectKey] == fingerprint || _disposed) return;
      await session.put(key, await bytes(), contentType);
      await store.markSynced(objectKey, fingerprint);
      synced[objectKey] = fingerprint;
      _uploaded++;
      notifyListeners();
    }

    // Clips first: recordings matter most.
    for (final clip in await store.allClips()) {
      final id = clip['id']! as String;
      if (clip['state'] != 'complete') continue;
      final ref = clip['full'] ?? clip['past'];
      if (ref is Map) {
        final mediaId = ref['mediaId']! as String;
        final mimeType = ref['mimeType'] as String? ?? 'video/webm';
        await upload(
          'clips/$id.${mimeType.contains('mp4') ? 'mp4' : 'webm'}',
          mediaId,
          () => media.bytes(mediaId),
          mimeType,
        );
      }
      final thumbnail = clip['thumbnail'];
      if (thumbnail is List && thumbnail.isNotEmpty) {
        final bytes = thumbnail is Uint8List
            ? thumbnail
            : Uint8List.fromList(thumbnail.cast<int>());
        await upload(
          'clips/$id.jpg',
          'thumbnail',
          () async => bytes,
          'image/jpeg',
        );
      }
      final details = _json({
        for (final MapEntry(:key, :value) in clip.entries)
          if (key != 'thumbnail') key: value,
      });
      await upload(
        'clips/$id.json',
        _fingerprint(details),
        () async => details,
        'application/json',
      );
    }

    for (final event in await store.allEvents()) {
      final id = event['id']! as String;
      final json = _json(event);
      await upload(
        'events/$id.json',
        _fingerprint(json),
        () async => json,
        'application/json',
      );
    }
  }

  static Uint8List _json(Map<String, Object?> record) =>
      Uint8List.fromList(utf8.encode(jsonEncode(record)));

  static String _fingerprint(Uint8List bytes) =>
      sha256.convert(bytes).toString();

  static String _describe(Object e) => switch (e) {
    S3Exception(:final statusCode) => 'Upload failed (HTTP $statusCode)',
    _ => 'Upload failed',
  };

  void _set(CloudSyncState state, [String? error]) {
    if (_disposed) return;
    _state = state;
    _error = error;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _changes.cancel();
    auth.removeListener(_onAuthChanged);
    super.dispose();
  }
}
