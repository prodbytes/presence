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
    (the project owner's account). Using the existing Presence project.
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
    client page for the Presence project, with the values to enter.
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
92. **Store files for the version numbers, `version.X.txt` and
    `version.Y.txt`, and auto-generate Z with the current timestamp on the
    build; change the make script and the action as appropriate.**
    (2026-09-26) Added `version.X.txt` (`1`) and `version.Y.txt` (`0`) and
    `scripts/version.sh`, which makes `X.Y.Z` with Z the build time as
    `YYYYMMDDHHMM` (UTC) and the build number the same instant in Unix
    seconds. `make` passes them to Flutter; the Makefile shares one build
    time across a run's targets. The release workflow resolves one version
    for all jobs, keeping the Z of a tag that carries `X.Y.Z` and failing
    if its X.Y doesn't match the files. Verified the version in web's
    `version.json`, the APK's `versionName`/`versionCode` and the iOS
    bundle.
93. **Create a script that tags a release with the current version numbers
    and an RC tag, and one that releases with the current version and a GA
    tag.** (2026-09-26) Added `scripts/release-rc.sh` (tag `X.Y.Z-RC`) and
    `scripts/release-ga.sh` (tag `X.Y.Z-GA`, commit must be on `main`),
    both through `scripts/tag-release.sh`, which checks for uncommitted
    changes, an unpushed commit and an existing tag, and supports
    `DRY_RUN=1`. The workflow now also runs on `*GA` tags and publishes
    them as full (latest) releases.
94. **Create a presence_index dir for an index module that just
    redirects to /app/; serve it from a process-compose process (Python
    http is fine) and map it on the Floci distribution.** (2026-09-26)
    Added [presence_index/](../presence_index) (`site/index.html`: script
    redirect, `meta refresh` and link) and a `5-index` process
    (`python3 -m http.server` on 127.0.0.1:8081). It's the distribution's
    default origin, so http://presence.localhost:4566/ redirects to
    `/app/`. The health monitor gained `🏠 index` and waits for it, and
    the dev container forwards 8081. Verified in headless Chrome.
95. **Make the version X 0 and Y 1 in the files; trigger the release-ga
    script; merge it all.** (2026-09-26) Merged #40 (version files), #41
    (RC/GA scripts, retargeted to `main`) and #42 (`presence_index`,
    after resolving its request-log conflict). Set `version.X.txt` to `0`
    and `version.Y.txt` to `1`, merged that, and ran
    `scripts/release-ga.sh` on `main` for the first GA release, `0.1.Z-GA`.
96. **Can Floci use 8443 for SSL?** (2026-09-26) Yes:
    `FLOCI_TLS_AWS_HTTPS_PORT=8443` moves its extra HTTPS listener off
    the privileged 443. No code change.
97. **Generate the required certs, if necessary, with mkcert and serve
    local HTTPS; start the services to check, and make sure the local
    HTTPS checks pass.** (2026-09-26)
    - Added mkcert and OpenSSL to devbox, and
      [scripts/local-certs.sh](../scripts/local-certs.sh). It writes a
      certificate for `presence.localhost` and friends into the git-ignored
      `presence_floci/certs/`, only when needed, and runs before Floci
      starts.
    - Floci now loads it and serves HTTPS on 8443 (and 4566).
    - Added a `🔒 https` health check that validates against mkcert's CA,
      and a port 8443 forward in the dev container.
    - Verified under `devbox services up`: `🔒 https ✅`, the mkcert
      certificate served and verified, the app loaded over HTTPS with the
      hot-reload WebSocket connected.
    - `mkcert -install` (browser trust) needs the user's password, so it's
      a one-time manual step.
98. **What callback URI should I use as the authorized redirect URI (on
    web)?** (2026-09-26) None: the web button signs in with Google's popup,
    so only the JavaScript origins matter. No code change.
99. **Google says "Invalid Origin: must end with a public top-level
    domain"; use local.presence.nu01.com, resolving to 127.0.0.1, with the
    AWS CLI and the existing Route 53 zone.** (2026-09-26)
    - Created an A record `local.presence.nu01.com` → `127.0.0.1` (TTL 300)
      in the `nu01.com` zone with `aws route53 change-resource-record-sets`
      (`CREATE`, so nothing was overwritten).
    - Added the name as a second distribution alias and to the mkcert
      certificate (an existing certificate regenerates automatically, since
      it no longer covers every name). The `🔒 https` health check now
      tests it.
    - The web client's local origin is `https://local.presence.nu01.com:8443`.
100. **Clone prodbytes/setec-astronomy in a sibling directory, move all the
     private files (`.env`, `env.local`) there and commit, link them so
     everything keeps working, and give this tenant (`presence.nu01`) its
     own directory in the private repo.** (2026-09-26) Cloned the private
     repo to `../setec-astronomy` and moved `.env` and `env.local/` into
     its `presence.nu01/`, with READMEs, committed and pushed there. This
     clone now has relative symlinks to them; added
     `scripts/link-private.sh` to recreate them. Verified the run scripts
     and `make web` read the client IDs through the link. The mkcert
     certificates stay local: they're generated per machine.
101. **Create another GitHub action that puts it all in prod on a `*GA`
    tag push, with CloudFormation templates for every module (SAM where it
    already exists), so that a pushed `*GA` version goes to
    https://presence.nu01.com; test and fix until right.** (2026-09-26)
    - Added [presence_infra_web/](../presence_infra_web): `site.yaml`
      (certificate, S3 with OAC, CloudFront for `/`, `/app*` and `/api/*`,
      Route 53) and `github-deploy.yaml` (the OIDC provider and a deploy
      role trusting only `*GA` tags).
    - Added [scripts/deploy.sh](../scripts/deploy.sh) (build, SAM deploy,
      site deploy, upload, invalidate, smoke test), a `WEB_BASE_HREF`
      option in `make.sh`, an `ApiDomain` output in the SAM template, and
      `.github/workflows/deploy.yml`.
    - Deployed by hand and verified: the live site serves the app, index
      and API.
    - Creating the IAM deploy role was declined in this session, so the
      GitHub path waits for an administrator to deploy
      `github-deploy.yaml`.
102. **Update the Y version, run the GA script and make sure prod is
    updated.** (2026-09-26) `version.Y.txt` goes from 1 to 2, so builds are
    0.2.Z. Tagged with `scripts/release-ga.sh`. The deploy role doesn't
    exist yet (it needs an administrator), so the tag was also deployed to
    https://presence.nu01.com with `scripts/deploy.sh`.
103. **Create a presence_infra folder for the components prod needs, with
    a bucket for users' videos, so a clip is uploaded to S3 automatically.
    Signed out, show no buttons at all. Signed in, use Cognito identity pools
    to exchange the web identity for a temporary role and sync videos and
    events to S3 directly.** (2026-09-26)
    - Moved `presence_infra_web` to [presence_infra/](../presence_infra), and
      added `user-data.yaml` (the bucket) and `identity.yaml` (the Google
      identity pool and a per-user-prefix role), both deployed.
    - The app: `lib/cloud/` (a SigV4 signer, a Cognito client, S3 uploads,
      and `CloudSync`), `AuthService.idToken`, and a `synced` store (DB v2).
      Signed out, the camera shows no buttons, and the account sheet shows
      the sync status.
    - `deploy.sh` deploys both stacks and builds the app with their IDs.
    - 92 tests pass, and uploads, CORS and pool checks were verified
      against AWS.
104. **Merge it all, and make sure all private info goes to the private
    repo.** (2026-09-26) Merged #49. This repo is public, so it no longer
    names:
    - the AWS account, hosted zone, bucket, identity pool or role;
    - the OAuth client IDs, the Google Cloud project or the owner's email;
    - the Android signing SHA-1.

    They're listed in the private `setec-astronomy/presence.nu01/README.md`,
    and the settings are in its `.env`. Changes here:
    - the templates take `HostedZoneId` without a default (`deploy.sh` reads
      `HOSTED_ZONE_ID` from `.env`, CI from the repository variable);
    - iOS reads its sign-in URL scheme from a git-ignored
      `Private.xcconfig` that `dart-defines.sh` writes from `.env`;
    - tests use `ana@example.com`.

    Earlier commits and PR descriptions still contain these values.
105. **Create the Cognito identity pool that lets identified users write
    to S3. Sync with S3 every minute or when a shot is taken, whichever comes
    first. Fetch the bucket on initialization after login. Make sure all the
    AWS pieces are in place: a shot should land on S3.** (2026-09-26)
    - The pool and bucket from the previous request were already live.
    - `CloudSync` now runs a pass every minute as well as when a shot is
      saved, and on sign-in first fetches the user's folder
      (`ListObjectsV2`, then `GET`), importing missing clips (with their
      recordings) and events into the local store and the timeline.
    - `S3Bucket` gained `get` and `list`, and `MediaStore` `saveBytes`.
    - Checked against AWS: every stack is complete (except the GitHub deploy
      role), CORS allows `GET`, and put, list and get round-tripped a
      recording.
    - 96 tests pass.
