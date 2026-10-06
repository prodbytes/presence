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
  ///
  /// iPadOS 13 and later Safari presents itself as a Mac; a Mac user agent
  /// with more than one touch point ([maxTouchPoints], the browser's
  /// `navigator.maxTouchPoints`) is taken to be an iPad, so iOS.
  ///
  /// Browsers on iOS name themselves with their own token (`CriOS/`,
  /// `FxiOS/`, `EdgiOS/`, `OPT/`) beside Safari's, so those are checked
  /// before `Safari/`; Edge and Opera elsewhere also carry `Chrome/`, so
  /// they are checked before Chrome.
  static String ofUserAgent(String userAgent, {int maxTouchPoints = 0}) {
    final ua = userAgent;
    final browser = switch (ua) {
      _
          when ua.contains('Edg/') ||
              ua.contains('EdgA/') ||
              ua.contains('EdgiOS/') =>
        'Edge',
      _ when ua.contains('OPR/') || ua.contains('OPT/') => 'Opera',
      _ when ua.contains('Firefox/') || ua.contains('FxiOS/') => 'Firefox',
      _ when ua.contains('Chrome/') || ua.contains('CriOS/') => 'Chrome',
      _ when ua.contains('Safari/') => 'Safari',
      _ => null,
    };
    final mac = ua.contains('Mac OS X') || ua.contains('Macintosh');
    final system = switch (ua) {
      _ when ua.contains('Android') => 'Android',
      _
          when ua.contains('iPhone') ||
              ua.contains('iPad') ||
              ua.contains('iPod') =>
        'iOS',
      _ when ua.contains('CrOS') => 'ChromeOS',
      _ when mac && maxTouchPoints > 1 => 'iOS',
      _ when mac => 'macOS',
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
