# iOS

The Swift counterpart of the Android layer
([ios/Runner/](../presence_app/ios/Runner)), registered in `AppDelegate`:

- **`RollingCamera.swift`:** an `AVCaptureSession` (1280×720, rotated to
  **portrait** frames on the capture connection, unmirrored) with a BGRA
  `AVCaptureVideoDataOutput`. Each frame goes to:
  - the **preview**, as a Flutter texture (`FlutterTexture`);
  - a hardware **H.264** encoder (VideoToolbox, 2.5 Mbps, a keyframe every
    second, no B-frames);
  - **motion** sampling to 64×48 luma, every 200 ms.

  Microphone audio (`AVCaptureAudioDataOutput`) is **deep-copied**, because
  capture buffers come from a small pool that holding them would starve.
  The frame rate is 30 fps, dropping to 10 fps in low light. Brightness uses
  `setExposureTargetBias`.
- **`SampleRing.swift`:** the same ring and pruning model as Android.
  Clips are written with `AVAssetWriter`: H.264 passed through, and audio
  encoded to AAC, starting at the keyframe at or before the window, with the
  same window offsets.
- **`PresenceCamerasPlugin.swift`:** the channel methods (permissions,
  list, open/close, pre-roll, brightness, clip parts, thumbnail) and motion
  events. The front preview is mirrored in Dart (`mirror` flag); recordings
  aren't. The screen is kept awake.
- `Info.plist` declares camera and **microphone** usage, locks iPhone to
  portrait, and names the app "Presence".
- **Verified:** it builds with Xcode 27, and on the iOS simulator the
  plugin answers the channel: the camera permission prompt appears, where
  before there was a `MissingPluginException`. **Not yet verified on a
  physical iPhone**: the simulator can't grant camera access from the
  command line, and a device run needs the iPhone paired for development and
  a signing identity (an Apple ID team in Xcode, plus a real bundle ID).
