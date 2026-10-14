/// Where the Presence session ([SavedSession], encoded) is kept between
/// launches: the browser's localStorage on web, the Keychain (iOS) or
/// Keystore-backed storage (Android) elsewhere.
library;

import 'session_store_io.dart'
    if (dart.library.js_interop) 'session_store_web.dart'
    as platform;

/// One saved session, under one key. Failures (storage disabled, no
/// plugin) read as nothing saved, and saving quietly does nothing.
abstract class SessionStore {
  const SessionStore();

  /// This platform's store.
  factory SessionStore.platform() => platform.platformSessionStore();

  Future<String?> load();

  Future<void> save(String session);

  Future<void> clear();
}

/// A store in memory: for tests.
class MemorySessionStore extends SessionStore {
  MemorySessionStore([this.value]);

  String? value;

  @override
  Future<String?> load() async => value;

  @override
  Future<void> save(String session) async => value = session;

  @override
  Future<void> clear() async => value = null;
}
