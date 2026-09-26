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
  - **Account** (the last icon; your Google avatar when signed in) is an
    action, not a tab. It opens the [account sheet](#sign-in).
- **Flipping:** tapping a tab or swiping sideways moves between screens
  (`TabBar` + `TabBarView`). The Camera screen is kept alive while other tabs
  are shown, so its live video isn't torn down.
- **Camera** (the start tab): **one camera at a time** fills the **whole
  screen**, edge to edge and under the app bar, which is transparent over
  the camera, with a dark gradient scrim to keep the title and tabs
  readable. There are **no overlays** on the video: no camera name, and no
  list of other cameras.
  - It opens the **default camera**: the first back camera, or else the
    first camera (on web, the one the browser picks by default).
  - The **Clip** trigger is an extended floating action button (bottom
    right), shown only on the Camera tab and only when a camera is open.
    Material says to hide a FAB that can't act, rather than disable it.
  - **Flip camera** (the camera-switch icon) sits just left of Clip, as a
    quieter secondary button. It's shown only when the device has more than
    one camera. It switches back ↔ front where the camera's facing is known
    (skipping extra back lenses), and otherwise goes to the next camera.
    The old camera is fully closed before the next one opens, because most
    phones allow only one open camera. The new camera starts its rolling
    recording from scratch, so a clip right after a flip has less "before"
    history.
  - **Readiness indicator:** the last item on the right of the button row
    (Flip, Clip, then readiness). It shows whether a clip taken now would be
    complete:
    - **"Ready"** (green dot): shown as soon as a camera is open, including
      right after a page reload or a flip. Only **automatic (motion)
      clips** start a countdown. A **Clip button press doesn't**: the pill
      stays Ready while its *after* part records, and the snackbar says it's
      saving. A clip in the first seconds after opening simply has less
      *before* history.
    - **"4:59"** after a **motion** clip: the **motion cooldown** countdown
      (5 minutes by default), starting when motion grabs the clip. The dot
      is red while that clip's *after* part is still saving, then amber.
      Motion can take another clip **only once this reaches zero**: the
      countdown and the trigger use the same end time
      (`CameraRig.motionCooldownEnds`). Below a minute it shows "45 s". A Clip
      press during the cooldown leaves the countdown as it is; the Clip
      button is never blocked. With motion clips turned off there's no
      cooldown.

    The countdown shows only the number.
    That keeps Flip, Clip and the pill on one row on a 320 dp phone. The
    pill refreshes twice a second, and its tooltip and screen-reader label
    spell the state out ("Motion can clip again in 4:28").
    - **The motion cooldown survives restarts and page reloads.** On
      launch, it's restored from the last motion clip in the stored events,
      so the countdown continues exactly where it was, and motion doesn't
      re-fire early just because the app restarted. Verified in Chrome: a
      reload 6 s after "4:28" showed "4:22", matching the stored event
      time.
  - **When any clip starts** (the Clip button or motion), a brief snackbar
    (4 s) says "Clip started · saving the next 15 s" or "Motion detected ·
    saving the next 15 s", with a **View** action that jumps to Events. It's
    set not to persist (Flutter otherwise keeps snackbars with actions until
    dismissed). For motion clips, the indicator carries the cooldown after it.
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
- On load, the app lists the device's cameras and opens the default one. On web, the browser asks for camera and microphone
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

### Motion clips

When enough of the picture moves, the app takes a clip automatically, the
**same way as pressing Clip**: same camera, before and after windows,
immediate before part, full clip update and storage. Its event card says
**"Motion detected"** (with a running-figure icon) instead of "Clip
requested", and its stored event has `trigger: "motion"`.

- **Measuring motion** (`MotionDetector`,
  [lib/motion.dart](../presence_app/lib/motion.dart), shared by all
  platforms):
  - Cameras supply 64×48 grayscale frames, about 5 per second.
  - The score is the **percentage of pixels whose brightness changed by
    more than 24/255** since the previous frame.
  - Overall brightness shifts (auto-exposure, a light switching on) are
    removed first, by subtracting the **median** per-pixel change. A moving
    object covering less than half the picture doesn't shift the median,
    unlike a mean.
  - The first 3 s after a camera opens or flips are ignored while exposure
    settles.
- **Triggering:** the score must be at or above the threshold for **3
  consecutive frames** (0.6 s). A one-frame glitch changes only two frames
  (appearing, then disappearing), so it doesn't count.
- **Cooldown:** at most **one automatic clip per 5 minutes** (configurable),
  counted from the moment motion grabs a clip. The readiness indicator
  shows it as a countdown, and motion retriggers only once it reaches zero.
  Manual clips are never limited.
- **Frames per platform:**
  - **Web:** the live `<video>` is drawn into a 64×48 canvas every 200 ms,
    and converted to luma.
  - **Android:** a third camera stream, a small YUV `ImageReader` (160×96
    on the S40), is sampled to 64×48 luma natively and sent over the
    `presence/motion` event channel. If a camera refuses three streams, it
    falls back to preview + recording only, and motion is unavailable for
    that camera.

### Sign-in

Sign in with Google, through the `google_sign_in` package
([lib/auth/](../presence_app/lib/auth)). Signing in unlocks the navigation;
there's no separate sign-in screen:

- **At launch** the app checks for a session quietly
  (`attemptLightweightAuthentication`: FedCM auto sign-in on web, Credential
  Manager's authorized accounts on Android, the saved session on iOS). The
  camera opens right away either way.
- **Signed out:** the camera shows full screen with its controls (flip,
  Clip, readiness), always recording as usual, but the **navigation is
  hidden**: the app bar has only the "Presence" title and **Sign in with
  Google**. You can't switch or swipe to Events or Settings, and the clip
  message has no "View" action. On web the button is Google's own (GIS
  `renderButton` with FedCM, medium size to fit the app bar), as Google
  Identity Services requires. On Android and iOS it's an app button that
  starts Google's sign-in: Credential Manager's Sign in with Google sheet,
  or the Google SDK. While the launch check runs, the button is hidden. If
  no client ID is configured, a person icon opens a sheet saying sign-in
  isn't set up. Sign-in errors pop a message.
- **Signed in:** all the buttons: the Camera / Events / Settings tabs and
  the **account button**, your avatar with the tooltip "Signed in as
  <name> · <email>". It opens a bottom sheet with avatar, name, email and
  **Sign out**. Signing out closes the sheet, returns to the camera and
  hides the navigation again. The camera keeps running.
- Sign-ins and sign-outs appear on the **event stream** ("Signed in" /
  "Signed out", with the email).
- Sign-in only identifies the user for now: there's no backend, and data
  stays on the device.
- `AuthService` is the interface (`GoogleAuthService` in the app, a fake in
  tests).

**Google Cloud:** project `presence-492410` (Presence, owned by
julio@nu01.com), with OAuth clients:

| Client | Identifies | In the app |
|---|---|---|
| Web application | JavaScript origin `http://localhost:8080` (and later `https://presence.nu01.com`) | `GoogleConfig.webClientId`: the web client ID, and Android's server client ID |
| Android | package `com.nu01.presence` + signing-key SHA-1 | nothing: matched by package and key (its ID is kept in `.env` as `GOOGLE_ANDROID_CLIENT_ID`, for reference only) |
| iOS | bundle ID `com.nu01.presence` | `GoogleConfig.iosClientId`, plus its reversed ID as a URL scheme |

Client IDs are public identifiers, not secrets, but they're kept out of
the source anyway: they live in the repo's **`.env`** (gitignored; the
committed [.env.example](../.env.example) lists the names). Server and device
starts load it: [scripts/flutter-web.sh](../scripts/flutter-web.sh) (used by
`devbox services up`) and [scripts/flutter-run.sh](../scripts/flutter-run.sh)
(`bash scripts/flutter-run.sh -d <device>`) pass them to Flutter as
`--dart-define`s through [scripts/dart-defines.sh](../scripts/dart-defines.sh),
which forwards **only** an allowlist (`GOOGLE_WEB_CLIENT_ID`,
`GOOGLE_IOS_CLIENT_ID`). Anything passed to Flutter ends up in the compiled
app, and the web bundle is readable, so `.env` can also hold secrets such
as the web client's secret (`GOOGLE_WEB_CLIENT_SECRET`), which the app never
uses and never receives: only a future backend would. Without `.env`, the
account sheet says sign-in isn't set up. The Android debug key SHA-1 on the development Mac
is `B8:90:8F:2F:A4:85:36:0D:32:34:86:22:2E:EE:B4:AD:6D:9A:42:A4`. A release
key will need its own Android client.