106. **In the infra templates, add a Cognito identity pool whose
    authenticated users assume a role that can read and write the user-data
    bucket, only under their own prefix. Write events to the bucket under the
    user's subject prefix, partitioned by day of year.** (2026-09-27)
    - The pool and role already existed in `presence_infra/identity.yaml`
      (deployed in #49): only authenticated identities of the pool may
      assume the role (`aud` and `amr` conditions), and it may only read,
      write and list under `${cognito-identity.amazonaws.com:sub}/`. No
      template change was needed.
    - Events now go to
      `<identityId>/events/year=YYYY/day=DDD/<eventId>.json` (the UTC day of
      the year of the event's time). The fetch still reads the old flat
      keys.
    - `user-data.yaml` describes the layout. 98 tests pass.
107. **Create an action that deploys every pushed `*RC*` tag (or a manual
    run) to rc.presence.nu01.com.** (2026-09-27)
    - Added `.github/workflows/deploy-rc.yml` and a `STAGE=rc` mode in
      `scripts/deploy.sh`. The RC gets its own `presence-rc-*` stacks
      (bucket, identity pool, API, site with its own certificate and DNS).
    - The templates are now per-stage (bucket exports by stack name, and the
      identity pool imports by `UserDataStackName`), with no change to prod,
      which a change set confirmed.
    - `github-deploy.yaml` gains a `presence-github-deploy-rc` role, trusting
      `*RC*` tags and manual runs from `main`, limited to `presence-rc-*`
      resources and the `rc.presence.nu01.com` records.
108. **Use a CloudFront distribution in front of the app.** (2026-09-27)
    Already the case: prod and RC each serve through their own
    distribution (`presence_infra/site.yaml`), with `/` the index, `/app*`
    the Flutter build from a private S3 bucket (OAC), and `/api/*` API
    Gateway. No change.
109. **Merge everything, tag an RC, check that the workflow runs through
    and the service is up at that address.** (2026-09-27)
    - Merged #52 and #53, and tagged `0.2.202609270714-RC`.
    - The Deploy RC workflow ran every step up to AWS login, which failed:
      the GitHub deploy roles (`presence-github-deploy` stack) aren't
      deployed yet, since creating IAM roles needs an administrator.
    - The same tag was then deployed with `STAGE=rc scripts/deploy.sh`.
      https://rc.presence.nu01.com serves `0.2.202609270714`: `/` and
      `/app/` return 200, `/app` redirects, `/api/events` returns 200, and
      headless Chrome renders the app. Google's button returns 403 until
      `https://rc.presence.nu01.com` is an authorized origin.
110. **Create the tag, monitor the workflow, check the deployment.**
    (2026-09-27)
    - The `presence-github-deploy` stack had been deployed by the owner.
      Tagged `0.2.202609270725-RC`.
    - First failure: `AWS_DEPLOY_RC_ROLE_ARN` was malformed. zsh had read
      `$ACCT:r` as a modifier when it was set; it's now set from the
      stack's `RcDeployRoleArn` output.
    - Second failure: "Not authorized to perform AssumeRoleWithWebIdentity".
      The repository uses immutable OIDC subject claims
      (`repo:prodbytes@<id>/presence@<id>:…`), which the roles' trust didn't
      match. Both roles now trust both subject forms; the stack was updated.
    - Third run: success. The workflow deployed the RC and its smoke test
      passed. Checked independently: version, routes, and the app in
      headless Chrome.
111. **Remove the SAM API module and all references to it.** (2026-09-27)
    - Deleted `presence_api_events/`, `scripts/sam-api.sh`,
      `specs/events-api.md`, the `3-sam-api` process and the `⚡ api` health
      check.
    - Removed the `/api/*` route from `site.yaml` (prod and RC) and from
      the Floci distribution, and the SAM steps and the `/api/events` check
      from `deploy.sh`.
    - Removed the SAM, Lambda and API Gateway grants from both GitHub deploy
      roles, the SAM and Java setup from the workflows, `aws-sam-cli` from
      devbox (Maven stays, for the CDK module), port 3000 from the dev
      container, and `.aws-sam/` from `.gitignore`.
    - The deployed `presence-api-events` and `presence-rc-api-events` stacks
      are deleted after the sites stop pointing at them.
112. **If the SAM events module is no longer used or referenced, delete
    it.** (2026-09-27)
    - Nothing used it any more, so #56 was merged, removing the module and
      every reference.
    - In AWS: both site stacks were updated, and their distributions now
      have only the S3 origin and `/app*`. Then `presence-api-events`,
      `presence-rc-api-events` and SAM's `aws-sam-cli-managed-default`
      artifact stack (emptied first) were deleted.
    - Prod and RC still serve `/` and `/app/`, and `/api/events` now returns
      404.
    - The leftover local `presence_api_events/` (untracked build output
      only) was removed.
113. **Create a new SAM module, auth_api, mapped to /api/auth, in Java,
    and add it to the build and deployment. The function takes the user's
    information and returns their roles: none for everyone, except the
    @nu01.com domain, or users present in a DynamoDB table that declares
    roles by email.** (2026-09-27)
    - Added `auth_api/` (now [presence_api_auth/](../presence_api_auth)): a Java 25 Lambda behind an HTTP API
      with a Google JWT authorizer, and a `UserRolesTable`.
    - Roles: `admin` for verified `@nu01.com`, plus the roles the table
      declares for the email.
    - `deploy.sh` deploys it (`presence-auth-api` / `presence-rc-auth-api`)
      before the site, and `site.yaml` routes `/api/*` to it again. The smoke
      test expects 401 without a token.
    - Both deploy roles gained Lambda, API Gateway v2, DynamoDB and SAM
      permissions, the workflows set up Java 25 and SAM, and `aws-sam-cli`
      is back in devbox.
    - 7 JUnit tests pass.
114. **Rename the module to presence_api_auth.** (2026-09-27) Renamed
    `auth_api/` to [presence_api_auth/](../presence_api_auth), with every
    reference (templates, `deploy.sh`, workflows, deploy roles, docs). The
    AWS stacks keep their names (`presence-auth-api`,
    `presence-rc-auth-api`).
115. **When the user is signed in, show events and features only if they
    have a role; otherwise show only their account and a sign-up icon.**
    (2026-09-27)
    - Added `RolesService` (`GET /api/auth` with the ID token; access means
      at least one role; deny by default) and `ApiConfig.baseUrl`.
    - Without a role, the app bar has only a sign-up icon ("Request access",
      "Check again") and the account button: no tabs, no camera buttons,
      and cloud sync stays off.
    - Locally, Floci routes `/api/*` to the deployed auth API
      (`AUTH_API_HOST` in the private `.env`); checked through Floci, no
      token and a forged token get 401.
    - 104 tests pass.
116. **Remove `presence_infra_tenant` if it is unused.** (2026-09-27)
    - Nothing referenced it, and it had no resources. Neither its stack nor
      the CDK bootstrap stack was ever deployed.
    - Deleted `presence_infra_tenant/` and `specs/tenant-infra.md`, and
      removed the AWS CDK CLI from devbox (only the module used it), the
      CDK entries from `.gitignore`, and the CDK row from the README's tool
      table. Maven and the SAM CLI stay, for the auth API.
117. **Where is the auth API I asked for? On sign-in, the auth API should
    say whether the user may use the system or should sign up; by default
    only the `@nu01.com` allowlist domain is accepted. Merge everything
    into main.** (2026-09-27)
    - The auth API (#113–#115) was built but still open in #60 and #61.
      #61 was merged into #60's branch, and #60 into `main`.
    - Then every open PR was merged into `main`, conflicts fixed and tests
      run on each: #63 (with Maven and the SAM CLI kept for the auth API),
      #62, #58 and #57, which became #118–#122. Their request-log entries
      were renumbered after `main`'s, and `cloud_sync_test.dart` keeps both
      the frame-upload and the no-role tests. No open PRs or unmerged
      branches remain; 121 app tests pass on `main`.
118. **Bug: reloading the app forgets the sign-in. Keep an authenticated
    user signed in across reloads.** (2026-09-27)
    - Cause: on web, Google Identity Services keeps no session, and the
      silent FedCM check at launch often finds nothing.
    - The app now remembers the user and ID token in `localStorage`,
      restores them at launch while the token is valid, still refreshes
      silently, and forgets them on sign-out.
    - Verified in headless Chrome: a remembered session survives a reload
      (the tabs show) and stays stored.
    - Unit tests cover encoding, expiry, malformed data, restore and
      sign-out. 103 tests pass.
119. **When the user opens a video event, let them annotate below the
    player a name for the person or pet in the video, stored with the
    event. There can be several people or pets: let users add as many names
    as needed, each at the position they click on the video.** (2026-09-27)
    - Added `ClipAnnotations` (`lib/annotations.dart`): the clip event's
      list of `{id, name, x, y}`, saved in its record and re-saved (and
      synced) on every change.
    - The player dialog gained a People and pets list: add a name by tapping
      its spot on the video, rename, remove, with markers drawn over the
      video (`pointer_interceptor` makes the tap reach Flutter over the
      web's `<video>`).
    - Fixed along the way: the name prompt's controller was disposed while
      its dialog was still closing.
    - 102 tests pass.
120. **Tagging people and pets doesn't work: let users click on a frame and
    add a name, then save the clicked frame, the position clicked and the
    name with the event.** (2026-09-27)
    - Clicks over the web's `<video>` were unreliable. Tagging now works on a
      still frame instead: **Tag this frame** pauses the player and grabs
      the frame (a canvas on the web, `MediaMetadataRetriever` on Android,
      `AVAssetImageGenerator` on iOS, via a new `frameAt` channel method).
      Users click people and pets on that image and name them.
    - Each tag stores its frame's ID and time, its position on the frame
      and its name. The frame JPEGs are stored with the event and synced as
      `clips/<clipId>/frames/<frameId>.jpg`. `pointer_interceptor` was
      dropped.
    - Checked in headless Chrome: a clip taken, a frame tagged, and the tag
      still there after a reload. The Android and iOS debug builds compile.
      104 tests pass.
121. **Tag the person on top of the video instead of below it: ideally just
    by clicking on the video, or with the frame placed over the player.**
    (2026-09-27)
    - A click on the playing video (a long press on phones) now grabs that
      frame, shows it in the player's place and asks the name for the spot
      clicked. More clicks tag more people; Done brings the video back.
      "Tag this frame" does the same without a first click.
    - On the web, a `click` listener on the `<video>` maps the point onto
      the video frame, skipping the controls bar and the letterbox bars.
    - Checked in headless Chrome: a click on the video tagged "Bob" at the
      spot clicked, over the player. 109 tests pass.
122. **Set up the user-data bucket with Intelligent-Tiering.**
    (2026-09-27)
    - `user-data.yaml` gains a lifecycle rule that moves current and old
      versions to `INTELLIGENT_TIERING` on day 0, and the app's `S3Bucket`
      uploads with `x-amz-storage-class: INTELLIGENT_TIERING` (a unit test
      checks it's sent and signed).
    - The opt-in Archive and Deep Archive tiers stay off, since they'd need
      a restore before reads.
    - Applied to both `presence-user-data` and `presence-rc-user-data`; each
      kept its CORS origins.
    - A live upload landed as `INTELLIGENT_TIERING` and was cleaned up.
123. **Fix authentication and authorization: after sign-in, check the auth
    API for a user role. Without it, give no service: just a sign-up button
    that lets the user request membership by sending a message. With it,
    the usual buttons. Only the listed domains have the role for now,
    `nu01.com` alone. Then: make the roles `presence_user` and
    `presence_admin`, give allowed-domain users both, and give admins an
    Admin icon and screen to grant the role to those who asked.**
    (2026-09-27)
    - The auth API's `PrivilegedDomain` became `AllowedDomains` (a list,
      `nu01.com`), and its `DomainRoles` became
      `presence_user,presence_admin` (was `admin`).
    - New `POST /api/auth/membership` (`MembershipHandler`): stores a
      request per email in the new `MembershipTable` (one an hour, else
      409) and publishes it to the new `MembershipTopic` (SNS). The route
      is throttled.
    - New admin routes (`AdminHandler`, users with both roles): list,
      grant (merges `presence_user` into `UserRolesTable`) and dismiss
      (keeps the row, so the cooldown holds).
    - A code review then fixed: grants on list-typed roles, the cooldown's
      time comparison (now epoch ms), SNS failures locking users out,
      dismissals resetting the cooldown, the 409/429 messages, and the
      server's admin rule matching the app's.
    - The app now needs `presence_user` (any role used to do). The sign-up
      sheet sends a message. Admins get an Admin icon that opens the
      "Membership requests" screen.
    - Added [Membership](membership.md). 18 JUnit and 124 Flutter tests
      pass.
124. **Make sure @nu01.com users get in with both roles and every feature;
    other domains must request access and be allowed; the admin panel,
    for admins only, authorizes requests.** (2026-09-27)
    - Confirms #123's rules. Added a JUnit test of the whole flow:
      `boss@nu01.com` gets both roles; `ana@example.com` gets none, asks,
      can't approve herself, is granted by the admin, and ends up
      `presence_user` only (no admin routes). 19 JUnit tests pass.
125. **No need to deploy to RC: make local work with Floci, and test with
    that. Also, the local auth logic is still wrong: review it, so that at
    start the app shows the right navigation for non-users, users and
    admins.** (2026-09-27)
    - Cause: local `/api/*` went to RC's older auth API, which gives
      `@nu01.com` the role `admin` (not `presence_user`), so the app
      offered sign-up.
    - Floci now deploys the auth API into itself at every start
      (`scripts/build-auth-api.sh`, `05-auth-api.sh`): the template's
      Lambdas, tables and topic, plus an HTTP API with the fixed ID
      `presence` and the Google JWT authorizer. CloudFront routes `/api/*`
      to it. `AUTH_API_HOST` is gone.
    - The app's roles check also retries when a check that failed gets a
      new ID token from a silent sign-in.
    - Checked: `/api/auth` answers 401 through the CDN without a token or
      with a forged one; the whole membership flow ran against the Lambdas
      in Floci. 19 JUnit and 126 Flutter tests pass.
126. **Replace "Could not open the camera / TypeError: null: type 'Null' is
    not a subtype of type 'JSObject'" with a human message; if possible,
    check the camera can be opened before trying; fix the null error if
    it's something else.** (2026-09-27)
    - Cause: on a page that isn't secure (plain HTTP on a name other than
      localhost), browsers leave `navigator.mediaDevices` undefined, and
      reading it threw the TypeError.
    - The web backend now checks for a secure page and `mediaDevices`, and
      for an already-denied camera permission, before asking. It turns
      browser errors into sentences (`CameraUnavailable`). The view shows
      only those; anything unexpected reads "Something went wrong while
      starting the camera." and is logged.
    - Checked in headless Chrome: `http://local.presence.nu01.com` shows
      "The camera only works on a secure page. Open Presence over HTTPS.",
      and `http://localhost` opens the camera path as before. 123 tests
      pass.
127. **Sync git, increment the Y version, push an RC tag and a GA tag, and
    verify the workflows and deployments.** (2026-09-27)
    - `version.Y.txt` 2 → 3, so releases are `0.3.<time>-RC` / `-GA`.
128. **Merge it all and pull main.** (2026-09-27)
    - Merged #65 (roles, membership, Admin screen), #66 (the local auth API
      in Floci, retargeted to `main`), #67 (camera errors) and #68 (version
      0.3), resolving request-log conflicts.
129. **On the Settings screen, at the bottom, add the version tag. Push the
    tags, monitor the workflows, test the deployment, and say when it's
    updated.** (2026-09-27)
    - Settings ends with "Presence <tag>" (`AppVersion.label`): the release
      tag in tagged builds, `X.Y.Z` in other builds, "development build" on
      the dev server. `scripts/make.sh` passes `PRESENCE_VERSION`, and
      `PRESENCE_TAG` when `TAG` matches the build's version.
    - Checked: a web build with a test tag had it compiled in. 128 tests
      pass.
    - Pushed `0.3.202609271127-RC` and `0.3.202609271127-GA`. Both Release
      workflows succeeded; both deploys failed creating the auth API's
      `MembershipTopic`, because the GitHub deploy roles had no SNS
      permissions. RC rolled back to its previous auth API; prod's first
      auth API stack ended in `ROLLBACK_COMPLETE`.
    - `github-deploy.yaml` now lets each role manage its own SNS topics
      (`presence-*` / `presence-rc-*`).
130. **Why SNS? Remove it, push the tags and update everything. Then review
    the code and sync git.** (2026-09-27)
    - SNS was only for emailing admins about new requests, which nobody
      had subscribed to. Removed the topic, its publish policy and output,
      the handler's notifier, and the SDK dependency. Admins see requests
      on the Admin screen.
    - Reverted the deploy roles' SNS permissions (#70), deleted the
      unapplied change set, and deleted the empty prod `presence-auth-api`
      stack left in `ROLLBACK_COMPLETE`, so the next deploy creates it.
    - Pushed `0.3.202609271216-RC` and `-GA`. RC deployed (Settings shows
      the tag), but its stack kept the old `DomainRoles=admin` value, so
      `@nu01.com` users would get only `admin`. `DOMAIN_ROLES` is now fixed
      in the template (both roles), with no parameter.
    - The GA deploy failed creating prod's first HTTP API stage: the deploy
      role lacked `apigateway:TagResource`. Both roles now have it (and
      `UntagResource`).
131. **Apply the deploy-role change, merge, push a GA tag, and show it in
    prod.** (2026-09-27)
    - Applied `add-apigateway-tagging` to `presence-github-deploy`. Pushed
      `0.3.202609271247-GA`, and the deploy succeeded. presence.nu01.com
      serves `0.3.202609271247` with the tag compiled in. `/api/auth`
      answers 401 without a token or with a forged one. Test identities:
      `@nu01.com` gets both roles, `@example.com` gets none.
132. **"I asked you to add the version tag on the Settings screen, do it."**
    (2026-09-27)
    - The label existed (#69), but the dev server, where it was being
      looked at, had no version and showed "development build". The dev
      scripts now pass `PRESENCE_VERSION=X.Y-dev` ("Presence 0.3-dev").
    - Found while checking it: a dev server started at 11:58 had survived
      every `devbox services stop`, because process-compose stopped the
      script but not Flutter's `dart` child. It kept serving that build on
      8080, so later restarts never updated the local app. `2-flutter-web`
      now has a shutdown command that kills the port's listener. Checked:
      after start and stop, 8080 is free.
133. **On that version tag, use only the build's X.Y.Z: no -dev.**
    (2026-09-27)
    - The label is now "Presence X.Y.Z" everywhere: no `-RC`/`-GA`
      (`PRESENCE_TAG` is gone) and no `-dev` (the dev scripts pass the full
      `$VERSION`). A build without a version shows no label.
134. **Tag an RC and a GA release, push them, verify the workflows and
    deploys, and wake me when done.** (2026-09-27)
    - Pushed `0.3.202609271306-RC` and `0.3.202609271307-GA`. All four
      workflows succeeded. Both sites serve their version, the label is the
      plain X.Y.Z (no `-RC`/`-GA`), and `/api/auth` answers 401 without a
      token.
135. **When the app loads, load all events from the same user on S3.**
    (2026-09-27)
    - Already the behaviour: at every app start with a signed-in member
      (restored sessions included), `CloudSync` lists the user's S3 folder
      and loads every event and clip the device lacks. The spec said "on
      sign-in"; `cloud-sync.md` now says when it runs, and that it needs
      `presence_user`.
    - Why it looked missing: sync waits for the roles check, and until
      today's deploys prod had no auth API (the check always failed), and
      the local dev server was a stale build.
136. **Sync git, make main and local the same, merge any branches and PRs,
    review the specs, and run every test and check.** (2026-09-27)
    - No open PRs and no unmerged branches; local `main` matches `origin`.
      Deleted the merged local branches.
    - Checks: `flutter analyze` (clean) and `flutter test` (128),
      `mvn test` (18), `sam validate --lint`, `validate-template` on the
      four `presence_infra` templates, `bash -n`/`sh -n` on every script,
      release dry runs, and the workflow and compose YAML all passed.
    - Specs: every file is indexed. Fixed a stale Android source link and
      the cloud-sync timing.
137. **On the user-data bucket, add a policy that deletes data older than 3
    months.** (2026-09-27)
    - `user-data.yaml`: a lifecycle rule expires every object 90 days after
      it was written. Old versions are still removed 30 days later (the
      undo window), so data is gone after about 120 days. Another rule
      removes the leftover delete markers.
    - It applies to `presence-user-data` and `presence-rc-user-data` on the
      next deploy of each (`scripts/deploy.sh` step 1).
138. **Estimate six months of S3 storage costs for one 30 s clip every 10
    minutes, with three viewed a day.** (2026-09-27)
    - About $11 per user over six months, and about $2.30 a month once the
      bucket holds ~120 days (~173 GB). Flagged: a new device downloaded
      everything.
139. **When restoring to a new device, load only one week of data.**
    (2026-09-27)
    - `CloudSync` fetches only events from the last 7 days
      (`restoreWindow`), skipping older day partitions without downloading
      them, and only the clips those events use. 129 tests pass.
140. **Merge all pending PRs.** (2026-09-28)
    - Merged #77 (3-month expiry) and #78 (one-week restore), resolving
      the request-log conflict.

## 2026-10-01

141. **Rewrite the README.** It still described the `blank-devbox`
    template. Now it covers: what Presence is (tracking what happens in a
    private place); a notice to check that local law allows recording
    there; the technology and main libraries; running locally with devbox;
    running on Codespaces; deploying to AWS (`*RC*` tags to
    https://rc.presence.nu01.com, `*GA` tags to production at
    https://presence.nu01.com); and contributing (welcome, deployed
    automatically). The request named `hu01.com`; the README uses the
    deployed `nu01.com` domains. The badges now point to `prodbytes/presence`.
    [dev-environment.md](dev-environment.md) describes what the README
    covers.
142. **Remove the README's private-settings paragraph.** (2026-10-01)
    - Dropped the note that maintainers keep `.env` and `env.local/` in the
      private `setec-astronomy` repo, with its clone and
      `link-private.sh` commands. The setup is unchanged and still
      described in [dev-environment.md](dev-environment.md).
143. **Add brief instructions for getting a Google account and OAuth
    clients, setting up the AWS CLI for the other variables, and what each
    variable is for.** (2026-10-01)
    - The README has a new **Settings** section: a table of every `.env`
      variable (purpose, source); Google OAuth steps (consent screen, web,
      iOS and Android clients); and AWS steps (account, `aws configure`,
      deploying `presence-user-data` and `presence-identity`, reading their
      outputs, finding the hosted zone ID). Step 2 of the local run links
      to it.
144. **Add a deploy-to-Floci section to the README.** (2026-10-01)
    - New **Deploy to Floci** section, before Deploy to AWS: what
      `devbox services up` deploys (the auth API stack and the CloudFront
      distribution), the steps, redeploying with
      `devbox services restart 4-floci`, and AWS CLI commands to inspect
      it. Checked locally: the stack reported `CREATE_COMPLETE` before
      and after a restart, the distribution listed both aliases, `/app/`
      answered 200 and `/api/auth` 401 over HTTPS.
145. **Make the guide cover creating the OAuth keys and getting AWS access
    before deploying or starting the dev environment.** (2026-10-01)
    - The README's setup is now **Before you start**, placed before
      running and deploying: 1. code and tools, 2. Google OAuth clients,
      3. AWS access and the cloud-sync stacks, 4. the variable table.
      "Run it locally" is just `mkcert -install` and
      `devbox services up`. Codespaces, Deploy to Floci and Deploy to AWS
      link back to it.
146. **Start the app by asking the auth API for the execution mode: DEV
    without OIDC settings (every role for the anonymous user, every feature
    but the account ones, a discreet "dev" label), RBAC with them
    (anonymous may only sign in, then roles as before).** Later in the same
    request: **use S3 and Cognito only when their variables are set, and show
    the API, AWS and OIDC health under the version in Settings.**
    (2026-10-01)
    - Auth API: `ExecutionMode` (DEV when `GOOGLE_WEB_CLIENT_ID` is empty),
      role `presence_anonymous`, and the public, throttled
      `GET /api/auth/anonymous`. `GoogleWebClientId` may be empty (DEV
      authorizer audience `no-oidc-client`). The Floci hook deploys the API
      without a client in DEV, with only that route. `deploy.sh`'s smoke
      test requires RBAC.
    - App: a spinner until the mode is known; falls back to DEV only
      without a client ID of its own. DEV shows all tabs and camera
      buttons, hides sign-in, account, sign-up and Admin, labels the title
      "dev", and never syncs. New [execution-mode.md](execution-mode.md).
    - S3 and Cognito were already used only with both IDs set; now
      specified, and shown in the new Settings health line
      (`🔌 API · ☁️ AWS · 🔑 OIDC`).
    - 22 Java and 133 Flutter tests pass; checked live in DEV through
      Floci and Chrome.
147. **Define devices, users and places (device groups). Give each device
    a funny, collision-resistant ID (`adjective_adjective_thing`, such as
    `automatic_paranoid_gadget`) on first load; add the device ID and the
    user ID to every event; when a user signs in, let them own the events
    recorded anonymously on the device, so none are lost (3 grabs signed
    out + 2 after = 5 events). Show the device ID discreetly under the
    version in Settings, and a discreet emoji health check for API, OIDC
    and AWS that asks the auth module whether the expected settings are
    set.** (2026-10-01)
    - New [devices-users-places.md](devices-users-places.md). `DeviceId`:
      1053 adjectives × 1052 × 1091 things, about 1.2 billion IDs, made
      with `Random.secure()` and kept in the `settings` store (`device`).
    - Events carry `deviceId` and `userId` (the Google ID, or
      `anonymous`). A sign-in, or a session restored at launch, takes over
      the anonymous events (`Persistence.claimAnonymous`). Cloud sync now
      uploads only the signed-in user's events and their clips.
    - Places are defined but not built (no place ID yet).
    - Auth API: `GET /api/auth/anonymous` adds
      `"settings": {"oidc": …, "aws": …}` (`Settings`; new template
      parameters `IdentityPoolId` and `UserDataBucket`, passed by
      `deploy.sh` and, from `.env`, by the Floci hook). The deploy smoke
      test requires both set.
    - Settings: the device ID under the version; the health line compares
      the API's settings with the build's own (⚠️ when they disagree).
    - 23 Java and 142 Flutter tests pass; the local API answered with its
      settings live through Floci.
148. **Commit the `.gitignore` change.** (2026-10-01)
    - `.env.*` is ignored, so copies like `.env.ga` stay out of git;
      `!.env.example` keeps the committed template tracked.
149. **Make the Codespaces link in the README default to 4 cores.**
    (2026-10-01)
    - The badge URL adds `?machine=standardLinux32gb` (4 cores, 16 GB), and
      Codespaces step 1 says so and how to pick 4-core by hand.
150. **Review the dev container so the system works on a new GitHub
    Codespace, and fix what's needed.** (2026-10-01)
    - `devbox install` failed: Nix got HTTP 403 from api.github.com
      (unauthenticated rate limit). New `.devcontainer/post-create.sh`
      passes the codespace's `GITHUB_TOKEN` to Nix (`NIX_CONFIG`), in
      post-create and every shell, without writing the token to disk.
    - Floci couldn't reach the dev servers in docker-in-docker: they bound
      127.0.0.1. `PRESENCE_BIND_HOST` (0.0.0.0 in the dev container).
    - The auth API's arm64 Lambdas wouldn't run on x86_64 Codespaces: a
      template `Architecture` parameter, set from the host by the Floci
      hook (AWS stays arm64).
    - `local-certs.sh` also regenerates a certificate from another
      machine's mkcert CA.
    - Pinned devbox 0.18.1 and Nix 2.35.0 (checksummed installer), locked
      the docker-in-docker feature, added `lsof` (used to stop the web
      server), `hostRequirements` (4 cores, 16 GB), and fixed the stale
      `/workspaces/blank-devbox` workdir.
    - Verified with the Dev Containers CLI on an arm64 Mac; not run on an
      x86_64 Codespace.
151. **Merge all pending PRs to main.** (2026-10-01)
    - Merged #88 (4-core Codespaces link), then merged `main` into #87
      (`codespaces-fixes`) and merged it. Conflicts resolved: the README's
      Codespaces steps keep the 4-core link and mention `post-create.sh`;
      the auth API template keeps `IdentityPoolId`, `UserDataBucket` and the
      optional `GoogleWebClientId`, plus `Architecture`; the Floci hook
      passes all four parameters. Request 148 (dev container) is renumbered
      150, after main's entries.
152. **Merge all pending PRs, and say in the README that without OIDC
    authentication is disabled and the anonymous user gets all access, and
    that without the AWS settings no events are shipped to S3.**
    (2026-10-01)
    - Merged #84 and #86, then #80–#83 and #85, resolving their
      request-log numbering (142–148). #87 and #88 were merged separately
      (entry 151).
    - README "Before you start": a warning with both consequences, and a
      pointer to the Settings health line that shows them.
153. **Check the health logs and fix the issues (the web app's CDN and
    HTTPS checks failing).** (2026-10-01)
    - Cause: the Floci container was stopped by a `devbox services stop` in
      another checkout (its `docker compose down` shares the project), and
      `4-floci` ended with exit code 0, so `restart: on_failure` never
      brought it back. The web app itself stayed up.
    - Restarted `4-floci` in the running instance; every check went ✅.
    - `4-floci` now has `restart: always`.
154. **Review the health check script: print one line per check, every
    15 s, checking the API, AWS and the rest.** (2026-10-01)
    - `scripts/health-check.sh` now prints one timestamped line per check
      with a reason, and adds `🔌 api` (the local auth API's mode),
      `🔑 oidc` and `🪣 aws` (whether the API reports their settings set).
    - README example and [dev-environment.md](dev-environment.md) updated.
155. **Add a "Device" navigation target that opens a map with the device's
    location, as close as possible; let the user override the location by
    repositioning the map; send the device's position on events too.**
    (2026-10-01)
    - New Device tab between Events and Settings: an OpenStreetMap map
      (`flutter_map`) with a fixed center pin, a card with the device ID,
      coordinates and source, and a My location button. Swiping between
      tabs is off there, so drags move the map.
    - The device's position comes from `geolocator` at best accuracy, read
      at launch (Android and iOS location permissions added). Moving the
      map sets the location by hand; it's kept across restarts until My
      location.
    - Every event gets `location` (`lat`, `lng`, `accuracy`, `source`,
      `time`) when it's published, in storage and the cloud JSON. New
      [device-location.md](device-location.md).
    - 151 Flutter tests pass; web release builds. Not tried on a device or
      in a browser with real positioning.
156. **On the map, label the device ID as a device ID and the position as
    a position, and add zoom in and out controls.** (2026-10-01)
    - The Device tab's card labels "Device ID" and "Position (latitude,
      longitude)".
    - Zoom in / Zoom out buttons above My location step the zoom around the
      center (2–19), turning off at their limits.
157. **When a device ID is generated, before the UI is shown, check for a
    consent verification hash for the device. Without one, ask for consent:
    that the user has the right to record, and that face data is biometric
    data under the GDPR, explained in plain terms. Once collected, don't
    ask again.** (2026-10-01)
    - New [consent.md](consent.md): `DeviceConsent` (a `consent` settings
      record with the device ID, text version, time and a SHA-256
      verification hash) and `ConsentScreen` (two ticks, then **Agree and
      start**).
    - At launch the app checks the consent before anything shows. The
      cameras open only once it's given or found. Agreeing saves it and
      publishes a "Recording consent given" event.
158. **Add a "Subjects" navigation screen listing the identified subjects,
    each with a frame captured on the last event with that subject; a
    line opens a "Subject" screen with a map and a dot per event with the
    subject, the most recent fully opaque and older ones more transparent;
    by default the last 20 events, configurable in Settings.** (2026-10-01)
    - New Subjects tab between Events and Device: one card per tagged name
      (matched ignoring case), most recently seen first, with the frame
      from their latest event and a dot where they were clicked, when
      they were last seen and how many events they're on.
    - Tapping a card opens the subject's screen: an OpenStreetMap map with
      a red dot at each event's location, fading from 100 % (newest) to
      15 % (oldest shown), fitted on the dots; under it, the events, which
      play their clip when tapped.
    - New Settings section, **Subjects**: "Latest events on a subject's
      map", 5–100, default 20 (`SubjectsConfig.mapEvents`, stored with the
      config).
    - With five tabs, an admin's app bar overflowed a 320 dp phone; the
      tabs now narrow (down to 40 dp) only where they don't fit.
    - New [subjects.md](subjects.md). The OpenStreetMap tiles and credit
      are shared with the Device map (`lib/location/map_parts.dart`).
159. **On a subject's map, show one color per device and opacity per age
    on the tracking dots per event.** (2026-10-01)
    - Built (a color per device, with a device legend), then replaced by
      request 161 before it merged.
160. **When a user clicks an event on the map, open it in the Events tab.**
    (2026-10-01)
    - Tapping a dot closes the subject's screen, switches to Events, scrolls
      to the event and outlines it for 4 s. Done in the same PR as 159,
      since both change the subject map's dots.
161. **Change it: make the color always match the subject, and the opacity
    the age; never mind the device ID here.** (2026-10-01)
    - Each subject has one color (`Subject.color`), picked from its name
      among Gruvbox's seven accents, so it's the same everywhere: every
      dot on its map, and the dot on its frames in the Subjects list and
      under the map. Opacity still runs from 100 % (newest) to 15 %
      (oldest).
    - The device colors, the device legend and the device ID in the event
      list are gone. A dot's tooltip gives its time and camera.
    - 169 Flutter tests pass; the web release builds.
162. **On top of the Subjects page, put a map merging all events, each
    subject identified by a color, with a square of that color on the
    subject's line for reference.** (2026-10-01)
    - The Subjects tab now opens with a map of every subject's latest
      located events, each dot in its subject's color and faded by age; a
      clip with several subjects gets a dot for each, and tapping one
      opens its event. Each subject's row has a matching color square
      before the name.
    - The subject screen's map and the new one share one map widget.
163. **Make the consent shorter: one click to agree, with the two
    conditions highlighted.** (2026-10-01)
    - The consent screen drops its checkboxes and long sections: the two
      conditions (the right to record; faces as biometric data under the
      GDPR, and the user's responsibility) are highlighted boxes with a
      bold statement and one plain line each, and **I agree** accepts.
    - [consent.md](consent.md) updated. The consent version stays 1: what's
      agreed to is the same, so devices that agreed aren't asked again.
164. **Codespace creation still fails; the pasted creation logs were cut
    off before the error.** (2026-10-01)
    - Every log stopped inside the image build's Nix step, which listed and
      copied ~800 store paths (3.5 GiB download, 9.8 GiB unpacked). The
      error itself was never visible.
    - The image no longer fills the Nix store. `post-create.sh` does it,
      quietly, then `devbox install`; a failure names the step and prints
      the free disk space. A failure there still opens the codespace with
      a terminal.
165. **At start and every 15 s, re-sync events with S3: upload the ones only
    on the device, download the ones only in the user's folder, at most two
    weeks or 1000 of them, then update the Events and Subjects tabs, so
    every device shows the same user data as S3.** (2026-10-01)
    - `CloudSync` now fetches on every pass, not once per sign-in, and
      passes run every 15 s (was a minute). The window is 14 days (was 7),
      with at most 1000 events per pass, the newest first.
    - Listings stay small: all of `events/` on a user's first pass, the
      whole window once an hour, and otherwise only today's and yesterday's
      partitions. A new remote event's clip is found by listing only its
      own keys. `CloudSession.list` takes a prefix.
    - Downloaded events join the event log, so both tabs update at once.
166. **On the Events tab, show only this device's events by default, with a
    checkbox at the top to see all devices.** (2026-10-01)
    - `EventTimeline` takes the device ID and an "Only this device"
      checkbox (a `ValueNotifier` kept by `HomeScreen`, so it survives tab
      switches), on at launch. Events without a device ID yet count as
      this device's. Opening another device's event from a subject's map
      clears it.
    - New `events_filter_test.dart`: filtered at launch, all after
      clearing, kept across a tab switch, and a new event shows before
      it's saved. 173 Flutter tests pass. Opening another device's event
      isn't covered by a test.
167. **Add a battery charge indicator to the Device screen, if possible,
    using open web APIs or a Flutter alternative.** (2026-10-01)
    - The Device tab's card has a **Battery** line: the charge, whether
      it's charging, full or on battery, a matching icon, and a warning
      below 15 %. "Not available in this browser" where there's no
      reading.
    - Read through `battery_plus` (Android, iOS, and the web's Battery
      Status API, which Firefox and Safari lack), when the tab opens, when
      charging changes and every minute. Not stored or sent.
    - 173 Flutter tests pass; web release, Android debug and iOS debug
      builds compile. Numbered after #99's 165.
168. **Make sure settings are persistent per device; store them on S3 as
    well, if S3 is available, or else use the local database. When the app
    starts and the device ID is determined, fetch its settings or
    initialize them with the defaults.** (2026-10-01)
    - The settings record now carries `updatedAt`, when the user last
      changed it, and stays in the local database as before.
    - With S3 available, it also goes to
      `<identityId>/devices/<deviceId>/settings.json`. The first sync pass
      after start fetches it, and the newer of the two wins. Every change
      is uploaded. A device with no record starts with the defaults and
      uploads them.
    - Without S3, only the local database is used.
    - 181 Flutter tests pass; the web release builds.
169. **Make the device info panel align to the top left.** (2026-10-01)
    - The Device tab's info panel (device ID, position, battery, source)
      now sits in the map's top-left corner, as wide as its content (at
      most 560 px), instead of centered across the top.
    - 181 Flutter tests pass.
170. **On a grab, regardless of source, capture the preview with the past
    seconds and show it at once; after the configured seconds, capture the
    final clip with the total duration, so it's always full and correct and
    no videos are joined. Always show the full clip, or the preview until
    it exists.** Later: **trimming every 5 seconds is fine.** (2026-10-01)
    - Recording already made the preview and the full clip as separate
      recordings on every platform. The players joined them, playing the
      preview and then continuing into the full file. Now the preview plays
      alone, labelled "Preview", and the full clip replaces it as soon as
      it's recorded, at the same moment.
    - Web files weren't the clip's length: the full clip came from the
      oldest recorder, with up to 2 × *before* of history. Chosen fix (of
      trimming at keyframes, re-encoding, or player only): recorders ask for
      a keyframe every 5 s, and `cutWebm` cuts each file to its window
      without re-encoding, stating its duration.
    - Tests: `webm_trim_test.dart` (a Chrome-like file: cut from the
      keyframe before the window, frames once each, duration stated,
      across a non-keyframe cluster break, cut twice, garbage left alone);
      pool tests for the trimmer (preview and full, one call for shared
      holds, a failed cut keeps the file). 188 Flutter tests pass.
    - Checked with a real 20 s recording from headless Chrome's fake camera:
      keyframes came at 0, 5, 10.05 and 15.05 s; a 7–17 s cut started at
      the 5 s keyframe, ffmpeg decoded its VP8 and Opus cleanly, and Chrome
      reported 12 s, seeked to 2 s and played. Not tried by pressing Clip in
      the running app.
171. **Automatically trigger a grab every 240 minutes (configurable from
    half an hour to daily in Settings), like the others, through the same
    pipeline.** Then, in the same request: **also take one when the app
    starts.** (2026-10-01)
    - New [scheduled-clips.md](scheduled-clips.md): `ScheduleConfig`
      (`enabled`, `every`: 240 min, 30 min–24 h) and a **Scheduled clips**
      Settings section. `CameraRig` takes a **startup clip** once the
      camera has a full "before" part, then a **scheduled clip** every
      interval from the last one, both through `requestClips` (triggers
      `startup` and `scheduled`).
172. **Push all changes, sync git, update Y and push an RC tag.**
    (2026-10-01)
    - Merged #103, #104, #105 and #102 (renumbering their request-log
      entries 168–171), with the analyze and tests run on each merge.
    - Y is now 4 (`version.Y.txt`): versions are `0.4.Z`.
    - Tagged `main` as an RC with `scripts/release-rc.sh` (`0.4.<Z>-RC`),
      which publishes the prerelease and deploys to
      https://rc.presence.nu01.com.
