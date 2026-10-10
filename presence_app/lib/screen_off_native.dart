import 'dart:io';

import 'package:flutter/services.dart';

import 'app_log.dart';
import 'screen_off.dart';

const _channel = MethodChannel('presence/device');

/// Asks Android (`screenOff` on `presence/device`); unsupported elsewhere.
class PlatformScreenOff implements ScreenOff {
  @override
  bool get supported => Platform.isAndroid;

  @override
  Future<void> set(bool off) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('screenOff', {'off': off});
    } catch (e) {
      AppLog.instance.add(
        'Screen ${off ? 'off' : 'on'} failed: $e',
        error: true,
      );
    }
  }
}
