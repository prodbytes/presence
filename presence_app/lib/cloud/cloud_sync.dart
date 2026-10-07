import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../auth/auth_service.dart';
import '../auth/roles_service.dart';
import '../config.dart' show LiveMode;
import '../events.dart';
import '../storage/event_store.dart';
import '../storage/media_store.dart';
import '../storage/records.dart';
import 'cognito.dart';
import 'event_copies.dart';
import 'live_sync.dart';
import 's3.dart';
import 'sigv4.dart';

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

  /// The identity's temporary AWS credentials, for live sync's connection
  /// (null when there are none to share).
  AwsCredentials? get credentials;
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
    this.live = false,
  });

  final List<Map<String, Object?>> events;
  final List<Map<String, Object?>> clips;

  /// Events the device has, changed on another device since: their records
  /// as fetched, with the frames their tags use that the device lacks.
  final List<Map<String, Object?>> updated;

  /// Whether these came over live sync ([LiveSync]), as soon as another
  /// device saved them: a new event's clip may still be recording there,
  /// so it comes later (in a batch of [clips] of its own).
  final bool live;

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
  AwsCredentials get credentials => _session.credentials;

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
/// - With [live] (an IoT endpoint is set), the profile's devices also tell
///   each other about events as they're uploaded, within a second: once a
///   pass has a session, [live] connects to the profile's topic; each event
///   a pass uploads is then published (its metadata only, never media), and
///   each one another device published is handed to [onRemote] at once
///   ([RemoteRecords.live]), marked as synced so it's neither uploaded nor
///   downloaded again. Its clip (record and thumbnail) and tagged frames
///   still come from the bucket: a pass is started for them right away
///   (and again when the event changes, as its clip completes); recordings
///   follow the usual rules.
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
    this.live,
    EventCopies? copies,
    bool? prefetchRecordings,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _ownsCopies = copies == null,
       prefetchRecordings = prefetchRecordings ?? !kIsWeb {
    this.copies = copies ?? EventCopies(store: _store);
    auth.addListener(_onAuthChanged);
    roles?.addListener(_onAuthChanged);
    live?.addListener(_onLiveChanged);
    _onLiveChanged();
    _deviceId.then((id) {
      if (!_disposed) this.copies.deviceId ??= id;
    }).ignore();
    _changes = changes.listen(_onChanged);
    _onAuthChanged();
  }

  final AuthService auth;

  /// Live sync over MQTT, when given and enabled (see the class comment).
  final LiveSync? live;

  /// Who holds a copy of each event (see [EventCopies]): this device and
  /// the cloud, as this sync finds them, and other devices, from their
  /// `copied` acks over [live].
  late final EventCopies copies;
  final bool _ownsCopies;

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

  /// Bumped whenever syncing starts over ([_startOver]: another profile,
  /// signed out, or [reconnect]): a pass of an older one stops at its next
  /// step ([_Pass.current]), so it never mixes two profiles' data.
  int _epoch = 0;

  /// Objects in the bucket that couldn't be used (not JSON, no ID or time,
  /// an unsafe ID), by object key, with their listed ETag: skipped (and
  /// logged once) until they change, rather than failing every pass.
  final Map<String, String> _damaged = {};
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

  /// The identity [live] was started for; null while it's stopped.
  String? _liveFor;

  /// This device's ID when there are no [settings] to give it (tests): one
  /// per run.
  late final String _fallbackDeviceId =
      'device-${Random().nextInt(1 << 30).toRadixString(36)}';

  /// This device's ID.
  late final Future<String> _deviceId = () async {
    try {
      return await settings?.deviceId ?? _fallbackDeviceId;
    } catch (_) {
      return _fallbackDeviceId;
    }
  }();

  /// The folder (identity ID) of the last pass's session.
  String? _identity;

  /// Copy checks ([_noteCopies]), one after another.
  Future<void> _copyChecks = Future.value();

  /// Clips of events that arrived over live sync (or changed in the
  /// bucket) that the device doesn't have, by ID, with their events' times
  /// and a serial number ([_want]): the next pass looks for them in the
  /// bucket. One stays wanted until it's fetched or found missing there
  /// (it's wanted again when its event changes, and at each full fetch);
  /// one whose fetch fails is tried again at the next pass, up to
  /// [_maxWantedTries] times.
  final Map<String, ({int time, int serial})> _wantedClips = {};
  int _wantSerial = 0;

  /// Failed fetches of wanted clips, by clip ID, since they were wanted.
  final Map<String, int> _wantedFailures = {};
  static const int _maxWantedTries = 5;

  /// Events whose upload (frames and JSON) runs now, by ID: an event
  /// arriving over live sync meanwhile waits for it ([_onLive]).
  final Map<String, Future<void>> _eventUploads = {};

  /// The IDs of the latest new events handed to [onRemote], so one that
  /// arrives both over live sync and from the bucket is handed over once.
  final Set<String> _handedOver = <String>{};

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
  /// background downloads of recordings and copy checks included.
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
      await _copyChecks;
      await Future<void>.delayed(Duration.zero);
    }
    // And the copy checks the last pass started.
    await _copyChecks;
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
    _stopLive();
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
    _epoch++;
    _damaged.clear();
    _lastFullFetch = null;
    _reconcile = true;
    _synced = null;
    _dirty.clear();
    _failures = 0;
    _ticksToSkip = 0;
    _prefetchFailed.clear();
    _wantedClips.clear();
    _wantedFailures.clear();
    _handedOver.clear();
  }

  void _stopLive() {
    _liveFor = null;
    live?.stop();
  }

  /// Starts [live] for [session]'s identity, unless it runs for it already.
  Future<void> _startLive(CloudSession session, String owner) async {
    final live = this.live;
    if (live == null || !live.enabled || _liveFor == session.prefix) return;
    if (session.credentials == null) return;
    _liveFor = session.prefix;
    final deviceId = await _deviceId;
    if (_disposed || _owner != owner || _liveFor != session.prefix) return;
    live.start(
      LiveLink(
        identityId: session.prefix,
        deviceId: deviceId,
        credentials: () async {
          final idToken = auth.idToken;
          if (idToken == null || _owner != owner) {
            throw StateError('signed out');
          }
          final credentials = (await backend.connect(idToken)).credentials;
          if (credentials == null) throw StateError('no credentials');
          return credentials;
        },
        onEvent: (event) => _onLive(event, owner),
        onCopied: _onCopied,
      ),
    );
  }

  /// Live sync's state changed: so may whether other devices' copies are
  /// heard of.
  void _onLiveChanged() {
    final live = this.live;
    copies.liveOn =
        live != null &&
        live.enabled &&
        live.config.mode != LiveMode.never &&
        live.state != LiveSyncState.off;
    notifyListeners();
  }

  /// Another device holds copies of events.
  void _onCopied(CopiedMessage ack) {
    for (final id in ack.eventIds) {
      copies.addDevice(id, ack.deviceId, ack.sentAt);
    }
  }

  /// Finds out again whether this device and the cloud hold the events
  /// [ids] ([_checkCopies]; all of the window's with null), after the ones
  /// asked before.
  Future<void> _noteCopies(Iterable<String>? ids) {
    final todo = ids == null
        ? null
        : {
            for (final id in ids)
              if (LiveSync.isSafeId(id)) id,
          };
    if ((todo != null && todo.isEmpty) || _disposed) return _copyChecks;
    return _copyChecks = _copyChecks.then((_) => _checkCopies(todo)).catchError(
      (Object e) {
        debugPrint('Presence: could not check event copies: $e');
      },
    );
  }

  /// Records whether this device and the cloud hold each of the events
  /// [ids] ([copyOf]), or with [ids] null each of the profile's events
  /// from the window (at a full fetch). Events this device now holds that
  /// another device recorded, and that it hasn't said so of yet, are acked
  /// over [live] ([LiveSync.ackCopied]).
  Future<void> _checkCopies(Set<String>? ids) async {
    if (_disposed) return;
    final store = await _store;
    final synced = _synced ??= await store.syncedKeys();
    final me = await _deviceId;
    final prefix = _identity;
    final owner = _owner;
    final records = <Map<String, Object?>>[];
    if (ids == null) {
      final since = _now().toUtc().subtract(_window).millisecondsSinceEpoch;
      for (final record in await store.allEvents()) {
        final time = record['time'];
        if (time is! int || time < since) continue;
        // Settled already: held here and in the cloud, and acked (or
        // recorded here). Its clip isn't read again.
        final known = copies.of('${record['id']}');
        if (known != null &&
            known.self &&
            known.cloud &&
            (known.acked || record['deviceId'] == me) &&
            !AppEvent.isDeletedRecord(record)) {
          continue;
        }
        records.add(record);
      }
    } else {
      for (final id in ids) {
        if (await store.getEvent(id) case final record?) records.add(record);
      }
    }
    final toAck = <String>[];
    for (final record in records) {
      await _breathe(50);
      if (_disposed) return;
      final id = record['id'];
      if (id is! String) continue;
      // Deleted (hidden): neither counted nor acked.
      if (AppEvent.isDeletedRecord(record)) {
        copies.forget(id);
        continue;
      }
      final clipId = record['clipId'];
      final clip = clipId is String ? await store.getClip(clipId) : null;
      final (:self, :cloud) = copyOf(
        record,
        clip: clip,
        synced: synced,
        prefix: prefix,
        deviceId: me,
      );
      copies.setLocal(id, self: self, cloud: cloud);
      final origin = record['deviceId'];
      if (self &&
          origin is String &&
          origin != me &&
          owner != null &&
          AppEvent.profileOf(record) == owner &&
          !(copies.of(id)?.acked ?? false)) {
        toAck.add(id);
      }
    }
    final live = this.live;
    if (toAck.isEmpty || live == null) return;
    // Not holding up the next checks: a scheduled connection may take a
    // while to send them.
    live.ackCopied(toAck).then((sent) {
      if (sent && !_disposed) copies.markAcked(toAck);
    }).ignore();
  }

  /// Whether this device ([self]) and the cloud hold a full copy of the
  /// event [record]: the event, the frames its tags use, and its clip
  /// ([clip], its record here) with the recording. An event without a clip
  /// is held with its record (and frames). [synced] is the synced-keys
  /// store, [prefix] the profile's folder, [deviceId] this device's.
  ///
  /// - This device: an event it recorded is always held here (its clip,
  ///   even while recording, is all there is of it). Another device's is
  ///   held once its frames are here and its clip's record is, with the
  ///   recording downloaded (not pending, `fetch:`), unless the clip failed
  ///   there (then there's no recording to have).
  /// - The cloud: the event's JSON is in the bucket (uploaded or fetched),
  ///   with its frames and, for a clip, its recording (uploaded, or seen
  ///   there by a fetch). Not while the clip is still recording.
  @visibleForTesting
  static ({bool self, bool cloud}) copyOf(
    Map<String, Object?> record, {
    Map<String, Object?>? clip,
    required Map<String, String> synced,
    required String? prefix,
    required String deviceId,
  }) {
    final mine = record['deviceId'] == deviceId;
    final clipId = record['clipId'];
    final frames = record['frames'];
    final frameIds = _frameIds(record).toList();
    bool inCloud(String key) =>
        prefix != null && synced.containsKey('$prefix/$key');
    final framesHere = frameIds.every(
      (f) => frames is Map && frames.containsKey(f),
    );
    final framesUp =
        clipId is! String ||
        frameIds.every((f) => inCloud(frameKeyOf(clipId, f)));
    final eventUp = inCloud(eventKey(record));
    if (clipId is! String) {
      return (self: mine || framesHere, cloud: eventUp && framesUp);
    }
    final recordings = _recordingKeys(clipId);
    final recordingUp = recordings.any(inCloud);
    final state = clip?['state'];
    if (state == 'failed') {
      return (self: mine || framesHere, cloud: eventUp && framesUp);
    }
    if (mine) {
      return (
        self: true,
        cloud: state == 'complete' && eventUp && framesUp && recordingUp,
      );
    }
    final cloud = eventUp && framesUp && recordingUp;
    if (clip == null || state != 'complete') return (self: false, cloud: cloud);
    final ref = clip['full'] ?? clip['past'];
    final recordingHere =
        ref is! Map ||
        (recordingUp &&
            !recordings.any(
              (k) => prefix != null && synced.containsKey('fetch:$prefix/$k'),
            ));
    return (self: framesHere && recordingHere, cloud: cloud);
  }

  /// Takes an event another device of [owner]'s profile published (live
  /// sync): a new one is handed to [onRemote] at once, an update to one the
  /// device has replaces its tags (unless it changed here too and that
  /// isn't uploaded yet: this version wins, as with the bucket). Either is
  /// marked as synced, with the ETag the sender uploaded, so it's neither
  /// uploaded back nor downloaded again. Its clip and tagged frames come
  /// from the bucket: a pass starts for them.
  ///
  /// It waits for an upload of the same event a pass is making
  /// ([_eventUploads]), so the pass can't put this device's older version
  /// back over it; and once the profile changes, or syncing stops, while
  /// it waits on storage or the network, it takes nothing.
  Future<void> _onLive(LiveEvent message, String owner) async {
    bool current() => !_disposed && _owner == owner && !stopped;
    if (!current()) return;
    final event = Map.of(message.event);
    // Another profile's: not for this folder.
    if (event['profileId'] case final String profile when profile != owner) {
      return;
    }
    event['profileId'] = owner;
    final time = event['time']! as int;
    final since = _now().toUtc().subtract(_window);
    if (DateTime.fromMillisecondsSinceEpoch(
      time,
      isUtc: true,
    ).isBefore(since)) {
      return;
    }
    final id = event['id']! as String;
    final store = await _store;
    final key = eventKey(event);
    final objectKey = '${message.identityId}/$key';
    for (var up = _eventUploads[id]; up != null; up = _eventUploads[id]) {
      await up;
    }
    if (!current()) return;
    final synced = _synced ??= await store.syncedKeys();
    final local = await store.getEvent(id);

    Future<void> settle() async {
      if (!current()) return;
      final stored = await store.getEvent(id);
      if (stored == null || eventKey(stored) != key || !current()) return;
      await _markSynced(store, objectKey, _fingerprint(_eventJson(stored)));
      if (message.etag case final etag?) {
        await _markSynced(store, _etagKey(objectKey), etag);
      }
    }

    final clipId = event['clipId'];
    // A deleted event's clip isn't shown: not wanted.
    final wantsClip =
        clipId is String &&
        !AppEvent.isDeletedRecord(event) &&
        !(await store.clipIds()).contains(clipId);
    if (local == null) {
      if (_handedOver.contains(id)) return;
      // The frames its tags use, if it has any yet.
      final frames = await _liveFrames(event, const {});
      if (frames.isNotEmpty) event['frames'] = frames;
      if (!current()) return;
      await _deliver(RemoteRecords(events: [event], live: true));
      await settle();
    } else {
      if (eventKey(local) != key) return;
      final localJson = _eventJson(local);
      if (_fingerprint(localJson) != _fingerprint(_eventJson(event))) {
        // Changed here, and not uploaded yet: this version goes up; unless
        // the other deletes it, which wins.
        if (synced[objectKey] != _fingerprint(localJson) &&
            !_deletes(event, local)) {
          return;
        }
        final frames = await _liveFrames(event, local);
        if (frames.isNotEmpty) event['frames'] = frames;
        if (!current()) return;
        await _deliver(RemoteRecords(updated: [event], live: true));
      }
      if (_undeletes(event, local)) {
        // A copy that isn't deleted, of an event deleted here: it stays
        // deleted ([Persistence.updateFromRemote]), and goes up again so.
        if (message.etag case final etag?) {
          await _markSynced(store, _etagKey(objectKey), etag);
        }
        await _forgetSynced(store, objectKey);
        _dirty.add(id);
        _schedule();
      } else {
        await settle();
      }
    }
    if (clipId is String && wantsClip && current()) {
      _want(clipId, time);
      _schedule(immediately: true);
    }
    if (current()) _noteCopies({id}).ignore();
  }

  /// Whether [remote], a copy of the event [local] stored here, deletes it.
  static bool _deletes(
    Map<String, Object?> remote,
    Map<String, Object?> local,
  ) => AppEvent.isDeletedRecord(remote) && !AppEvent.isDeletedRecord(local);

  /// Whether [remote] is a copy that isn't deleted of the event [local],
  /// deleted here.
  static bool _undeletes(
    Map<String, Object?> remote,
    Map<String, Object?> local,
  ) => _deletes(local, remote);

  /// The frames [event]'s tags use that [local] (its record here) lacks,
  /// from the bucket; none that aren't there yet.
  Future<Map<String, Uint8List>> _liveFrames(
    Map<String, Object?> event,
    Map<String, Object?> local,
  ) async {
    final have = local['frames'] is Map ? local['frames']! as Map : const {};
    final missing = [
      for (final frameId in _frameIds(event))
        if (!have.containsKey(frameId) && LiveSync.isSafeId(frameId)) frameId,
    ];
    final idToken = auth.idToken;
    if (missing.isEmpty || idToken == null) return const {};
    final frames = <String, Uint8List>{};
    try {
      final session = await backend.connect(idToken);
      final store = await _store;
      for (final frameId in missing) {
        final frameKey = frameKeyOf('${event['clipId']}', frameId);
        try {
          frames[frameId] = await session.get(frameKey);
          await _markSynced(store, '${session.prefix}/$frameKey', frameId);
        } catch (e) {
          debugPrint('Presence: live sync could not get frame $frameId: $e');
        }
      }
    } catch (e) {
      debugPrint('Presence: live sync could not get frames: $e');
    }
    return frames;
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
      // Saved here: held here (an event recorded here, or its clip done).
      _noteCopies(ids);
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
    _stopLive();
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

  /// Forgets what was uploaded to [key]: the cloud holds something else
  /// now, so the next upload sends it again.
  Future<void> _forgetSynced(EventStore store, String key) async {
    await store.unmarkSynced(key);
    _synced?.remove(key);
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
    final epoch = _epoch;
    // What this pass uploads; given back if it fails.
    final dirty = Set.of(_dirty);
    _dirty.clear();
    var reconcile = _reconcile;
    _reconcile = false;
    CloudSession? used;
    Future<void> run(CloudSession session) async {
      final pass = _Pass(this, session, await _store, owner, epoch)..check();
      used = session;
      _identity = session.prefix;
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
        _synced = await pass.store.syncedKeys();
      }
      if (last == null) await _fetchSettings(pass);
      await _fetch(pass, _fetchPrefixes(now, first: last == null, full: full));
      pass.check();
      if (full) {
        _lastFullFetch = now;
        await _rewantClips(owner);
      }
      await _fetchWanted(pass);
      await _syncAll(pass, reconcile ? null : dirty);
      pass.check();
      // Who holds what, for every event of the window (and acks not sent
      // before, such as while live sync was off).
      if (full) _noteCopies(null).ignore();
    }

    void giveBack() {
      // Not to another profile's sync.
      if (epoch != _epoch) return;
      _dirty.addAll(dirty);
      if (reconcile) _reconcile = true;
    }

    try {
      try {
        await run(await backend.connect(idToken));
      } on S3Exception catch (e) {
        if (e.credentialsRejected) {
          // Credentials expired mid-sync: get new ones and go on.
          debugPrint('Presence: cloud credentials rejected, renewing: $e');
          backend.reset();
        } else if (e.clockSkewed) {
          // The clock is corrected by AWS's time (S3Bucket): again with it.
          debugPrint('Presence: request signed at the wrong time, again: $e');
        } else {
          rethrow;
        }
        await run(await backend.connect(idToken));
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
      if (used case final session?) await _startLive(session, owner);
    } on _Abandoned {
      // Signed out, another profile, or stopped meanwhile: whatever comes
      // next starts over.
      debugPrint('Presence: a cloud sync pass ended: the profile changed');
    } on CognitoException catch (e) {
      if (epoch != _epoch) return;
      giveBack();
      // Trying again each pass fails the same way: stop until the user
      // signs in again or retries.
      _stoppedFor = idToken;
      _stopLive();
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
      if (epoch != _epoch) return;
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
  ///
  /// An object that can't be used (not JSON, no ID or time, an unsafe ID,
  /// or another ID than its key's) is skipped and logged, and not read
  /// again until it changes ([_damaged]); the rest go on.
  Future<void> _fetch(_Pass pass, List<String> prefixes) async {
    final session = pass.session;
    final store = pass.store;
    final listed = <String, String>{
      for (final under in prefixes) ...await session.listETags(under),
    };
    pass.check();
    // Only the IDs: records are read one by one, when needed.
    final localEvents = await store.eventIds();
    final localClips = await store.clipIds();
    final syncedKeys = _synced ??= await store.syncedKeys();
    final since = _now().toUtc().subtract(_window);
    bool damaged(String key) {
      final etag = _damaged[pass.objectKey(key)];
      return etag != null && etag == listed[key];
    }

    // Partitioned keys (events/year=YYYY/day=DDD/<id>.json), and flat ones
    // from before partitioning (events/<id>.json). The newest day first:
    // the zero-padded partitions sort by date.
    final missing = [
      for (final key in listed.keys)
        if (_eventIdOf(key) case final id?
            when !localEvents.contains(id) &&
                _partitionMayBeSince(key, since) &&
                !damaged(key))
          key,
    ]..sort((a, b) => b.compareTo(a));

    // Changed elsewhere: only at the key this device uploads the event to
    // (not a copy left under the layout from before partitioning).
    final changed = <String>[];
    // Of those, the ones changed here too and not uploaded yet: taken only
    // if the other copy deletes them (deletion wins).
    final changedHereToo = <String>{};
    for (final MapEntry(:key, value: etag) in listed.entries) {
      await _breathe(200);
      final id = _eventIdOf(key);
      if (id == null || !localEvents.contains(id)) continue;
      if (!_partitionMayBeSince(key, since) || damaged(key)) continue;
      final objectKey = pass.objectKey(key);
      if (syncedKeys[_etagKey(objectKey)] == etag) continue;
      final local = await store.getEvent(id);
      if (local == null || eventKey(local) != key) continue;
      final json = _eventJson(local);
      if (etagOf(json) == etag) {
        // The same bytes (uploaded before ETags were kept).
        await pass.keepETag(key, etag);
        continue;
      }
      // Changed here and not uploaded yet: this version wins, unless the
      // other deletes it (an event deleted here needs nothing from it).
      if (syncedKeys[objectKey] != _fingerprint(json)) {
        if (AppEvent.isDeletedRecord(local)) continue;
        changedHereToo.add(key);
      }
      changed.add(key);
    }
    changed.sort((a, b) => b.compareTo(a));

    // Hands a batch over, and counts it; who holds them is checked once
    // they're all in (and marked as synced).
    final delivered = <String>{};
    Future<void> deliver(RemoteRecords records) {
      for (final e in [...records.events, ...records.updated]) {
        if (e['id'] case final String id) delivered.add(id);
      }
      return _deliver(records, pass);
    }

    // The new events, a batch at a time, newest first.
    var kept = 0;
    final todo = missing.take(maxFetch).toList();
    for (var i = 0; i < todo.length; i += fetchBatch) {
      pass.check();
      final batch = todo.sublist(i, min(i + fetchBatch, todo.length));
      final (events, clips) = await _fetchNew(
        pass,
        batch,
        listed,
        since: since,
        localClips: localClips,
      );
      kept += events.length;
      await deliver(RemoteRecords(events: events, clips: clips));
    }

    // Then the changed ones, with the frames their tags use that the
    // device doesn't have.
    final changedTodo = changed.take(max(0, maxFetch - kept)).toList();
    for (var i = 0; i < changedTodo.length; i += fetchBatch) {
      pass.check();
      final updated = <Map<String, Object?>>[];
      final updatedETags = <String, String>{};
      // Those that aren't deleted there.
      final notDeleted = <String>{};
      for (final key in changedTodo.sublist(
        i,
        min(i + fetchBatch, changedTodo.length),
      )) {
        pass.check();
        final bytes = await _getOrSkip(session, key);
        if (bytes == null) continue;
        final event = _eventFrom(bytes, key);
        if (event == null) {
          _damaged[pass.objectKey(key)] = listed[key] ?? '';
          continue;
        }
        final deleted = AppEvent.isDeletedRecord(event);
        if (changedHereToo.contains(key) && !deleted) continue;
        if (!deleted) notDeleted.add(key);
        event['profileId'] = pass.owner;
        final local = await store.getEvent(event['id']! as String);
        final have = local?['frames'] is Map ? local!['frames']! as Map : {};
        final frames = <String, Uint8List>{};
        final clipId = event['clipId'];
        for (final frameId in _frameIds(event)) {
          if (have.containsKey(frameId) || clipId is! String) continue;
          final frameKey = frameKeyOf(clipId, frameId);
          if (!(await pass.mediaKeys(clipId)).contains(frameKey)) continue;
          if (await _getOrSkip(session, frameKey) case final frame?) {
            frames[frameId] = frame;
            await pass.synced(frameKey, frameId);
          }
        }
        if (frames.isNotEmpty) event['frames'] = frames;
        updated.add(event);
        updatedETags[key] = etagOf(bytes);
        // Its clip, if it has completed since (not a deleted event's).
        if ((clipId, event['time']) case (final String id, final int time)
            when !localClips.contains(id) && !deleted) {
          _want(id, time);
        }
      }
      if (updated.isEmpty) continue;
      await deliver(RemoteRecords(updated: updated));
      // The changed events as the device keeps them now are in sync: not
      // uploaded back, nor downloaded again.
      for (final MapEntry(:key, value: etag) in updatedETags.entries) {
        final id = _eventIdOf(key);
        final record = id == null ? null : await store.getEvent(id);
        if (record == null || eventKey(record) != key) continue;
        await pass.keepETag(key, etag);
        if (AppEvent.isDeletedRecord(record) && notDeleted.contains(key)) {
          // Deleted here, not there: it stays deleted
          // (`Persistence.updateFromRemote`), and goes up again so.
          await _forgetSynced(store, pass.objectKey(key));
          _dirty.add(id!);
          continue;
        }
        await pass.synced(key, _fingerprint(_eventJson(record)));
      }
    }
    _noteCopies(delivered).ignore();
  }

  /// Downloads [key], or null when it's gone (deleted since it was
  /// listed): skipped, not a failed pass.
  static Future<Uint8List?> _getOrSkip(CloudSession session, String key) async {
    try {
      return await session.get(key);
    } on S3Exception catch (e) {
      if (e.statusCode != 404) rethrow;
      debugPrint('Presence: $key is gone from the cloud; skipped');
      return null;
    }
  }

  /// The event in [bytes], downloaded from [key]: null (logged) when it
  /// can't be used ([Records.tryParseEvent] with safe IDs), or names
  /// another event than its key.
  static Map<String, Object?>? _eventFrom(Uint8List bytes, String key) {
    final decoded = Records.decode(bytes, what: key);
    if (decoded == null) return null;
    final event = Records.tryParseEvent(decoded, safeIds: true);
    if (event == null) return null;
    if (event['id'] != _eventIdOf(key)) {
      debugPrint('Presence: skipped $key: it holds another event');
      return null;
    }
    return event;
  }

  /// Downloads the events at [keys] (missing here; with their ETags in
  /// [listed]) that are from [since] on, with their tagged frames and
  /// their clips (records and thumbnails). Their recordings are only noted
  /// as pending ([_Pass.pending]): they come down later, so the batch is
  /// handed over without waiting for them.
  Future<(List<Map<String, Object?>>, List<Map<String, Object?>>)> _fetchNew(
    _Pass pass,
    List<String> keys,
    Map<String, String> listed, {
    required DateTime since,
    required Set<String> localClips,
  }) async {
    final store = pass.store;
    final session = pass.session;
    final events = <Map<String, Object?>>[];
    for (final key in keys) {
      pass.check();
      // Arrived over live sync since the listing.
      if (_eventIdOf(key) case final id?
          when await store.getEvent(id) != null) {
        continue;
      }
      final bytes = await _getOrSkip(session, key);
      if (bytes == null) continue;
      final event = _eventFrom(bytes, key);
      if (event == null) {
        _damaged[pass.objectKey(key)] = listed[key] ?? '';
        continue;
      }
      final time = event['time']! as int;
      if (DateTime.fromMillisecondsSinceEpoch(
        time,
        isUtc: true,
      ).isBefore(since)) {
        continue;
      }
      // Events in the profile's folder are the profile's, even from before
      // events had profiles.
      event['profileId'] = pass.owner;
      await pass.synced(key, _fingerprint(_json(event)));
      await pass.keepETag(key, etagOf(bytes));
      // The frames its tags were clicked on come back as images.
      final frames = <String, Uint8List>{};
      final clipId = event['clipId'];
      if (clipId is String) {
        final ofClip = await pass.mediaKeys(clipId);
        for (final frameId in _frameIds(event)) {
          final frameKey = frameKeyOf(clipId, frameId);
          if (!ofClip.contains(frameKey)) continue;
          if (await _getOrSkip(session, frameKey) case final frame?) {
            frames[frameId] = frame;
            await pass.synced(frameKey, frameId);
          }
        }
      }
      if (frames.isNotEmpty) event['frames'] = frames;
      events.add(event);
    }

    // Only the clips those events show. Each clip's record is in its
    // event's day partition (both are timed when the clip was requested).
    final clipTimes = <String, int>{
      for (final e in events)
        if ((e['clipId'], e['time']) case (final String id, final int time)
            when !AppEvent.isDeletedRecord(e))
          id: time,
    };
    final clips = await _fetchClips(pass, clipTimes, localClips: localClips);
    return (events, clips);
  }

  /// Downloads the clips [clipTimes] (by ID, with their events' times)
  /// that the device doesn't have and that are in the bucket: their
  /// records and thumbnails, marked as synced. Their recordings are only
  /// noted as pending ([_Pass.pending]). A clip record that can't be used
  /// ([Records.tryParseClip] with safe IDs, or another clip's) is skipped.
  Future<List<Map<String, Object?>>> _fetchClips(
    _Pass pass,
    Map<String, int> clipTimes, {
    required Set<String> localClips,
  }) async {
    final session = pass.session;
    final clips = <Map<String, Object?>>[];
    for (final MapEntry(key: id, value: time) in clipTimes.entries) {
      pass.check();
      if (localClips.contains(id) || !Records.isSafeId(id)) continue;
      final key = clipRecordKey(id, time);
      if (_damaged.containsKey(pass.objectKey(key))) continue;
      if (!(await session.list(key)).contains(key)) continue;
      final ofClip = await pass.mediaKeys(id);
      final bytes = await _getOrSkip(session, key);
      if (bytes == null) continue;
      final decoded = Records.decode(bytes, what: key);
      final clip = decoded == null
          ? null
          : Records.tryParseClip(decoded, safeIds: true);
      if (clip == null || clip['id'] != id) {
        if (clip != null) debugPrint('Presence: skipped $key: another clip');
        _damaged[pass.objectKey(key)] = etagOf(bytes);
        continue;
      }
      await pass.synced(key, _fingerprint(_json(clip)));
      final ref = clip['full'] ?? clip['past'];
      if (ref is Map) {
        // Safe: [Records.tryParseClip] checked it.
        final mediaId = ref['mediaId']! as String;
        // Where it is, or, for a complete clip whose recording is still
        // going up from its device, where it'll be.
        final video =
            _recordingKeys(id).where(ofClip.contains).firstOrNull ??
            (clip['state'] == 'complete'
                ? 'media/$id.${_extOf(ref['mimeType'] as String?)}'
                : null);
        if (video != null) await pass.pending(video, mediaId, time);
      }
      if (ofClip.contains('media/$id.jpg')) {
        if (await _getOrSkip(session, 'media/$id.jpg') case final jpeg?) {
          clip['thumbnail'] = jpeg;
          await pass.synced('media/$id.jpg', 'thumbnail');
        }
      }
      clips.add(clip);
    }
    return clips;
  }

  /// Hands a batch over to [onRemote], and counts it. New events already
  /// handed over (from live sync, or the bucket) are left out. With [pass],
  /// only while it's current: nothing of a profile is stored once another
  /// one syncs.
  Future<void> _deliver(RemoteRecords records, [_Pass? pass]) async {
    if (_disposed) return;
    pass?.check();
    final events = [
      for (final e in records.events)
        if (_handedOver.add('${e['id']}')) e,
    ];
    while (_handedOver.length > 5000) {
      _handedOver.remove(_handedOver.first);
    }
    final fresh = RemoteRecords(
      events: events,
      clips: records.clips,
      updated: records.updated,
      live: records.live,
    );
    if (fresh.isEmpty) return;
    await onRemote?.call(fresh);
    _downloaded +=
        fresh.events.length + fresh.clips.length + fresh.updated.length;
    notifyListeners();
  }

  /// Wants clip [clipId] (of an event at [time]): the next pass looks for
  /// it ([_fetchWanted]). Wanting it again gives it a new serial, so a pass
  /// that found it missing meanwhile doesn't drop the new want.
  void _want(String clipId, int time) {
    _wantedClips[clipId] = (time: time, serial: ++_wantSerial);
    _wantedFailures.remove(clipId);
  }

  /// At a full fetch (the first pass for a user, after a restart, and
  /// every [fullFetchEvery]): wants the clips of the profile's events from
  /// the window that the device has no record of (another device's, whose
  /// clip hadn't come when the app closed or a fetch failed), the newest
  /// [maxRewanted]. The device stores its own clips' records as soon as
  /// they're requested, so these are other devices'.
  Future<void> _rewantClips(String owner) async {
    final store = await _store;
    final localClips = await store.clipIds();
    final since = _now().toUtc().subtract(_window).millisecondsSinceEpoch;
    final found = <(int, String)>[];
    for (final record in await store.allEvents()) {
      await _breathe(200);
      final clipId = record['clipId'];
      final time = record['time'];
      if (clipId is! String || time is! int || time < since) continue;
      if (localClips.contains(clipId) || _wantedClips.containsKey(clipId)) {
        continue;
      }
      if (AppEvent.profileOf(record) != owner) continue;
      if (AppEvent.isDeletedRecord(record)) continue;
      found.add((time, clipId));
    }
    found.sort((a, b) => b.$1.compareTo(a.$1));
    for (final (time, clipId) in found.take(maxRewanted)) {
      _want(clipId, time);
    }
  }

  /// The most clips a full fetch wants again ([_rewantClips]).
  static const int maxRewanted = 100;

  /// Fetches the clips live sync (or a changed event, or a full fetch)
  /// asked for ([_wantedClips]). One stays wanted until it's here: fetched
  /// now, or found missing in the bucket (still recording on its device;
  /// it's wanted again when its event changes). One whose fetch fails is
  /// tried again at the next pass, at most [_maxWantedTries] times (then at
  /// the next full fetch); its failure doesn't fail the pass, unless the
  /// credentials were rejected (the pass renews them and tries again).
  Future<void> _fetchWanted(_Pass pass) async {
    if (_wantedClips.isEmpty) return;
    pass.check();
    final wanted = Map.of(_wantedClips);
    final store = pass.store;
    final localClips = await store.clipIds();
    // Done with one: unless it was wanted again meanwhile.
    void done(String id) {
      if (_wantedClips[id]?.serial == wanted[id]?.serial) {
        _wantedClips.remove(id);
        _wantedFailures.remove(id);
      }
    }

    for (final id in wanted.keys) {
      if (localClips.contains(id)) done(id);
    }
    wanted.removeWhere((id, _) => localClips.contains(id));
    if (wanted.isEmpty) return;
    // Listed afresh: what the fetch listed may have come since.
    pass.forgetMediaKeys();
    final clips = <Map<String, Object?>>[];
    final fetched = <String>[];
    for (final MapEntry(key: id, value: (:time, serial: _)) in wanted.entries) {
      pass.check();
      try {
        clips.addAll(
          await _fetchClips(pass, {id: time}, localClips: localClips),
        );
        // Here now, or not in the bucket (yet), or damaged there.
        fetched.add(id);
      } on _Abandoned {
        rethrow;
      } on S3Exception catch (e) {
        if (e.credentialsRejected || e.clockSkewed) rethrow;
        _wantedFailed(id, e);
      } catch (e) {
        _wantedFailed(id, e);
      }
    }
    await _deliver(RemoteRecords(clips: clips, live: true), pass);
    fetched.forEach(done);
    // Their events may be held here now (or once their recordings come).
    _noteCopies([
      for (final c in clips)
        if (c['eventId'] case final String id) id,
    ]).ignore();
  }

  void _wantedFailed(String id, Object e) {
    final failures = _wantedFailures[id] = (_wantedFailures[id] ?? 0) + 1;
    debugPrint('Presence: could not fetch clip $id ($failures tries): $e');
    if (failures >= _maxWantedTries) {
      _wantedClips.remove(id);
      _wantedFailures.remove(id);
    }
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
        try {
          await _download(session, key, mediaId);
        } on S3Exception catch (e) {
          if (!e.credentialsRejected && !e.clockSkewed) rethrow;
          // Expired while downloading (or signed at the wrong time, now
          // corrected): new credentials, and this one again with them.
          if (e.credentialsRejected) backend.reset();
          final token = auth.idToken;
          if (token == null || !current()) return;
          session = await backend.connect(token);
          await _download(session, key, mediaId);
        }
        failuresInRow = 0;
      } catch (e) {
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
        // Its event is held here now.
        if (_recordingKey.firstMatch(key)?[1] case final clipId?) {
          if ((await store.getClip(clipId))?['eventId'] case final String id) {
            _noteCopies({id}).ignore();
          }
        }
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
      if (!Records.isSafeId(clipId)) return false;
      final candidates = _recordingKeys(clipId);
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
        if (!e.credentialsRejected && !e.clockSkewed) rethrow;
        if (e.credentialsRejected) backend.reset();
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
  ///
  /// Settings in the cloud that can't be read (not JSON, no config) count
  /// as none: the local ones are uploaded over them.
  Future<void> _fetchSettings(_Pass pass) async {
    final settings = this.settings;
    if (settings == null) return;
    final session = pass.session;
    final owner = pass.owner;
    final id = await settings.deviceId;
    final key = settingsKey(id);
    // Listed first: a new device has none, and a missing key is an error.
    if ((await session.list('devices/$id/')).contains(key)) {
      final bytes = await _getOrSkip(session, key);
      pass.check();
      if (bytes != null) {
        // Remember what the cloud holds, so local settings that differ
        // from it (older there, or damaged) are uploaded over it.
        await pass.synced(key, _fingerprint(bytes));
        final decoded = Records.decode(bytes, what: key);
        final remote = decoded == null
            ? null
            : Records.tryParseSettings(decoded);
        if (remote != null && remote['deviceId'] == id) {
          final local = await settings.settingsRecord();
          final mine = local['profileId'];
          if ((mine != null && mine != owner) ||
              _updatedAt(remote) > _updatedAt(local)) {
            pass.check();
            await settings.applySettings(remote);
          }
        }
      }
    }
    pass.check();
    await settings.claimSettings(owner);
  }

  static int _updatedAt(Map<String, Object?> record) =>
      Records.intOf(record['updatedAt']) ?? 0;

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
  ///
  /// Only while [pass] is current: each upload checks first, so a pass
  /// that outlives its profile (signed out, another profile) uploads
  /// nothing more. A stored record that can't be read is skipped.
  Future<void> _syncAll(_Pass pass, Set<String>? only) async {
    final session = pass.session;
    final store = pass.store;
    final owner = pass.owner;
    final media = await _media;
    final synced = _synced ??= await store.syncedKeys();

    // Uploads [key] unless it's in the cloud already; returns the ETag of
    // what it uploaded (null for none, or a recording).
    Future<String?> upload(
      String key,
      String fingerprint,
      Future<Uint8List> Function()? bytes,
      String contentType, {
      String? mediaId,
      String? was,
      bool keepETag = false,
    }) async {
      pass.check();
      final objectKey = pass.objectKey(key);
      if (synced[objectKey] == fingerprint) return null;
      // Uploaded before under the old layout ([was]): not again, so what
      // was deleted from the bucket stays deleted.
      if (was != null && synced['${session.prefix}/$was'] == fingerprint) {
        await _markSynced(store, objectKey, fingerprint);
        return null;
      }
      String? etag;
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
        etag = etagOf(body);
        if (keepETag) await _markSynced(store, _etagKey(objectKey), etag);
      }
      await _markSynced(store, objectKey, fingerprint);
      _uploaded++;
      notifyListeners();
      return etag;
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
        if (record['id'] is String && AppEvent.profileOf(record) == owner) {
          events.add(record);
        }
      }
      final eventIds = {for (final e in events) e['id']};
      for (final clip in await store.allClips()) {
        if (eventIds.contains(clip['eventId'])) clips.add(clip);
      }
    } else {
      for (final id in only) {
        final record = await store.getEvent(id);
        if (record == null || AppEvent.profileOf(record) != owner) continue;
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
      // Read through the codec (a damaged record is skipped); uploaded as
      // stored.
      final parsed = Records.tryParseClip(clip, safeIds: true);
      if (parsed == null) continue;
      final id = parsed['id']! as String;
      if (parsed['state'] != 'complete') continue;
      final ref = parsed['full'] ?? parsed['past'];
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

    // Events uploaded now: the cloud holds them.
    final uploadedEvents = <String>{};
    for (final snapshot in events) {
      await _breathe();
      pass.check();
      final id = snapshot['id']! as String;
      // While it goes up, an event arriving over live sync waits for it.
      final uploading = Completer<void>();
      _eventUploads[id] = uploading.future;
      Map<String, Object?>? published;
      String? publishedKey;
      String? etag;
      try {
        // As stored now, not as listed when the pass started: the clips
        // took time, and live sync may have taken a newer version from
        // another device meanwhile (and marked it as synced). Uploading
        // the listed one would put the older version back.
        final record = await store.getEvent(id);
        if (record == null || AppEvent.profileOf(record) != owner) continue;
        // Tagged frames go up as images next to the clip; the event's
        // JSON keeps the tags (name, position, frame id and time) without
        // them.
        final frames = record['frames'];
        if (frames is Map) {
          for (final MapEntry(:key, :value) in frames.entries) {
            final jpeg = value is Uint8List
                ? value
                : (value is List
                      ? Uint8List.fromList(value.cast<int>())
                      : null);
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
        final key = eventKey(record);
        etag = await upload(
          key,
          _fingerprint(json),
          () async => json,
          'application/json',
          keepETag: true,
        );
        if (etag != null) uploadedEvents.add(id);
        // Then the profile's other devices hear of it at once (live
        // sync): recent events only, not a reconciliation's old ones.
        final time = record['time'];
        if (etag != null &&
            time is int &&
            _now().millisecondsSinceEpoch - time < _window.inMilliseconds) {
          published = (jsonDecode(utf8.decode(json)) as Map)
              .cast<String, Object?>();
          publishedKey = key;
        }
      } finally {
        if (_eventUploads[id] == uploading.future) _eventUploads.remove(id);
        uploading.complete();
      }
      // Not holding up received events: a scheduled connection may take
      // a while to send it.
      if ((live, published, publishedKey, etag)
          case (final live?, final event?, final key?, final etag?)
          when pass.current) {
        await live.publishEvent(event, key: key, etag: etag);
      }
    }
    _noteCopies(uploadedEvents).ignore();
  }

  /// The frames [event]'s tags use, by ID: only safe ones
  /// ([Records.isSafeId]), since they go into object keys.
  static Iterable<String> _frameIds(Map<String, Object?> event) sync* {
    final annotations = event['annotations'];
    if (annotations is! List) return;
    final seen = <String>{};
    for (final a in annotations) {
      final id = a is Map ? a['frameId'] : null;
      if (id is String && Records.isSafeId(id) && seen.add(id)) yield id;
    }
  }

  /// Event keys, partitioned (`events/year=YYYY/day=DDD/<id>.json`) or
  /// flat, from before partitioning (`events/<id>.json`).
  static final RegExp _eventKey = RegExp(r'^events/(?:.+/)?([^/]+)\.json$');

  /// The ID of the event at [key] (see [_eventKey]); null for other keys.
  static String? _eventIdOf(String key) => _eventKey.firstMatch(key)?[1];

  /// Recording keys (`media/<clipId>.webm` or `.mp4`): the clip's ID.
  static final RegExp _recordingKey = RegExp(r'^media/(.+)\.(?:webm|mp4)$');

  /// Where clip [clipId]'s recording may be: WebM (the web) or MP4.
  static List<String> _recordingKeys(String clipId) => [
    'media/$clipId.webm',
    'media/$clipId.mp4',
  ];

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
    S3Exception(clockSkewed: true, :final clockOffset) =>
      clockOffset == null
          ? "This device's clock is wrong: set it to the right time to sync"
          : AwsClock.describe(clockOffset),
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
    live?.removeListener(_onLiveChanged);
    if (_ownsCopies) copies.dispose();
    live?.stop();
    _timer?.cancel();
    _periodic?.cancel();
    _changes.cancel();
    auth.removeListener(_onAuthChanged);
    roles?.removeListener(_onAuthChanged);
    super.dispose();
  }
}

/// Thrown when a pass is no longer [_Pass.current]: it ends quietly.
class _Abandoned implements Exception {
  const _Abandoned();
}

/// One pass of [CloudSync]: the session it connected with, the store, and
/// the profile ([owner]) it syncs, all as they were when it started. Every
/// step stamps, uploads and imports for [owner] only, and checks [current]
/// first ([check]): once the account signs out, moves to another profile or
/// reconnects, or syncing stops, the pass ends at its next step instead of
/// mixing that profile's data with the next one's.
class _Pass {
  _Pass(this._sync, this.session, this.store, this.owner, this._epoch);

  final CloudSync _sync;
  final CloudSession session;
  final EventStore store;
  final String owner;
  final int _epoch;

  /// Each clip's media keys, as listed once by this pass.
  final Map<String, Set<String>> _mediaKeys = {};

  /// Whether the pass may still go on: its profile still syncs, from the
  /// same start ([CloudSync._epoch]), not stopped, not disposed.
  bool get current =>
      _epoch == _sync._epoch && !_sync.stopped && !_sync._disposed;

  /// Throws [_Abandoned] unless [current].
  void check() {
    if (!current) throw const _Abandoned();
  }

  /// [key], under the profile's folder.
  String objectKey(String key) => '${session.prefix}/$key';

  /// Marks [key] (in the folder) as synced, with [fingerprint].
  Future<void> synced(String key, String fingerprint) {
    check();
    return _sync._markSynced(store, objectKey(key), fingerprint);
  }

  /// Keeps [etag] as [key]'s, as this device last uploaded or downloaded
  /// it.
  Future<void> keepETag(String key, String etag) {
    check();
    return _sync._markSynced(store, CloudSync._etagKey(objectKey(key)), etag);
  }

  /// A recording in the cloud ([key]): synced (never uploaded back), and
  /// pending here, as [mediaId] of an event at [time], until it's
  /// downloaded.
  Future<void> pending(String key, String mediaId, int time) async {
    await synced(key, mediaId);
    await _sync._markSynced(
      store,
      CloudSync._fetchKey(objectKey(key)),
      '$time:$mediaId',
    );
  }

  /// Clip [clipId]'s media in the bucket (recording, thumbnail, tagged
  /// frames), listed once per pass.
  Future<Set<String>> mediaKeys(String clipId) async => _mediaKeys[clipId] ??= {
    for (final k in await session.list('media/$clipId'))
      if (k.startsWith('media/$clipId.') || k.startsWith('media/$clipId/')) k,
  };

  /// Lists clips' media afresh from now on.
  void forgetMediaKeys() => _mediaKeys.clear();
}