173. **Add the temperature in Celsius to the Device screen, if Flutter can
    get it.** (2026-10-01)
    - Flutter has no temperature API, and neither do browsers or iOS (only
      a thermal state there). Android reports the battery's temperature, so
      the Device panel shows "Battery temperature: 31.5 °C" on Android,
      hot (error color) from 45 °C, and nothing elsewhere.
    - Read through a new `presence/device` channel in `MainActivity`, with
      each battery reading (at open, on charging changes, every minute).
    - 202 Flutter tests pass; Android debug and web release builds compile.
      Not yet read on a phone.
174. **Merge the Events and Subjects screens into "Monitoring": on top, to
    the left, the map with all subjects and clickable events; on top, to the
    right, the subjects, one card each, opening the subject's map and
    history; below the map, all events, by default only this device's, with
    a checkbox for all.** (2026-10-01)
    - New Monitoring tab (`MonitoringView`) in place of Events and Subjects,
      between Camera and Device. Wide screens (720 dp+): the map top left
      with the events under it, the subjects down the right (340 dp).
      Phones: the map, a sideways strip of compact subject cards, then the
      events. Swiping between tabs is off on it, as on Device.
    - `SubjectsView` split into `SubjectsMap` and `SubjectList`. A tapped dot
      scrolls this tab's events to its event, as before.
    - New [monitoring.md](monitoring.md); the other specs updated. 202
      Flutter tests pass; web release builds.
