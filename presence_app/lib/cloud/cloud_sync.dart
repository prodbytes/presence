import 'dart:async';
import 'dart:convert';
import 'dart:math';

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
  /// The user's folder in the bucket (their profile's Cognito identity ID).
  String get prefix;

  /// Uploads [bytes] to [key], relative to [prefix].
  Future<void> put(String key, Uint8List bytes, String contentType);

  /// Uploads [length] bytes from [body] to [key], relative to [prefix], as
  /// they're read (a recording, without holding or hashing it whole).
  Future<void> putStream(
    String key,
    Stream<List<int>> body,
    int length,
    String contentType,
  );

  /// Every key in the user's folder that starts with [under] (all of them
  /// by default), relative to [prefix].
  Future<List<String>> list([String under = '']);

  /// Like [list], with each key's ETag: the MD5 of its bytes, in hex
  /// ([CloudSync.etagOf]), so a changed object shows without downloading it.
  Future<Map<String, String>> listETags([String under = '']);

  /// Downloads [key], relative to [prefix].
  Future<Uint8List> get(String key);
}

/// This device's settings, kept in the cloud per device
/// ([CloudSync.settingsKey]). `Persistence` in the app.
abstract class DeviceSettings {
  /// This device's ID.
  Future<String> get deviceId;

  /// The settings as stored: `{deviceId, profileId, updatedAt, config,
  /// location}`, where `profileId` is the profile they were last synced
  /// with (absent before the first sync), `updatedAt` is when they were
  /// last changed (ms since the epoch; 0 for the defaults, never changed)
  /// and `location` is the location set on the map, or null.
  Future<Map<String, Object?>> settingsRecord();

  /// Takes on a record fetched from the cloud: newer than the local one,
  /// or the signing-in profile's while the local one is another's.
  Future<void> applySettings(Map<String, Object?> record);

  /// The settings now belong to [profileId] (they're synced with its
  /// folder). Not a change by the user.
  Future<void> claimSettings(String profileId);
}

/// What a restore brought down from the cloud, one batch of it: records the
/// device didn't have (with their thumbnails), and the events it has that
/// changed elsewhere. The recordings their clips use aren't in it: they
/// come down afterwards, into the `MediaStore` ([CloudSync.fetchRecording],
/// and in the background off the web).
class RemoteRecords {
  const RemoteRecords({
    this.events = const [],
    this.clips = const [],
    this.updated = const [],
  });

  final List<Map<String, Object?>> events;
  final List<Map<String, Object?>> clips;

  /// Events the device has, changed on another device since: their records
  /// as fetched, with the frames their tags use that the device lacks.
  final List<Map<String, Object?>> updated;

  bool get isEmpty => events.isEmpty && clips.isEmpty && updated.isEmpty;
}

/// Opens [CloudSession]s from a Google ID token. [AwsCloudBackend] in the
/// app; a fake in tests.
abstract class CloudBackend {
  Future<CloudSession> connect(String idToken);

  /// Drops cached credentials (after a sign-out, or when AWS rejects them).
  void reset();
}

/// Profile credentials (the auth API, then the Cognito identity pool) +
/// direct S3 uploads.
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
  Future<void> putStream(
    String key,
    Stream<List<int>> body,
    int length,
    String contentType,
  ) => _bucket.putStream(
    '$prefix/$key',
    body,
    length,
    contentType: contentType,
    credentials: _session.credentials,
  );

  @override
  Future<List<String>> list([String under = '']) async => [
    for (final key in await _bucket.list(
      '$prefix/$under',
      credentials: _session.credentials,
    ))
      key.substring(prefix.length + 1),
  ];

  @override
  Future<Map<String, String>> listETags([String under = '']) async => {
    for (final MapEntry(:key, :value) in (await _bucket.listETags(
      '$prefix/$under',
      credentials: _session.credentials,
    )).entries)
      key.substring(prefix.length + 1): value,
  };

  @override
  Future<Uint8List> get(String key) =>
      _bucket.get('$prefix/$key', credentials: _session.credentials);
}

enum CloudSyncState { off, syncing, synced, error }

