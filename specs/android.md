# Android

The web approach (overlapping `MediaRecorder`s) doesn't exist on Android, so
Android uses the standard dashcam technique instead
([android/app/src/main/kotlin/…](../presence_app/android/app/src/main/kotlin/com/nu01/presence)):

- **`RollingCamera`:** Camera2 feeds both the preview (a Flutter `Texture`)
  and a hardware **H.264** encoder, up to 1280×720, with a keyframe every
  second, at 1.5 Mbps (1 Mbps below 1280 wide), variable bitrate where the
  encoder offers it (a still scene then costs fewer bits).
  - **Frame rate is variable, up to 30 fps** (for example 5–30 on the S40).
    A fixed 30 fps caps exposure at 1/30 s, which made the S40's picture
    almost black indoors (average luma 17). With 5–30 fps and +1 EV it
    measured 68, about 4× brighter. The trade-off: in dim light, frames
    expose longer, so motion blurs and the frame rate drops. In good light
    it stays at 30 fps. Keyframes may then be further apart, so clip files
    can start a little earlier before their window (the window offsets
    still cut them exactly).
  - The default microphone (`AudioRecord`, read 100 ms at a time) feeds an
    **AAC** encoder at **16 kHz mono, 32 kbps** (under half the encoding
    work of 44.1 kHz); if the phone refuses 16 kHz, it falls back to
    44.1 kHz at 64 kbps. Audio and video share the camera's clock.
  - The **motion stream** (a small YUV `ImageReader`) is handled on the
    camera's own thread: every frame (~30/s) is released at once, and only
    about 5 a second are acquired as the latest and sampled to 64×48 luma.
  - The encoder threads wait up to 100 ms for output (it's handed over as
    soon as it's ready; the long timeout only means fewer idle wake-ups).
  - **Closing** returns at once: the camera, microphone and codecs are
    closed on the camera thread (after the encoder threads stop), and the
    returned future completes once the camera device has closed (or 3 s
    pass), so the main thread never blocks on it.
- **`SampleRing`:** the encoded samples are kept in an in-memory ring buffer,
  holding *before* + 1 s of history (up to 1 s more between keyframes),
  pruned a whole GOP at a time, when a video keyframe arrives.
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
  latest keyframe), decoded straight to thumbnail size where Android allows
  (8.1+, `getScaledFrameAtTime`), scaled to 480 px wide before it's turned
  upright, and saved as JPEG; the bitmaps are recycled at once.
- **Playback:** `video_player` (ExoPlayer), with the same before-then-full
  continuation and exact window end as web. Tap to pause and play.
