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
  same window offsets. Each input (video, audio) is fed its own track in
  time order through `requestMediaDataWhenReady`. Feeding both from one
  list, in the order the samples arrived, deadlocked: the writer
  interleaves the tracks and can hold one input until the other gets
  data, so a clip whose audio was ahead of its encoded video never
  finished; on the iPhone 12 mini, 6 of its first 8 clips stayed at the
  "before" part (`partial`). Each stage (feeding, finishing) is given up
  after **30 s** (`SampleRing.writeTimeout`): the writing is cancelled and
  the part answers nothing, so the clip shows as interrupted instead of
  recording forever.
- **Tests** (`RunnerTests/RunnerTests.swift`, `SampleRingTests`, run with
  `xcodebuild test -workspace ios/Runner.xcworkspace -scheme Runner
  -destination 'platform=iOS Simulator,name=…'
  -only-testing:RunnerTests/SampleRingTests` after `flutter build ios
  --simulator --debug`): real H.264 (VideoToolbox) and PCM samples written
  to MP4: all the audio ahead of the video (15 s with both tracks; the old
  writer hung past the test's 60 s), interleaved with the video 0.1 s late,
  and video only.
- **`PresenceCamerasPlugin.swift`:** the channel methods (permissions,
  list, open/close, pre-roll, brightness, clip parts, thumbnail) and motion
  events. The front preview is mirrored in Dart (`mirror` flag); recordings
  aren't. The screen is kept awake.
- **CocoaPods:** `tflite_flutter` (for [recognition](recognition.md))
  ships through CocoaPods (`TensorFlowLiteC` 2.12), so the project has a
  `Podfile`, `Podfile.lock` and the Pods in its Xcode project;
  `flutter build ios` runs `pod install` (CocoaPods must be installed, as
  on GitHub's macOS runners). [Recognition](recognition.md) runs on iOS
  with it (frames from `keyframesAt` in Swift).
- `Info.plist` names the app "Presence" and locks it to portrait. Its
  permission texts say what the app does, as the App Store wants
  ([Store readiness](store-readiness.md)):
  - camera: while open, it records video continuously, keeping recent
    footage and saving clips, and shows the live feed;
  - microphone: while open, it records sound with the video and keeps it
    in clips;
  - location (when in use): it shows the device on a map and records it
    with each event.
- **iPhone only:** `TARGETED_DEVICE_FAMILY = 1` in every build
  configuration (Runner and RunnerTests inherit it), so there's no iPad
  build, iPad review or iPad screenshots, and no iPad orientations in
  `Info.plist`. It has only been run on an iPhone.
- **Export compliance:** `ITSAppUsesNonExemptEncryption` is `false`, so
  App Store Connect doesn't ask at each upload. The app's only
  cryptography is HTTPS (the system's) and standard AES-256-GCM for its
  own media ([Encryption](encryption.md)), both exempt (standard
  algorithms, used to protect the app's own data), so no export
  documentation is needed.
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
- **The Mac's team is a free Personal Team** (`LMX88986F3`), and Apple
  doesn't give free teams the Sign in with Apple capability: since
  `Runner.entitlements` asks for it, a phone build fails to sign ("Personal
  development teams ... do not support the Sign In with Apple
  capability"). Until Xcode has a paid Apple Developer Program team, a
  phone build removes the entitlement locally for the build (`PlistBuddy
  -c "Delete :com.apple.developer.applesignin"
  ios/Runner/Runner.entitlements`, restored after; never committed): the
  app runs and shows both sign-in buttons, but Apple's fails when
  tapped (2026-10-15, 0.6.202610150825 on the iPhone 12 mini).
- **App Store signing:** the Xcode project still names no team, and local
  builds keep Flutter's automatic development signing. The Release
  workflow's App Store build writes `Flutter/Signing.xcconfig` (included
  by `Release.xcconfig` when present: manual style, `APPLE_TEAM_ID`,
  `Apple Distribution`, the App Store profile) and builds an `.ipa` with
  `make ipa`; entitlements (`Runner.entitlements`: Sign in with Apple's)
  come from the project and must be in the profile. See [Store
  signing](release.md#app-store-ios).
- **Sign in with Apple:** `Runner/Runner.entitlements` holds
  `com.apple.developer.applesignin` = `[Default]`, set as the Runner
  target's `CODE_SIGN_ENTITLEMENTS` (Debug, Release, Profile). Device
  builds need the capability on the App ID `com.nu01.presence`; the
  simulator build doesn't check it. The `sign_in_with_apple` plugin
  (8.2.0) uses `ASAuthorizationAppleIDProvider`; see
  [Sign-in](sign-in.md#sign-in-with-apple-ios). Sessions are kept in the
  Keychain (`flutter_secure_storage` 11.1.1, readable after the first
  unlock, this device only).
