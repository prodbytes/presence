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
