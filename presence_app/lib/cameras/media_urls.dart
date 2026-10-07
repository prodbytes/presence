import 'package:flutter/foundation.dart';

import 'media_urls_none.dart'
    if (dart.library.js_interop) 'media_urls_web.dart'
    as platform;

/// In-memory recording URLs (on web, Blob object URLs: each holds its
/// recording's bytes in the page's memory until revoked) and who uses
/// them, so each is revoked once nothing needs it. An unattended browser
/// records clips for days: without this, every clip stayed in memory.
///
/// A URL is revoked when it has no owners and no users:
/// - an *owner* is a live recording not yet saved ([own] / [disown]);
/// - a *user* is a player or a frame sampler showing it ([retain] /
///   [release]).
///
/// A URL made to play a stored recording ([loaded]) has no owner: it's
/// revoked when its last user lets go, and loaded again next time.
///
/// URLs it was never told about (file paths on Android) are left alone;
/// on Android it tracks nothing ([MediaUrls.none]).
class MediaUrls {
  MediaUrls({required this._revoke}) : _enabled = true;

  /// Tracks nothing: where recordings are files, not memory.
  MediaUrls.none() : _revoke = _ignore, _enabled = false;

  static void _ignore(String _) {}

  /// The app's: tracks Blob URLs on web, nothing elsewhere. Tests replace
  /// it to count revokes.
  static MediaUrls instance = platform.hasMediaUrls
      ? MediaUrls(revoke: platform.revokeMediaUrl)
      : MediaUrls.none();

  final void Function(String url) _revoke;
  final bool _enabled;
  final _entries = <String, _Entry>{};

  /// How many URLs are still held (for tests and diagnostics).
  int get tracked => _entries.length;

  /// Whether [url] is tracked and not revoked yet.
  bool isLive(String url) => _entries.containsKey(url);

  /// A live recording at [url] keeps it until it [disown]s it.
  void own(String url) {
    if (!_enabled) return;
    (_entries[url] ??= _Entry()).owners++;
  }

  /// A live recording no longer needs [url] (it was saved, or replaced by
  /// a trimmed copy): revoked now, or when its last user lets go.
  void disown(String url) {
    final entry = _entries[url];
    if (entry == null) return;
    entry.owners--;
    _revokeIfUnused(url, entry);
  }

  /// [url] was made to play a stored recording: revoked when its last
  /// user lets go, which then calls [onRevoked] (to forget it).
  void loaded(String url, {VoidCallback? onRevoked}) {
    if (!_enabled) return;
    (_entries[url] ??= _Entry()).onRevoked = onRevoked;
  }

  /// A player or sampler uses [url] until it [release]s it.
  void retain(String url) => _entries[url]?.users++;

  /// A player or sampler is done with [url].
  void release(String url) {
    final entry = _entries[url];
    if (entry == null) return;
    entry.users--;
    _revokeIfUnused(url, entry);
  }

  void _revokeIfUnused(String url, _Entry entry) {
    if (entry.owners > 0 || entry.users > 0) return;
    _entries.remove(url);
    _revoke(url);
    entry.onRevoked?.call();
  }
}

class _Entry {
  int owners = 0;
  int users = 0;
  VoidCallback? onRevoked;
}
