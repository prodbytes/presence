# Presence — software specification

The current specification of the product. Update it whenever a request changes
what the software does or how it is built. [requests.md](requests.md) holds the
history of requests that shaped it.

## Product

Presence is a surveillance app. It shows live camera feeds and a stream of
events detected from them. The cameras are always recording, video and
audio, so a clip can include the moments before someone pressed Clip.

## User interface

The app is a Flutter app ([presence_app/](../presence_app)). The main screen
has two panels:

| Panel | Position | Contents |
|-------|----------|----------|
| Cameras | Left, takes all remaining width | Titled with the app name. Live feeds from every camera on the device, in a grid. |
| Events | Right, always 360 px wide | Timeline of events, newest first. |

- The layout is the same at every window size: the Events panel never
  resizes, and the Cameras panel fills the rest. There is no stacked
  narrow-screen layout, so on phone-sized screens the Cameras panel gets very
  little width.
- Header buttons are tonal filled icon buttons, 8 px apart.
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

### Cameras panel

- The panel title is the app name, **Presence**, in the accent color. It links
  to https://presence.nu01.com and opens in a new tab. On web it's a real link,
  so middle-click and "open in new tab" work.
- The header has a **Clip** button (camera icon) at its top right. It's
  disabled until at least one camera is open. See [Clips](#clips).
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

### Events panel

- The header has two icon buttons at its top right, in this order:
  - **Settings** (gear icon) opens the [Settings pane](#settings-pane).
  - **Login** (person icon) is a placeholder for now. It shows a tooltip but
    takes no action.
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

1. For each camera, the app publishes a **`ClipRequested`** event on the bus.
   Its card shows the camera's current frame as a thumbnail, the camera name,
   the time, and a status line.
2. The **previous 15 s** (the "before" part) are saved almost at once and are
   playable immediately. Status: "Previous 15 s ready · recording next 15 s…".
3. Once the **next 15 s** (the "after" part) have been recorded, the whole
   clip is saved as one continuous 30 s recording. Status: "30 s clip ready".
4. Tapping a playable card opens the player. It plays the before part first,
   then continues into the full clip at the moment of the press, so a clip
   always plays **before + after = 30 s** by default. If the after part isn't
   recorded yet when the before part ends, the player waits ("Recording the
   next 15 s…") and continues as soon as it's ready. Seeking is kept inside
   the clip window, and replaying after the end starts from the beginning.
5. **Playback has audio.** The player is never muted. If the browser blocks
   autoplay with sound, the player stays paused on its controls, and one tap
   on play starts it with audio.

The before and after lengths are configurable in the Settings pane.

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

### Settings pane

- Opened by the **Settings** button, hidden to start with. It's an end drawer
  that slides in from the right and has a close button.
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
| `events` | `id`, with an index on `time` | type, title, detail, time, camera ID, and for clips the clip ID |
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
   deleted in the same transaction (the full clip contains it). State
   becomes `complete`.
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
- Links open through the `url_launcher` package.
- Cameras are platform-specific, behind the `CameraSource` interface
  ([lib/cameras/](../presence_app/lib/cameras)):
  - **Web** uses browser APIs directly through `package:web`: one
    `getUserMedia` stream per camera (plus the microphone), a `<video>`
    element for the preview, canvas snapshots for thumbnails, and
    `MediaRecorder` for the rolling recordings and clips.
  - **Android/iOS** use the official `camera` plugin, for previews and
    thumbnails only: the plugin can't keep a rolling recording, so clip cards
    there say video clips aren't supported.
  - macOS and Linux desktop have no camera implementation.
- The Android, iOS, Linux and macOS scaffolding from `flutter create` is kept.
- iOS: `Info.plist` declares `NSCameraUsageDescription`, which the camera
  plugin needs. There's no microphone key yet, because the native side
  doesn't record; it will need `NSMicrophoneUsageDescription` once it does.
  Running on a physical iPhone requires full Xcode, a connected or paired
  iPhone with Developer Mode on, and a signing team. The bundle ID is still
  the placeholder `com.example.presenceApp`.

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
- On Android/iOS, storage is in memory only (a fresh database each launch),
  since clips aren't recorded there yet.
- Persistence has been verified with unit and widget tests against an
  in-memory IndexedDB, but not yet in a real browser.
- The browser's native video controls show the whole recording file, which
  can be longer than the clip window. Playback is still kept to the window.
- Audio recording has been verified in unit tests and code review only. The
  in-browser run that checked recording and playback timing ran before audio
  was added.
