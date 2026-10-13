import 'dart:io';

import '../recognition/memory.dart';
import 'device_memory.dart';

/// Android's free memory (`memoryStatus`), Linux's `MemAvailable`; none
/// elsewhere.
Future<DeviceMemory?> readDeviceMemory() async {
  try {
    if (Platform.isAndroid) {
      final status = await MemoryMonitor().status();
      return status == null
          ? null
          : DeviceMemory(bytes: status.availableBytes, free: true);
    }
    if (Platform.isLinux) {
      final bytes = DeviceMemory.memAvailableOf(
        await File('/proc/meminfo').readAsString(),
      );
      return bytes == null ? null : DeviceMemory(bytes: bytes, free: true);
    }
  } catch (_) {
    // Unknown, then.
  }
  return null;
}
