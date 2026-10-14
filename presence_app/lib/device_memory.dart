import 'device_memory_native.dart'
    if (dart.library.js_interop) 'device_memory_web.dart'
    as platform;

/// This device's total memory, in MB; null where the platform doesn't say.
/// Android: `ActivityManager`'s total (`memoryStatus` on `presence/device`);
/// iOS: `physicalMemory` (`totalMemory` on `presence/cameras`); a browser:
/// `navigator.deviceMemory` (Chrome's, rounded: 0.25 to 8 GB; Safari and
/// Firefox don't say).
Future<int?> deviceMemoryMb() => platform.deviceMemoryMb();

/// Recognition runs only from this much memory: a "2 GB" device reports a
/// little less (the system keeps some), so 1800 MB, not 2048. Below it (a
/// Raspberry Pi, an old phone), recognition is left to the cloud and the
/// other devices.
const int minRecognitionMemoryMb = 1800;

/// [mb] as people say it: "4 GB", "3.5 GB", "512 MB".
String formatMemory(int mb) {
  if (mb < 1000) return '$mb MB';
  final gb = mb / 1024;
  // Halves: a 3.6 GB report is a "3.5 GB" device.
  final halves = (gb * 2).round() / 2;
  return halves == halves.roundToDouble()
      ? '${halves.round()} GB'
      : '${halves.toStringAsFixed(1)} GB';
}
