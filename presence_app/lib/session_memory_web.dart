import 'package:web/web.dart' as web;

import 'session_memory.dart';

/// In `sessionStorage`: kept across refreshes of this browser tab only.
class PlatformSessionMemory implements SessionMemory {
  @override
  String? read(String key) {
    try {
      return web.window.sessionStorage.getItem(key);
    } catch (_) {
      // Storage blocked (privacy settings): the defaults.
      return null;
    }
  }

  @override
  void write(String key, String value) {
    try {
      web.window.sessionStorage.setItem(key, value);
    } catch (_) {}
  }
}
