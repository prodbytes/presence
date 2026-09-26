# Request log

Requests that shaped the specification, oldest first. Each entry summarizes
what was asked and what changed. See [README.md](README.md) for the current
spec.

## 2026-09-25

1. **Run the app in web mode.** The app now runs as a Flutter web app. Chrome
   debug mode lost its debug connection, so it runs on the `web-server` device
   at http://localhost:8080.
2. **Add Flutter support to devbox and the dev container.** Added `flutter` to
   devbox, plus a `devbox run web` script. The dev container got the Dart and
   Flutter extensions and forwards port 8080.
3. **Redesign the app UI as a surveillance app.** Removed the demo UI entirely.
   The screen now has two panels: a large Cameras panel on the left and an
   Events panel on the right. The Events panel has Settings (gear) and Login
   (person) buttons at its top right.
4. **Keep a software specification in `specs/`.** Created this folder. A rule
   in [CLAUDE.md](../CLAUDE.md) keeps it up to date with every request.
5. **Make `devbox services up` start the Flutter app in web mode.** Added a
   `2-flutter-web` process to process-compose. It runs
   `scripts/flutter-web.sh`, which `devbox run web` also uses, and has an HTTP
   readiness probe. The health monitor now checks the web app too.
6. **Open all device cameras in the Cameras panel.** Added the `camera` plugin.
   The panel opens every available camera and shows them as a grid of live
   tiles, with loading, empty and error states.
7. **Add a Clip button (camera icon) to the top of the Events panel.** It sits
   before Settings and Login, and is a placeholder for now.
8. **Update the spec on every prompt.** Saved as a standing rule for the
   assistant. The CLAUDE.md rule now covers every request.

Also fixed along the way: relaxed the Dart SDK constraint from `^3.13.4` to
`^3.13.0`, because the dev container's Nix Flutter 3.47.0 ships Dart 3.13.0.
9. **Run the app on an iPhone.** Blocked: this Mac has only the Command Line
   Tools (no Xcode), and no iPhone was connected. Added the iOS camera
   permission string (`NSCameraUsageDescription`) so the app can open cameras
   once it's installed on an iPhone.
10. **Separate the Events header buttons more, add a startup event, and make
    events scroll like a timeline.** The buttons are now tonal filled, 8 px
    apart. An "Application started" card is pushed on launch. Events show in a
    scrolling timeline, newest first, and scroll to the newest event when it
    arrives.
11. **Keep the Events panel a fixed size, with the Cameras panel taking the
    rest.** Removed the narrow-screen stacked layout. Events is always 360 px
    wide.
12. **Move the Clip button to the top of the Cameras panel.** It's now in the
    Cameras header. The Events header keeps Settings and Login.
13. **Restart the server.** Restarted the local Flutter web server on
    http://localhost:8080.
14. **Use the Gruvbox soft dark colors.** Added a Gruvbox palette and a
    matching Material theme, with the page on bg0_s `#32302f`. Camera tiles
    and labels use palette colors instead of black and white, and the web
    manifest colors match.
15. **Remove the marker beside each event and show just the card.** Removed
    the timeline dot and rail. Events are now a plain scrolling list of cards,
    newest first.
16. **Make the Cameras panel title the app title.** It now reads "Presence"
    and links to https://presence.nu01.com in a new tab. Added
    `url_launcher`.
17. **Review the code, commit and push.** The review found one bug: disposing
    a camera tile whose camera had failed to open raised an uncaught async
    error, because `CameraController.dispose()` rethrows the initialize
    error. Fixed. Verified in a freshly built dev container image: 13/13
    tests pass, the web build succeeds, and `devbox services up` brings the
    database and the web app up healthy.
18. **Where is the spec, and open it.** It lives in `specs/`. Opened
    `specs/README.md` in the editor.
19. **Is there a popular event bus for Flutter?** Answered: `event_bus` on
    pub.dev, or the more common alternatives (a broadcast `Stream`, Bloc,
    Riverpod). No change; the existing `EventLog` store stays for now.
