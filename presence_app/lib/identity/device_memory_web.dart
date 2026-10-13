import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'device_memory.dart';

/// `navigator.deviceMemory`: the device's memory in GB, rounded down to a
/// power of two and capped (Chromium only; null elsewhere).
Future<DeviceMemory?> readDeviceMemory() async {
  try {
    final value = (web.window.navigator as JSObject).getProperty<JSAny?>(
      'deviceMemory'.toJS,
    );
    if (value case final JSNumber gb) {
      return DeviceMemory(
        bytes: (gb.toDartDouble * (1 << 30)).round(),
        free: false,
      );
    }
  } catch (_) {
    // Unknown, then.
  }
  return null;
}
