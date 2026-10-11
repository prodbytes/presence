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
- **CocoaPods:** `tflite_flutter` (for [recognition](recognition.md))
  ships through CocoaPods (`TensorFlowLiteC` 2.12), so the project has a
  `Podfile`, `Podfile.lock` and the Pods in its Xcode project;
  `flutter build ios` runs `pod install` (CocoaPods must be installed, as
  on GitHub's macOS runners). Recognition itself isn't on iOS yet.
- `Info.plist` declares camera and **microphone** usage, locks iPhone to
  portrait, and names the app "Presence".
- **Verified:** it builds with Xcode 27, and on the iOS simulator the
  plugin answers the channel: the camera permission prompt appears, where
  before there was a `MissingPluginException`.
- **On a physical iPhone** (2026-10-11, an iPhone 12 mini on iOS 26.3.1,
  paired by USB): `flutter build ios --release` with the repo's settings
  (`scripts/dart-defines.sh`, `scripts/version.sh`) signs it automatically
  with the Mac's Apple Development identity (team `LMX88986F3`, chosen by
  Flutter; the Xcode project names no team), then `xcrun devicectl device
  install app --device <UDID> build/ios/iphoneos/Runner.app` and `xcrun
  devicectl device process launch --terminate-existing --device <UDID>
  com.nu01.presence` install and start it; it runs. What it does once
  open (the camera, sign-in) wasn't checked from the command line.