20. **Always use a separate PR.** Added the rule to CLAUDE.md and saved it to
    the assistant's memory. Opened PR #1 for the app work; this rule ships in
    its own PR.
21. **Sync git.** Fetched from `origin`. Local and remote branches were
    already in sync.
22. **Use a plain broadcast stream as the event bus.** Added `AppEventBus`, a
    broadcast `StreamController`, exposed through `AppEventBusScope`.
    `EventLog` now subscribes to it instead of being pushed to directly. A
    test caught the startup event being dropped when the log subscribed
    lazily; fixed by subscribing before publishing.
23. **Merge everything to main, and start on clip videos.** Merging was
    blocked by the permission system, since it merges without review, so PRs
    #1–#3 are left for the user to merge. Planned clip videos: all cameras,
    including the moments before the press, shown as an event card with
    playback.
24. **Always record; on Clip, publish `ClipRequested` with the current frame
    as thumbnail; keep the previous 15 s and the next 15 s; make the previous
    part playable immediately and the next part as soon as it exists.** Added
    a web camera layer built on browser APIs, with a rolling `RecorderPool`
    per camera, `ClipRequested` events with clip cards, and a player that
    continues from the before part into the full clip.
25. **Clips must play 30 s: the previous 15 s and the next 15 s.** The player
    plays one continuous before + after window, and stops exactly at its end.
26. **Make that time configurable in a Settings pane, opened by the Settings
    button and hidden at first.** Added an end-drawer Settings pane with
    before/after sliders (5–60 s, default 15 s).
27. **Rebuild and restart the server.** Restarted the dev server with the clip
    feature.
28. **Capture audio as well.** Cameras record the default microphone (one
    permission prompt for camera and microphone), in WebM with Opus. Recording
    falls back to video-only if the microphone is denied.
29. **Playback must have audio as well.** The clip player is unmuted, and
    never falls back to muted playback; if autoplay with sound is blocked, it
    waits for a tap on play.
30. **Save all video clips and events to local storage so app data survives a
    refresh, with events referencing their clips and cameras correctly; think
    about the best storage first.** Discussed Flutter storage options:
    `shared_preferences`, files, and embedded databases (drift, sqflite,
    sembast, Hive/Isar, ObjectBox, Realm).
31. **Drift or IndexedDB?** Recommended IndexedDB directly for now: clips are
    web-only, it stores binary recordings directly with atomic transactions,
    and it needs no WASM or code-generation setup. drift stays the upgrade
    path.
32. **Go ahead with IndexedDB.** Added the `presence` IndexedDB database
    (via `idb_shim`) with cameras, events, clips, media and settings stores,
    and stable IDs linking events, clips and cameras. Clips are saved in two
    steps (before part, then full clip, which deletes the before-only file).
    Events, clips and settings are restored on launch, and interrupted clips
    keep their before part. Defaults chosen: delete the before-only file once
    the full clip is saved; keep everything (no retention limit yet).
33. **Getting an error (a RangeError): check, rebuild, fix, and check the
    logs.** The browser console showed the app failing at startup:
    `AppEvent.newId()` used `nextInt(1 << 32)`, and on web, shifts are
    32-bit, so `1 << 32` is 0 and `nextInt(0)` throws. The VM tests couldn't
    catch it, because there the shift is 64-bit. Fixed with a literal
    `0xFFFFFFFF`, rebuilt the server, and confirmed the browser console is
    clean and the app renders.
34. **Make the clip playable the moment its event appears, and update the
    event with the full clip once the next segment is captured.** Clip now
    publishes each camera's `ClipRequested` once its before part is ready
    (capped at 2 s, per camera), so the event starts out playable. When the
    full clip arrives, the same event is updated in place and in storage
    (`clipState: complete`).
