import 'memory.dart';

/// Browsers don't say: recognition always runs.
class PlatformMemoryMonitor implements MemoryMonitor {
  @override
  Future<MemoryStatus?> status() async => null;
}
