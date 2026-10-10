import 'screen_off.dart';

/// Browsers can't dim or turn off the screen.
class PlatformScreenOff implements ScreenOff {
  @override
  bool get supported => false;

  @override
  Future<void> set(bool off) async {}
}