35. **Port the app to Android and run it on the connected USB Android
    device.** Found a DOOGEE S40 on USB. The user chose to install the
    Android SDK via Homebrew (plus JDK 21) and to port clips fully. Added a
    native Kotlin camera layer: Camera2 + H.264/AAC encoders into an
    in-memory ring buffer, clips muxed to MP4. Also video_player playback,
    and file-based clip storage with a persistent sembast database. Removed
    the `camera` plugin.
    On the phone:
    - The fixed 360 px Events panel overflowed its 320 dp screen, so phones
      now stack the panels.
    - Cameras opened while the screen was off are blocked by Android, so
      they're now retried when the app returns to the foreground.
    - Unavailable cameras are listed compactly instead of taking tiles.
    - Full clips failed on out-of-order audio timestamps, so audio is now
      stamped from the sample count.
    - Thumbnails failed on the last-frame decode, so the retriever now falls
      back, and thumbnails run on their own thread.
    Verified on the device: recording, the 15.7 s before part and 30.1 s
    full clip with real audio, the thumbnail, persistence across relaunches,
    and playback.
36. **Change the UI completely.** The start screen is the camera, full
    screen, with a "Presence" title overlaid. The top right has Camera
    (selected), Events, Settings and Login. Each flips to its own screen, as
    traditional Android tabs following Material guidelines. For now: the
    camera with the clip trigger, the events stream, the settings, and login
    disabled. On Android and web.
    Implemented as app-bar tabs with `TabBarView` (tap or swipe), with a
    Clip FAB on the Camera tab, a snackbar with "View", readable-width Events
    and Settings screens, and Login as a disabled icon button. Verified on web
    (headless Chrome) and on the DOOGEE S40. The title link was removed;
    phones group unavailable cameras into one line.
37. **Restart the app on Android.** Restarted it through `adb`.
38. **Remove the "Back camera 0" message from the camera, use the default
    camera, and add a flip button beside Clip.** The camera screen now shows
    one camera (the default: the first back camera), with no overlays. A
    **Flip camera** button next to Clip switches back ↔ front, closing the
    old camera fully before opening the next. The camera layer became a
    `CameraBackend` that lists devices and opens one at a time, on both
    platforms. Verified on the S40: flip went from camera 0 to camera 1 in
    ~330 ms, and front-camera clips have thumbnails.
39. **Set up Xcode and the required CLIs for Flutter development.** On this
    Mac, Flutter, Homebrew and the Android SDK were already in place, but only
    the Command Line Tools were installed, so `xcodebuild` and the iOS SDK were
    missing, and CocoaPods wasn't installed at all. Installed CocoaPods 1.17.0
    from Homebrew and full **Xcode 27.0** from the Mac App Store, then
    `xcode-select --switch`, `xcodebuild -license accept`,
    `xcodebuild -runFirstLaunch` and `xcodebuild -downloadPlatform iOS` for the
    iOS 27.0 simulator runtime (the base Xcode no longer ships it).
    `flutter doctor` now reports no issues at all, and the app was verified
    building and running on an iPhone 18 Pro simulator.
    Along the way: the first `flutter doctor` run wrongly reported the Android
    SDK missing, so Android Studio was nearly installed before a re-run showed
    the existing SDK was fine; and `-runFirstLaunch` must come after
    `-license accept`, not before.
39. **Run on the USB-connected iPhone.** Not possible yet: Xcode isn't
    installed (only the Command Line Tools), there's no iOS camera layer yet
    (Swift/AVFoundation, like the Kotlin one), and signing needs an Apple
    team and a real bundle ID.
40. **Sync git.** Fetched: all branches matched `origin`. PRs #1–#9 are
    open and stacked.
41. **Rebuild and run the app again on Android.** Rebuilt and reinstalled.
    The camera, the tabs, and the Flip and Clip buttons all worked.
42. **The camera is extremely dark; make it brighter if there's a flag.** The
    cause was a fixed 30 fps capture range, which caps exposure at 1/30 s.
    The capture now uses a variable range (5–30 fps on the S40) and +1 EV
    exposure compensation by default, plus a Brightness slider in Settings
    (−2 to +2 EV, live, saved). Measured on the S40: average luma went from
    17 to 68.
43. **Camera orientation is wrong; make it match.** The preview was
    rotated twice: once by Camera2's SurfaceTexture transform and once by
    the app. Removed the app's rotation, keeping the portrait aspect, and
    locked the Android activity to portrait. Verified on the S40, back and
    front, by comparing the preview with a recorded frame of the same scene
    (recordings were already upright).
