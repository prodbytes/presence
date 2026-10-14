import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'session_store.dart';

SessionStore platformSessionStore() => const SecureSessionStore();

/// Android and iOS: `flutter_secure_storage`, i.e. the Keychain on iOS and
/// Keystore-encrypted storage on Android. The refresh token lasts weeks,
/// so it isn't kept in plain preferences.
class SecureSessionStore extends SessionStore {
  const SecureSessionStore();

  static const String _key = 'presence.session';

  // Readable after the first unlock, so the unattended phone can refresh
  // its session while locked after a reboot; this device only, never in a
  // backup or iCloud Keychain.
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  // Errors are logged by type only: their messages could quote the value.
  @override
  Future<String?> load() async {
    try {
      return await _storage.read(key: _key);
    } catch (e) {
      debugPrint('Presence: no saved session: ${e.runtimeType}');
      return null;
    }
  }

  @override
  Future<void> save(String session) async {
    try {
      await _storage.write(key: _key, value: session);
    } catch (e) {
      debugPrint('Presence: could not save the session: ${e.runtimeType}');
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (e) {
      debugPrint('Presence: could not forget the session: ${e.runtimeType}');
    }
  }
}
