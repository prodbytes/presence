import 'device_memory_native.dart'
    if (dart.library.js_interop) 'device_memory_web.dart'
    as platform;

/// How much memory this device has for the app, as far as the platform
/// says (Settings shows it after the device's ID).
class DeviceMemory {
  const DeviceMemory({required this.bytes, required this.free});

  /// [free]: what's free now (Android's `availMem`, Linux's
  /// `MemAvailable`); else the device's whole memory, approximate (a
  /// browser's `navigator.deviceMemory`).
  final int bytes;
  final bool free;

  /// This device's, or null where the platform doesn't say (iOS, macOS,
  /// Windows, Firefox and Safari).
  static Future<DeviceMemory?> read() => platform.readDeviceMemory();

  /// [bytes] as people read them: `512 MB`, `1.2 GB`, `8 GB`.
  static String format(int bytes) {
    const gb = 1 << 30;
    if (bytes < gb) return '${(bytes / (1 << 20)).round()} MB';
    final g = bytes / gb;
    return g >= 10 || g == g.roundToDouble()
        ? '${g.round()} GB'
        : '${g.toStringAsFixed(1)} GB';
  }

  /// `MemAvailable` in a `/proc/meminfo` [text], in bytes, or null.
  static int? memAvailableOf(String text) {
    final m = RegExp(
      r'^MemAvailable:\s+(\d+)\s+kB',
      multiLine: true,
    ).firstMatch(text);
    return m == null ? null : int.parse(m.group(1)!) * 1024;
  }
}