175. **Disband the Device screen as well: make the position label and map a
    section of Settings, make Settings full width (it already shows the
    device ID), and move the battery indicator over the camera screen, to
    the left, in the same style as the readiness indicator, which moves to
    the left as well.** (2026-10-01)
    - Settings is full width and has a **Location** section: the labeled
      position and its source, then the map (40 % of the screen's height,
      200–320 px) with the pin, zoom and My location buttons. A drag on
      the map moves it, not the list or the tabs. The device ID isn't
      repeated there.
    - Over the camera, bottom left: battery, temperature (Android) and
      readiness pills, one style. In a row level with Flip and Clip on
      wide screens; stacked above the buttons' row on phones, so they never
      touch them.
    - With Monitoring (174) merged first: three tabs, Camera, Monitoring
      and Settings. App-level tests now run with a blank map layer and a
      locator that fails at once, so Settings' map settles. 204 Flutter
      tests pass; web release and Android debug builds compile.
176. **The Monitoring screen is broken: make the first row the map (left)
    and the subjects (right), and the second row the full width for the
    event cards.** (2026-10-01)
    - Wide screens: the map and the subjects (340 dp) share the top row
      (two fifths of the height), and the events fill the full width
      below. Phones stay stacked.
    - The clip card was stretching its thumbnail across the whole width
      (the video filled the screen): from 600 dp on, the 16:9 thumbnail
      (320 dp) now sits beside the details.
177. **If the dev tag is shown, show the version in it.** (2026-10-01)
    - The "dev" label next to the title reads "dev 0.4.<Z>" when the build
      has a version (just "dev" without one), and is cut short with an
      ellipsis where there's no room.
178. **Change the Monitoring screen: only two columns, the map and then the
    events; each event shows its subjects and their colors.** Then, in the
    same request: **on the map, label each subject's newest (full opacity)
    dot with their name; move the checkbox to the top of the page; add some
    padding and width control, make it look nice.** (2026-10-01)
    - Monitoring: the map (rounded, outlined) on the left, the events on
      the right (two fifths of the width, 360–520 dp); on phones the map
      (35% of the height) above the events. 16 dp padding and gap (12 on
      phones), the page centered past 1600 dp. The subjects list is gone.
    - Clip cards list their subjects, each after a square in their color
      (`EventSubjects`).
    - The map labels each subject's newest located dot with their name, in
      a pill edged in their color; tapping it opens the subject's screen.
    - "Only this device" is a filter chip at the top of the tab
      (`ThisDeviceOnly`), out of the timeline.
    - 212 Flutter tests pass; web release builds.
179. **Make the map and position the first setting in Settings.**
    (2026-10-01)
    - The Location section (position and map) is now the first in
      Settings, above Camera; the version, device ID and health lines stay
      at the bottom.
    - Tests that used sliders further down now scroll to them. 212 Flutter
      tests pass.
180. **Every time a clip is grabbed, detect whether it contains any
    subject, with the best technology for each platform (TensorFlow, with
    TensorFlow.js and Dart): recognize all subjects on the event, on the
    first frame each appears.** Answers: above a configurable threshold,
    tag automatically; with low confidence, emit an event asking the user
    to tag; people by face with appearance as the fallback; web first,
    then mobile. (2026-10-01)
    - New [recognition.md](recognition.md): new clips are sampled every
      0.5 s once recorded; EfficientDet-Lite0 finds people, cats and dogs,
      BlazeFace and MobileFaceNet embed faces, MobileNetV3 embeds looks;
      each is compared with the subjects' references (their latest vouched
      tags' frames). From 80 % (Settings) a recognized tag, from 50 % a
      suggestion and a "Is this Rex?" event with Yes / No.
    - The same `.tflite` models on every platform, decoded and matched in
      shared Dart; on web through TensorFlow.js (`tfjs-tflite`), served
      with the app. Android and iOS come in the next PR.
    - Tags have a source (manual, detected, suggested, confirmed) and a
      confidence; suggestions aren't tags until confirmed. A Recognition
      section in Settings.
    - 233 Flutter tests pass, plus 3 in Chrome with the real models and a
      real `MediaRecorder` WebM; web release builds.
181. **Increase the font size of the dev tag.** (2026-10-01)
    - The "dev" label's text is 14 sp (`labelLarge`, was 11 sp
      `labelSmall`), with a little more padding (8 × 2 dp). It still cuts
      short with an ellipsis where there's no room.
182. **Add a "show system events" flag in the monitoring view: default true
    in dev mode and false in other modes; marked, show all events,
    including application started and system events; unmarked, only grab
    events.** (2026-10-01)
    - A **Show system events** filter chip sits next to Only this device at
      the top of Monitoring. Off, the timeline shows only grabs
      (`ClipRequested`: by hand, on motion, scheduled, at start) and the
      recognition suggestions about them ("Is this Rex?"); on, every
      event. It starts on in DEV and off in RBAC, and keeps its state
      across tabs.
    - Off with only system events, the timeline says "No grabs yet: system
      events are hidden". Opening a hidden event from elsewhere turns it on.
    - Tests that look for system events in RBAC turn the chip on first
      (`revealSystemEvents`). 215 Flutter tests pass.