The iOS client is `104441697281-djrabadfdeavjb7sejfgu855duq716p6`, created
with bundle ID `com.nu01.presence` and no App Store ID or Team ID (neither
exists yet; both can be added to the client later without changing it). Its
ID goes in `.env` as `GOOGLE_IOS_CLIENT_ID`, and its reversed form,
`com.googleusercontent.apps.104441697281-djrabadfdeavjb7sejfgu855duq716p6`,
is registered in [ios/Runner/Info.plist](../presence_app/ios/Runner/Info.plist)
(`CFBundleURLTypes`) so Google's sign-in page can return to the app. On the
simulator, iOS offers to open that URL in Presence. A full sign-in on iOS
hasn't been run yet.

**App ID:** `com.nu01.presence` on Android (namespace and `applicationId`)
and iOS (bundle ID), replacing the `com.example` placeholders. On a device
it installs as a new app, next to any earlier test install.

### Configuration

All user configuration is one immutable object, **`PresenceConfig`**
([lib/config.dart](../presence_app/lib/config.dart)), grouped by area:

| Group | Values (default, range) |
|---|---|
| `clip` (`ClipConfig`) | `before` (15 s, 5–60 s, 5 s steps), `after` (15 s, 5–60 s) |
| `camera` (`CameraConfig`) | `brightness` (+1 EV, −2 to +2 in ½ EV steps) |
| `motion` (`MotionConfig`) | `enabled` (on), `threshold` (10 %, 1–50 %), `cooldown` (5 min, 1–60 min) |