44. **Show how events are stored in the database.** Walked through live
    records pulled from the phone's database (events, clips, cameras, and
    how their IDs link).
45. **Show me the code.** Walked through `toRecord`, `Persistence._onEvent`,
    `EventStore._put` and the schema, `_ClipWriter.run`, and `allEvents`.
46. **What icon format should a Flutter app use? Generate non-default
    icons.** Explained the per-platform formats (Android densities and
    adaptive icons, iOS opaque sizes, web and maskable icons). Designed a
    lens icon as SVG, rendered it to PNG with headless Chrome, and generated
    icons for all platforms with `flutter_launcher_icons`. Verified on the
    S40.
47. **Measure motion in the video; if there's enough (configurable
    threshold), take a clip as if Clip was pressed; allow at most one
    automatic clip every 5 minutes (configurable).** Added a shared
    `MotionDetector` (frame differencing on 64×48 luma, with median
    brightness compensation), motion frames on web (canvas) and Android (a
    third YUV camera stream, with fallback), and triggering that needs 3
    consecutive frames and respects a cooldown. Automatic clips use the
    manual flow, titled "Motion detected". Settings: a switch, threshold,
    cooldown and live meter.
48. **Make the configurable settings persistent.** Everything in Settings is
    saved and restored (clip lengths, brightness, motion switch, threshold,
    cooldown), with tests that change each through the UI and check it
    after a refresh.
49. **Note those changes in the spec, and make the same work on Android,
    iPhone and web.** The spec already covered the motion clips; added a
    feature-parity table. Web and Android already had every feature. iOS had
    none (no camera code), so added a Swift camera layer with the same
    channel API as Android: AVFoundation capture, a VideoToolbox H.264 ring,
    `AVAssetWriter` clips with AAC audio, a Core Image thumbnail, motion
    frames, brightness, flip, and a mirrored front preview. Builds and runs
    on the simulator (the plugin answers, and the permission prompt shows);
    not yet tested on a physical iPhone, which needs pairing and a signing
    team.
50. **The same features on all devices; update the web if needed; restart
    the server.** Web already had every feature. Closed the one gap: a
    low-light frame-rate hint (10–30 fps) like Android and iOS. Restarted
    the dev server and verified motion clips end to end in headless Chrome:
    the live meter read ~10% for the fake camera, and at a 1% threshold a
    "Motion detected" clip appeared, playable.
51. **Add a readiness indicator beside the Clip button; after a clip
    triggers, pop a message and show the countdown / ready state.** Added a
    readiness pill (buffering with countdown / ready / saving countdown),
    computed by the rig, and a brief snackbar for every clip start, manual
    or motion. The snackbar was persisting (Flutter's default with an
    action), so it's now set to 4 s. Verified on the S40: 14 → 10 → 6 → 3 →
    0 s → Ready. Also saw a real motion clip trigger on the phone.
52. **No "saving" in the label, only the countdown; make it the last button
    on the right.** The saving state shows only "12 s" with the red dot, and
    the row is Flip, Clip, then readiness. The new 320 dp phone test caught
    "Buffering 15 s" overflowing the row by 128 px, so buffering also shows
    only the countdown (with its progress ring). The tooltip and
    screen-reader label keep the full wording.
53. **What are the 67 tests; are they UI tests?** Explained: 41 Flutter
    widget tests (the real UI rendered headless, with fake cameras and
    storage) and 26 unit tests; native camera code is verified by hand on
    devices. Offered `integration_test` for on-device end-to-end tests.
54. **The counter should start when motion grabs a clip, and motion should
    retrigger only once it's down to zero from the countdown time (5
    minutes by default).** After a motion clip, the readiness pill counts
    down the cooldown ("4:59"; red while saving, then amber). The trigger
    and the countdown share `motionCooldownEnds`, so motion fires again
    exactly at zero.
55. **Wrap the entire configuration in a configuration object.** Replaced the
    mutable `ClipSettings` with an immutable `PresenceConfig` (clip, camera
    and motion groups, each owning its defaults, limits and clamping), held
    by a `ConfigController`. It's persisted as one versioned JSON record,
    with migration from the old flat record. While porting, a test caught
    settings controls writing back stale values, which undid a previous
    change made before a rebuild. They now apply changes to the current
    config.
