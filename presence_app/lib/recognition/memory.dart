import 'memory_native.dart'
    if (dart.library.js_interop) 'memory_web.dart'
    as platform;

/// How much memory the device has left, as Android's `ActivityManager`
/// reports it (`memoryStatus` on `presence/device`).
class MemoryStatus {
  const MemoryStatus({
    required this.lowMemory,
    required this.availableBytes,
    required this.thresholdBytes,
    this.lowRamDevice = false,
  });

  static MemoryStatus? fromMap(Map<Object?, Object?>? map) {
    if (map == null) return null;
    return MemoryStatus(
      lowMemory: map['lowMemory'] == true,
      availableBytes: (map['availMem'] as num?)?.toInt() ?? 0,
      thresholdBytes: (map['threshold'] as num?)?.toInt() ?? 0,
      lowRamDevice: map['lowRamDevice'] == true,
    );
  }

  /// What recognition needs on top of the system's threshold: the models
  /// and a frame's working memory.
  static const int recognitionBytes = 64 << 20;

  /// The system says memory is low: it's killing background apps.
  final bool lowMemory;

  /// Memory free or quickly freed.
  final int availableBytes;

  /// Below this, the system thinks memory is low.
  final int thresholdBytes;

  final bool lowRamDevice;

  /// Too little to run recognition without the system killing the app.
  bool get tight =>
      lowMemory || availableBytes < thresholdBytes + recognitionBytes;

  @override
  String toString() =>
      '${availableBytes >> 20} MB free (low under '
      '${thresholdBytes >> 20} MB${lowMemory ? ', low now' : ''}'
      '${lowRamDevice ? ', low-RAM device' : ''})';
}

/// Reads the device's [MemoryStatus], so recognition waits while memory is
/// tight.
abstract class MemoryMonitor {
  /// This platform's: Android's `ActivityManager`; none elsewhere.
  factory MemoryMonitor() = platform.PlatformMemoryMonitor;

  /// Null where it's unknown: recognition then always runs.
  Future<MemoryStatus?> status();
}
