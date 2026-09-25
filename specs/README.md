# Presence — software specification

The current specification of the product. Update it whenever a request changes
what the software does or how it is built. [requests.md](requests.md) holds the
history of requests that shaped it.

## Product

Presence is a surveillance app. It shows live camera feeds and a stream of
events detected from them. The cameras are always recording, video and
audio, so a clip can include the moments before someone pressed Clip.

## User interface

The app is a Flutter app ([presence_app/](../presence_app)). The same UI
runs on Android and web. It follows Material 3 top-level navigation: **tabs
in the app bar**, which flip between full screens.

- **App bar:** the title **Presence** (accent color, plain text) on the left.
  In the top right are three icon tabs, in order **Camera**, **Events** and
  **Settings**, then a **Login** icon button.
  - Tabs have tooltips and semantic labels, and a 48 dp touch target each.
    An indicator marks the selected tab.
  - **Login** is shown but **disabled** ("Login (coming soon)"). It isn't a
    tab, because Material advises against destinations that go nowhere.
- **Flipping:** tapping a tab or swiping sideways moves between screens
  (`TabBar` + `TabBarView`). The Camera screen is kept alive while other tabs
  are shown, so its live video isn't torn down.
- **Camera** (the start tab): the camera feeds fill the **whole screen**,
  edge to edge and under the app bar, which is transparent over the camera,
  with a dark gradient scrim to keep the title and tabs readable.
  - Several cameras share the screen in a grid with hairline gaps.
  - The **Clip** trigger is an extended floating action button (bottom
    right), shown only on the Camera tab and only when a camera is open.
    Material says to hide a FAB that can't act, rather than disable it.
  - After a clip, a snackbar says "Clip requested", with a **View** action
    that jumps to Events.
- **Events:** the event stream, full screen. On wide screens it's centered
  at a readable width (max 560 px), so clip thumbnails don't stretch across
  the desktop.
- **Settings:** the clip settings as a normal screen (no longer a drawer),
  same 560 px readable width.
- The title no longer links to presence.nu01.com. On a full-screen camera,
  an accidental tap would open a browser. `url_launcher` was removed.
- The Flutter demo UI was removed entirely.

### Theme

The colors follow **Gruvbox dark, soft contrast**, defined in
[lib/theme.dart](../presence_app/lib/theme.dart):

| Role | Gruvbox color | Hex |
|------|---------------|-----|
| Page background | bg0_s | `#32302f` |
| Panels | bg1 | `#3c3836` |
| Event cards, header buttons, dividers | bg2 | `#504945` |
| Camera tile background | bg0_h | `#1d2021` |
| Text | fg | `#ebdbb2` |
| Secondary text | fg4 | `#a89984` |
| Primary accent (app title, event icons, spinners) | yellow | `#fabd2f` |
| Secondary accent | aqua | `#8ec07c` |
| Errors | red | `#fb4934` |

The web manifest's `theme_color` and `background_color` are also `#32302f`.

### Camera screen

