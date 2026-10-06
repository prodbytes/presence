import 'package:flutter/material.dart';

import 'device_os_native.dart'
    if (dart.library.js_interop) 'device_os_web.dart'
    as platform;

/// The operating system a device runs, as recorded on its events
/// (`AppEvent.os`): `Android`, `iOS`, `macOS`, `Windows`, `Linux`, or on
/// the web the browser and the system under it, such as
/// `Web (Chrome, macOS)`.
abstract final class DeviceOs {
  /// This device's, worked out once.
  static final String current = platform.currentOs();

  /// The icon for [os] (as [current] names it); a generic device for an
  /// unknown or missing one.
  static IconData iconOf(String? os) {
    if (os == null) return Icons.devices_other;
    if (os.startsWith('Web')) return Icons.language;
    return switch (os) {
      'Android' => Icons.android,
      'iOS' => Icons.phone_iphone,
      'macOS' => Icons.laptop_mac,
      'Windows' => Icons.desktop_windows,
      'Linux' => Icons.computer,
      _ => Icons.devices_other,
    };
  }

  /// The browser in a web [userAgent], and the system it runs on, as
  /// `Web (Chrome, macOS)`; `Web` alone when neither is recognized.
  static String ofUserAgent(String userAgent) {
    final ua = userAgent;
    final browser = switch (ua) {
      _ when ua.contains('Edg/') || ua.contains('EdgA/') => 'Edge',
      _ when ua.contains('OPR/') => 'Opera',
      _ when ua.contains('Firefox/') || ua.contains('FxiOS/') => 'Firefox',
      _ when ua.contains('Chrome/') || ua.contains('CriOS/') => 'Chrome',
      _ when ua.contains('Safari/') => 'Safari',
      _ => null,
    };
    final system = switch (ua) {
      _ when ua.contains('Android') => 'Android',
      _ when ua.contains('iPhone') || ua.contains('iPad') => 'iOS',
      _ when ua.contains('CrOS') => 'ChromeOS',
      _ when ua.contains('Mac OS X') || ua.contains('Macintosh') => 'macOS',
      _ when ua.contains('Windows') => 'Windows',
      _ when ua.contains('Linux') => 'Linux',
      _ => null,
    };
    final parts = [?browser, ?system];
    return parts.isEmpty ? 'Web' : 'Web (${parts.join(', ')})';
  }

  /// The name `Platform.operatingSystem` gives, written the usual way.
  static String ofPlatform(String name) => switch (name) {
    'android' => 'Android',
    'ios' => 'iOS',
    'macos' => 'macOS',
    'windows' => 'Windows',
    'linux' => 'Linux',
    'fuchsia' => 'Fuchsia',
    _ => name,
  };
}
