# Android

The web approach (overlapping `MediaRecorder`s) doesn't exist on Android, so
Android uses the standard dashcam technique instead
([android/app/src/main/kotlin/…](../presence_app/android/app/src/main/kotlin/com/nu01/presence)):

- **`RollingCamera`:** Camera2 feeds both the preview (a Flutter `Texture`)
  and a hardware **H.264** encoder, up to 1280×720, with a keyframe every
  second.
  - **Frame rate is variable, up to 30 fps** (for example 5–30 on the S40).
    A fixed 30 fps caps exposure at 1/30 s, which made the S40's picture
    almost black indoors (average luma 17). With 5–30 fps and +1 EV it
    measured 68, about 4× brighter. The trade-off: in dim light, frames
    expose longer, so motion blurs and the frame rate drops. In good light
    it stays at 30 fps. Keyframes may then be further apart, so clip files
    can start a little earlier before their window (the window offsets
    still cut them exactly). The default microphone (`AudioRecord`) feeds an **AAC**
  encoder. Audio and video share the camera's clock.
- **`SampleRing`:** the encoded samples are kept in an in-memory ring buffer,
  holding *before* + 1 s of history, pruned a whole GOP at a time.
- **On Clip:** the before part is muxed from the ring into an MP4 at once
  (`MediaMuxer`). The full clip is muxed once the after period has been
  buffered. Files start at the keyframe at or before the window, and the
  window offsets are returned, the same "file + window" model as web.
  Clips in progress pin their samples, so they can't be pruned.
- **Orientation:**
  - **Preview:** Camera2 sets a transform on the preview `SurfaceTexture`
    that turns the image upright for the phone's natural orientation, and
    Flutter's `Texture` applies it. So the preview isn't rotated again; only
    its aspect ratio is swapped (sensor buffers are landscape). Front-camera
    previews are mirrored, like a selfie view.
  - **Recordings** don't get that transform. They're stored in sensor
    orientation, with an MP4 rotation flag (sensor orientation: back 90°,
    front 270° on the S40), and play upright and unmirrored.
  - Verified on the S40 for both cameras: the preview matches a recorded
    frame of the same scene. Before the fix, the preview was rotated 90°
    because of a double rotation.
- **Thumbnail:** the latest frame, taken from the ring with
  `MediaMetadataRetriever` (just before the last frame, falling back to the
  latest keyframe), turned upright and saved as JPEG.
- **Playback:** `video_player` (ExoPlayer), with the same before-then-full
  continuation and exact window end as web. Tap to pause and play.
- **One camera at a time:** Flip closes the open camera (waiting for
  Camera2's closed callback, with a 3 s timeout) before opening the next.
  This works on phones without concurrent-camera support, and was verified
  on the S40 (back camera 0 ↔ front camera 1).
- **Screen off / background:** Android refuses to open cameras while the
  screen is off or the app is in the background. A camera that failed to
  open is reopened automatically when the app returns to the foreground.
- **Audio timestamps** come from the sample count, anchored to the camera
  clock, and are strictly increasing: MP4 rejects audio that goes back in
  time even by a few ms. The muxer also skips any non-increasing sample
  instead of aborting the file.
- Slow work (encoders, microphone, opening the camera, thumbnails) runs off
  the main thread, and thumbnails have their own thread so they never delay
  a clip's before part.
- **Permissions:** camera and microphone are requested at launch. Without
  the microphone, recording is video-only. The screen is kept on.
- **Storage:** metadata goes in a persistent sembast database (via
  `idb_shim`) in the app's private storage. Recordings are MP4 files in the
  app's private `clips/` folder, not database rows, because sembast keeps
  its whole database in memory. If private storage is unavailable, data is
  kept in memory for the session.
- **App Links:** the manifest's `autoVerify` intent filter takes
  `https://presence.nu01.com/app…` and `https://rc.presence.nu01.com/app…`
  links (the [Add a device](add-device.md) links) to `app_links`, with
  Flutter's own deep linking off (`flutter_deeplinking_enabled`). Without
  the site's `assetlinks.json`, Android doesn't open them in the app by
  itself yet.

## Subject recognition

- [Recognition](recognition.md) runs the bundled `.tflite` models with
  **LiteRT** through Google's `tflite_flutter` plugin (Dart FFI, a
  background isolate per model).
- **`framesAt`** (`presence/cameras`): `{path, ms: [..], maxWidth}` →
  a JPEG per time (null where a frame can't be read), from one
  `MediaMetadataRetriever` per call, each frame upright and scaled as
  `frameAt`'s; bitmaps are recycled as soon as they're encoded. `frameAt`
  is now `framesAt` with one time.
- **Build:** `tflite_flutter` compiles its Java for JVM 11 but leaves its
  Kotlin on the toolchain default (21), which Kotlin rejects; the root
  `build.gradle.kts` pins that plugin's Kotlin to JVM 11.
- **Run on a USB phone:** `devbox run android`, or
  [scripts/flutter-android.sh](../scripts/flutter-android.sh), finds `adb`
  (on the `PATH`, `ANDROID_HOME`, Flutter's configured SDK or Homebrew's
  `android-commandlinetools`), picks the one phone attached by USB
  (ignoring emulators and wireless devices; `ANDROID_SERIAL` picks among
  several), and runs `scripts/flutter-run.sh -d <serial>` with any extra
  arguments, so the `.env` settings and the version are passed as for the
  other run scripts. It stops with what to do when no phone is attached,
  several are, or the phone hasn't allowed this computer. Native builds
  default to the production API (`API_BASE_URL` overrides it), so the
  phone runs in OIDC mode, with Google sign-in.
- **On-device test:** `integration_test/recognition_android_test.dart`
  (fixtures pushed with `integration_test/push_fixtures.sh`, which needs
  `ffmpeg` and `adb`); see [Subject recognition](recognition.md#verified).
  An emulator works: `sdkmanager "emulator"
  "system-images;android-35;google_apis;arm64-v8a"`, then `avdmanager
  create avd` and `emulator -avd <name> -no-window`.

## Known limitations

- The Android app is locked to portrait (`screenOrientation="portrait"`):
  the preview, the recording's rotation flag and thumbnails all assume a
  portrait phone. Landscape support would need all three to follow the
  device rotation.
- **Verified on a DOOGEE S40 (Android 9, MT6739):**
  - The camera opens, and the hardware H.264 encoder runs at ~30 fps.
  - Clips are written as a before part (15.7 s) and a full clip (30.1 s),
    each 1280×720 H.264 with AAC audio at 44.1 kHz, with real sound.
  - The full clip is saved, the before-only file is deleted, the thumbnail
    is an upright 480×853 JPEG, and clips and events survive relaunches.
  - Playback starts with audio.
  - Not yet verified: the preview and recordings showing an actual scene.
    The camera saw only black during testing (average luma 16), most likely
    because the phone was lying on its back.
