import 'tab_memory_none.dart'
    if (dart.library.js_interop) 'tab_memory_web.dart'
    as platform;

/// Remembers which tab is open, so a browser refresh comes back to it.
abstract class TabMemory {
  /// This platform's: the browser tab's `sessionStorage` on web (a refresh
  /// keeps it, a new browser tab starts on the camera); nothing elsewhere.
  factory TabMemory() = platform.PlatformTabMemory;

  /// The remembered tab's name, if any.
  String? read();

  void write(String tab);
}

/// Keeps it in memory, for tests.
class InMemoryTabMemory implements TabMemory {
  InMemoryTabMemory([this.tab]);

  String? tab;

  @override
  String? read() => tab;

  @override
  void write(String tab) => this.tab = tab;
}
