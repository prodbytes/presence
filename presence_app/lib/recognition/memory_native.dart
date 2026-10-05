import 'dart:io';

import 'package:flutter/services.dart';

import 'memory.dart';

const _channel = MethodChannel('presence/device');

/// Asks Android (`memoryStatus` on `presence/device`); unknown elsewhere,
/// or if it can't say.
class PlatformMemoryMonitor implements MemoryMonitor {
  @override
  Future<MemoryStatus?> status() async {
    if (!Platform.isAndroid) return null;
    try {
      return MemoryStatus.fromMap(
        await _channel.invokeMapMethod<Object?, Object?>('memoryStatus'),
      );
    } catch (_) {
      return null;
    }
  }
}