183. **Make the status message a pill beside the readiness pill instead of a
    separate line.** (2026-10-01)
    - The "Clip started · saving the next 15 s" message (and its motion,
      scheduled and startup forms) is no longer a snackbar along the
      bottom: it's a pill with the clip's icon beside the readiness pill,
      for 4 s, on the Camera tab. Tapping it opens Monitoring (it was the
      snackbar's View).
    - On phones the readiness and the message share the stack's lowest
      line; on wide screens the row keeps clear of Flip and Clip. Pills cut
      long labels short with an ellipsis.
    - 214 Flutter tests pass (2 new: the pill's place at 320 and 1280 dp).
184. **In the camera view, make messages show as a pill beside the
    readiness pill, to the right, at the bottom, so they don't move or
    cover other components.** (2026-10-02)
    - Every message on the Camera tab is now that pill (`CameraMessage`):
      the clip messages (from #183) and "Sign-in failed: …", which was
      still a snackbar (it pushed Flip and Clip up). A newer message
      replaces the shown one; each stays 4 s. On other tabs the sign-in
      error is still a snackbar.
    - Added to the same PR as #183, with `main` merged in.
    - 237 Flutter tests pass (new: the sign-in error as a pill; a message
      leaves the readiness pill and Clip where they were).
185. **A QR code sharing function: last in Settings, an icon with a Share
    button and a QR code, to open the app (or the site, without the app) on
    another device as a new device, with a new device ID, of the same user;
    unauthenticated, sign in, checked to be the same user.** (2026-10-01)
    - Settings ends with **Add a device**: a dialog with a QR code of
      `<app>/?from=<device ID>&user=<user code>`, Share (the system's share
      sheet, or a copy) and Copy link. The user code is a short SHA-256 of
      the Google account ID, so the link has no account ID or token.
    - A device opened with the link keeps its own device ID and shows a
      banner: sign in with the account that shared it; another account
      (with Sign out); or this is the sharing device. The same user joins,
      with a message; the web address drops the link's query.
    - Android: an App Link intent filter for the site's `/app` hands links
      to the app (`app_links`); it needs an `assetlinks.json` (the release
      key's SHA-256) to open them without asking. iOS opens the site.
    - Added `qr_flutter`, `share_plus` and `app_links`. 220 Flutter tests
      pass; the web release and an Android debug APK build.
    - Spec: new [Add a device](add-device.md).
186. **Merge (recognition on web, #119) and start Android.** (2026-10-02)
    - Merged #119.
    - Recognition on Android: LiteRT through `tflite_flutter` (the same
      models, a background isolate each), and a new `framesAt` channel
      method reading many frames of an MP4 with one
      `MediaMetadataRetriever`. The Settings switch works there now.
    - The root Gradle build pins `tflite_flutter`'s Kotlin to JVM 11 (its
      Java target).
    - New on-device integration test, run on an Android 15 emulator: the
      same face scores as on web, `framesAt` on an MP4, and a clip where
      Grace Hopper appears at 1 s tagged on the 1.0 s frame. 233 Flutter
      tests pass; web, Android debug and release, and iOS (unsigned) build.
    - iOS now builds through CocoaPods (`tflite_flutter` ships its
      `TensorFlowLiteC` that way): `Podfile`, `Podfile.lock` and the Xcode
      project's Pods.
187. **Besides the "Tag" button, in the event player screen, add an "Auto"
    button that tries to tag automatically based on known subjects (people
    and pets), client side only.** (2026-10-02)
    - The player has **Auto** (✨) beside **Tag this frame**: it runs
      [recognition](recognition.md) on the clip shown, on the device, even
      on restored clips and with recognition off in Settings, and says who
      it tagged, who it asked about, or why it found no one. Disabled
      where recognition can't run (Android, iOS).
    - `SubjectRecognizer.recognizeNow` queues a run after any in progress
      and returns a `RecognitionResult`; `SubjectRecognizerScope` gives the
      player the app's recognizer. The title and buttons wrap on narrow
      dialogs.
    - 238 Flutter tests pass; web release builds.
188. **Merge (#120, recognition on Android), clean, update Y, rebuild.**
    (2026-10-02)
    - #120 was already merged. Removed the recognition worktree and the
      merged branches.
    - Y is now 5 (`version.Y.txt`): versions are `0.5.Z`.
    - Rebuilt from `main` after `flutter clean`: `make` (web, Android
      release APK, iOS unsigned), and the dev services restarted.
189. **Sync git: merge all pending PRs and check out main; wait for all
    agents to be done and sync again.** (2026-10-02)
    - Merged #116, #117, #118 and #115, then, once the other sessions were
      idle, #120 and #121, each after merging `main` into it, resolving
      conflicts (request-log numbers, now #181–#187; `pubspec`; the app
      root, with both the recognizer scope and the join link), and passing
      the tests (253 at the end) and builds.
    - Recognition suggestions ("Is this Rex?") count as grabs, so they
      show with Show system events off.
    - #112 (an earlier Monitoring layout, replaced by #113) stays open,
      not merged.
190. **Make the QR code appear at the end of Settings, no need for a popup:
    show the QR code, link and Share button at the end of Settings.**
    (2026-10-02)
    - The Add a device button and its dialog are gone: the end of Settings
      shows an **Add a device** title, the QR code, the explanation, the
      link, and **Copy link** and **Share** in place
      (`AddDeviceSection`).
    - 253 Flutter tests pass; web release builds.
191. **On the Settings panel, put the location beside the map, to the
    right, so that scrolling doesn't hit the map.** (2026-10-02)
    - The Location section is a row: the map on the left, and to its right
      the position (label, coordinates, where it came from) in a column 36 %
      of the width (120–320 px). A drag on that column scrolls Settings; the
      map still takes drags on itself.
    - The "Settings is full width" test became a check of the new layout at
      360 and 1280 px, with a drag beside the map that scrolls the list.
      254 Flutter tests pass.
192. **After a clip is fully recorded (before + after), run the recognition
    pipeline to identify subjects: same rule, first frame matching only, no
    duplicates.** (2026-10-02)
    - New clips were already searched, but each was queued the moment it
      was published and then waited in the queue for its "after" part, so
      a clip still recording held up the others and the player's Auto. Now
      a new clip is queued only once its full recording is saved.
    - Same rules as Auto: a subject is tagged (or asked about) once, on the
      first frame they're found on; subjects already on the clip are
      skipped. A new clip already searched with Auto while recording isn't
      searched again.
    - Two new recognizer tests drive it through the event bus with a clip
      still recording. 256 Flutter tests pass.
193. **The recognition pipeline must have two segments, one to identify
    subjects (people and pets) and another to identify tags (human, cat,
    dog, bicycle, bottle). Subjects have identity (person Julio, dog Fido);
    tags are just for future search (videos of cats and bicycles).**
    (2026-10-02)
    - Recognition now runs two segments on the same frames and the same
      EfficientDet pass: **subjects** as before, and **object tags**: every
      one of the detector's 80 COCO labels (`person` named `human`) scoring
      0.5 or more, each kept once per clip from the first frame it's seen
      on, over the whole clip. They need no references.
    - Stored with the clip as `objectTags: [{label, ms, score}]` (absent
      until searched), synced with its event, shown as chips on the clip's
      card. A clip already searched for objects isn't searched again.
    - Settings: **Tag objects in new clips** (default on,
      `recognition.objects`). Auto also tags objects on clips without them
      and says "Also saw: cat, bicycle."
    - `Vision.analyse` returns a `FrameAnalysis` (subjects seen, objects);
      once every subject is found, frames only go through the detector.
    - 262 Flutter tests pass (6 new), the real-model Chrome tests pass (the
      Hopper frame gets `human`), and the web release builds. The Android
      integration test is updated but not rerun.
194. **Add a search bar on top of the events page, top left, beside the
    checkboxes.** (2026-10-02)
    - A **Search events** field (`EventSearch`, 220 dp, with a search icon
      and an x to clear) leads the Monitoring tab's filter row, before Only
      this device and Show system events; the row wraps on narrow phones.
    - Typing filters the timeline live, case-insensitive, on each event's
      title, detail, camera label and, for clips, the names tagged on them
      (not unconfirmed suggestions). It combines with the chips, says
      `No events match "<text>"` when nothing matches, keeps its text
      across tabs, and clears itself when an event it hides is opened from
      a map. The fields searched live in one function,
      `eventSearchFields` / `eventMatches` in `lib/events.dart`.
    - New `events_search_test.dart` (5 tests). The subjects test that opens
      a far-down event now runs at 400 x 900, since the field adds a row to
      the phone header. 267 Flutter tests pass (after merging #126 and #130); web release builds.
195. **Create a script to `curl | sh` that downloads, extracts and runs the
    right Presence app; fall back to web if no native one works.**
    (2026-10-02)
    - Added [scripts/install.sh](../scripts/install.sh) (POSIX `sh`): the
      latest GA's Linux bundle for x64 or arm64, sha256-checked when the
      release API answers, kept in `~/.local/share/presence/<tag>/` and run;
      otherwise, or when the download, the libraries, the display or the
      app fail, it opens https://presence.nu01.com. See
      [Install script](install-script.md); the README shows the command.
    - Tested in Ubuntu 24.04 amd64 and arm64 containers (native run under
      Xvfb, cache reuse, missing libraries, no display, no arm64 asset).
196. **Fix conflicts and merge** (#126, #130 and #128). (2026-10-02)
    - Merged in request order: #126, then #130 after merging `main` into
      it (in the recognizer, a new clip already searched with Auto skips
      only the subjects' segment; object tags still run if it has none),
      then #128 (its request-log entry renumbered #194). 267 Flutter tests
      pass on the result; web release builds.
197. **Make the search work with object tags, then sync everything.**
    (2026-10-02)
    - The Events search also matches a clip's object tags ("bicycle" finds
      the clips with a bicycle).
    - While searching, the list matches again when a clip's tags or object
      tags change, so a clip recognition tags after the search was typed
      shows up then (this was a known limitation).
    - 268 Flutter tests pass; web release builds.
198. **Make the GitHub Actions build both arm and x86 Linux, and the release
    have them both.** (2026-10-02)
    - The release workflow's `linux` build runs twice: x64 on
      `ubuntu-latest` and arm64 on `ubuntu-24.04-arm`, since Flutter
      doesn't cross-compile Linux desktop. Matrix entries got a `name`
      (`linux-x64`, `linux-arm64`) for the job and artifact names.
    - Releases carry `presence-<tag>-linux-x64.tar.gz` and
      `presence-<tag>-linux-arm64.tar.gz`.
199. **Make a browser refresh keep the same view (camera / events /
    settings).** (2026-10-02)
    - The open tab is remembered in the browser tab's `sessionStorage`
      (`TabMemory`), and restored on load once there's access; a new
      browser tab still starts on the Camera, and the apps are unchanged.
    - Tests: restored after a reload for each tab, an unknown value or no
      access opens on the camera, and signing in later goes back to it;
      the `sessionStorage` itself in Chrome. 256 Flutter tests pass; web
      release builds.
200. **Create a presence-sh component with the template for a bucket,
    distribution, records and ACM certificate to serve the curl bang URL;
    test it until it works on a Raspberry Pi. Every GA release updates it.**
    (2026-10-02)
    - Added [presence_sh/](../presence_sh) (stack `presence-sh`): an ACM
      certificate for `sh.presence.nu01.com`, a private bucket, a
      CloudFront distribution that serves `install.sh` at every path
      (HTTPS only) and A/AAAA records. See [Install URL](install-url.md).
    - [scripts/deploy-sh.sh](../scripts/deploy-sh.sh) deploys it, uploads
      the script, invalidates and smoke-tests it; the Deploy workflow runs
      it on every `*GA` tag after the site.
    - Deployed by hand: `/` and `/install.sh` serve the script, http
      gets 403. The README and the script now show
      `curl -fsSL https://sh.presence.nu01.com | sh`.
    - Merged #129 and released `0.5.202610021047-GA`, the first GA with a
      `linux-arm64` bundle, for the Pi.
201. **(Fix found testing `curl -fsSL https://sh.presence.nu01.com | sh` for
    the Raspberry Pi.)** (2026-10-02)
    - The `0.5.202610021047-GA` arm64 bundle failed on Debian 12 (the base
      of Raspberry Pi OS Bookworm): `undefined symbol:
      g_once_init_enter_pointer`, because the Ubuntu 24.04 build needs
      GLib 2.80 and Debian 12 has 2.74.
    - The Linux release jobs now run on `ubuntu-22.04` and
      `ubuntu-22.04-arm`. Their PR bundles run (still up after 30 s under
      Xvfb) on Debian 12 arm64 and x64, and on Ubuntu 24.04 x64.
202. **(The sync of #197, finished)** (2026-10-02)
    - After #132, merged #127 (a browser refresh keeps the open tab) after
      merging `main` into it twice, as `main` moved meanwhile (request-log
      numbers only; 270 Flutter tests passed); #129 and #131 were merged by
      their own sessions. The main folder was fast-forwarded to `main`.
203. **What is the current average size of a clip on our bucket? And how big
    is the metadata JSON for a clip?** (2026-10-02)
    - Answered, nothing changed: on the production bucket 92 clips (all
      WebM), 12.7 MB on average (6.8–14.9 MB); a clip record about 394 B,
      a clip event about 301 B (500 B with tags), a thumbnail about 20 KB.
      Now in [Recording and data formats](data-formats.md).
204. **Empty all buckets.** (2026-10-02)
    - Asked first which ones: emptied only the two user-data buckets (prod
      and RC), every version and delete marker included (716 in all, about
      1.3 GB); the web, install-script and SAM buckets were left alone.
      Devices still hold their own copies.
205. **Add a section to the spec explaining how videos and metadata are
    recorded (file formats and encoding) and how they're represented on
    S3; make sure the metadata can be queried on S3 in the future, with
    friendly formats.** (2026-10-02)
    - New [Recording and data formats](data-formats.md): the containers,
      codecs, sizes, frame and bit rates per platform; the JSON rules (one
      compact UTF-8 object per file, no binary, epoch-ms UTC times, `…Ms`
      durations); each record's fields; the S3 layout; and an Athena table
      (partition projection) with an example query.
    - The S3 layout changed so the JSON can be queried without meeting
      media: clip records moved from `clips/<clipId>.json` to
      `clips/year=YYYY/day=DDD/<clipId>.json` (their event's day), and the
      recordings, thumbnails and tagged frames from `clips/` to `media/`.
      What a device uploaded under the old keys isn't uploaded again.
    - [Cloud sync](cloud-sync.md) and the bucket template's description
      updated. 271 Flutter tests pass (one new); web release builds.
206. **Add the Raspberry Pi dependencies and instructions to the README.**
    (2026-10-02)
    - New README section "Run it on a Raspberry Pi": 64-bit Raspberry Pi
      OS (Bookworm or newer) with the desktop, `sudo apt install -y curl
      libgtk-3-0 libegl1 libgles2`, then
      `curl -fsSL https://sh.presence.nu01.com | sh`; where it installs,
      how to update, and the web fallback. Also in
      [Install script](install-script.md#raspberry-pi).
    - Also asked: drop the download's checksum check ("just run it"). Not
      done in this change; the script still verifies when the release API
      answers.
207. **Make the events map centered on the latest event and zoomed out to
    catch all events; add zoom controls as well.** (2026-10-02)
    - The Monitoring tab's subjects map, and each subject's map, open
      centered on the newest event, as close as they can be with every
      dot in view (48 px padding, zoom 17 at most): each dot and its
      mirror through the newest, in Web Mercator, are fitted
      (`framedAround`). The whole world without located events, as before.
    - Zoom in and out buttons in the bottom-right corner, one step around
      the center, off at zoom 2 and 19. The Settings location map's zoom
      buttons moved to `MapZoomButtons` in `lib/location/map_parts.dart`,
      shared by both.
    - Spec: new "The map's view" section in [Subjects](subjects.md).
    - 274 Flutter tests pass (3 new in `subjects_test.dart`); the web
      release builds.
208. **Change the default clip times to 5 s before the trigger and 10 s
    after.** (2026-10-02)
    - `ClipConfig` defaults are now `before` 5 s and `after` 10 s
      (`defaultBefore`, `defaultAfter`, replacing the single
      `defaultLength` of 15 s), so a default clip is 15 s. The 5–60 s range
      and 5 s steps are unchanged, and settings already saved on a device or
      in the cloud keep their values.
    - The startup clip comes 5 s after a camera opens (once its "before"
      part is full).
    - Tests and the specs' example texts follow the new defaults. 270
      Flutter tests pass.
209. **Show the event counts (matching / all) beside the search at the top
    of the Events (Monitoring) tab.** (2026-10-02)
    - New `EventCount` right after the search field: "shown / all", where
      *shown* is what the timeline lists after the search and the chips,
      and *all* is every event in the log. It has a tooltip ("2 of 12 events
      shown").
    - The timeline's filter steps are now static helpers
      (`EventTimeline.ofDevices`, `ofKinds`, `matching`) used by both, so
      the count and the list always agree.
    - The field and the count share one row; on a 320 dp phone the field
      gets narrower so the count stays beside it.
    - Tests: the count follows the search, Show system events, new events,
      late object tags and Only this device; where it sits at 1280 and
      320 dp. 271 Flutter tests pass.
210. **Event counts: *all* is every event of this user on this device,
    updated as more load from S3; *matching* is after the search and the
    chips.** (2026-10-02)
    - `EventCount` now counts only the signed-in user's events
      (`EventTimeline.ofUser`). Events recorded signed out still count, since
      the next sign-in takes them over, and so do new ones not saved yet.
      Other users' events left on the device don't. *Matching* applies the
      search and both chips to those events.
    - `MonitoringView` takes the signed-in `userId` and passes it to the
      count. Events fetched by cloud sync join the log, so *all* grows as
      they arrive.
    - Test: another user's event is left out, a signed-out one counts, and
      cloud events raise *all* (one from another device isn't *matching*
      while Only this device is on). 272 Flutter tests pass.
211. **When the app loads, and every 3 hours, delete all events older than
    2 weeks (configurable in Settings from 1 day to three months).**
    (2026-10-02)
    - New `HistoryConfig` (`history: {keepMs}`): 14 days by default, 1–90
      days in 1-day steps. Settings has a new **History** section with a
      **Keep events for** slider.
    - `EventRetention` runs `Persistence.deleteEventsBefore` once the
      history is restored at load, then every 3 h. It deletes the events,
      their clip records and recordings, and suggestions about deleted
      clips, from storage and from the event log. A new setting applies on
      the next run, so dragging the slider deletes nothing.
    - Cloud sync's fetch window shrinks to the setting when it's shorter
      than two weeks, so deleted events don't come back from S3. Nothing
      is deleted from S3.
    - New spec: [event-retention.md](event-retention.md).
    - Tests that store fixed-date events now give the app a matching clock,
      so they won't break once those dates are more than two weeks old.
      278 Flutter tests pass; the web release builds.

212. **Create the concept of a profile, mostly in the auth module: when a
    user logs in, find the profile associated with that subject and load
    it; if there is none, create one and associate them, so it's current
    and found at the next login. This is so users can add collaborators,
    change emails or authentication providers without losing their data,
    which should be scoped to their profiles. Make it prominent in the
    spec. Make the profile ID like the device ID, `adjective-adjective-animal`,
    with word lists long enough to have no collisions.** (2026-10-02)
    - New [Profiles](profiles.md) spec, stated at the top of the spec index:
      data belongs to profiles, not logins.
    - Auth API: `ProfilesTable` (`id`, `createdAt`, `lastSignInAt`) and
      `ProfileSubjectsTable` (`<iss>#<sub>` → `profileId`, `email`,
      `linkedAt`). `GET /api/auth` finds the subject's profile, or creates
      one and links it (`Profiles`), and answers `"profile"` beside the
      roles, for every signed-in user. Two racing first sign-ins share the
      first link. The route is now throttled (20/s, burst 50).
    - Profile IDs (`ProfileId`): two different adjectives and an animal,
      hyphenated (`huge-wavy-darter`), from the device ID's 1053 adjectives
      and 1031 new animals: about 1.14 billion. A conditional put means no
      two profiles ever share an ID; a taken one is redrawn (10 tries).
    - App: `RolesClient.fetch` returns `UserAccess` (roles and profile);
      `RolesService.profile` holds it.
    - Not done yet, and listed in the spec: events' `userId`, the cloud
      sync folder and roles still use the Google account or email, and
      there's no way to link another subject to a profile.
    - 32 JUnit tests pass (9 new in `ProfilesTest`), 269 Flutter tests
      (2 new); `sam validate --lint` passes. In local Floci, the deployed
      `AuthFunction` created a profile and link, and returned the same
      profile on the second call.
213. **Always show the device ID and the profile ID on the Settings view.**
    (2026-10-02)
    - Under the version, two labelled lines, always there: **Device**
      `automatic_paranoid_gadget` (*loading…* until known) and **Profile**
      `huge_wavy_darter` (or why there's none: *none in DEV*,
      *checking…*, *not signed in*, *unavailable*). The IDs stay
      selectable (`device-id`, `profile-id` keys).
    - `SettingsView` takes `profileId` and `noProfile`; the home screen
      passes `RolesService.profile` and the reason.
    - Stacked on #133 (profiles). 272 Flutter tests pass (3 new in
      `add_device_test.dart`); the web release builds.
214. **Make both the device ID and the profile ID separated by `_`.**
    (2026-10-02)
    - Profile IDs are now `adjective_adjective_animal`
      (`huge_wavy_darter`), like device IDs; `ProfileId.PATTERN` and the
      examples across the auth API, the app and the specs follow. Device
      IDs already used underscores and are unchanged.
    - The two can now be the same string (191 animals are also device
      "things"); they're separate namespaces, and the spec says so.
    - Made on #133 before it merged, so no hyphenated profile was ever
      deployed. 32 JUnit tests and 269 Flutter tests pass.

## 2026-10-04

215. **One person, several Google accounts: let a user reach the same
    profile, objects and events from any of their identities, even two from
    the same provider (e.g. `jfaerman@gmail.com` and `julio@nu01.com`).**
    (2026-10-04)
    - Asked which IAM policy variables could replace
      `${cognito-identity.amazonaws.com:sub}`: none identifies a person
      across logins, and a Cognito identity holds only one login per
      provider. Chose developer-authenticated identities through the auth
      API.
    - New [Profiles](profiles.md):
      - an accounts table maps each Google account (`sub`) to a profile and
        its Cognito identity;
      - `POST /api/auth/credentials` issues developer-identity tokens
        (`presence_user` only), on the identity the account already had,
        so no data moves;
      - one-time link codes (10 minutes, hashed, throttled), unlinking,
        and the **Linked accounts** sheet;
      - a linked account shares the owner's roles.
    - The identity pool got `DeveloperProviderName: login.presence.profiles`
      and keeps Google. The bucket policy is unchanged.
    - The app now gets credentials from the auth API
      (`CognitoCredentials`), and `CloudSync.reconnect()` starts over after
      a link.
    - [Auth API](auth-api.md), [Cloud sync](cloud-sync.md) and
      [Sign-in](sign-in.md) updated.
    - Tests: 37 JUnit (14 new) and 277 Flutter (6 new) pass; both templates
      lint clean; Floci deploys the new tables, function and routes. Not
      deployed to AWS.
    - Before release, reconciled with #133 (request 212): the profile is
      #133's (`ProfilesTable`, `ProfileSubjectsTable` by `<iss>#<sub>`,
      `huge_wavy_darter` IDs, made at the first sign-in). This change's
      `AccountsTable` was dropped. The profile now also keeps
      `ownerSubject`, `ownerEmail` and `identityId` (set once), and the
      subjects table got a `profile` index.
216. **Increment Y for the data scoping change; tag a new RC and GA; rebuild
    and deploy it all; sync git (merge all pending PRs, reconciling #133
    with #144).** (2026-10-04)
    - Y is now 6 (`version.Y.txt`): versions are `0.6.Z`.
    - Merged #141, #142, #137, #138 and #140, each after merging `main`
      into it and passing the tests (request-log numbers now 206–211).
    - Reconciled #133 (profiles) into #144 (profile folders and linking):
      one design, in [Profiles](profiles.md). 47 JUnit and 295 Flutter
      tests pass, and the template lints clean.
    - The GitHub deploy roles (`github-deploy.yaml`) may now describe and
      update DynamoDB TTL, which the link-codes table needs.
217. **Create a voucher code system in the auth module and views: users
    submit a voucher code on the Request access sheet and get the
    voucher's role if it's valid; admins create codes (after the
    membership requests on the Admin screen) that grant a given role, with
    an expiration date and a usage count.** (2026-10-04)
    - Auth API: new `VoucherTable` (keyed by code), `POST /api/auth/voucher`
      (`VoucherHandler`, throttled like requests) to redeem, and
      `GET`/`POST /api/auth/vouchers` and `POST /api/auth/vouchers/delete`
      on `AdminHandler`. Codes are random `XXXX-XXXX-XXXX` (60 bits); a
      redemption is one conditional write (exists, not expired, uses left,
      not already used by this email), and any failure answers the same
      404. An Admin voucher also grants `presence_user`.
    - App: a **Voucher code** field and **Redeem** on the Request access
      sheet (a valid code re-checks the roles, so the user gets in at
      once); the Admin screen (now titled "Admin") gets a **Voucher codes**
      section: a form (role, valid-through date, uses) and the codes with
      their uses, expiry, redeemers, Copy and Delete.
    - Floci's local routes added. [Membership](membership.md) and
      [Auth API](auth-api.md) updated. 34 JUnit tests (11 new) and 273
      Flutter tests (2 new) pass.
218. **Add a button "All" to the camera view that shows this device's
    camera in the top left and a grid with the latest available image of
    every device in the profile.** (2026-10-04)
    - An **All** button (grid icon) left of Flip and Clip toggles the grid:
      this device's live camera in the top-left cell, then each other
      device of the signed-in user (the profile, whose events come from
      its cloud folder) with its newest clip thumbnail, its ID and age;
      tapping a cell plays that clip. Devices without an image show an
      icon. The camera isn't reopened when switching.
    - The pills keep room for the wider button row. [Navigation](navigation.md)
      and [Camera screen](camera.md) updated (the camera screen's leftover
      multi-camera grid statements replaced). 279 Flutter tests pass (8
      new, `camera_all_test.dart`); web release builds.
219. **Let there be three roles: `presence_root` for the members of the
     admin allowlist (the `nu01.com` domain), and also explicit emails, both
     as environment variables prefixed with `PRESENCE_`; then
     `presence_admin`, then `presence_user`. Roots can create
     `presence_admin` vouchers, admins can't, and nobody can create
     `presence_root` vouchers, so only roots make admins and admins only
     make users. Allowlist members (domain or email) have all three
     roles.** (2026-10-04)
     - Also asked first: merge all pending PRs. #146 (vouchers) and #145
       (camera All) were brought up to date with `main` and merged.
     - Auth API: `ALLOWED_DOMAINS`/`DOMAIN_ROLES` became
       `PRESENCE_ROOT_DOMAINS` and `PRESENCE_ROOT_EMAILS` (template
       parameters `RootDomains`, default `nu01.com`, and `RootEmails`,
       default none). Their verified users get `presence_root`,
       `presence_admin` and `presence_user`; the roles table can't give
       `presence_root`. DEV's anonymous user gets it too.
     - `POST /api/auth/vouchers` answers 403 for an Admin voucher unless the
       caller is a root; a root voucher stays a 400.
     - `scripts/deploy.sh` passes both on every deploy (environment or
       `.env`; the workflows take repository variables), logging only the
       number of emails; local Floci reads them from `.env`.
     - App: `rootRole` and `RolesService.isRoot`; the Admin screen offers
       Admin codes to roots only.
     - Specs: [Membership](membership.md), [Auth API](auth-api.md),
       [Execution mode](execution-mode.md), [Profiles](profiles.md),
       [Sign-in](sign-in.md), [Local CDN](local-cdn.md),
       [Production deploy](deploy.md). 62 JUnit tests (6 new) and 307
       Flutter tests (2 new) pass; the template lints clean. Not run in
       Floci: your main folder's services were running.
220. **Settings showed profile "none", a bug: there should always be a
     profile. Like the device ID, create one when the app starts if there
     isn't one, owned by no identity; the first sign-in makes that
     identity own it.**
     - App: `ProfileId` (the device ID's adjectives and the API's 1031
       animals) makes a profile at the first start, kept as the `profile`
       settings record (`EventStore.profileId`, `setProfileId`).
       `RolesService.profile` is always this device's profile; each roles
       check sends it (`GET /api/auth?profile=<id>`) and keeps the profile
       the API answers with. Signing out, a failed check and DEV keep it.
       Settings no longer shows *none in DEV*, *checking…*, *not signed
       in* or *unavailable*.
     - Auth API: a subject's first sign-in creates its profile with the
       app's ID when it's valid (`ProfileId.valid`: two different
       adjectives and an animal from the lists) and free, so the subject
       owns it; otherwise a fresh ID as before. A linked subject keeps its
       profile. Unsigned-in profiles stay on the device: nothing creates
       server rows without a sign-in.
     - Specs: [Profiles](profiles.md), [Settings screen](settings.md),
       [Auth API](auth-api.md), [Devices, users and
       places](devices-users-places.md), [Sign-in](sign-in.md), and the
       index, which listed Profiles twice. 64 JUnit tests (2 new) and 309
       Flutter tests (3 new, 2 rewritten) pass. Not run in Floci: the
       main folder's services are shared.
221. **(Fix found releasing 0.6: the RC deploy failed in the identity
    stack.)** (2026-10-04)
    - #144 had changed the authenticated role's description, which needs
      `iam:UpdateRoleDescription`. The RC deploy role lacks it, so
      `presence-rc-identity` failed and its rollback failed too
      (`UPDATE_ROLLBACK_FAILED`). The description is back to the deployed
      text, with a comment saying why it stays.
222. **In the detection pipeline, when a tag is detected, also store the
     frame where that was. When a user clicks the label, open the player
     paused at that position, for both subject labels and tag labels.**
     (2026-10-04)
     - Recognition already stored the position: each object tag keeps the
       `ms` of the first frame it was seen on, and each subject tag its
       `frameId` and `frameMs` (with the frame's JPEG). Nothing changed in
       what's stored; object tags still keep only the time.
     - App: the clip card's subject names (`EventSubjects`) and object tag
       chips (`ClipObjectTags`) are clickable (`OpenAtLabel`, with a "Show
       at 0:02.5" tooltip) when the clip is playable. A click opens the
       player (`showClipPlayer(at:)` → `ClipPlayerDialog.startAt` →
       `ClipPlayerView.startAt`, web and native) loaded at that point and
       paused, clamped to the clip window (`startPosition`). A subject
       opens at its earliest tagged frame; a tag without a frame plays
       from the start, as the card does.
     - Specs: [Clips](clips.md), [Subjects](subjects.md), [Subject
       recognition](recognition.md). 311 Flutter tests pass (2 new); web
       release builds. Not tried in the running app: the main folder's
       services are shared.
223. **Empty both the RC and prod buckets (all events).** An operation, not
     a code change. The RC user-data bucket was already empty. The prod
     bucket had 14 objects, all under one identity: 7 events, 2 clips
     (record, thumbnail and WebM, 62.6 MB in all) and 1 device settings
     record. `aws s3 rm --recursive` deleted all 14, so both buckets now
     list no objects. The bucket is versioned, so the deleted objects
     stay as old versions behind delete markers until the
     `expire-old-versions` rule removes them after 30 days. No feature
     spec changed.
224. **Show a log panel with the latest log events at the end of Settings,
    capturing all log messages: the AWS sync indicator said it failed, but
    not why. Then: make it its own view, only viewable by admins.**
    (2026-10-04)
    - New [Log](log.md) screen, opened from a **Log** button on the Admin
      screen (so `presence_admin` only); it isn't in Settings.
    - `AppLog.capture` in `main()` keeps the latest 500 entries: every
      `debugPrint` and `print`, Flutter errors and uncaught errors, each
      still printed as before.
    - Cloud sync now logs Cognito failures too (they weren't logged), the
      stack trace of other failures, the auth API's response when it
      refuses credentials, and renewed credentials.
    - Specs: [Log](log.md), [Membership](membership.md), [Cloud
      sync](cloud-sync.md), the index. 312 Flutter tests (3 new) pass; the
      web build compiles.
225. **Let DEV mode see the log screen; the log should be its own section
    in the nav bar. In DEV mode the anonymous user should be equivalent to
    root.** (2026-10-04)
    - The Log is a fourth tab after Settings (`HomeTab.log`,
      [lib/log_view.dart](../presence_app/lib/log_view.dart)), shown when
      the user is an admin; the Admin screen's Log button is gone. The tab
      controller is rebuilt when the roles add or remove it.
    - DEV's anonymous user already had every role up to `presence_root`
      (the auth API's `Roles.anonymous` and the app's fallback), so DEV
      gets the Log tab through the role check; a test now asserts
      `isRoot` in DEV. The Admin screen stays hidden in DEV: it needs a
      signed-in token.
    - Specs: [Log](log.md), [Navigation](navigation.md), [Execution
      mode](execution-mode.md), [Membership](membership.md), the index.
      312 Flutter tests pass; the web build compiles.
226. **On the create code screen, let me write the code that I want.
    Suggest a code containing the current season, an animal and a
    number. Also let vouchers have a discount value, default to 100%.**
    (2026-10-04)
    - App: the Admin screen's voucher form has a **Code** field,
      prefilled with a suggestion (`suggestVoucherCode`:
      `AUTUMN-OTTER-4821`, the northern meteorological season, one of 63
      animals, 100 to 9999), a dice button for another, and blank for a
      random code; and a **Discount** field (1 to 100 %, 100 by
      default). Cards show "N% off"; a taken code says so.
    - Auth API: `POST /api/auth/vouchers` takes optional `code` (6 to 40
      letters, digits and dashes, normalized to upper case with single
      dashes; 409 when taken) and `discount` (1 to 100, default 100).
      `discount` is stored, listed and returned on redemption; old items
      read as 100. Random codes and loose typing still work.
    - Specs: [Membership](membership.md), [Auth API](auth-api.md). 15
      VoucherTest (2 new) and 313 Flutter tests (4 new) pass. Not run in
      Floci: the main folder's services are shared.
227. **When a user redeems a voucher, only grant the role if the voucher
    is 100%; otherwise they should pay the remaining value, to be done
    later.** (2026-10-04)
    - Auth API: redeeming's conditional update also requires a full
      discount (or none stored). When it fails, the code is read
      (`Store.find`, a `GetItem`, now allowed to the voucher function),
      and one this email could otherwise redeem with a partial discount
      gets 402 `{"error", "discount"}`: no role, no use counted. Every
      other refusal is the same 404.
    - App: `PaymentRequiredException` (402, with the discount); the
      Request access sheet says "That code gives N% off. Paying the rest
      isn't available yet, so it can't let you in." Payment itself is
      left for later.
    - Specs: [Membership](membership.md), [Auth API](auth-api.md). 16
      VoucherTest (1 new) and 314 Flutter tests (1 new) pass. Stacked on
      #152.
228. **Make sure the log view is only viewable by admin users in OIDC
    mode.** (2026-10-04)
    - It already was (`RolesService.isAdmin`); now tested for every case:
      admin and root see it; signed out, no role, member, admin without
      `presence_user` and a failed roles check don't; a member's refresh
      remembered on the Log tab doesn't reopen it; losing the admin role
      (at the next roles check) or signing out removes it. Roles aren't
      re-checked on token renewal, as for the Admin screen.
    - Specs: [Log](log.md). 324 Flutter tests pass.
229. **Run the app on the attached Android USB device (create a script to
    do this).** (2026-10-04)
    - New [scripts/flutter-android.sh](../scripts/flutter-android.sh) and
      `devbox run android`: finds `adb`, picks the USB phone
      (`ANDROID_SERIAL` for several), and runs `scripts/flutter-run.sh -d
      <serial>`; clear errors for no phone, several, or an unauthorized
      one. Documented in the README and [Android](android.md).
    - Tested with a fake `adb` and `flutter` (one phone, one beside an
      emulator and a wireless device, several, unauthorized,
      `ANDROID_SERIAL`). Not run on a phone: none was attached (macOS saw
      no phone on USB).
230. **When the brightness setting changes, restart the camera view with
    the new setting.** (2026-10-05)
    - `CameraRig` still applies a new brightness live, then closes and
      reopens the open camera 0.8 s after the last change
      (`brightnessRestartDelay`), so dragging the slider restarts it once.
      Skipped while a camera is opening or switching (it opens with the
      current value).
    - Specs: [Settings](settings.md). 324 Flutter tests pass (the
      brightness test now checks the restart).

230. **When the grab button is pressed in the All cameras mode, generate a
    global capture event that makes all cameras take a grab, so the next
    S3 sync shows the current state of all cameras; in the single camera
    mode (default), only grab this camera.** (2026-10-04)
    - Clip with the All grid showing publishes a `capture_all` event
      (`AppEvent.captureAll`) and clips this camera with the new trigger
      `all` ("Capture all"). The event syncs to S3; each other device of
      the profile that fetches it from another device, under 5 minutes old,
      takes one clip of its own (`CameraRig.answerCaptureAll`), which
      syncs back to the asker's grid. Without the grid, Clip is unchanged.
    - Capture all requests count as grabs in the Monitoring timeline.
    - Specs: [Camera screen](camera.md#capture-all), [Navigation](navigation.md),
      [Events](events.md), [Recording and data formats](data-formats.md).
      New `capture_all_test.dart`; 330 Flutter tests pass.

230. **Cognito failures repeat in the log: if it fails, stop trying, and
    print a better error to debug it.** (2026-10-04)
    - The app: a failure to get credentials (`/api/auth/credentials` or
      Cognito) stops cloud sync. No pass runs, for new events or every
      15 s, until the Google ID token changes, the account sheet's new
      **Retry** button, or a profile link's reconnect. It's logged once,
      as `Presence: cloud sync failed, stopped until sign-in or retry:
      Cognito HTTP 502 from /api/auth/credentials: <error> (cause: …;
      request …)`, instead of two lines a pass.
    - The auth API: the 502 now carries `cause` (the AWS service, error
      code and status, or the exception type) and `requestId` (the Lambda
      request ID, also in its log line), still without AWS's message.
    - Specs: [Cloud sync](cloud-sync.md), [Log](log.md),
      [Profiles](profiles.md). ProfileTest (2 new) and 328 Flutter tests
      (4 new) pass.
231. **Make voucher have start and end validity dates and defaults to start
    and end of season.** (2026-10-05)
    - The auth API: vouchers have a `startsAt` beside `expiresAt`.
      `POST /api/auth/vouchers` takes an optional `startsAt` (before
      `expiresAt`, up to 366 days back; now when absent), stores and lists it, and
      redeeming before it gets the usual 404 (also in the conditional
      update). Vouchers stored without one start at their creation.
    - The app: the Admin form has **Valid from** and **Valid through**
      date pickers, defaulting to the current season's first and last days
      (`seasonStart`, `seasonEnd`), instead of a week from today. Cards
      show "valid from … · expires …" and "Not yet valid".
    - Specs: [Membership](membership.md), [Auth API](auth-api.md),
      [README](README.md). 17 VoucherTest (1 new) and 329 Flutter tests
      (1 new) pass.

231. **Allow production reads; allowlist frequent read-only commands
    (`/fewer-permission-prompts`).** (2026-10-05)
    - From the 50 latest transcripts: 24 read-only rules added to
      [.claude/settings.json](../.claude/settings.json), including the AWS
      reads (DynamoDB scan, Cognito Identity lookups, Lambda config,
      CloudWatch logs) the Cognito debugging needed.
    - Specs: [Dev environment](dev-environment.md).

231. **On the top of the log view add a health check panel, with the same
    checks as the settings view (API, AWS/S3, OIDC) and last update, run
    every 30 s; also show a clickable history of health checks as small
    bricks, red for any failed check, green when all pass.** (2026-10-05)
    - The Log tab opens with a **Health** card
      ([lib/system_health.dart](../presence_app/lib/system_health.dart),
      `HealthPanel`): the Settings health line, "Last update HH:MM:SS",
      and a row of bricks, one per check, oldest first: green when all
      passed, red when any is ❌ or ⚠️. Tapping a brick shows that check's
      time and the three statuses; tapping it again hides them.
    - The checks run when the tab opens and every 30 s while it's open:
      `RolesService.checkApi` asks `GET /api/auth/anonymous` again and
      updates the API status and the settings it reports (the execution
      mode stays the start check's). AWS shows the cloud sync's latest
      pass. The history (`HealthHistory`, the latest 120 checks) is in
      memory, so it outlasts closing the tab but not a restart.
    - Specs: [Log](log.md), [Settings screen](settings.md). 329 Flutter
      tests (1 new) pass.
    - Follow-up: the panel wasn't showing because this PR was unmerged
      and conflicted with `main`; rebased (only this log conflicted), 329
      tests pass, and merged.
232. **Make AWS access work in prod: events synced through S3 with the
    Cognito identity pool; verify the policy and how profile IDs are
    handled.** (2026-10-05)
    - Found: every `/api/auth/credentials` failed with `NotAuthorizedException:
      Logins don't match`. The profile's identity came from Google sign-in
      (`GetId`), and `GetOpenIdTokenForDeveloperIdentity` with only the
      profile ID can't add a login to it. Reproduced on the RC pool with a
      throwaway identity (deleted after).
    - Fixed: the API retries with the caller's Google ID token beside the
      profile ID, which links it once; a link code links it too.
    - Checked in prod: the pool (authenticated only, Google client and
      developer provider), the authenticated role (trust limited to the
      pool and `authenticated`; Get, Put and List only under
      `${cognito-identity.amazonaws.com:sub}/`), the bucket policy (TLS
      only) and CORS (the prod origin). No change needed.
    - Specs: [Profiles](profiles.md). ProfileBackendTest (2 new) and 71
      auth API tests pass.

234. **In the health check panel on the Log tab, also add the count of
     distinct devices from events.** (2026-10-05)
    - The panel shows **📱 Devices N** under the health line: the distinct
      device IDs of the user's events (`HealthPanel.devicesIn`, over
      `EventTimeline.ofUser`), local and synced, with events not saved yet
      counted as this device. Updates live.
    - Specs: [Log](log.md). 331 Flutter tests (2 new) pass.

## 2026-10-05

233. **Reloads ask to sign in again: check whether already signed in and
     don't prompt if so.** On web, a reload restored the remembered session
     but still ran Google's quiet check (`attemptLightweightAuthentication`),
     which starts the FedCM prompt.
    - Now, when a still-valid session is restored, the app skips that check
      at launch and runs it only five minutes before the ID token expires
      (`SavedSession.refreshIn`), to refresh the token. Every sign-in
      schedules the next refresh; sign-out cancels it. Android and iOS are
      unchanged.
    - Specs: [Sign-in](sign-in.md). session_test (1 new) and all 329 app
      tests pass.

233. **Show the profile name and all the profile's device IDs, collected
    from events, on the popup the user icon opens.** (2026-10-05)
    - The account sheet shows the profile ID (the profile's only name)
      and every device ID on the signed-in user's events, this device
      first and labelled, the rest sorted; the list updates live.
    - Specs: [Sign-in](sign-in.md). 332 Flutter tests (3 new) pass.

235. **Cognito still not working; the logs are still insufficient.**
     (2026-10-05) The log showed `Cognito HTTP 502 from
     /api/auth/credentials: the profile service failed (cause:
     CognitoIdentity UnknownOperationException (HTTP 400); request …)`.
    - Found: the requests ran on the local stack. The auth API's Lambda
      runs inside Floci, which received `cognito-identity GetId` and
      doesn't implement Cognito Identity. Production's profile function
      logged no failures in that hour.
    - Logs: the API's `cause` now names the operation that failed
      (`CognitoIdentity GetId: UnknownOperationException (HTTP 400)`), and
      an `UnknownOperationException` adds that the endpoint doesn't
      implement it (a local AWS emulator?). The function's log line
      carries the same cause.
    - Not fixed: cloud sync on the local stack needs Cognito Identity,
      which Floci lacks; recorded under [Profiles](profiles.md#known-limitations).
    - Specs: [Profiles](profiles.md), [Log](log.md). 73 auth API tests
      (1 new) pass.
236. **Sign-in failed on Android: check the reason, make sure application
    logs are readable and check for Android errors.** (2026-10-05)
    - Found: Play services' sign-in flow failed with code 28473, after the
      account was picked. The app's signing key matches the Android
      client's registered debug-key SHA-1. The app's own error was lost:
      sign-in errors were shown but never logged, and the phone's 256 KB
      log buffer held only minutes.
    - Sign-in errors are now logged in full (code, description, details).
      New `devbox run android-log`
      ([scripts/android-log.sh](../scripts/android-log.sh)): a 16 MB
      buffer, and only the app's lines plus Google sign-in and crash
      lines. Phone lookup shared in `scripts/android-device.sh`.
    - With the new log: `[28473] Caller could not be verified`, both times
      from an account sheet answered long after it opened (17 min, then
      3 h 45 min; Play services' caller-verification token had expired).
      A fresh sheet works. That failure also made the app call sign-in
      "unavailable" (hiding the button) until a restart; now only a
      library that can't start does.
    - Also seen: the debug build starts slowly enough that the launch
      check of the auth API timed out (5 s) again.
    - Specs: [Android](android.md), [Sign-in](sign-in.md), [Log](log.md).
      330 Flutter tests pass (1 new).
237. **Verify profiles: the same account on two devices must find and use
    the same profile; no profile (null) while nobody is signed in, and no
    sync to S3 then; at sign-in, events get the profile and sync.**
    (2026-10-05)
    - Found: the server already found the account's profile by its
      subject, but the app made a profile per device at its first start
      and kept the last account's after sign-out, and events belonged to
      the Google account (`userId`), not the profile. So linked accounts
      didn't share events, and signed-out events went to the account.
    - Changed: no profile until a sign-in; `RolesService.profile` is the
      API's answer for the signed-in account (null signed out, in DEV and
      until the answer; another account drops it at once), not stored.
      The app no longer makes or sends profile IDs (`ProfileId` and its
      store removed). Every event gets `profileId`; once the profile
      arrives, the device's events without one become its
      (`Persistence.claimForProfile`). Cloud sync runs only with a profile,
      uploads its events and gives fetched ones its ID. The Events count,
      the All grid, the health panel's device count and the account
      sheet's devices go by profile. Settings shows *none until signed
      in*.
    - Specs: [Profiles](profiles.md), [Devices, users and
      places](devices-users-places.md), [Cloud sync](cloud-sync.md),
      [Events](events.md), [Recording and data formats](data-formats.md),
      [Settings screen](settings.md), [Auth API](auth-api.md),
      [Sign-in](sign-in.md), [Camera screen](camera.md), [Log](log.md),
      [README](README.md). 346 Flutter tests (5 new) pass.
238. **On the events page, show every device's events by default; let
     users check Only this device otherwise, and re-filter the map and the
     events when it changes.**
    - Was: **Only this device** was checked at launch, and it filtered only
      the events list; the subjects map always showed every device.
    - Changed: the chip starts unchecked (`ValueNotifier(false)` in the
      app, `MonitoringView` and `EventTimeline`). `SubjectsMap` takes the
      device ID and the chip and keeps only this device's events while
      it's checked (`EventTimeline.ofDevices`); toggling it redraws the
      dots and fits the map to them again (`_SightingsMap.fitKey`).
    - Specs: [Events](events.md), [Monitoring](monitoring.md),
      [Subjects](subjects.md), [Navigation](navigation.md). 348 Flutter
      tests (1 new) pass.
239. **On Android the API health check still shows ❌: check why in the
    app logs, and make health checks print somewhere findable.**
    (2026-10-05)
    - Found: the start check timed out (5 s) on the phone's debug build,
      and the request reached the API 4 s later; nothing checked again
      unless the Log tab was open, so ❌ stayed.
    - Now an unanswered start check is retried (5 s, 15 s, 30 s, then
      every minute) until the API answers; later checks wait 15 s. Every
      check is logged with its duration (`Presence: auth API …`), in the
      Log tab and in logcat (`devbox run android-log`).
    - Specs: [Execution mode](execution-mode.md), [Log](log.md). 344
      Flutter tests pass (1 new).
240. **Make the Settings map open on the detected place, only as a default
     when nothing is set; users can move it elsewhere.** The map used to
     follow only device readings that came after it was ready, so a saved
     location that loaded late, or a reading that came before the map was
     ready, left it on the whole world. And a reading that arrived just
     after a drag pulled the map back. Now, until the user moves the map, it
     follows the location in force: the saved one once it loads, then the
     device's reading. A reading that came before the map was ready is
     applied when it's ready. Once the user drags the map it stays put, and
     only My location makes it follow the device again. Updated
     [Device location and battery](device-location.md). 3 new widget tests
     pass, and so do the existing location tests.
241. **Improve the health checks on the Log tab: a card per check, the
    devices as a number in a pill, all aligned, and the timeline with
    proper times and scrolling.** (2026-10-05)
    - The panel is now a card per check (Auth API, AWS, OIDC) with its
      status in a colored pill (OK, Failed, Mismatch, Checking, Syncing,
      Off) and what it means under the name, plus a Devices card with the
      count in a pill. Four across from 720 dp, two by two below, each
      row's cards the same width and height; under 200 dp the pill goes
      under the name.
    - The history of bricks became a timeline card: a row per check, a
      colored cell per run, the newest on the right and scrolled to,
      sideways scrolling, and the time (HH:MM) under the first run of
      every 2 minutes. Tapping a run still shows its details.
    - Checked by rendering the panel at 360 and 1100 dp.
    - Specs: [Log](log.md). 350 Flutter tests (3 new) pass.
242. **When a user logs in, restore all of the device's settings. Save
     them all on S3, per profile per device.**
    - Was: the settings record (`devices/<deviceId>/settings.json` in the
      profile's folder) held the Settings values only, not the location
      set on the map, and the newer `updatedAt` always won: signing in to
      profile B on a device last used, and changed later, by profile A kept
      A's settings and wrote them over B's record.
    - Changed: the record is `{deviceId, profileId, updatedAt, config,
      location}`. Setting the location on the map (or going back to My
      location) is a settings change; device readings aren't. At the
      first pass for a profile (start or sign-in), the profile's record
      for this device wins when it's newer **or when the local settings
      are another profile's**; then they're claimed for the profile
      (`DeviceSettings.claimSettings`) and uploaded if different. Its map
      location is restored (`LocationController.applyRemote`). A
      reinstall or cleared storage still makes a new device ID, whose
      record starts from the defaults.
    - Specs: [Configuration](configuration.md), [Cloud
      sync](cloud-sync.md), [Recording and data formats](data-formats.md),
      [Device location and battery](device-location.md),
      [Storage](storage.md). 352 Flutter tests (4 new) pass.
243. **On the timeline of health checks, make it a single block per check:
     red if any fails, green if all pass.** (2026-10-05)
     - Was: a column per run with a colored cell per check (API, AWS, OIDC)
       and their names on the left.
     - Changed: each run is one block (`health-block-<i>`), red (the error
       color) when any check failed (❌ or ⚠️, `HealthCheck.failed`) and
       green otherwise; the names column is gone. Tapping a run still shows
       the three statuses.
     - Specs: [Log](log.md). 359 Flutter tests pass.
244. **Add an x beside each subject and tag label to delete that label from
     the event, and update the app's state so the subjects and tags are
     counted right everywhere.**
    - Each subject name and object tag on a clip's card has a small x
      (tooltip "Remove Rex from this event"). A subject's x removes every
      tag of that name on the clip (`ClipAnnotations.removeName`; pending
      suggestions stay) and frames no entry uses any more. An object tag's
      x removes that label (`ClipAnnotations.removeObject`). Removal is
      immediate, with no confirmation or undo.
    - Everything that counts subjects and tags is already worked out from
      each clip's annotations and listens to them, so one change updates
      it all: the card, the subjects map's dots and names, a subject's
      screen, the Events search and its matching / all count. The event is
      saved and queued for cloud sync like any tag edit.
    - Specs: [Subjects](subjects.md), [Subject
      recognition](recognition.md), [Clips](clips.md), [Events](events.md).
      363 Flutter tests (4 new, `label_remove_test.dart`) pass.
245. **Make the health check period 15 s in DEV mode and 60 s in standard
     (RBAC) mode.** (2026-10-05)
     - Was: the Log tab's health panel checked every 30 s in both modes.
     - Changed: `HealthPanel.intervalFor` picks 15 s in DEV and 60 s in
       RBAC from `RolesService.mode` (the build's mode before the start
       check), read again before each run, so the period follows the mode.
       The timeline's header says "every 15 s" or "every 1 min". The 120
       runs kept now span 30 min in DEV and 2 h in RBAC.
     - Specs: [Log](log.md), [Settings screen](settings.md),
       [README](README.md). 361 Flutter tests pass (2 new).
246. **If the health check fails, show an icon warning pill on the camera
     screen as well.**
    - Was: a failed health check showed only in Settings' health line and
      the Log tab's health panel.
    - Changed: over the camera, first among the status pills, a pill with
      only a warning icon (error color) while any check fails (❌, or ⚠️);
      its tooltip names the failed checks, and tapping it opens the Log
      tab's health panel (admins) or Settings. `StatusPill`'s label is
      now optional.
    - Specs: [Navigation](navigation.md), [Settings screen](settings.md).
      361 Flutter tests (2 new) pass.
247. **Add an "about" navigation icon that explains what this app is, made
     with love by prodbytes, links, a call to action to support it by
     becoming a member, etc. Make it always visible.**
    - Added: an About icon (`info_outline`) in the app bar, shown signed
      out, signed in without access, with access and in DEV. It opens an
      About screen: what Presence does, the version, "Made with ♥ by
      prodbytes", a support card (sign in, then Become a member, which
      opens Request access; members are thanked), links (the web app,
      the source, prodbytes, the license) and the install command.
    - `url_launcher` is back, for the links; one that can't open is
      copied.
    - Specs: [About](about.md) (new), [Navigation](navigation.md).
      364 Flutter tests (5 new) pass.
248. **The prodbytes URL is https://prodbytes.substack.com.**
    - Changed: About's prodbytes link opens `https://prodbytes.substack.com`
      (was `https://github.com/prodbytes`).
    - Specs: [About](about.md).
249. **Ensure that on Android the device keeps capturing even if untouched
     for a long time: prevent the camera and device from sleeping to the
     point the app stops working; turning only the screen off to save
     battery is fine.** (2026-10-05)
     - Found on the S40: under Google's sign-in chooser at launch, Android
       refused the camera ("can't use the camera from an idle UID"), as it
       does with the screen off; a running camera taken away was closed
       without telling Dart, so capture stopped silently; and with the
       screen off, the undrawn preview could stall the recording.
     - Changed: a `CaptureService` foreground service (camera, microphone)
       with a partial wake lock and a Wi-Fi lock, started when the app is
       shown; the preview leaves the capture request while the app isn't
       shown; a lost camera is reported (`CameraSource.lost`) and reopened
       every 10 s until it opens; the app asks once to skip battery
       optimization.
     - Verified on the S40: the camera kept recording with the screen asleep
       for over a minute. Specs: [Android](android.md). 361 Flutter tests
       pass (2 new).
250. **When events are synced, update them on screen, so a tag removed on
     one device stops showing on the others at the next sync. Check
     whether it already works that way, or make it so.**
    - Checked: it didn't. The fetch only downloaded events the device
      didn't have and never overwrote local ones, so another device's
      change to an event (a tag added, renamed or removed) never reached
      a device that already had it. Also, the sync runs every 15 s, not
      every 5 minutes; events older than yesterday are only listed in
      the hourly full pass.
    - Changed: the listing now reads each event's ETag (the MD5 of its
      bytes for this bucket, `S3Bucket.listETags`), and the `synced`
      store keeps the ETag of each event as this device last uploaded or
      downloaded it (`etag:<key>`). An event whose ETag differs comes down
      again (`RemoteRecords.updated`), unless the device has its own
      change not uploaded yet, which then goes up over it. The app
      replaces that clip's tags, suggestions, object tags and frames in
      the event on screen (`Persistence.updateFromRemote`,
      `ClipAnnotations.replaceWith`) and saves it, so the card, the
      subjects map, a subject's screen and the Events search and count
      update at once. Then that version counts as synced, so it isn't
      uploaded back.
    - Specs: [Cloud sync](cloud-sync.md), [Subjects](subjects.md),
      [Storage](storage.md). 365 Flutter tests (6 new) pass.
251. **Verify that a grab event is triggered, captured, recognized and
     synced when the app loads and every 3 hours. Make that interval
     configurable and show a countdown in Settings.** (2026-10-05)
    - Verified: a new end-to-end test runs the whole app, signed in and
      syncing, with recognition on fake models. The startup grab and the
      one 3 h later are each triggered, captured, recognized (object tags)
      and uploaded with their recording and thumbnail; none comes a minute
      early. To let the test use fake models, `PresenceApp` now takes an
      optional `recognizer` factory.
    - Changed: the default interval is **3 h** (was 4 h). It was already
      configurable (30 min to 24 h); devices that saved their settings
      before keep what they saved.
    - Added: under the **One clip every** slider, a countdown that updates
      every second: "Startup clip: once the camera is ready", then "Next
      clip in 2 h 59 min 58 s", or "Next clip: due, once a camera is open";
      hidden while scheduled clips are off.
    - Specs: [Scheduled clips](scheduled-clips.md),
      [Settings](settings.md), [Configuration](configuration.md),
      [Camera](camera.md). 362 Flutter tests (3 new) pass.
252. **Add to CLAUDE.md: "do a barrel roll" is to run a complete cycle of
     commit changes, rebuild, run tests, merge PRs, cut RC and GA releases,
     deploy locally starting the dev servers, and redeploy and restart on
     the Android phone connected by USB.**
    - Added: a "Do a barrel roll" section to [CLAUDE.md](../CLAUDE.md)
      listing those steps in order, with the commands for each. No app
      change; no feature spec changes.
253. **The Android app on the USB phone seems to have crashed: no events
     from it all day. Keep the app alive even when the phone is
     unattended, log messages so they can be retrieved for debugging, check
     why the last run failed, and restart it.** (2026-10-05)
     - Found: nothing brought the app back once its process died (a
       crash, a kill, Back, a reboot), and a camera that stopped sending
       frames without an error went unnoticed. The app's messages lived
       only in memory and in logcat, which the phone overwrites within
       hours, so the last run left nothing to read.
     - Changed: `KeepAlive` reopens the app (a watchdog alarm every 15 min,
       10 s after a crash, when Android restarts the sticky capture
       service, and at boot); a camera without frames for 60 s is reopened;
       `FileLog` writes every Dart and native message to daily files on the
       phone, and saves the app's logcat at each start;
       `devbox run android-pull` fetches them with the phone's status and
       crash records.
     - Specs: [Android](android.md). 385 Flutter tests pass (2 new).
