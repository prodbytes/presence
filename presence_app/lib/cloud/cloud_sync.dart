import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../auth/auth_service.dart';
import '../auth/roles_service.dart';
import '../config.dart' show LiveMode;
import '../crypto/media_seal.dart';
import '../events.dart';
import '../storage/event_store.dart';
import '../storage/media_store.dart';
import '../storage/records.dart';
import 'cognito.dart';
import 'event_copies.dart';
import 'live_sync.dart';
import 's3.dart';
import 'sigv4.dart';

import 'cloud_backend.dart';

export 'cloud_backend.dart';

part 'cloud_sync_copies.dart';
part 'cloud_sync_fetch.dart';
part 'cloud_sync_free.dart';
part 'cloud_sync_keys.dart';
part 'cloud_sync_live.dart';
part 'cloud_sync_pass.dart';
part 'cloud_sync_recordings.dart';
part 'cloud_sync_seal.dart';
part 'cloud_sync_upload.dart';

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
/// - Only a **premium** profile ([premium]: `presence_premium`, from
///   rbacr) syncs with the bucket, which refuses the others' credentials.
///   A **free** profile's devices sync over [live] alone
///   ([_LivePublisher]): each event saved here is published with its
///   clip's record and thumbnail, and other devices' come in the same way;
///   recordings, tagged frames, settings and history stay where they were
///   made. A change of tier starts over, with new credentials.
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
    MediaSeal? seal,
    EventCopies? copies,
    bool? prefetchRecordings,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _ownsCopies = copies == null,
       seal = seal ?? MediaSeal.instance,
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

  /// The media keys: this device's goes up with its settings (and with
  /// its live events), and other devices' come down from theirs.
  final MediaSeal seal;

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

  /// Counts an object uploaded.
  void _countUpload() {
    _uploaded++;
    notifyListeners();
  }

  /// The profile syncing now ([_syncProfile]); null while nothing syncs.
  String? _owner;

  /// Bumped whenever syncing starts over ([_startOver]: another profile,
  /// signed out, or [reconnect]): a pass of an older one stops at its next
  /// step ([_Pass.current]), so it never mixes two profiles' data.
  int _epoch = 0;

  Timer? _timer;
  Timer? _periodic;

  /// When the last pass that listed the whole window ran; null until the
  /// first pass for this user, which lists all of `events/`.
  DateTime? _lastFullFetch;
  int _downloaded = 0;
  Future<void>? _running;

  bool _again = false;
  bool _disposed = false;

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

  /// The parts of a pass, and what runs beside it (each in its own file).
  late final _Fetcher _fetcher = _Fetcher(this);
  late final _Sealing _sealing = _Sealing(this);
  late final _Uploader _uploader = _Uploader(this);
  late final _LivePublisher _publisher = _LivePublisher(this);
  late final _Recordings _recordings = _Recordings(this);
  late final _LiveBridge _liveBridge = _LiveBridge(this);
  late final _CopyTracker _copyTracker = _CopyTracker(this);

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
        _recordings.running != null ||
        (_timer?.isActive ?? false)) {
      if (_timer?.isActive ?? false) {
        _timer!.cancel();
        _startNow();
      }
      await _running;
      await _recordings.running;
      await _copyTracker.checks;
      await Future<void>.delayed(Duration.zero);
    }
    // And the copy checks the last pass started.
    await _copyTracker.checks;
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

  /// Whether the profile syncs with the bucket ([RolesService.isPremium]);
  /// otherwise over live sync alone. Without [roles] (tests), it does.
  bool get premium => roles?.isPremium ?? true;

  /// [premium] when the profile last started syncing.
  bool? _premiumWas;

  void _onAuthChanged() {
    final profile = _syncProfile;
    if (profile == _owner) {
      if (profile != null && _premiumWas != premium) {
        // Premium came or went: new credentials (their tier tag), and the
        // bucket or not.
        _premiumWas = premium;
        reconnect();
        return;
      }
      // Signed in again (a new ID token): try again after a stop.
      if (profile != null && stopped && auth.idToken != _stoppedFor) retry();
      return;
    }
    _premiumWas = premium;
    _owner = profile;
    _stoppedFor = null;
    backend.reset();
    _liveBridge.stop();
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
    _lastFullFetch = null;
    _reconcile = true;
    _synced = null;
    _dirty.clear();
    _failures = 0;
    _ticksToSkip = 0;
    _recordings.forgetFailures();
    _fetcher.reset();
    _handedOver.clear();
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

  /// Whether this device ([self]) and the cloud hold a full copy of the
  /// event [record] (see [_CopyTracker.copyOf]).
  @visibleForTesting
  static ({bool self, bool cloud}) copyOf(
    Map<String, Object?> record, {
    Map<String, Object?>? clip,
    required Map<String, String> synced,
    required String? prefix,
    required String deviceId,
  }) => _CopyTracker.copyOf(
    record,
    clip: clip,
    synced: synced,
    prefix: prefix,
    deviceId: deviceId,
  );

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
      _copyTracker.note(ids);
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
    _liveBridge.stop();
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
        _recordings.forgetFailures();
      }
      // Read again at each reconciliation, so entries pruned with the
      // events they were for go from memory too.
      if (_synced == null || reconcile) {
        _synced = await pass.store.syncedKeys();
      }
      // What the folder held unsealed goes first, once.
      await _sealing.purgeUnsealed(pass);
      if (last == null) await _fetcher.fetchSettings(pass);
      // The other devices' keys, to open their media.
      await _sealing.fetchKeys(pass, all: full);
      await _fetcher.fetch(
        pass,
        _fetcher.prefixes(now, first: last == null, full: full),
      );
      pass.check();
      if (full) {
        _lastFullFetch = now;
        await _fetcher.rewantClips(owner);
      }
      await _fetcher.fetchWanted(pass);
      await _uploader.syncAll(pass, reconcile ? null : dirty);
      pass.check();
      // Who holds what, for every event of the window (and acks not sent
      // before, such as while live sync was off).
      if (full) _copyTracker.note(null).ignore();
    }

    void giveBack() {
      // Not to another profile's sync.
      if (epoch != _epoch) return;
      _dirty.addAll(dirty);
      if (reconcile) _reconcile = true;
    }

    try {
      if (!premium) {
        // Free: live sync only, never the bucket.
        final session = await backend.connect(idToken);
        _identity = session.prefix;
        await _liveBridge.start(session, owner);
        await _publisher.publish(owner, epoch, reconcile ? null : dirty);
        if (epoch != _epoch) return;
        _failures = 0;
        _ticksToSkip = 0;
        _set(CloudSyncState.synced);
        return;
      }
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
      _recordings.start();
      if (used case final session?) await _liveBridge.start(session, owner);
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
      _liveBridge.stop();
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

  /// Downloads the recording [mediaId] of clip [clipId] from the signed-in
  /// profile's folder into the `MediaStore`, for playing a clip fetched
  /// from the cloud whose recording isn't here yet. Returns whether it's
  /// stored now; false when signed out, or it isn't in the cloud, or the
  /// download failed; and for a free profile, which has no bucket: its
  /// recordings are only on the device that made them.
  Future<bool> fetchRecording(String clipId, String mediaId) async =>
      premium && await _recordings.fetchRecording(clipId, mediaId);

  /// The most clips a full fetch wants again ([_Fetcher.rewantClips]).
  static const int maxRewanted = 100;

  /// The content type of sealed media in the bucket ([MediaSeal]): its
  /// thumbnails, tagged frames and recordings.
  static const String sealedType = 'application/octet-stream';

  /// Where a device's settings go in the user's folder:
  /// `devices/<deviceId>/settings.json`.
  static String settingsKey(String deviceId) =>
      'devices/$deviceId/settings.json';

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

  /// An object's ETag as S3 lists it, from its bytes: their MD5, in hex
  /// (single PUTs to a bucket with SSE-S3 encryption).
  static String etagOf(Uint8List bytes) => md5.convert(bytes).toString();

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
