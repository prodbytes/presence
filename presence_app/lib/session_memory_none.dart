import 'session_memory.dart';

/// Apps don't refresh: nothing to keep.
class PlatformSessionMemory implements SessionMemory {
  @override
  String? read(String key) => null;

  @override
  void write(String key, String value) {}
}