- Each group owns its defaults and limits. `copyWith` clamps values into
  range. Groups and the whole config have value equality.
- **`ConfigController`** (a `ChangeNotifier`, owned by the app) holds the
  current config. Change it with `update((c) => c.copyWith(…))`; it
  notifies only on real changes. The Settings screen, the camera rig
  (clip windows, brightness, motion), motion detection and persistence all
  read it.
- Settings controls apply each change to the **current** config at call
  time. Two changes before the next rebuild (for example, quick successive
  drags) both stick.
- **Stored** as one versioned JSON record (`settings` store, key
  `config`: `{version, clip, camera, motion}`). `fromJson` tolerates
  missing or invalid fields (defaults) and out-of-range values (clamped).
  On upgrade, the flat `clip` settings record written by earlier versions is
  read once, through `PresenceConfig.fromLegacy`.
- Internal tuning constants (the motion pixel threshold, the 2 s wait cap
  for the before part, 3 frames to trigger, frame sizes) remain code
  constants, not user configuration.

### Settings screen

- The **Settings** tab.
- **Motion** section:
  - A **Clip automatically on motion** switch (default on).
  - **Motion threshold**, 1–50% of the picture (default 10%).
  - A **live motion meter** showing the open camera's current score, with a
    marker at the threshold, to help calibrate it.
  - **At most one automatic clip every** 1–60 minutes (default 5).
- **Camera** section: a **Brightness** slider from −2 to +2 EV in ½ EV
  steps, default **+1 EV**. It's applied live to the open camera, and to its
  recordings, as auto-exposure compensation. Cameras opened later, after a
  flip or restart, get the current value. On Android it's clamped to what
  the camera supports (the S40: −2 to +2 EV). On web it uses the browser's
  `exposureCompensation` constraint, where the camera supports it, and does
  nothing elsewhere.
- **Clips** section, with two sliders from 5 s to 60 s in 5 s steps:
  - **Before the press**, default 15 s. This also sets how much history the
    cameras keep recording.
  - **After the press**, default 15 s.
- It shows the total clip length, and notes that a new "before" value takes
  up to that long to apply fully.
