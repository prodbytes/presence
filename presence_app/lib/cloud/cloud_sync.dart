import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../auth/auth_service.dart';
import '../auth/roles_service.dart';
import '../events.dart';
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

  /// Every key in the user's folder, relative to [prefix].
  Future<List<String>> list();

  /// Downloads [key], relative to [prefix].
  Future<Uint8List> get(String key);
}

/// What a restore brought down from the cloud: records the device didn't
/// have, and the recordings their clips use (by media ID).
class RemoteRecords {
  const RemoteRecords({
    required this.events,
    required this.clips,
    required this.media,
  });

  final List<Map<String, Object?>> events;
  final List<Map<String, Object?>> clips;
  final Map<String, Uint8List> media;

  bool get isEmpty => events.isEmpty && clips.isEmpty;
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

  @override
  Future<List<String>> list() async => [
    for (final key in await _bucket.list(
      '$prefix/',
      credentials: _session.credentials,
    ))
      key.substring(prefix.length + 1),
  ];

  @override
  Future<Uint8List> get(String key) =>
      _bucket.get('$prefix/$key', credentials: _session.credentials);
}

enum CloudSyncState { off, syncing, synced, error }

/// Syncs the signed-in user's clips (videos, thumbnails, details) and
/// events with their folder in the cloud, straight from the device.
///
/// - Signed out, nothing is synced.
/// - On sign-in, the folder is fetched first: clips and events the device
///   doesn't have (from another device, or an earlier install) are
///   downloaded and handed to [onRemote]. Then everything stored and not
///   yet uploaded goes up.
/// - While signed in, a sync runs every [interval] (a minute), or sooner:
///   each new event, and each clip once its recording is complete, goes up
///   as soon as it's saved, whichever comes first.
/// - Only the user's own events go up (their `userId`), with their clips.
///   Anonymous ones go up once the user takes them over
///   (`Persistence.claimAnonymous`); other users' never do.
///
/// What's been uploaded is remembered per object key with a fingerprint of
/// its content, so nothing is sent twice and a changed event (a clip's
/// event is updated when the clip completes) is sent again.
class CloudSync extends ChangeNotifier {
  CloudSync({
    required this.auth,
    this.roles,
    required this.backend,
    required this._store,
    required this._media,
    required Stream<void> changes,
    this.onRemote,
    this.debounce = const Duration(milliseconds: 500),
    this.interval = const Duration(minutes: 1),
    this.restoreWindow = const Duration(days: 7),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    auth.addListener(_onAuthChanged);
    roles?.addListener(_onAuthChanged);
    _changes = changes.listen((_) => _schedule());
    _onAuthChanged();
  }

  final AuthService auth;

  /// When given, only users with access (a role) sync.
  final RolesService? roles;
  final CloudBackend backend;
  final Duration debounce;
  final Duration interval;

  /// How far back the fetch after sign-in goes: a new device gets the last
  /// week, not months of video. Older events stay in the cloud (until the
  /// bucket expires them) and on the devices that recorded them.
  final Duration restoreWindow;
  final DateTime Function() _now;

  /// Receives what a sign-in's fetch downloaded, after it's marked as
  /// synced (the app stores it and shows its events).
  final Future<void> Function(RemoteRecords records)? onRemote;
  final Future<EventStore> _store;
  final Future<MediaStore> _media;
  late final StreamSubscription<void> _changes;

  CloudSyncState _state = CloudSyncState.off;
  String? _error;
  int _uploaded = 0;
  String? _user;
  Timer? _timer;
  Timer? _periodic;
  bool _fetchPending = false;
  int _downloaded = 0;
  Future<void>? _running;
  bool _again = false;
  bool _disposed = false;

  CloudSyncState get state => _state;

  /// Why the last sync failed, when [state] is [CloudSyncState.error].
  String? get error => _error;

  /// Objects uploaded since the app started.
  int get uploaded => _uploaded;

  /// Clips and events downloaded since the app started.
  int get downloaded => _downloaded;

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

  /// The user whose data syncs: the signed-in one, if they have access.
  /// Never in dev mode, where access doesn't come from signing in.
  String? get _syncUser => roles?.mode == ExecutionMode.dev
      ? null
      : (roles == null || roles!.hasAccess)
      ? auth.user?.id
      : null;

  void _onAuthChanged() {
    final user = _syncUser;
    if (user == _user) return;
    _user = user;
    backend.reset();
    _periodic?.cancel();
    if (user == null) {
      _timer?.cancel();
      _fetchPending = false;
      _set(CloudSyncState.off);
    } else {
      _fetchPending = true;
      _periodic = Timer.periodic(interval, (_) => _schedule(immediately: true));
      _schedule(immediately: true);
    }
  }

  void _schedule({bool immediately = false}) {
    if (_disposed || _syncUser == null) return;
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
    if (_syncUser == null || idToken == null) {
      _set(CloudSyncState.off);
      return;
    }
    _set(CloudSyncState.syncing);
    Future<void> pass(CloudSession session) async {
      if (_fetchPending) {
        await _fetch(session);
        _fetchPending = false;
      }
      await _syncAll(session);
    }

    try {
      try {
        await pass(await backend.connect(idToken));
      } on S3Exception catch (e) {
        if (!e.credentialsRejected) rethrow;
        // Credentials expired mid-sync: get new ones and go on.
        backend.reset();
        await pass(await backend.connect(idToken));
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

  /// Downloads the events of the last [restoreWindow] in the user's folder
  /// that the device doesn't have, with their clips (recording and
  /// thumbnail) and tagged frames, marks them as synced, and hands them to
  /// [onRemote]. Event keys are partitioned by day, so older events aren't
  /// even read.
  Future<void> _fetch(CloudSession session) async {
    final store = await _store;
    final keys = (await session.list()).toSet();
    final localEvents = {for (final e in await store.allEvents()) e['id']};
    final localClips = {for (final c in await store.allClips()) c['id']};
    final since = _now().toUtc().subtract(restoreWindow);

    Future<Map<String, Object?>> json(String key) async =>
        (jsonDecode(utf8.decode(await session.get(key))) as Map)
            .cast<String, Object?>();
    Future<void> synced(String key, String fingerprint) =>
        store.markSynced('${session.prefix}/$key', fingerprint);

    final events = <Map<String, Object?>>[];
    for (final key in keys) {
      // Partitioned keys (events/year=YYYY/day=DDD/<id>.json), and flat
      // ones from before partitioning (events/<id>.json).
      final id = RegExp(r'^events/(?:.+/)?([^/]+)\.json$').firstMatch(key)?[1];
      if (id == null || localEvents.contains(id) || _disposed) continue;
      if (!_partitionMayBeSince(key, since)) continue;
      final event = await json(key);
      final time = event['time'];
      if (time is! int ||
          DateTime.fromMillisecondsSinceEpoch(
            time,
            isUtc: true,
          ).isBefore(since)) {
        continue;
      }
      // Events in the user's folder are theirs, even from before events
      // had owners.
      event['userId'] ??= _user;
      await synced(key, _fingerprint(_json(event)));
      // The frames its tags were clicked on come back as images.
      final frames = <String, Uint8List>{};
      final clipId = event['clipId'];
      for (final frameId in _frameIds(event)) {
        final frameKey = 'clips/$clipId/frames/$frameId.jpg';
        if (!keys.contains(frameKey)) continue;
        frames[frameId] = await session.get(frameKey);
        await synced(frameKey, frameId);
      }
      if (frames.isNotEmpty) event['frames'] = frames;
      events.add(event);
    }

    // Only the clips those events show.
    final clips = <Map<String, Object?>>[];
    final media = <String, Uint8List>{};
    final clipIds = {
      for (final e in events)
        if (e['clipId'] case final String id) id,
    };
    for (final id in clipIds) {
      final key = 'clips/$id.json';
      if (!keys.contains(key) || localClips.contains(id) || _disposed) continue;
      final clip = await json(key);
      await synced(key, _fingerprint(_json(clip)));
      final ref = clip['full'] ?? clip['past'];
      if (ref is Map) {
        final mediaId = ref['mediaId']! as String;
        final video = [
          'clips/$id.webm',
          'clips/$id.mp4',
        ].where(keys.contains).firstOrNull;
        if (video != null) {
          media[mediaId] = await session.get(video);
          await synced(video, mediaId);
        }
      }
      if (keys.contains('clips/$id.jpg')) {
        clip['thumbnail'] = await session.get('clips/$id.jpg');
        await synced('clips/$id.jpg', 'thumbnail');
      }
      clips.add(clip);
    }

    final records = RemoteRecords(events: events, clips: clips, media: media);
    if (records.isEmpty || _disposed) return;
    await onRemote?.call(records);
    _downloaded += events.length + clips.length;
    notifyListeners();
  }

  /// Whether an event key's day partition (see [eventKey]) can hold events
  /// at or after [since]: false only for a partition that ends before it.
  /// Flat keys, from before partitioning, have no day and are read.
  static bool _partitionMayBeSince(String key, DateTime since) {
    final m = RegExp(r'^events/year=(\d{4})/day=(\d{3})/').firstMatch(key);
    if (m == null) return true;
    final dayStart = DateTime.utc(int.parse(m[1]!))
        .add(Duration(days: int.parse(m[2]!) - 1));
    return !dayStart.add(const Duration(days: 1)).isBefore(since);
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

    // Only the user's events, and the clips they show.
    final events = [
      for (final record in await store.allEvents())
        if (AppEvent.ownerOf(record) == _user) record,
    ];
    final eventIds = {for (final e in events) e['id']};

    // Clips first: recordings matter most.
    for (final clip in await store.allClips()) {
      final id = clip['id']! as String;
      if (clip['state'] != 'complete') continue;
      if (!eventIds.contains(clip['eventId'])) continue;
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

    for (final record in events) {
      // Tagged frames go up as images next to the clip; the event's JSON
      // keeps the tags (name, position, frame id and time) without them.
      final frames = record['frames'];
      if (frames is Map) {
        for (final MapEntry(:key, :value) in frames.entries) {
          final jpeg = value is Uint8List
              ? value
              : (value is List ? Uint8List.fromList(value.cast<int>()) : null);
          if (jpeg == null) continue;
          await upload(
            'clips/${record['clipId']}/frames/$key.jpg',
            '$key',
            () async => jpeg,
            'image/jpeg',
          );
        }
      }
      final event = {
        for (final MapEntry(:key, :value) in record.entries)
          if (key != 'frames') key: value,
      };
      final json = _json(event);
      await upload(
        eventKey(event),
        _fingerprint(json),
        () async => json,
        'application/json',
      );
    }
  }

  static Iterable<String> _frameIds(Map<String, Object?> event) sync* {
    final annotations = event['annotations'];
    if (annotations is! List) return;
    final seen = <String>{};
    for (final a in annotations) {
      final id = a is Map ? a['frameId'] : null;
      if (id is String && seen.add(id)) yield id;
    }
  }

  /// Where an event goes in the user's folder: partitioned by the UTC day
  /// of the year of its time, Hive-style so tools such as Athena can prune
  /// by partition: `events/year=2026/day=269/<id>.json`.
  static String eventKey(Map<String, Object?> event) {
    final time = event['time'];
    final at = DateTime.fromMillisecondsSinceEpoch(
      time is int ? time : 0,
      isUtc: true,
    );
    final day = at.difference(DateTime.utc(at.year)).inDays + 1;
    return 'events/year=${at.year}/day=${day.toString().padLeft(3, '0')}/'
        '${event['id']}.json';
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
    _periodic?.cancel();
    _changes.cancel();
    auth.removeListener(_onAuthChanged);
    roles?.removeListener(_onAuthChanged);
    super.dispose();
  }
}