- The **Clip** floating action button starts a clip. See [Clips](#clips).
- On load, the app opens every camera available to the device and shows each
  one as a live tile. On web, the browser asks for camera and microphone
  permission first, in a single prompt. The app owns the open cameras
  (`CameraRig`), so they stay open, and keep recording, across rebuilds.
- The grid has ceil(√n) columns, and the tiles fill the panel.
- Each tile shows the camera's label at the bottom left, or "Camera" if the
  browser hides device labels.
- **Audio is captured.** Cameras rarely have their own microphone, so every
  camera records the default microphone, each with its own copy of the
  track. If microphone access is denied, recording continues video-only.
- Live previews are muted, so the microphone doesn't feed back.
- States:
  - **Loading:** a spinner while cameras are discovered or opened.
  - **No cameras:** "No camera feeds", with a Retry button.
  - **Access error:** for example, permission denied. Shows the error and a
    Retry button.
  - **Per-tile error:** if one camera fails to open (for example, it's in use),
    only that tile shows the error.

### Events screen

- Events appear in a vertically scrolling timeline, newest at the top. Each
  entry is just a card, with no dot or rail beside it, and cards are 8 px
  apart.
- Each event card shows an icon, a title, an optional detail line and the time
  (HH:mm:ss). Event types can supply their own card (`AppEvent.buildCard`);
  `ClipRequested` does.
- When a new event arrives, the timeline scrolls back to the top to show it.
- On launch, the app pushes an **Application started** event.
- With no events, the panel shows a "No events" empty state.
- Events flow through an app-wide **event bus**: a plain Dart broadcast
  `StreamController` (`AppEventBus` in
  [lib/events.dart](../presence_app/lib/events.dart)). Any widget can publish
  with `AppEventBusScope.of(context).publish(event)`, and any number of
  listeners can subscribe to `bus.stream`.
- The bus keeps no history. `EventLog` subscribes to it at startup and holds
  the history the timeline shows. The app owns both, above `MaterialApp`, so
  every screen and route can reach the bus. The startup event is published
  only after `EventLog` subscribes; otherwise it would be dropped.

### Clips

Pressing **Clip** records a clip from **every** open camera at once:

1. For each camera, the app publishes a **`ClipRequested`** event on the bus
   once that camera's **previous 15 s** (the "before" part) are recorded,
   normally within milliseconds. So the event is **playable the moment it
   appears**. Its card shows the camera's current frame as a thumbnail, the
   camera name, the time, and a status line: "Previous 15 s ready ·
   recording next 15 s…".
   - Cameras publish independently: a slow camera doesn't hold up the
     others.
   - If a camera's before part takes longer than 2 s (`CameraRig.pastWait`),
     its event is published anyway ("Saving previous 15 s…") and becomes
     playable when the before part arrives.
2. Once the **next 15 s** (the "after" part) have been recorded, **the same
   event is updated with the full clip**, one continuous 30 s recording. No
   new event is added. The card updates in place ("30 s clip ready"), and the
   stored event record changes from `clipState: partial` to
   `clipState: complete`.
3. Tapping a playable card opens the player. It plays the before part first,
   then continues into the full clip at the moment of the press, so a clip
   always plays **before + after = 30 s** by default. If the after part isn't
   recorded yet when the before part ends, the player waits ("Recording the
   next 15 s…") and continues as soon as it's ready. Seeking is kept inside
   the clip window, and replaying after the end starts from the beginning.
4. **Playback has audio.** The player is never muted. If the browser blocks
   autoplay with sound, the player stays paused on its controls, and one tap
   on play starts it with audio.

The before and after lengths are configurable on the Settings screen.

**How "always recording" works (web).** Browser recordings (`MediaRecorder`)
can't be trimmed or joined, so each camera runs a rolling pool of overlapping
recorders (`RecorderPool` in
[lib/cameras/recorder_pool.dart](../presence_app/lib/cameras/recorder_pool.dart)):

- A new recorder starts every *before* ÷ 2 seconds, and each is discarded
  after 2 × *before*. That's about 4 recorders per camera, and at least two of
  them always hold more than *before* seconds of history.
- On Clip, one of those is stopped at once to produce the before part, and
  another is held until the after part ends to produce the full clip. A timer
  releases it at exactly +*after*.
- Clips are cut to their exact window by seeking, using each recorder's start
  time. Verified in Chrome: the before part starts exactly *before* seconds
  before the press, the player continues into the full clip at the press
  point without a gap, and playback stops exactly at the end of the window.
- Presses close together share the held recorder.
- A clip requested before enough history exists (just after startup, or right
  after raising *before*) starts at the oldest recording instead.
- Recording format: WebM with Opus audio (`vp8,opus` preferred, as VP8 is
  cheapest to encode, then `vp9,opus`). Without a microphone: VP8, VP9,
  generic WebM, then MP4.
- Clips (thumbnails and recordings) are saved to local storage and survive a
  page refresh. See [Storage](#storage).

### Settings screen

- The **Settings** tab.
- **Clips** section, with two sliders from 5 s to 60 s in 5 s steps:
  - **Before the press**, default 15 s. This also sets how much history the
    cameras keep recording.
  - **After the press**, default 15 s.
- It shows the total clip length, and notes that a new "before" value takes
  up to that long to apply fully.
- Settings (`ClipSettings`) are saved to local storage and restored on
  launch.

## Storage

All app data is saved in the browser's **IndexedDB**, so it survives a page
refresh. It's accessed through [`idb_shim`](https://pub.dev/packages/idb_shim)
(`EventStore` in
[lib/storage/event_store.dart](../presence_app/lib/storage/event_store.dart),
with the mapping in
[lib/storage/persistence.dart](../presence_app/lib/storage/persistence.dart)).

On **web**, all app data is in IndexedDB, as described below. On
**Android**, the same stores live in a sembast database on disk, and
recordings are files instead of `media` rows (see [Android](#android)).
Everything goes through `EventStore` and `MediaStore`.

**Why IndexedDB (not drift/SQLite or `localStorage`):**
- `localStorage` holds only ~5 MB of strings. One 30 s clip is ~10 MB per
  camera.
- IndexedDB stores binary recordings directly, and can save a clip's record
  and delete its media in one transaction.
- It needs no code generation, WASM or special server headers.
- drift remains the upgrade path if SQL queries or mobile clip storage are
  needed; everything goes through `EventStore`, so it can be swapped out.

**Database `presence`, version 1:**

| Store | Key | Holds |
|-------|-----|-------|
| `cameras` | `id` (the browser's device ID) | label, last seen |
| `events` | `id`, with an index on `time` | type, title, detail, time, camera ID, and for clips the clip ID and `clipState` (`partial` / `complete`) |
| `clips` | `id`, with an index on `eventId` | event ID, camera ID and label, before/after lengths, state, thumbnail (JPEG bytes), and a media reference for the before part or the full clip (media ID, window start/end, format) |
| `media` | media ID (`<clipId>-past` or `<clipId>-full`) | recording bytes |
| `settings` | name (`clip`) | before/after lengths |

**References:** each event has a stable `id`, and events from a camera carry
its `cameraId`. A `ClipRequested` event references its clip (`clipId`). The
clip references its event (`eventId`), its camera (`cameraId`) and its media.
Camera IDs are the browser's device IDs, which stay stable for the site until
its data is cleared.

**How a clip is saved:**
1. When Clip is pressed, the event and a clip record (state `recording`,
   with the thumbnail) are saved.
2. The before part is saved as soon as it exists, so it survives a refresh
   during the after part.
3. When the full clip exists, it's saved, and the before-only file is
   deleted in the same transaction (the full clip contains it). The clip's
   state becomes `complete`, and the event record is updated to
   `clipState: complete`.
4. If saving fails (for example, storage is full), the clip card says "not
   saved" with the reason. The clip still plays for the rest of the session.

**On launch**, events are restored newest first, below the new launch's
"Application started" event. Stored clips are playable. Their recordings load
from IndexedDB the first time they're played, not all at startup. A clip
whose after part was cut short by a refresh keeps its before part and says
so. Clip settings are restored too.

**Persistence and quota:** the app asks the browser for persistent storage
(`navigator.storage.persist()`), so saved clips aren't evicted when disk space
runs low. Browsers may grant or decline this silently. Everything is kept;
there's no retention limit yet.

## Platforms

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
    on the `presence/cameras` method channel; see [Android](#android)).
    It has the same always-on recording, clips, audio and playback as web.
  - iOS, macOS and Linux have no camera implementation yet.
- The Android, iOS, Linux and macOS scaffolding from `flutter create` is kept.
- iOS: `Info.plist` declares `NSCameraUsageDescription`, which the camera
  plugin needs. There's no microphone key yet, because the native side
  doesn't record; it will need `NSMicrophoneUsageDescription` once it does.
  Running on a physical iPhone requires full Xcode, a connected or paired
  iPhone with Developer Mode on, and a signing team. The bundle ID is still
  the placeholder `com.example.presenceApp`.

### Android

The web approach (overlapping `MediaRecorder`s) doesn't exist on Android, so
Android uses the standard dashcam technique instead
([android/app/src/main/kotlin/…](../presence_app/android/app/src/main/kotlin/com/example/presence_app)):

- **`RollingCamera`:** Camera2 feeds both the preview (a Flutter `Texture`)
  and a hardware **H.264** encoder, 30 fps, up to 1280×720, with a keyframe
  every second. The default microphone (`AudioRecord`) feeds an **AAC**
  encoder. Audio and video share the camera's clock.
- **`SampleRing`:** the encoded samples are kept in an in-memory ring buffer,
  holding *before* + 1 s of history, pruned a whole GOP at a time.
- **On Clip:** the before part is muxed from the ring into an MP4 at once
  (`MediaMuxer`). The full clip is muxed once the after period has been
  buffered. Files start at the keyframe at or before the window, and the
  window offsets are returned, the same "file + window" model as web.
  Clips in progress pin their samples, so they can't be pruned.
- **Thumbnail:** the latest frame, taken from the ring with
  `MediaMetadataRetriever` (just before the last frame, falling back to the
  latest keyframe), turned upright and saved as JPEG.
- **Playback:** `video_player` (ExoPlayer), with the same before-then-full
  continuation and exact window end as web. Tap to pause and play.
- **Several cameras:** phones that can't run cameras concurrently (all
  before Android 11, and most after) open the first back camera. The others
  are listed in a compact line under the live feeds, with the reason. They
  get grid tiles only when no camera is live.
- **Screen off / background:** Android refuses to open cameras while the
  screen is off or the app is in the background. Failed cameras are reopened
  automatically when the app returns to the foreground (permanent limits,
  like the one above, aren't retried).
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

## Development environment

- [devbox.json](../devbox.json) manages the toolchain: GraalVM CE (musl),
  Python, Node.js, Go, PostgreSQL and Flutter.
- The dev container ([.devcontainer/](../.devcontainer)) installs devbox and
  includes the Dart and Flutter VS Code extensions. It forwards port 8080 for
  Flutter web.
- Flutter web runs on the `web-server` device, so the container doesn't need
  Chrome.
- `devbox services up` ([process-compose.yaml](../process-compose.yaml)) starts
  PostgreSQL, the Flutter web server (`2-flutter-web`, via
  [scripts/flutter-web.sh](../scripts/flutter-web.sh), with an HTTP readiness
  probe) and the health monitor, which logs the status of both the database
  and the web app.
- The app requires Dart SDK `^3.13.0`, which covers the Nix Flutter 3.47.0
  (Dart 3.13.0).
- **Android builds on macOS:** Homebrew's `android-commandlinetools` cask
  (SDK at `/opt/homebrew/share/android-commandlinetools`, with
  platform-tools, platform 36 and build-tools 36), and JDK 21
  (`openjdk@21`), configured with `flutter config --android-sdk` and
  `--jdk-dir`. Gradle fetches the NDK and extra platforms on the first
  build. The dev container doesn't include the Android SDK.

## Workflow

- Every change goes on its own branch, with its own pull request. Nothing is
  pushed directly to `main`. See [CLAUDE.md](../CLAUDE.md).
- Every request updates this spec and the [request log](requests.md) in the
  same PR.

## Known limitations

- `graalvmPackages.graalvm-ce-musl` is Linux-only, so `devbox install` fails on
  macOS hosts. Use the dev container, or a locally installed Flutter SDK.
- The Nix Flutter package has no `x86_64-darwin` (Intel Mac) build.
- Always-on recording runs about 4 video encoders per camera, which uses
  noticeable CPU with several cameras.
- Nothing is deleted automatically: storage grows by roughly 10 MB per
  camera per clip until a retention policy is added.
- Android opens only one camera on phones without concurrent-camera
  support.
- Android preview orientation assumes the phone is held in its natural
  (portrait) orientation.
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
- Persistence has been verified with unit and widget tests against an
  in-memory IndexedDB, but not yet in a real browser.
- The browser's native video controls show the whole recording file, which
  can be longer than the clip window. Playback is still kept to the window.
- Audio recording has been verified in unit tests and code review only. The
  in-browser run that checked recording and playback timing ran before audio
  was added.