- **All settings are persistent:** the whole `PresenceConfig` (clip lengths,
  brightness, and the motion switch, threshold and cooldown) is saved to
  local storage on every change and restored on launch.

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
| `settings` | name (`config`) | the whole `PresenceConfig` as versioned JSON (the older flat `clip` record is read once, on upgrade) |

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

### App icon

A camera lens in the Gruvbox palette: a yellow ring (`#fabd2f`) on the dark
background (`#32302f`), a dark iris with a blue glint, and a red recording
dot on the ring.

- **Masters:** SVGs in
  [presence_app/assets/icon/](../presence_app/assets/icon), rendered to
  1024×1024 PNGs with headless Chrome.
  - `icon.png` is the full, opaque icon, used for iOS, web and legacy
    Android.
  - `icon_foreground.png` is the art on transparency, used for Android's
    adaptive-icon foreground layer.
- **Generated** by `flutter_launcher_icons` (configured in `pubspec.yaml`;
  rerun with `dart run flutter_launcher_icons` after editing the masters):
  - **Android:** `mipmap-*/launcher_icon.png`, plus an adaptive icon
    (foreground inset 16% for the safe zone, background `#32302f`). The
    default Flutter `ic_launcher.png` icons were removed.
  - **iOS:** the whole `AppIcon.appiconset`, with alpha removed.
  - **Web:** `favicon.png`, `Icon-192/512` and maskable variants, plus the
    manifest colors.
- Verified on the S40: the adaptive icon shows in Recents, next to the app
  name "Presence".

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
  - **iOS** uses a native Swift camera layer with the **same channel API**
    (`presence/cameras` + `presence/motion`), so the Dart side is shared
    with Android. See [iOS](#ios).
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

### Android

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

### iOS

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
- **Google Cloud CLI:** Homebrew's `gcloud-cli` cask, logged in with
  `gcloud auth login` (a browser sign-in) as julio@nu01.com, with project
  `presence-492410` set as the default. It can manage the project, but
  Google offers no CLI for creating Android or iOS OAuth clients, so those
  are made in the Cloud Console.
- **Android builds on macOS:** Homebrew's `android-commandlinetools` cask
  (SDK at `/opt/homebrew/share/android-commandlinetools`, with
  platform-tools, platform 36 and build-tools 36), and JDK 21
  (`openjdk@21`), configured with `flutter config --android-sdk` and
  `--jdk-dir`. Gradle fetches the NDK and extra platforms on the first
  build. The dev container doesn't include the Android SDK.

- **iOS and macOS builds on macOS:** full **Xcode** from the Mac App Store.
  The Command Line Tools alone are not enough: Flutter needs `xcodebuild` and
  the iOS SDK, which only the full Xcode ships. After installing it, point the
  toolchain at it and finish its setup:
  `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`,
  then `sudo xcodebuild -license accept` and `sudo xcodebuild -runFirstLaunch`
  — in that order, because `-runFirstLaunch` refuses to run until the license
  is accepted. Finally `xcodebuild -downloadPlatform iOS` (no `sudo`) for the
  iOS simulator runtime, which the base Xcode no longer bundles: it's an
  ~8 GB download of its own.
  **CocoaPods** comes from Homebrew (`brew install cocoapods`); Flutter needs
  it to resolve plugin pods. The dev container has none of this, because Xcode
  is macOS-only.
- Xcode 27 ships no `Simulator.app`, so simulators are driven from the command
  line with `xcrun simctl` (`list devices`, `boot <udid>`, `io <udid>
  screenshot`). `flutter run -d <udid>` picks up a booted simulator.

## Workflow

- Every new feature or bug fix starts on a new branch from `main`, with its
  own pull request. Nothing is pushed directly to `main`, and PRs are merged
  only when the user says so. See [CLAUDE.md](../CLAUDE.md).
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
- Only one camera records at a time. Clips come from the camera being
  shown.
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
- Persistence has been verified with unit and widget tests against an
  in-memory IndexedDB, but not yet in a real browser.
- The browser's native video controls show the whole recording file, which
  can be longer than the clip window. Playback is still kept to the window.
- Audio recording has been verified in unit tests and code review only. The
  in-browser run that checked recording and playback timing ran before audio
  was added.
