import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('presence/cameras');

/// The screen as a light for night mode: while [CameraRig.screenLight] is
/// on, the whole app is white and the screen at full brightness
/// (`setScreenLight` on Android and iOS; a browser can't change it, but
/// the white still lights a face or a room).
class ScreenLightOverlay extends StatefulWidget {
  const ScreenLightOverlay({super.key, required this.on});

  final ValueListenable<bool> on;

  @override
  State<ScreenLightOverlay> createState() => _ScreenLightOverlayState();
}

class _ScreenLightOverlayState extends State<ScreenLightOverlay> {
  @override
  void initState() {
    super.initState();
    widget.on.addListener(_changed);
  }

  @override
  void dispose() {
    widget.on.removeListener(_changed);
    if (widget.on.value) _brightness(false);
    super.dispose();
  }

  void _changed() {
    _brightness(widget.on.value);
    setState(() {});
  }

  static void _brightness(bool on) {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return;
    }
    _channel
        .invokeMethod<void>('setScreenLight', {'on': on})
        .catchError((Object e) => debugPrint('Presence: screen light: $e'));
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.on.value) return const SizedBox.shrink();
    // Over everything, taking no taps.
    return const Positioned.fill(
      child: IgnorePointer(
        child: ColoredBox(key: Key('screen-light'), color: Colors.white),
      ),
    );
  }
}
