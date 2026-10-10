part of 'cloud_sync.dart';

/// Media sealing's part of a pass: deleting what the profile's folder held
/// before media was sealed ([purgeUnsealed]), and fetching the media keys
/// of the profile's other devices ([fetchKeys]).
class _Sealing {
  _Sealing(this._sync);

  final CloudSync _sync;

  /// The marker at the root of a profile's folder: the profile's media is
  /// sealed since it was written. What's older under [_purged] was stored
  /// unsealed, by older versions of the app, and is deleted.
  static const String markerKey = 'encryption.json';

  /// The trees a purge deletes from: events, clip records and media.
  /// Devices' settings (`devices/`) stay: they hold the media keys.
  static const List<String> _purged = ['events/', 'clips/', 'media/'];

  /// Settings-store key of the profiles (folders) whose unsealed data this
  /// device has deleted.
  static const String _purgedKey = 'sealed';

  /// Folders purged (or tried) in this run: once a run is enough.
  final Set<String> _tried = {};

  /// Deletes what the profile's folder held before its media was sealed:
  /// once per device and profile, before anything is fetched or uploaded.
  ///
  /// The first device that seals for the profile writes the marker
  /// ([markerKey]) if it isn't there; its time (S3's) is the cutover.
  /// Every device then deletes each object under `events/`, `clips/` and
  /// `media/` written before it. Devices that seal upload only after the
  /// marker is there, so nothing of theirs is older. Each device does it
  /// once (remembered in the settings store); one that's interrupted, or
  /// refused (credentials without the right to delete), tries again in
  /// its next run. It never fails the pass.
  Future<void> purgeUnsealed(_Pass pass) async {
    final session = pass.session;
    final folder = session.prefix;
    if (!_tried.add(folder)) return;
    final store = pass.store;
    final done = await store.getSettings(_purgedKey);
    final folders = done?['folders'];
    if (folders is List && folders.contains(folder)) return;
    try {
      var cutover = (await session.listModified(markerKey))[markerKey];
      if (cutover == null) {
        await session.putIfNew(
          markerKey,
          _json({
            'version': SealFormat.magic.last,
            'sealedSince': _sync._now().millisecondsSinceEpoch,
          }),
          'application/json',
        );
        cutover = (await session.listModified(markerKey))[markerKey];
        if (cutover == null) throw StateError('the marker is missing');
      }
      pass.check();
      var deleted = 0;
      for (final tree in _purged) {
        final listed = await session.listModified(tree);
        for (final MapEntry(:key, :value) in listed.entries) {
          if (!value.isBefore(cutover)) continue;
          pass.check();
          await session.delete(key);
          await _sync._forgetSynced(store, pass.objectKey(key));
          deleted++;
          await _sync._breathe();
        }
      }
      await store.putSettings(_purgedKey, {
        'folders': [
          if (folders is List) ...folders.whereType<String>(),
          folder,
        ],
      });
      debugPrint(
        'Presence: deleted $deleted objects stored unencrypted in the cloud',
      );
    } on _Abandoned {
      _tried.remove(folder);
      rethrow;
    } catch (e) {
      debugPrint(
        'Presence: could not delete what the cloud holds unencrypted: $e',
      );
    }
  }

  /// The device IDs whose keys were wanted at the last look.
  Set<String> _looked = const {};

  /// Fetches the media keys of the profile's other devices, from their
  /// settings (`devices/<id>/settings.json`, `mediaKey`): with [all] (the
  /// first pass, and each full fetch) every device's it doesn't know yet;
  /// otherwise only when a key was wanted (an image that wouldn't open)
  /// since the last look.
  Future<void> fetchKeys(_Pass pass, {required bool all}) async {
    final keys = _sync.seal.keys;
    final wanted = keys.wanted;
    if (!all && (wanted.isEmpty || setEquals(wanted, _looked))) return;
    _looked = Set.of(wanted);
    final session = pass.session;
    final own = keys.ownId;
    final listed = await session.list('devices/');
    for (final key in listed) {
      final parts = key.split('/');
      if (parts.length != 3 || parts[2] != 'settings.json') continue;
      final id = parts[1];
      if (id == own || keys.keyOf(id) != null || !Records.isSafeId(id)) {
        continue;
      }
      pass.check();
      final bytes = await _Fetcher._getOrSkip(session, key);
      if (bytes == null) continue;
      final decoded = Records.decode(bytes, what: key);
      final record = decoded == null ? null : Records.tryParseSettings(decoded);
      if (record == null || record['deviceId'] != id) continue;
      if (MediaKeys.decode(record['mediaKey']) case final mediaKey?) {
        keys.add(id, mediaKey);
      }
    }
  }
}
