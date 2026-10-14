import 'package:web/web.dart' as web;

import 'session_store.dart';

SessionStore platformSessionStore() => const WebSessionStore();

/// The browser's localStorage, under one key, so a reload stays signed in.
///
/// Trade-off: script running on the app's origin (an XSS) could read the
/// refresh token, which lasts up to 60 days. An httpOnly cookie would keep
/// it out of script's reach, but needs the API to set and read it;
/// acceptable for now.
class WebSessionStore extends SessionStore {
  const WebSessionStore();

  static const String _key = 'presence.session';

  @override
  Future<String?> load() async {
    try {
      return web.window.localStorage.getItem(_key);
    } catch (_) {
      return null; // storage disabled (e.g. some private modes)
    }
  }

  @override
  Future<void> save(String session) async {
    try {
      web.window.localStorage.setItem(_key, session);
    } catch (_) {}
  }

  @override
  Future<void> clear() async {
    try {
      web.window.localStorage.removeItem(_key);
    } catch (_) {}
  }
}
