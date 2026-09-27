import 'package:web/web.dart' as web;

/// The browser's localStorage, under one key. Google Identity Services on
/// web keeps no session of its own, so without this a reload signs out.
class SessionStore {
  const SessionStore();

  static const String _key = 'presence.session';

  String? load() {
    try {
      return web.window.localStorage.getItem(_key);
    } catch (_) {
      return null; // storage disabled (e.g. some private modes)
    }
  }

  void save(String session) {
    try {
      web.window.localStorage.setItem(_key, session);
    } catch (_) {}
  }

  void clear() {
    try {
      web.window.localStorage.removeItem(_key);
    } catch (_) {}
  }
}