56. **Merge it all.** Merged PRs #1–#19 into `main` in order, as merge
    commits (retargeting each to `main` first). `main` matches the top
    branch, and 78/78 tests pass on it.
57. **The countdown doesn't match the cooldown timer; when an auto clip is
    grabbed, trigger the cooldown and show its exact countdown on the camera
    screen.** The phone was running a build from before the countdown
    (installed 18:39; the countdown landed at 18:54), so it showed only the
    15 s save. Installed the current build. Also found the cooldown was
    reset by restarts; it's now restored from the last stored motion clip.
58. **On a web page reload it starts with a 15 s timer; start Ready (unless
    already counting down) and start the countdown only on clipping.**
    Removed the buffering state: the pill starts at Ready, and counts down
    only after a clip, or the restored motion cooldown after a reload.
    Verified in Chrome (Ready, then 4:48 → 4:28 → 4:22 across a reload,
    matching the 19:11:33 event) and on the S40 (Ready on launch).
59. **Merge it (PR #20).** Merged into `main`; 78/78 tests pass.
60. **For every new feature or bug, start a new branch/PR, and note the rule
    in memory.** Sharpened the CLAUDE.md rule and the assistant's memory:
    each feature or bug fix gets a new branch from an up-to-date `main` and
    its own PR (stacking only when truly dependent), and merges happen only
    on the user's say-so.
61. **Enable sign in with Google.** Chosen: plain `google_sign_in` (no
    Firebase), app ID `com.nu01.presence`, with the assistant walking the
    user through the credentials. Renamed the app ID on Android and iOS, and
    added an `AuthService` with a Google implementation (GIS button on web,
    Credential Manager on Android, the SDK on iOS), an account button and
    sheet, silent session restore, and sign-in/out events.
62. **First install the Google Cloud CLI and help me authenticate.**
    Installed `gcloud-cli` (586.0.0) via Homebrew and ran the browser login
    (julio@nu01.com). Using the existing Presence project `presence-492410`.
    Gave console steps for the consent screen and the web, Android (debug
    SHA-1) and iOS OAuth clients.
63. **Can't you do all that? Don't add Firebase to the project; just create
    the OAuth IDs.** Checked the CLI routes: Google Sign-In OAuth clients
    can't be created from `gcloud` without Firebase (`gcloud iam
    oauth-clients` is Workforce Identity, the IAP brand API is deprecated),
    so they're made in the Cloud console. The consent screen already exists.
    Firebase was not added.
64. **When the app loads, check if the user is signed in: if so, show the
    tabs as usual, with the user icon and an identity tooltip; if not, show
    only the Google sign-in prompt. Use the latest Google sign-in best
    practices (FedCM etc.).** Added an auth gate: a quiet session check with
    a splash, a full-screen sign-in prompt (GIS button with FedCM on web,
    Credential Manager on Android), the camera only while signed in, and the
    tooltip "Signed in as <name> · <email>". Sign-out closes the account
    sheet.
65. **Why don't you go ahead and create the Android and iOS keys?**
    (2026-09-25) Not possible from the CLI without Firebase: Google has no
    public API or `gcloud` command for Android or iOS OAuth clients (the
    IAP API makes only IAP web clients). Opened the console's Create OAuth
    client page for project `presence-492410`, with the values to enter.
66. **Go ahead and do the clicks.** (2026-09-25) Not possible from this
    session: it has no tool that controls the user's signed-in browser, and a
    browser it starts itself isn't signed in to Google (and Google blocks
    sign-in from automated browsers). The OAuth clients stay a manual
    console step.
67. **Here is the web OAuth client ID, and the secret. Don't store them in
    source: store them in .env and load them on server start.**
    (2026-09-25) Added a gitignored `.env` (with a committed
    `.env.example`). `scripts/flutter-web.sh` and a new
    `scripts/flutter-run.sh` pass the client IDs to Flutter via an
    allowlist in `scripts/dart-defines.sh`. The client secret stays in
    `.env` only: the app doesn't need it, and passing it to Flutter would
    publish it in the web bundle.
68. **Here is the Android OAuth client ID; add it to .env under its own
    name.** (2026-09-25) Added `GOOGLE_ANDROID_CLIENT_ID` to `.env` and
    `.env.example`. It's for reference only and isn't passed to the app:
    Google matches Android's client by package name and signing-key SHA-1.
    Tested sign-in on the S40.
69. **Don't create a separate login screen: let the camera show and only
    hide the navigation. When the user is signed in, show all buttons.**
    (2026-09-25) Removed the sign-in screen and the gate. The camera opens
    and records at launch whether or not anyone is signed in. Signed out,
    the app bar has only the title and Sign in with Google (Google's button
    on web), the tabs are hidden, swiping is off, and sign-in errors pop a
    message. Signed in, the tabs and the account button (identity tooltip)
    show. Verified on the S40 (320 dp): the signed-out app bar fits, and
    the button opens Google's sign-in sheet.
70. **Pressing Clip starts a 15 s countdown. That's not right: only
    automatic triggers (detections) should start the countdown.**
    (2026-09-25) Removed the readiness pill's "saving" state. A Clip press
    now leaves the pill as it is (Ready, or the running motion cooldown);
    only motion clips start a countdown. The snackbar still says the clip
    is saving.
71. **Merge it all.** (2026-09-25) Merged #21 (branch rule), #23 (only
    motion clips count down) and #22 (sign in with Google) into `main`,
    resolving request-log conflicts. 80/80 tests pass on the merged code.
    iOS sign-in still needs its client ID in `.env`.

## 2026-09-26

72. **Split the spec into separate specs per feature, one file per
    feature.** Split `specs/README.md` into feature files (navigation,
    theme, camera, events, clips, motion clips, sign-in, configuration,
    settings, storage, app icon, platforms, Android, iOS, development
    environment). The README now holds the product summary, an index of the
    feature files and the workflow. The old "Known limitations" list moved
    into the feature each item belongs to. The spec rule in
    [CLAUDE.md](../CLAUDE.md) now says to revise the affected feature files.
73. **Fix the devbox GraalVM package with a multi-platform one.**
    (2026-09-26) Replaced `graalvmPackages.graalvm-ce-musl` (Linux-only,
    which made `devbox install` fail on macOS) with
    `graalvmPackages.graalvm-ce` 25.2.4 (JDK 25.0.4, with `native-image`),
    locked for aarch64-darwin, aarch64-linux and x86_64-linux. Verified
    `devbox install` and the toolchain on an Apple Silicon Mac, and that
    the dev container image builds.
74. **Remove the Postgres stuff from the services and the health check.**
    (2026-09-26) Removed the `1-postgresql` process, the root
    `compose.yaml` (which only defined the `devbox-db` Postgres container)
    and the health monitor's `🐘 database` check. Updated the README,
    AGENTS.md and the spec. The `postgresql` devbox package is kept.
75. **Create a Makefile that delegates to a make script and builds the app
    binaries (web, android, ios and linux).** Added a `Makefile` whose
    targets (`web`, `android`, `ios`, `linux`, `all`, `clean`) call
    `scripts/make.sh`, which runs `flutter build` with the `.env` settings.
    `MODE` picks the build mode, and iOS is unsigned unless `IOS_CODESIGN=1`.
    `make` builds every platform the host can build; on the Mac it built
    web, the Android APK and the iOS app, and skipped Linux.
76. **Run make and fix any errors; make sure the binaries are correctly
    built.** (2026-09-26) `make` built web, Android and iOS with no errors,
    so the scripts needed no fixes. Checked the outputs: the web bundle has
    the web client ID and no secret; the APK is `com.nu01.presence` for
    arm64, armv7 and x86_64, signed with the debug key (no release key yet);
    `Runner.app` is an arm64 device build. Its missing client ID is because
    `GOOGLE_IOS_CLIENT_ID` is empty in `.env`. `make linux` also built in a
    Linux arm64 container with Flutter 3.47.5.
77. **What should I use as bundle ID, App Store ID and Team ID for the
    Google iOS client? Here is the iOS client ID.** (2026-09-26) Bundle ID
    `com.nu01.presence`; App Store ID and Team ID left blank, since neither
    exists yet. Put the client ID in `.env` (`GOOGLE_IOS_CLIENT_ID`) and
    registered its reversed ID as a URL scheme in the iOS `Info.plist`.
    Verified on the iPhone 18 Pro simulator: the ID is compiled into the
    build, and iOS offers to open the reversed-ID URL in Presence. Also
    dropped the spec's stale note that the bundle ID is still a placeholder.
78. **Create a new SAM module called presence_api_events, in Java, on the
    latest runtime.** (2026-09-25) Added
    [presence_api_events/](../presence_api_events): a SAM template with one
    `java25` (arm64) Lambda, `EventsFunction`, serving `GET /events` (an
    empty list for now), a Maven project with a unit test, a sample event,
    `samconfig.toml` and a README. `.aws-sam/` is git-ignored.
79. **In a separate folder, create a presence_infra_tenant CDK project,
    also in Java, on the latest version.** (2026-09-25) Added
    [presence_infra_tenant/](../presence_infra_tenant): a CDK v2 Java app
    (JDK 25, `aws-cdk-lib` 2.270.0) with an empty
    `PresenceInfraTenantStack`, a synth test, the recommended feature flags
    in `cdk.json`, and a README. `cdk.out/` is git-ignored.
80. **Change process-compose to start both the app and the SAM API
    modules.** (2026-09-25) Added a `3-sam-api` process
    ([scripts/sam-api.sh](../scripts/sam-api.sh): `sam build` +
    `sam local start-api` on port 3000, with a readiness probe on
    `/events`, stopped with SIGINT). Also added an API check to the health
    monitor and forwarded port 3000 in the dev container. Verified
    standalone: `/events` returns 200 in the `java25` container, and SIGINT
    stops SAM and its containers. `devbox add maven aws-sam-cli` fails on
    macOS (Linux-only GraalVM), so they aren't in devbox yet.
81. **Can Floci emulate CloudFront, dispatching requests to the static app
    and the API as CloudFront would?** (2026-09-25) Yes: since 1.7.0 it
    serves distributions from S3 and custom origins, with path-based cache
    behaviors. No code change.
82. **Create a presence_floci dir for any config needed, set it up, and add
    it to process-compose.** (2026-09-25) Added
    [presence_floci/](../presence_floci): a compose file for Floci 2.1.0
    and a ready hook that creates a CloudFront distribution
    (`presence.localhost`) routing `/events*` to the SAM API and the rest to
    the Flutter web server. Added `4-floci` to process-compose, a `☁️ cdn`
    health check, and a port 4566 forward in the dev container. Verified
    under process-compose on macOS.
83. **(Fix found while moving the app to /app/.)** (2026-09-25) Through
    Floci, the real Flutter web server returned 502, because Dart bound
    `localhost` to `[::1]` only. It now binds `127.0.0.1`.
84. **Serve presence_app at /app/ instead of the root.** (2026-09-25) The
    Flutter web server now runs with `--base-href /app/` and serves only
    under `/app/`, because CloudFront forwards paths as is and can't strip
    a prefix. The Floci distribution has an explicit `/app*` behavior for
    the app. The web readiness probe and the web and CDN health checks use
    `/app/`, and the READMEs and spec point at `/app/`. `/` isn't
    redirected, since Floci doesn't run CloudFront Functions.
85. **Run the Flutter app in Flutter dev mode on /app, the events API on
    sam local at /api/events, and use Floci only to route between them as
    CloudFront would.** (2026-09-26)
    - The SAM route moved to `/api/events`. The distribution routes `/app*`
      to the Flutter dev server and `/api/*` to SAM, and `/events` is gone.
    - Found while testing: the app never started through Floci. The
      Flutter dev server's debug channel (a WebSocket, or SSE) can't pass
      through Floci, and the dev server built its URL from the Host
      header it saw (`host.docker.internal`), which the browser can't
      resolve.
    - The fix: both origins are named `dev.presence.localhost`, mapped to
      the Docker host inside the container and to loopback in the browser,
      so the debug WebSocket goes straight to the dev server.
    - Floci is pinned to `nightly-09242026-compat`, because 2.1.0 forwards
      no viewer headers.
    - Verified: the app renders through
      http://presence.localhost:4566/app/, hot-reload WebSocket 101, and
      `/api/events` 200.
86. **Merge all open PRs, sync git, and commit the `.gitignore` change.**
    (2026-09-26) All open PRs (#24–#33) were merged and local `main` was
    synced. `.gitignore` now also ignores `*.local*` files (machine-local
    overrides), next to the new SAM and CDK entries.
87. **Create a GitHub action to build a release with the binaries, on
    manual dispatch and on pushes of tags named `*QA` or `*RC*`.**
    (2026-09-26) Added `.github/workflows/release.yml`: `make` builds web,
    Android and Linux on Ubuntu and iOS on macOS (Flutter 3.47.5), and a
    release job attaches the four packages to a GitHub (pre)release. PRs
    that change the build run the builds without releasing. Set the
    repository variables `GOOGLE_WEB_CLIENT_ID` and `GOOGLE_IOS_CLIENT_ID`
    for the builds. The PR's run built all four; the artifacts had the
    client IDs compiled in, no secret, and the expected package and
    architectures. Added [release.md](release.md).
88. **On process-compose, 3-sam-api says sam is not on PATH; add it to
    devbox.** (2026-09-26) Added `aws-sam-cli` (1.165.0) and `maven`
    (3.9.16, which runs on devbox's GraalVM JDK 25) to devbox, locked for
    aarch64-darwin, aarch64-linux and x86_64-linux. Verified
    `devbox services up` on a Mac with no host `sam` or `mvn`: `3-sam-api`
    built and served, and the health line showed `🌐 web ✅ ⚡ api ✅
    ☁️ cdn ✅`.
89. **Add all requirements to devbox, and make sure `devbox services up`
    starts OK and the health check passes after a couple of seconds.**
    (2026-09-26)
    - Added the AWS CDK CLI (2.1138.0), the AWS CLI (2.35.11), GNU Make
      and curl to devbox. Docker stays a host requirement (daemon and
      `compose` plugin).
    - The health monitor now waits for every service's readiness probe,
      and the probes start after 1–2 s and poll every 2 s (was a 10–15 s
      initial delay).
    - Measured: the first health line came 9 s after `devbox services up`
      (10 s with build caches cleared), all green.
90. **Merge the PR, trigger the action, verify build and release
    artifacts.** (2026-09-26) Merged #35 and pushed the tag `1.0.0-RC1` on
    `main`, which ran the workflow: all four builds and the release job
    passed, publishing the prerelease with the web zip, APK, unsigned iOS
    app and Linux x64 bundle. Downloaded the release assets and checked
    each (client IDs compiled in, no secret, package `com.nu01.presence`,
    valid APK signature, arm64 iOS with its URL scheme, x86-64 Linux).
91. **Make the release full named (`presence-X.Y.Z-KK`); push another RC
    to check that it triggers correctly.** (2026-09-26) Release titles are
    now `presence-<tag>` (also applied when a run updates an existing
    release); tags stay `X.Y.Z-KK`. Pushed `1.0.0-RC2` on this change to
    check the trigger and the new name, and renamed the `1.0.0-RC1`
    release to `presence-1.0.0-RC1` to match.
92. **Create a presence_index dir for an index module that just
    redirects to /app/; serve it from a process-compose process (Python
    http is fine) and map it on the Floci distribution.** (2026-09-26)
    Added [presence_index/](../presence_index) (`site/index.html`: script
    redirect, `meta refresh` and link) and a `5-index` process
    (`python3 -m http.server` on 127.0.0.1:8081). It's the distribution's
    default origin, so http://presence.localhost:4566/ redirects to
    `/app/`. The health monitor gained `🏠 index` and waits for it, and
    the dev container forwards 8081. Verified in headless Chrome.
