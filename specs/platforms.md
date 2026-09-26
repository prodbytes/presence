# Platforms

- Web is the primary development target. `devbox services up` (or
  `devbox run web` on its own) serves it at http://localhost:8080. The port can
  be changed with `FLUTTER_WEB_PORT`.
- Cameras are platform-specific, behind the `CameraSource` interface
  ([lib/cameras/](../presence_app/lib/cameras)):
  - **Web** uses browser APIs directly through `package:web`: one
    `getUserMedia` stream per camera (plus the microphone), a `<video>`
    element for the preview, canvas snapshots for thumbnails, and
    `MediaRecorder` for the rolling recordings and clips.
  - **Android** uses a native Kotlin camera layer (`PresenceCamerasPlugin`,
    on the `presence/cameras` method channel; see [Android](android.md)).
  - **iOS** uses a native Swift camera layer with the **same channel API**
    (`presence/cameras` + `presence/motion`), so the Dart side is shared
    with Android. See [iOS](ios.md).
  - macOS and Linux have no camera implementation.

**Feature parity:**

| Feature | Web | Android | iOS |
|---|---|---|---|
| Full-screen default camera, flip | ✅ | ✅ | ✅ |
| Always-on recording (rolling history) | `MediaRecorder` pool | Camera2 + H.264/AAC ring | AVFoundation + H.264 ring |
| Clip: before part immediately, full clip later | ✅ | ✅ | ✅ |
| Audio in clips | ✅ Opus | ✅ AAC | ✅ AAC |
| Thumbnail at press | canvas | `MediaMetadataRetriever` | Core Image |
| Motion clips (threshold, cooldown, live meter) | canvas sampling | YUV `ImageReader` | BGRA frame sampling |
| Brightness (EV) | where the browser supports it | ✅ | ✅ |
| Low light: variable frame rate | 10–30 fps (a hint to the browser) | 5–30 fps | 10–30 fps |
| Persistent events, clips, settings | IndexedDB | sembast + MP4 files | sembast + MP4 files |
| Portrait lock | — | ✅ | ✅ (iPhone) |
| Verified on a device | Chrome (fake camera): recording, clips, audio playback timing, motion clip end to end | DOOGEE S40 | build + simulator only (see below) |

The only remaining differences are platform limits, not missing features:
- Web brightness depends on the browser supporting `exposureCompensation`
  for that camera.
- A web page can't lock the screen orientation.
- iOS hasn't been run on a physical device yet.
- The Android, iOS, Linux and macOS scaffolding from `flutter create` is kept.
- iOS: `Info.plist` declares `NSCameraUsageDescription` and
  `NSMicrophoneUsageDescription`.
  The app builds and runs on the **iOS simulator** (verified on an iPhone 18
  Pro, iOS 27.0): the UI, theme and tabs render, and the camera screen shows
  "Could not open the camera" with a `MissingPluginException` for
  `presence/cameras`, because that channel is implemented on Android only.
  Running on a physical iPhone additionally needs a connected or paired
  iPhone with Developer Mode on, and a signing team (none is set up yet).
