import 'package:web/web.dart' as web;

import 'device_os.dart';

String currentOs() {
  final navigator = web.window.navigator;
  return DeviceOs.ofUserAgent(
    navigator.userAgent,
    maxTouchPoints: navigator.maxTouchPoints,
  );
}
