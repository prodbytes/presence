import 'screen_off_native.dart'
    if (dart.library.js_interop) 'screen_off_web.dart'
    as platform;

/// Lets the screen go dark while capture goes on, to save battery
/// (Android only): the screen no longer stays on, drops to its lowest
/// brightness, and the camera's preview stops, until [set] turns it back.
/// The system's screen timeout then turns the screen off for real.
abstract class ScreenOff {
  /// This platform's: Android's (`screenOff` on `presence/device`); none
  /// elsewhere ([supported] false).
  factory ScreenOff() = platform.PlatformScreenOff;

  /// Whether this platform can do it: the button only shows where it can.
  bool get supported;

  /// Darkens the screen ([off]) or brings it back.
  Future<void> set(bool off);
}
