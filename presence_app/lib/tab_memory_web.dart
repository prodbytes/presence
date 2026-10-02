import 'package:web/web.dart' as web;

import 'tab_memory.dart';

/// In `sessionStorage`: kept across refreshes of this browser tab only.
class PlatformTabMemory implements TabMemory {
  static const String key = 'presence.tab';

  @override
  String? read() {
    try {
      return web.window.sessionStorage.getItem(key);
    } catch (_) {
      // Storage blocked (privacy settings): start on the camera.
      return null;
    }
  }

  @override
  void write(String tab) {
    try {
      web.window.sessionStorage.setItem(key, tab);
    } catch (_) {}
  }
}
