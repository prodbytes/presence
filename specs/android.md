# Android

The web approach (overlapping `MediaRecorder`s) doesn't exist on Android, so
Android uses the standard dashcam technique instead
([android/app/src/main/kotlin/…](../presence_app/android/app/src/main/kotlin/com/example/presence_app)):

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
