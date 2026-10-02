import 'tab_memory.dart';

/// Apps don't refresh: they always start on the camera.
class PlatformTabMemory implements TabMemory {
  @override
  String? read() => null;

  @override
  void write(String tab) {}
}
