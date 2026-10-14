import 'dart:io';

import 'package:flutter/services.dart';

/// Android: `memoryStatus` on `presence/device`; iOS: `totalMemory` on
/// `presence/cameras`; null elsewhere, or if it can't say.
Future<int?> deviceMemoryMb() async {
  try {
    if (Platform.isAndroid) {
      final status = await const MethodChannel('presence/device')
          .invokeMapMethod<Object?, Object?>('memoryStatus');
      final total = status?['totalMem'];
      return total is num && total > 0 ? total ~/ (1 << 20) : null;
    }
    if (Platform.isIOS) {
      final total = await const MethodChannel('presence/cameras')
          .invokeMethod<num>('totalMemory');
      return total != null && total > 0 ? total ~/ (1 << 20) : null;
    }
  } catch (_) {
    // Unknown.
  }
  return null;
}