/// Syncs the signed-in user's clips (videos, thumbnails, details) and
/// events with their folder in the cloud, straight from the device.
///
/// - Signed out, nothing is synced.
/// - Every pass fetches first: events in the user's folder the device
///   doesn't have (from another device, or an earlier install), newest
///   first and at most [maxFetch], no older than [restoreWindow], with
///   their clips, are downloaded and handed to [onRemote] (the app stores
///   them, and the Events and Subjects tabs show them). Events the device
///   has that another device changed since (their listed ETag isn't the
///   one this device last uploaded or downloaded) come down again too, as
///   [RemoteRecords.updated], unless changed here and not uploaded yet.
///   They're handed over in batches of [fetchBatch] events, with their
///   clips' records and thumbnails and their tagged frames, but not the
///   recordings: those are big (megabytes each, against kilobytes for the
///   rest), so a new device shows every device's events within seconds.
///   Then what's not yet uploaded goes up. So every device of a user ends
///   up with the same events as the bucket.
/// - Recordings come down after their clips, never holding them up: each
///   one a fetched clip uses is remembered as pending (`fetch:` entries of
///   the synced store) and marked as synced at once, since it's in the
///   cloud (so it's never uploaded back). With [prefetchRecordings] (not
///   on the web, where they'd fill IndexedDB), a background download takes
///   the pending ones after each pass, newest first, one at a time; one
///   that fails is skipped until the next full fetch, and what's left
///   resumes after the next pass. Playing a clip whose recording isn't here
///   yet downloads it then ([fetchRecording]), on any platform.
/// - Uploads look only at the events saved since the last pass (`changes`
///   names them), with their clips. A reconciliation, which looks at every
///   stored event, runs on the first pass for a user, with each full fetch
///   ([fullFetchEvery]), and after a change notification that doesn't say
///   what changed (null).
/// - A pass runs at start (sign-in, or a session restored at launch), every
///   [interval] (15 s), and soon after each new event or completed clip.
///   After a failed pass the timer backs off: each failure in a row
///   doubles the wait, up to [maxBackoff] intervals.
/// - When credentials can't be had (the auth API or Cognito fails), syncing
///   stops: no pass runs until the Google ID token changes (signing in
///   again), [retry] or [reconnect].
/// - What a pass lists is kept small, since listing is billed per request:
///   the first pass for a user lists all of `events/` (old unpartitioned
///   keys included), one every [fullFetchEvery] lists each day of the
///   [restoreWindow], and the others only today's and yesterday's
///   partitions, where other devices' new events land.
/// - Only the profile's own events go up (their `profileId`), with their
///   clips. Nothing syncs without a profile: events recorded signed out go
///   up once a sign-in gives them its profile
///   (`Persistence.claimForProfile`); other profiles' never do.
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
    required Stream<Set<String>?> changes,
    this.onRemote,
    this.settings,
    this.debounce = const Duration(milliseconds: 500),
    this.interval = const Duration(seconds: 15),
    this.restoreWindow = const Duration(days: 14),
    this.keep,
    this.maxFetch = 1000,
    this.fetchBatch = 25,
    this.fullFetchEvery = const Duration(hours: 1),
    this.maxBackoff = 16,
    bool? prefetchRecordings,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       prefetchRecordings = prefetchRecordings ?? !kIsWeb {
    auth.addListener(_onAuthChanged);
    roles?.addListener(_onAuthChanged);
    _changes = changes.listen(_onChanged);
    _onAuthChanged();
  }

  final AuthService auth;

  /// When given, this device's settings sync too: fetched on the first pass
  /// for a user (taken on when newer than the local ones), and uploaded
  /// whenever they change.
  final DeviceSettings? settings;

  /// When given, only users with access (a role) sync.
  final RolesService? roles;
  final CloudBackend backend;
  final Duration debounce;
  final Duration interval;

  /// How far back a fetch goes: a new device gets the last two weeks, not
  /// months of video. Older events stay in the cloud (until the bucket
  /// expires them) and on the devices that recorded them.
  final Duration restoreWindow;

  /// How long the device keeps events (the History setting): a fetch
  /// doesn't download what it deletes as too old, so with a shorter
  /// setting the window shrinks to it.
  final Duration Function()? keep;

  /// [restoreWindow], or [keep] when that's shorter.
  Duration get _window {
    final keep = this.keep?.call();
    return keep != null && keep < restoreWindow ? keep : restoreWindow;
  }

  /// The most events one fetch downloads, the newest first; the rest come
  /// in later passes.
  final int maxFetch;

  /// How many events a fetch downloads before handing them to [onRemote]
  /// (with their clips and thumbnails), so a big restore doesn't pile up
  /// in memory.
  final int fetchBatch;

  /// The longest wait between passes after failures in a row, in
  /// [interval]s (16: 4 min at 15 s).
  final int maxBackoff;

  /// How often a pass lists every day of the [restoreWindow] (to catch
  /// events uploaded late, by a device that was offline) rather than only
  /// today and yesterday.
  final Duration fullFetchEvery;

  /// Whether fetched clips' recordings are downloaded in the background
  /// after each pass (Android and desktop), rather than only when played
  /// (the web, whose IndexedDB quota a profile's recordings would fill).
  final bool prefetchRecordings;
  final DateTime Function() _now;

  /// Receives what a fetch downloaded, after it's marked as synced (the app
  /// stores it and shows its events).
  final Future<void> Function(RemoteRecords records)? onRemote;
  final Future<EventStore> _store;
  final Future<MediaStore> _media;
  late final StreamSubscription<Set<String>?> _changes;

  /// Events saved since the last pass (named by `changes`): the only ones
  /// an ordinary pass uploads.
  final Set<String> _dirty = {};

  /// Whether the next pass looks at every stored event: at start, and
  /// after a change notification that doesn't name what changed.
  bool _reconcile = true;

  /// The `synced` store as this sync knows it: read at each
  /// reconciliation, and kept up to date with what it marks since.
  Map<String, String>? _synced;

  /// Failed passes in a row, and how many timer ticks to let go by before
  /// the next try.
  int _failures = 0;
  int _ticksToSkip = 0;

  /// Lets frames through during long loops ([_breathe]).
  int _steps = 0;

  CloudSyncState _state = CloudSyncState.off;
  String? _error;
  int _uploaded = 0;

  /// The profile syncing now ([_syncProfile]); null while nothing syncs.
  String? _owner;
  Timer? _timer;
  Timer? _periodic;

  /// When the last pass that listed the whole window ran; null until the
  /// first pass for this user, which lists all of `events/`.
  DateTime? _lastFullFetch;
  int _downloaded = 0;
  Future<void>? _running;

  /// The background download of pending recordings, while it runs.
  Future<void>? _prefetching;

  /// Recordings being downloaded now, by object key: one download each,
  /// whether in the background or for playing.
  final Map<String, Future<bool>> _inFlight = {};

  /// Recordings the background download failed to get: not tried again
  /// until the next full fetch (one may not be uploaded yet).
  final Set<String> _prefetchFailed = {};
  bool _again = false;
  bool _disposed = false;

  /// The ID token credentials failed for: syncing has stopped until it
  /// changes, or until [retry].
  String? _stoppedFor;

  /// Whether syncing has stopped after credentials failed (see [retry]).
  bool get stopped => _stoppedFor != null;

  CloudSyncState get state => _state;

  /// Why the last sync failed, when [state] is [CloudSyncState.error].
  String? get error => _error;

  /// Objects uploaded since the app started.
  int get uploaded => _uploaded;

  /// Clips and events downloaded since the app started.
  int get downloaded => _downloaded;

  /// Completes when the current sync (if any) has finished (for tests),
  /// background downloads of recordings included.
  Future<void> idle() async {
    // Let pending change notifications reach the listener first.
    await Future<void>.delayed(Duration.zero);
    while (_running != null ||
        _prefetching != null ||
        (_timer?.isActive ?? false)) {
      if (_timer?.isActive ?? false) {
        _timer!.cancel();
        _startNow();
      }
      await _running;
      await _prefetching;
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// The profile whose data syncs: the signed-in account's, once the auth
  /// API has answered with it, if the account has access. Never in dev
  /// mode, where nobody signs in. Without [roles] (tests), the signed-in
  /// user's ID stands in for it.
  String? get _syncProfile {
    final roles = this.roles;
    if (roles == null) return auth.user?.id;
    if (roles.mode == ExecutionMode.dev || !roles.hasAccess) return null;
    return auth.user == null ? null : roles.profile;
  }

  void _onAuthChanged() {
    final profile = _syncProfile;
    if (profile == _owner) {
      // Signed in again (a new ID token): try again after a stop.
      if (profile != null && stopped && auth.idToken != _stoppedFor) retry();
      return;
    }
    _owner = profile;
    _stoppedFor = null;
    backend.reset();
    _periodic?.cancel();
    _startOver();
    if (profile == null) {
      _timer?.cancel();
      _set(CloudSyncState.off);
    } else {
      _startPeriodic();
      _schedule(immediately: true);
    }
  }

  /// As for a new user: the first pass lists everything and reconciles.
  void _startOver() {
    _lastFullFetch = null;
    _reconcile = true;
    _synced = null;
    _dirty.clear();
    _failures = 0;
    _ticksToSkip = 0;
    _prefetchFailed.clear();
  }

  void _startPeriodic() {
    _periodic?.cancel();
    _periodic = Timer.periodic(interval, (_) {
      // Backing off after failures.
      if (_ticksToSkip > 0) {
        _ticksToSkip--;
        return;
      }
      _schedule(immediately: true);
    });
  }

  void _onChanged(Set<String>? ids) {
    if (ids == null) {
      _reconcile = true;
    } else {
      _dirty.addAll(ids);
    }
    // While backing off, the timer's next try takes them.
    if (_ticksToSkip == 0) _schedule();
  }

  /// How long until the next pass after the failures so far: [interval]
  /// after one, doubling with each more, up to [maxBackoff] intervals.
  @visibleForTesting
  Duration get backoff => interval * (_ticksToSkip + 1);

  /// Starts over with new credentials, as for a new user: after the
  /// signed-in account joins or leaves a profile, its folder is another one.
  void reconnect() {
    if (_owner == null) return;
    backend.reset();
    _startOver();
    retry();
  }

  /// Syncs again after credentials failed and syncing [stopped].
  void retry() {
    if (_owner == null || _disposed) return;
    if (stopped) {
      _stoppedFor = null;
      _startPeriodic();
    }
    _ticksToSkip = 0;
    _schedule(immediately: true);
  }

  void _schedule({bool immediately = false}) {
    if (_disposed || _syncProfile == null || stopped) return;
    _timer?.cancel();
    _timer = Timer(immediately ? Duration.zero : debounce, _startNow);
  }

  /// Every [every]th call, waits for the event loop, so frames get drawn
  /// during long loops over storage (whose reads may complete at once,
  /// which would otherwise chain into one long task).
  Future<void> _breathe([int every = 20]) async {
    if (++_steps % every == 0) await Future<void>.delayed(Duration.zero);
  }

  Future<void> _markSynced(EventStore store, String key, String value) async {
    await store.markSynced(key, value);
    _synced?[key] = value;
  }

  void _startNow() {
    if (stopped) return;
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
    final owner = _syncProfile;
    if (owner == null || idToken == null) {
      _set(CloudSyncState.off);
      return;
    }
    _set(CloudSyncState.syncing);
    // What this pass uploads; given back if it fails.
    final dirty = Set.of(_dirty);
    _dirty.clear();
    var reconcile = _reconcile;
    _reconcile = false;
    Future<void> pass(CloudSession session) async {
      final now = _now().toUtc();
      final last = _lastFullFetch;
      final full = last == null || now.difference(last) >= fullFetchEvery;
      if (full) {
        reconcile = true;
        // Recordings that failed get another try.
        _prefetchFailed.clear();
      }
      // Read again at each reconciliation, so entries pruned with the
      // events they were for go from memory too.
      if (_synced == null || reconcile) {
        _synced = await (await _store).syncedKeys();
      }
      if (last == null) await _fetchSettings(session, owner);
      await _fetch(
        session,
        _fetchPrefixes(now, first: last == null, full: full),
      );
      if (full) _lastFullFetch = now;
      await _syncAll(session, reconcile ? null : dirty);
    }

    void giveBack() {
      _dirty.addAll(dirty);
      if (reconcile) _reconcile = true;
    }

    try {
      try {
        await pass(await backend.connect(idToken));
      } on S3Exception catch (e) {
        if (!e.credentialsRejected) rethrow;
        // Credentials expired mid-sync: get new ones and go on.
        debugPrint('Presence: cloud credentials rejected, renewing: $e');
        backend.reset();
        await pass(await backend.connect(idToken));
      }
      if (_failures > 0) {
        debugPrint(
          'Presence: cloud sync recovered after $_failures failed passes',
        );
      }
      _failures = 0;
      _ticksToSkip = 0;
      _set(CloudSyncState.synced);
      _startPrefetch();
    } on CognitoException catch (e) {
      giveBack();
      // Trying again each pass fails the same way: stop until the user
      // signs in again or retries.
      _stoppedFor = idToken;
      _periodic?.cancel();
      _timer?.cancel();
      _again = false;
      debugPrint(
        'Presence: cloud sync failed, stopped until sign-in or retry: $e',
      );
      _set(
        CloudSyncState.error,
        e.needsSignIn ? 'Sign in again to resume uploads' : e.message,
      );
    } catch (e, stack) {
      giveBack();
      _failures++;
      // Each failure in a row doubles the wait: 1, 2, 4… intervals.
      _ticksToSkip = min(1 << min(_failures - 1, 30), maxBackoff) - 1;
      if (_failures == 1) {
        // The stack once per streak, not every 15 s while offline.
        debugPrint('Presence: cloud sync failed: $e\n$stack');
      } else {
        debugPrint(
          'Presence: cloud sync failed again ($_failures in a row, next '
          'try in ${backoff.inSeconds} s): $e',
        );
      }
      _set(CloudSyncState.error, _describe(e));
    }
  }

  /// What a pass lists under the user's folder: all of `events/` on the
  /// [first] pass, every day of the [restoreWindow] on a [full] one, and
  /// otherwise today's and yesterday's partitions (UTC).
  List<String> _fetchPrefixes(
    DateTime now, {
    required bool first,
    required bool full,
  }) {
    if (first) return const ['events/'];
    final days = full ? _window.inDays : 1;
    return [
      for (var d = 0; d <= days; d++)
        _dayPrefix(now.subtract(Duration(days: d))),
    ];
  }

  /// Downloads the events under [prefixes] that the device doesn't have,
  /// from the last [restoreWindow] and at most [maxFetch] of them (the
  /// newest first), with their clips (recording and thumbnail) and tagged
  /// frames, marks them as synced, and hands them to [onRemote]. Event keys
  /// are partitioned by day, so older events aren't even read.
  ///
  /// Events the device has that another device changed since (their ETag
  /// isn't the one this device last uploaded or downloaded) are downloaded
  /// again, within the same [maxFetch], and handed over as
  /// [RemoteRecords.updated]; unless they changed here too and that isn't
  /// uploaded yet: then this device's version goes up over the other.
  Future<void> _fetch(CloudSession session, List<String> prefixes) async {
    final store = await _store;
    final listed = <String, String>{
      for (final under in prefixes) ...await session.listETags(under),
    };
    final keys = listed.keys;
    // Only the IDs: records are read one by one, when needed.
    final localEvents = await store.eventIds();
    final localClips = await store.clipIds();
    final syncedKeys = _synced ??= await store.syncedKeys();
    final since = _now().toUtc().subtract(_window);

    // Each new event's media (recording, thumbnail, tagged frames), listed
    // only for it.
    final mediaKeyCache = <String, Set<String>>{};
    Future<Set<String>> mediaKeys(
      String clipId,
    ) async => mediaKeyCache[clipId] ??= {
      for (final k in await session.list('media/$clipId'))
        if (k.startsWith('media/$clipId.') || k.startsWith('media/$clipId/')) k,
    };

    Map<String, Object?> decode(Uint8List bytes) =>
        (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();
    Future<void> synced(String key, String fingerprint) =>
        _markSynced(store, '${session.prefix}/$key', fingerprint);
    Future<void> keepETag(String key, String etag) =>
        _markSynced(store, _etagKey('${session.prefix}/$key'), etag);
    // A recording in the cloud: synced (never uploaded back), and pending
    // here until it's downloaded.
    Future<void> pending(String key, String mediaId, int time) async {
      await synced(key, mediaId);
      await _markSynced(
        store,
        _fetchKey('${session.prefix}/$key'),
        '$time:$mediaId',
      );
    }

    // Partitioned keys (events/year=YYYY/day=DDD/<id>.json), and flat ones
    // from before partitioning (events/<id>.json). The newest day first:
    // the zero-padded partitions sort by date.
    final idOf = RegExp(r'^events/(?:.+/)?([^/]+)\.json$');
    final missing = [
      for (final key in keys)
        if (idOf.firstMatch(key)?[1] case final id?
            when !localEvents.contains(id) && _partitionMayBeSince(key, since))
          key,
    ]..sort((a, b) => b.compareTo(a));

    // Changed elsewhere: only at the key this device uploads the event to
    // (not a copy left under the layout from before partitioning).
    final changed = <String>[];
    for (final MapEntry(:key, value: etag) in listed.entries) {
      await _breathe(200);
      final id = idOf.firstMatch(key)?[1];
      if (id == null || !localEvents.contains(id)) continue;
      if (!_partitionMayBeSince(key, since)) continue;
      final objectKey = '${session.prefix}/$key';
      if (syncedKeys[_etagKey(objectKey)] == etag) continue;
      final local = await store.getEvent(id);
      if (local == null || eventKey(local) != key) continue;
      final json = _eventJson(local);
      if (etagOf(json) == etag) {
        // The same bytes (uploaded before ETags were kept).
        await keepETag(key, etag);
        continue;
      }
      // Changed here and not uploaded yet: this version wins.
      if (syncedKeys[objectKey] != _fingerprint(json)) continue;
      changed.add(key);
    }
    changed.sort((a, b) => b.compareTo(a));

    // Hands a batch over, and counts it.
    Future<void> deliver(RemoteRecords records) async {
      if (records.isEmpty || _disposed) return;
      await onRemote?.call(records);
      _downloaded +=
          records.events.length + records.clips.length + records.updated.length;
      notifyListeners();
    }

    // The new events, a batch at a time, newest first.
    var kept = 0;
    final todo = missing.take(maxFetch).toList();
    for (var i = 0; i < todo.length && !_disposed; i += fetchBatch) {
      final batch = todo.sublist(i, min(i + fetchBatch, todo.length));
      final (events, clips) = await _fetchNew(
        session,
        batch,
        since: since,
        localClips: localClips,
        mediaKeys: mediaKeys,
        synced: synced,
        keepETag: keepETag,
        pending: pending,
      );
      kept += events.length;
      await deliver(RemoteRecords(events: events, clips: clips));
    }

    // Then the changed ones, with the frames their tags use that the
    // device doesn't have.
    final changedTodo = changed.take(max(0, maxFetch - kept)).toList();
    for (var i = 0; i < changedTodo.length && !_disposed; i += fetchBatch) {
      final updated = <Map<String, Object?>>[];
      final updatedETags = <String, String>{};
      for (final key in changedTodo.sublist(
        i,
        min(i + fetchBatch, changedTodo.length),
      )) {
        if (_disposed) break;
        final bytes = await session.get(key);
        final event = decode(bytes);
        event['profileId'] = _owner;
        final local = await store.getEvent('${event['id']}');
        final have = local?['frames'] is Map ? local!['frames']! as Map : {};
        final frames = <String, Uint8List>{};
        final clipId = event['clipId'];
        for (final frameId in _frameIds(event)) {
          if (have.containsKey(frameId)) continue;
          final ofClip = clipId is String
              ? await mediaKeys(clipId)
              : <String>{};
          final frameKey = frameKeyOf('$clipId', frameId);
          if (!ofClip.contains(frameKey)) continue;
          frames[frameId] = await session.get(frameKey);
          await synced(frameKey, frameId);
        }
        if (frames.isNotEmpty) event['frames'] = frames;
        updated.add(event);
        updatedETags[key] = etagOf(bytes);
      }
      if (updated.isEmpty || _disposed) continue;
      await deliver(RemoteRecords(updated: updated));
      // The changed events as the device keeps them now are in sync: not
      // uploaded back, nor downloaded again.
      for (final MapEntry(:key, value: etag) in updatedETags.entries) {
        final id = idOf.firstMatch(key)?[1];
        final record = id == null ? null : await store.getEvent(id);
        if (record == null || eventKey(record) != key) continue;
        await synced(key, _fingerprint(_eventJson(record)));
        await keepETag(key, etag);
      }
    }
  }

  /// Downloads the events at [keys] (missing here) that are from [since]
  /// on, with their tagged frames and their clips (records and
  /// thumbnails). Their recordings are only noted as [pending]: they come
  /// down later, so the batch is handed over without waiting for them.
  Future<(List<Map<String, Object?>>, List<Map<String, Object?>>)> _fetchNew(
    CloudSession session,
    List<String> keys, {
    required DateTime since,
    required Set<String> localClips,
    required Future<Set<String>> Function(String clipId) mediaKeys,
    required Future<void> Function(String key, String fingerprint) synced,
    required Future<void> Function(String key, String etag) keepETag,
    required Future<void> Function(String key, String mediaId, int time)
    pending,
  }) async {
    Map<String, Object?> decode(Uint8List bytes) =>
        (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();

    final events = <Map<String, Object?>>[];
    for (final key in keys) {
      if (_disposed) break;
      final bytes = await session.get(key);
      final event = decode(bytes);
      final time = event['time'];
      if (time is! int ||
          DateTime.fromMillisecondsSinceEpoch(
            time,
            isUtc: true,
          ).isBefore(since)) {
        continue;
      }
      // Events in the profile's folder are the profile's, even from before
      // events had profiles.
      event['profileId'] = _owner;
      await synced(key, _fingerprint(_json(event)));
      await keepETag(key, etagOf(bytes));
      // The frames its tags were clicked on come back as images.
      final frames = <String, Uint8List>{};
      final clipId = event['clipId'];
      final ofClip = clipId is String ? await mediaKeys(clipId) : <String>{};
      for (final frameId in _frameIds(event)) {
        final frameKey = frameKeyOf('$clipId', frameId);
        if (!ofClip.contains(frameKey)) continue;
        frames[frameId] = await session.get(frameKey);
        await synced(frameKey, frameId);
      }
      if (frames.isNotEmpty) event['frames'] = frames;
      events.add(event);
    }

    // Only the clips those events show.
    final clips = <Map<String, Object?>>[];
    // Each clip's record is in its event's day partition (both are timed
    // when the clip was requested).
    final clipTimes = <String, int>{
      for (final e in events)
        if ((e['clipId'], e['time']) case (final String id, final int time))
          id: time,
    };
    for (final MapEntry(key: id, value: time) in clipTimes.entries) {
      final key = clipRecordKey(id, time);
      if (localClips.contains(id) || _disposed) continue;
      if (!(await session.list(key)).contains(key)) continue;
      final ofClip = await mediaKeys(id);
      final clip = decode(await session.get(key));
      await synced(key, _fingerprint(_json(clip)));
      final ref = clip['full'] ?? clip['past'];
      if (ref is Map) {
        final mediaId = ref['mediaId']! as String;
        // Where it is, or, for a complete clip whose recording is still
        // going up from its device, where it'll be.
        final video =
            [
              'media/$id.webm',
              'media/$id.mp4',
            ].where(ofClip.contains).firstOrNull ??
            (clip['state'] == 'complete'
                ? 'media/$id.${_extOf(ref['mimeType'] as String?)}'
                : null);
        if (video != null) await pending(video, mediaId, time);
      }
      if (ofClip.contains('media/$id.jpg')) {
        clip['thumbnail'] = await session.get('media/$id.jpg');
        await synced('media/$id.jpg', 'thumbnail');
      }
      clips.add(clip);
    }
    return (events, clips);
  }

  /// A recording's file extension in the cloud, from its MIME type.
  static String _extOf(String? mimeType) =>
      (mimeType ?? '').contains('mp4') ? 'mp4' : 'webm';

  /// Starts the background download of pending recordings, unless it's
  /// running already or this platform downloads them only when played.
  void _startPrefetch() {
    if (!prefetchRecordings || _prefetching != null || _disposed) return;
    final owner = _owner;
    if (owner == null) return;
    // Nothing pending (as this sync knows): not even a connection.
    if (!_hasPending(_synced)) return;
    _prefetching = _prefetch(owner)
        .catchError((Object e) {
          debugPrint('Presence: recordings download stopped: $e');
        })
        .whenComplete(() => _prefetching = null);
  }

  /// Downloads the recordings pending for [owner]'s folder, newest first,
  /// one at a time, while [owner] is still the one syncing. One that fails
  /// is skipped (until the next full fetch); a few failures in a row (the
  /// network is down) stop it until the next pass.
  Future<void> _prefetch(String owner) async {
    bool current() => !_disposed && !stopped && _owner == owner;
    final idToken = auth.idToken;
    if (idToken == null || !current()) return;
    // Read afresh: entries of events deleted since are gone.
    final synced = await (await _store).syncedKeys();
    if (!_hasPending(synced)) return;
    var session = await backend.connect(idToken);
    final todo = _pendingIn(synced, session.prefix)
        .where(
          (p) => !_prefetchFailed.contains(
            _fetchKey('${session.prefix}/${p.key}'),
          ),
        )
        .toList();
    var failuresInRow = 0;
    for (final (:key, :mediaId) in todo) {
      if (!current()) return;
      try {
        await _download(session, key, mediaId);
        failuresInRow = 0;
      } catch (e) {
        if (e is S3Exception && e.credentialsRejected) {
          // Expired while downloading: new ones for the rest.
          backend.reset();
          final token = auth.idToken;
          if (token == null) return;
          session = await backend.connect(token);
        }
        _prefetchFailed.add(_fetchKey('${session.prefix}/$key'));
        debugPrint('Presence: could not download recording $key: $e');
        if (++failuresInRow >= 3) return;
      }
    }
  }

  /// Whether [synced] (all of it when null, not read yet) has recordings
  /// pending download that haven't failed since the last full fetch.
  bool _hasPending(Map<String, String>? synced) =>
      synced == null ||
      synced.keys.any(
        (k) => k.startsWith('fetch:') && !_prefetchFailed.contains(k),
      );

  /// The recordings pending download into [prefix]'s folder (`fetch:`
  /// entries of [synced]), newest first: their keys relative to the
  /// folder, and their media IDs.
  static List<({String key, String mediaId})> _pendingIn(
    Map<String, String> synced,
    String prefix,
  ) {
    final start = _fetchKey('$prefix/');
    final found = <(int, String, String)>[];
    for (final MapEntry(:key, :value) in synced.entries) {
      if (!key.startsWith(start)) continue;
      final colon = value.indexOf(':');
      if (colon < 0) continue;
      found.add((
        int.tryParse(value.substring(0, colon)) ?? 0,
        key.substring(start.length),
        value.substring(colon + 1),
      ));
    }
    found.sort((a, b) => b.$1.compareTo(a.$1));
    return [
      for (final (_, key, mediaId) in found) (key: key, mediaId: mediaId),
    ];
  }

  /// Downloads the recording at [key] into the `MediaStore` as [mediaId],
  /// and marks it as synced and no longer pending. Once at a time per key.
  Future<bool> _download(CloudSession session, String key, String mediaId) {
    final objectKey = '${session.prefix}/$key';
    return _inFlight[objectKey] ??= () async {
      try {
        final store = await _store;
        final bytes = await session.get(key);
        await (await _media).saveBytes(mediaId, bytes);
        await _markSynced(store, objectKey, mediaId);
        await store.unmarkSynced(_fetchKey(objectKey));
        _synced?.remove(_fetchKey(objectKey));
        return true;
      } finally {
        _inFlight.remove(objectKey);
      }
    }();
  }

  /// Downloads the recording [mediaId] of clip [clipId] from the signed-in
  /// profile's folder into the `MediaStore`, for playing a clip fetched
  /// from the cloud whose recording isn't here yet. Returns whether it's
  /// stored now; false when signed out, or it isn't in the cloud, or the
  /// download failed.
  Future<bool> fetchRecording(String clipId, String mediaId) async {
    final idToken = auth.idToken;
    if (_owner == null || idToken == null || stopped || _disposed) {
      return false;
    }
    try {
      var session = await backend.connect(idToken);
      final candidates = ['media/$clipId.webm', 'media/$clipId.mp4'];
      final synced = _synced ??= await (await _store).syncedKeys();
      final key =
          candidates
              .where(
                (k) => synced.containsKey(_fetchKey('${session.prefix}/$k')),
              )
              .firstOrNull ??
          (await session.list('media/$clipId.'))
              .where(candidates.contains)
              .firstOrNull;
      if (key == null) return false;
      try {
        return await _download(session, key, mediaId);
      } on S3Exception catch (e) {
        if (!e.credentialsRejected) rethrow;
        backend.reset();
        session = await backend.connect(idToken);
        return await _download(session, key, mediaId);
      }
    } catch (e) {
      debugPrint('Presence: could not download recording of $clipId: $e');
      return false;
    }
  }

  /// Fetches this device's settings, if the cloud has them, and hands them
  /// to [settings] when they're newer than the local ones, or when the
  /// local ones are another profile's: a sign-in restores what the
  /// profile last had on this device. Then the local settings are the
  /// profile's.
  Future<void> _fetchSettings(CloudSession session, String owner) async {
    final settings = this.settings;
    if (settings == null) return;
    final id = await settings.deviceId;
    final key = settingsKey(id);
    // Listed first: a new device has none, and a missing key is an error.
    if ((await session.list('devices/$id/')).contains(key)) {
      final bytes = await session.get(key);
      // Remember what the cloud holds, so local settings that differ from
      // it (older there, or damaged) are uploaded over it.
      await _markSynced(
        await _store,
        '${session.prefix}/$key',
        _fingerprint(bytes),
      );
      final remote = jsonDecode(utf8.decode(bytes));
      if (remote is Map && remote['deviceId'] == id) {
        final local = await settings.settingsRecord();
        final mine = local['profileId'];
        if ((mine != null && mine != owner) ||
            _updatedAt(remote) > _updatedAt(local)) {
          await settings.applySettings(remote.cast<String, Object?>());
        }
      }
    }
    await settings.claimSettings(owner);
  }

  static int _updatedAt(Map<Object?, Object?> record) =>
      switch (record['updatedAt']) {
        final int at => at,
        _ => 0,
      };

  /// Where a device's settings go in the user's folder:
  /// `devices/<deviceId>/settings.json`.
  static String settingsKey(String deviceId) =>
      'devices/$deviceId/settings.json';

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

  /// Uploads what isn't in the cloud yet: the settings, and of the
  /// profile's events either those in [only] (the ones saved since the
  /// last pass) or, when null, all of them (a reconciliation), with the
  /// clips (recording, thumbnail, details) and tagged frames they show.
  Future<void> _syncAll(CloudSession session, Set<String>? only) async {
    final store = await _store;
    final media = await _media;
    final synced = _synced ??= await store.syncedKeys();

    Future<void> upload(
      String key,
      String fingerprint,
      Future<Uint8List> Function()? bytes,
      String contentType, {
      String? mediaId,
      String? was,
      bool keepETag = false,
    }) async {
      final objectKey = '${session.prefix}/$key';
      if (synced[objectKey] == fingerprint || _disposed) return;
      // Uploaded before under the old layout ([was]): not again, so what
      // was deleted from the bucket stays deleted.
      if (was != null && synced['${session.prefix}/$was'] == fingerprint) {
        await _markSynced(store, objectKey, fingerprint);
        return;
      }
      if (mediaId != null) {
        // A recording: streamed from storage, not held or hashed whole.
        final recording = await media.read(mediaId);
        await session.putStream(
          key,
          recording.stream,
          recording.length,
          contentType,
        );
      } else {
        final body = await bytes!();
        await session.put(key, body, contentType);
        if (keepETag) {
          await _markSynced(store, _etagKey(objectKey), etagOf(body));
        }
      }
      await _markSynced(store, objectKey, fingerprint);
      _uploaded++;
      notifyListeners();
    }

    // This device's settings (tiny, and whenever they changed).
    if (settings case final settings?) {
      final record = await settings.settingsRecord();
      final json = _json(record);
      await upload(
        settingsKey(record['deviceId']! as String),
        _fingerprint(json),
        () async => json,
        'application/json',
      );
    }

    // Only the profile's events, and the clips they show.
    final events = <Map<String, Object?>>[];
    final clips = <Map<String, Object?>>[];
    if (only == null) {
      for (final record in await store.allEvents()) {
        if (AppEvent.profileOf(record) == _owner) events.add(record);
      }
      final eventIds = {for (final e in events) e['id']};
      for (final clip in await store.allClips()) {
        if (eventIds.contains(clip['eventId'])) clips.add(clip);
      }
    } else {
      for (final id in only) {
        final record = await store.getEvent(id);
        if (record == null || AppEvent.profileOf(record) != _owner) continue;
        events.add(record);
        clips.addAll(await store.clipsOfEvent(id));
      }
    }
    // A clip's record goes in its event's day partition, where a fetch
    // looks for it.
    final eventTimes = {
      for (final e in events)
        if (e['time'] case final int time) e['id']: time,
    };

    // Clips first: recordings matter most.
    for (final clip in clips) {
      await _breathe();
      final id = clip['id']! as String;
      if (clip['state'] != 'complete') continue;
      final ref = clip['full'] ?? clip['past'];
      if (ref is Map) {
        final mediaId = ref['mediaId']! as String;
        final mimeType = ref['mimeType'] as String? ?? 'video/webm';
        final ext = _extOf(mimeType);
        await upload(
          'media/$id.$ext',
          mediaId,
          null,
          mimeType,
          mediaId: mediaId,
          was: 'clips/$id.$ext',
        );
      }
      final thumbnail = clip['thumbnail'];
      if (thumbnail is List && thumbnail.isNotEmpty) {
        final bytes = thumbnail is Uint8List
            ? thumbnail
            : Uint8List.fromList(thumbnail.cast<int>());
        await upload(
          'media/$id.jpg',
          'thumbnail',
          () async => bytes,
          'image/jpeg',
          was: 'clips/$id.jpg',
        );
      }
      final details = _json({
        for (final MapEntry(:key, :value) in clip.entries)
          if (key != 'thumbnail') key: value,
      });
      final requestedAt = clip['requestedAt'];
      await upload(
        clipRecordKey(
          id,
          eventTimes[clip['eventId']] ?? (requestedAt is int ? requestedAt : 0),
        ),
        _fingerprint(details),
        () async => details,
        'application/json',
        was: 'clips/$id.json',
      );
    }

    for (final record in events) {
      await _breathe();
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
            frameKeyOf('${record['clipId']}', '$key'),
            '$key',
            () async => jpeg,
            'image/jpeg',
            was: 'clips/${record['clipId']}/frames/$key.jpg',
          );
        }
      }
      final json = _eventJson(record);
      await upload(
        eventKey(record),
        _fingerprint(json),
        () async => json,
        'application/json',
        keepETag: true,
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
    return '${_dayPrefix(_utc(time is int ? time : 0))}${event['id']}.json';
  }

  /// Where a clip's record goes: partitioned like its event, by the UTC
  /// day it was requested ([requestedAt], ms since the epoch), so `clips/`
  /// holds only JSON: `clips/year=2026/day=269/<clipId>.json`.
  static String clipRecordKey(String clipId, int requestedAt) =>
      '${_dayPrefix(_utc(requestedAt), 'clips')}$clipId.json';

  /// Where the frame [frameId], tagged on clip [clipId], goes:
  /// `media/<clipId>/frames/<frameId>.jpg`, beside its recording
  /// (`media/<clipId>.webm` or `.mp4`) and thumbnail (`media/<clipId>.jpg`).
  static String frameKeyOf(String clipId, String frameId) =>
      'media/$clipId/frames/$frameId.jpg';

  static DateTime _utc(int ms) =>
      DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

  /// The partition of [root] (`events` or `clips`) holding [at]'s UTC day:
  /// `events/year=2026/day=269/`.
  static String _dayPrefix(DateTime at, [String root = 'events']) {
    final utc = at.toUtc();
    final day =
        DateTime.utc(
          utc.year,
          utc.month,
          utc.day,
        ).difference(DateTime.utc(utc.year)).inDays +
        1;
    return '$root/year=${utc.year}/day=${day.toString().padLeft(3, '0')}/';
  }

  /// An event's JSON as uploaded: its record without the frames (they go
  /// up as images).
  static Uint8List _eventJson(Map<String, Object?> record) => _json({
    for (final MapEntry(:key, :value) in record.entries)
      if (key != 'frames') key: value,
  });

  /// An object's ETag as S3 lists it, from its bytes: their MD5, in hex
  /// (single PUTs to a bucket with SSE-S3 encryption).
  static String etagOf(Uint8List bytes) => md5.convert(bytes).toString();

  /// Where the synced-keys store keeps the ETag of [objectKey] as this
  /// device last uploaded or downloaded it.
  static String _etagKey(String objectKey) => 'etag:$objectKey';

  /// Where the synced-keys store notes that the recording at [objectKey]
  /// is in the cloud but not downloaded yet, as `<time>:<mediaId>` (the
  /// time of its event, ms since the epoch, to take the newest first).
  static String _fetchKey(String objectKey) => 'fetch:$objectKey';

  /// Whether [syncedKey], a key of the synced-keys store (an object key
  /// under the user's folder, or its `etag:` or `fetch:` entry), is about
  /// one of the events [eventIds] or the clips [clipIds] (a clip's record,
  /// recording, thumbnail or tagged frame), in the current layout or the
  /// old one. For forgetting deleted events
  /// (`Persistence.deleteEventsBefore`).
  static bool isSyncedKeyOf(
    String syncedKey,
    Set<String> eventIds,
    Set<String> clipIds,
  ) {
    final key = switch (syncedKey) {
      final k when k.startsWith('etag:') => k.substring('etag:'.length),
      final k when k.startsWith('fetch:') => k.substring('fetch:'.length),
      final k => k,
    };
    final slash = key.indexOf('/'); // After the identity ID.
    if (slash < 0) return false;
    String stem(String name) {
      final dot = name.lastIndexOf('.');
      return dot < 0 ? name : name.substring(0, dot);
    }

    return switch (key.substring(slash + 1).split('/')) {
      ['events', ..., final name] => eventIds.contains(stem(name)),
      ['media' || 'clips', final clipId, 'frames', _] => clipIds.contains(
        clipId,
      ),
      ['media' || 'clips', ..., final name] => clipIds.contains(stem(name)),
      _ => false,
    };
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
    // Listeners rebuild the UI: only for a real change.
    if (_disposed || (state == _state && error == _error)) return;
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