- **One camera at a time:** Flip closes the open camera (waiting for
  Camera2's closed callback, with a 3 s timeout) before opening the next.
  This works on phones without concurrent-camera support, and was verified
  on the S40 (back camera 0 ↔ front camera 1).
- **Keeps capturing untouched, with the screen off:** the screen stays on
  while the app is shown (`FLAG_KEEP_SCREEN_ON`), but it may go off (the
  power button, a covering app); recording, motion clips and sync go on:
  - **`CaptureService`**, a foreground service (types `camera` and
    `microphone`, the latter only with the microphone allowed), with an
    ongoing low-importance notification, "Presence is capturing". Android
    lets only such an app use the camera with the screen off or covered
    (on the S40: "can't use the camera from an idle UID", e.g. under
    Google's sign-in chooser at launch). It may only start while the app is
    shown, so `MainActivity.onStart` starts it once the camera is allowed
    (and the permission grant and every camera opening start it too), with
    a plain `startService`: `startForegroundService` kills the app when the
    service isn't foreground within 10 s, which a debug build's busy launch
    missed. It stops when the activity is destroyed.
  - It holds a **partial wake lock** (`presence:capture`; the CPU keeps
    running) and a **Wi-Fi lock** (events keep syncing).
  - **The preview pauses while the app isn't shown** (`onStop`;
    `RollingCamera.setPreview` takes the preview out of the repeating
    request, and `onStart` puts it back): nothing draws it then, and its
    full buffers would stall the camera's other outputs, the recording too.
  - **Battery optimization:** at the first launch, the app asks once (per
    install) to be left out of it (`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`),
    so Doze doesn't cut its network or wake lock on battery. Plugged in,
    Doze doesn't apply.
  - **A camera taken away is reopened:** when a running camera is
    disconnected or fails, the `presence/motion` stream sends
    `{id, lost: reason}`; the source's `lost` completes, and `CameraRig`
    closes it and tries to reopen it every 10 s
    (`CameraRig.lostRetryDelay`) until it opens. A camera that failed to
    open is also reopened when the app returns to the foreground.
  - **A stuck camera is reopened too:** every 30 s the plugin checks each
    open camera's motion frames (about 5 a second); after 60 s without
    one, it reports the camera lost ("No camera frames for N s"), and it
    is reopened as above. A camera without the motion stream isn't checked.
  - **The app comes back when it isn't running** (`KeepAlive`):
    - a **watchdog** alarm (`WatchdogReceiver`, every 15 min, even in
      Doze) reopens the app's screen if it's gone: killed, crashed, or
      closed with Back;
    - after an uncaught **crash** (logged with its stack first), the
      watchdog reopens it 10 s later;
    - when Android restarts the **capture service** after killing the
      process (`START_STICKY`), the service reopens the app;
    - after the phone **boots** (`BootReceiver`, `RECEIVE_BOOT_COMPLETED`),
      or the app is **updated** (`MY_PACKAGE_REPLACED`; not after `flutter
      run` or `android-install.sh`, which force-stop it first, and a
      stopped app gets no broadcasts), the app opens.
    - The watchdog opens it in a fresh task (`NEW_TASK | CLEAR_TASK`), so
      a screen left on top of the app's old task can't keep it from
      starting.
    - Only a force stop (Settings > Apps) keeps it closed: it cancels the
      alarms until the app is opened again. Android 10 and later may refuse
      to open an app from the background (the S40 runs Android 9); the
      attempt is logged.
    - Verified on the S40: after `adb shell am crash`, the log file had the
      crash and its stack; Android restarted the capture service 4 s later,
      which reopened the app, and the camera was open again 18 s after the
      crash. The log files, the service, the wake lock and the watchdog
      alarm were all in place after a launch.
  - Verified on the S40 (plugged in): with the screen asleep for over a
    minute, the encoder and motion streams kept running (972 frames each,
    no disconnect) while the preview stream stopped, and the preview came
    back when the screen woke.
- **Audio timestamps** come from the sample count, anchored to the camera
  clock, and are strictly increasing: MP4 rejects audio that goes back in
  time even by a few ms. The muxer also skips any non-increasing sample
  instead of aborting the file.
- Slow work (encoders, microphone, opening the camera, thumbnails) runs off
  the main thread, and thumbnails have their own thread so they never delay
  a clip's before part.
- **Permissions:** camera and microphone are requested at launch. Without
  the microphone, recording is video-only. The screen is kept on while the
  app is shown. The manifest also has `FOREGROUND_SERVICE` (and its
  `_CAMERA` and `_MICROPHONE` types), `WAKE_LOCK` and
  `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, for capturing untouched.
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
  **LiteRT** through Google's `tflite_flutter` plugin (Dart FFI), all in
  one worker isolate, 2 CPU threads, the models mapped from files in
  `files/models/` (copied from the assets on first use).
- **`keyframesAt`** (`presence/cameras`): `{path, ms: [..], maxWidth}` →
  a list of `{ms, width, height, pixels}`: for each time, the **keyframe**
  nearest to it (found in the file's index with `MediaExtractor`, nothing
  decoded), each keyframe once, `ms` being its own time. Each is decoded
  alone (`OPTION_CLOSEST_SYNC`) by one `MediaMetadataRetriever` per call,
  straight to at most `maxWidth` (recognition asks 1280) px wide upright
  (`getScaledFrameAtTime`, Android 8.1+; scaled before turning on older
  ones), then turned upright, and returned as raw RGBA; frames that can't
  be read are left out. Bitmaps are recycled at once.
- **`encodeJpeg`** (`presence/cameras`): `{width, height, pixels}` (RGBA,
  checked to match) → a JPEG (quality 85), for the frame of a recognized
  tag or suggestion.
- **`frameAt`** (`presence/cameras`, for tags made by hand): the frame
  closest to a time (`OPTION_CLOSEST`), upright, at most `maxWidth` px
  wide, as a JPEG.
- **`memoryStatus`** (`presence/device`): `ActivityManager`'s
  `{lowMemory, availMem, threshold, totalMem, lowRamDevice}`; recognition
  waits while memory is tight.
- **`googleAccount`, `rememberGoogleAccount`, `forgetGoogleAccount`,
  `silentGoogleSignIn`** (`presence/device`, `GoogleSilentSignIn.kt`): the
  signed-in Google account's email, kept in the app's preferences, and
  its silent re-sign-in through Play services (`play-services-auth`,
  a direct dependency of the app), so a restart doesn't stop at Google's
  account chooser. See [Sign-in](sign-in.md).
- **Build:** `tflite_flutter` compiles its Java for JVM 11 but leaves its
  Kotlin on the toolchain default (21), which Kotlin rejects; the root
  `build.gradle.kts` pins that plugin's Kotlin to JVM 11.
- **Install on the unattended phone:** `devbox run android-release`, or
  [scripts/android-install.sh](../scripts/android-install.sh), builds a
  release APK with the `.env` settings and the version, installs it over
  the app (keeping its data; the version code stays the pubspec's, as
  `flutter run` builds it), starts it in a fresh task (`NEW_TASK |
  CLEAR_TASK`), and checks it runs. Release, because on the S40 it took
  173 MB against the debug build's 384 MB, and Dart runs compiled. A
  fresh task, because a screen left on top of the app's task (Google's
  account chooser) kept Android from starting the app at all: `flutter
  run`'s own start, after its install, only brought that screen back.
- **Run on a USB phone while developing:** `devbox run android` (debug,
  with hot reload), or
  [scripts/flutter-android.sh](../scripts/flutter-android.sh), finds `adb`
  (on the `PATH`, `ANDROID_HOME`, Flutter's configured SDK or Homebrew's
  `android-commandlinetools`), picks the one phone attached by USB
  (ignoring emulators and wireless devices; `ANDROID_SERIAL` picks among
  several), and runs `scripts/flutter-run.sh -d <serial>` with any extra
  arguments, so the `.env` settings and the version are passed as for the
  other run scripts. It stops with what to do when no phone is attached,
  several are, or the phone hasn't allowed this computer. Native builds
  default to the production API (`API_BASE_URL` overrides it), so the
  phone runs in OIDC mode, with Google sign-in. The phone lookup is
  [scripts/android-device.sh](../scripts/android-device.sh), shared with
  the log script.
- **Log files on the phone** (`FileLog`): every message the app logs,
  Dart's (`AppLog.persistToDevice`, through `presence/device` `log`) and
  the native side's (the app opened, shown or hidden, the capture service,
  cameras opened, failed, lost or stuck, the watchdog, crashes with their
  stack), also goes to `presence-YYYY-MM-DD.log` in
  `/sdcard/Android/data/com.nu01.presence/files/logs/`, which adb reads
  without root; the latest 7 days are kept. At each start the app also
  saves what logcat still holds of it (`logcat-before-<time>.txt`, the
  latest 5): the minutes before a crash or a kill. Native lines are logged
  with tag `Presence` too. Account emails in them are masked
  (`a***@example.com`, see [Sign-in](sign-in.md)); tokens are never
  logged.
- **Pull them:** `devbox run android-pull`, or `scripts/android-log.sh
  --pull [dir]`, copies those files to `android-logs/<time>/`
  (git-ignored), with `status.txt` (the phone's time and uptime, whether
  the app, its service and wake lock are up, the battery, and the system's
  crash, ANR and kill records) and `dropbox.txt` (those records in full).
- **Read the app's log live:** `devbox run android-log`, or
  [scripts/android-log.sh](../scripts/android-log.sh), raises the phone's
  log buffer to 16 MB (Android's 256 KB default holds only minutes of a
  busy phone's log), shows what the buffer holds and follows it, keeping
  only the app's lines (tag `flutter`: its `Presence: …` messages) and the
  system lines that explain them: Google sign-in (`Auth.Api.*`,
  `CredentialManager*`, `GoogleSignIn*`), crashes (`AndroidRuntime`,
  `FATAL`) and the app's process starting or being killed. `--clear`
  starts from now; `--all` shows every line of the app's process instead.
- **On-device test:** `integration_test/recognition_android_test.dart`
  (fixtures pushed with `integration_test/push_fixtures.sh`, which needs
  `ffmpeg` and `adb`); see [Subject recognition](recognition.md#verified).
  An emulator works: `sdkmanager "emulator"
  "system-images;android-35;google_apis;arm64-v8a"`, then `avdmanager
  create avd` and `emulator -avd <name> -no-window`.

## Known limitations

- Capturing untouched was verified for minutes, plugged in, on Android 9;
  not yet for hours, on battery (Doze), or on Android 13+, where the
  capture notification needs `POST_NOTIFICATIONS`, which the app doesn't
  ask for: without it the service still runs, with its notification only
  in the task manager.
- Between a kill and the watchdog's next check, up to 15 min go
  unrecorded (a crash reopens it in 10 s). A native crash (in a codec or
  a model) skips the crash handler: the watchdog reopens the app, and the
  next start's saved logcat shows what logcat kept of it.

- The Android app is locked to portrait (`screenOrientation="portrait"`):
  the preview, the recording's rotation flag and thumbnails all assume a
  portrait phone. Landscape support would need all three to follow the
  device rotation.
- **Verified on a DOOGEE S40 (Android 9, MT6739):**
  - The camera opens, and the hardware H.264 encoder runs at ~30 fps.
  - Clips are written as a before part (15.7 s) and a full clip (30.1 s),
    each 1280×720 H.264 with AAC audio, with real sound (verified at
    44.1 kHz and 2.5 Mbps; the 16 kHz audio and 1.5 Mbps VBR video of
    2026-10-05 are not yet verified on the phone).
  - The full clip is saved, the before-only file is deleted, the thumbnail
    is an upright 480×853 JPEG, and clips and events survive relaunches.
  - Playback starts with audio.
  - Not yet verified: the preview and recordings showing an actual scene.
    The camera saw only black during testing (average luma 16), most likely
    because the phone was lying on its back.
