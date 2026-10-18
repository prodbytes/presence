import 'session_memory_none.dart'
    if (dart.library.js_interop) 'session_memory_web.dart'
    as platform;

/// Keeps small values across a browser refresh, by key (the Monitoring
/// tab's filters: [EventFilters.remembered]).
abstract class SessionMemory {
  /// This platform's: the browser tab's `sessionStorage` on web (a refresh
  /// keeps it, a new browser tab starts afresh); nothing elsewhere.
  factory SessionMemory() = platform.PlatformSessionMemory;

  String? read(String key);

  void write(String key, String value);
}

/// Keeps it in memory, for tests.
class InMemorySessionMemory implements SessionMemory {
  final values = <String, String>{};

  @override
  String? read(String key) => values[key];

  @override
  void write(String key, String value) => values[key] = value;
}
