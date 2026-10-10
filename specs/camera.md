# Camera screen

- The **Clip** floating action button starts a clip. See [Clips](clips.md).
  Its label's (and icon's) color is the readiness, discreet, on a
  neutral background: green when ready, amber with the time left during
  the cooldown ("Clip · 4:59"), red while a clip is saving, and grey and
  disabled when no clip can be taken (see
  [Navigation](navigation.md)). With the All grid showing, it asks every device for one
  ([Capture all](#capture-all) below), as opening the grid does.
- On load, once the device's [recording consent](consent.md) is given or found, the app lists the device's cameras and opens the default one. Before that, no camera opens. On web, the browser asks for camera and microphone
  permission first, in a single prompt. The app owns the open cameras
  (`CameraRig`, [lib/camera/camera_rig.dart](../presence_app/lib/camera/camera_rig.dart)), so they stay open, and keep recording, across rebuilds.
- **Screen off** (Android only, an icon-only button left of the view
  button, tooltip "Turn the screen off (capture goes on)") saves battery:
  the screen is the biggest drain on an unattended phone. A tap covers
  the app in black ("Capturing with the screen off. Tap to wake.", faint),
  and the app (`ScreenOff`, `screenOff` on `presence/device`) stops
  keeping the screen on, drops it to its lowest brightness and stops the
  preview. The system's screen timeout then turns the screen off for
  real; recording, motion clips and sync go on, as with the power button
  (see [Android](android.md)). A tap on the cover undoes it all. Apps
  can't turn the screen off at once without device-admin rights, so the
  timeout does it. It isn't saved: a restart keeps the screen on. Test:
  `screen_off_test.dart`.
- **The view button** (One / All / None, an icon-only button, see
  [Navigation](navigation.md)) chooses what the Camera tab shows: **One**, this camera full screen;
  **All**, the grid ([All devices](#all-devices) below); **None**, the
  camera off.
  - **None** closes the camera (`CameraRig.setPaused`): nothing is
    recorded, no motion, scheduled or Capture all clips are taken, and
    Flip is hidden and Clip is disabled (grey, tooltip "Camera
    off"). The camera shows "Camera off / Nothing is recorded until you
    turn it on." with **Turn on**.
  - Nothing reopens it (Retry, the app returning to the foreground, a lost
    camera's retries) but the button (None → One) or Turn on.
  - Pausing and resuming run one after the other: a resume waits for the
    pause before it to close the camera (phones allow one open camera). A
    pause doesn't wait for a camera still opening: that open is stale
    (`CameraRig`'s open generation, bumped by every open and close), and
    whatever it opens is closed at once, so pressing None and One while
    the camera opens never leaves two cameras open, and a stale open's
    error never shows.
  - It's a camera setting (`camera.paused`), saved with the device's
    settings, so it lasts across restarts, including the Android
    watchdog's; One and All aren't kept (One at launch).
- One camera shows at a time, full screen (see [Navigation](navigation.md)).
  The view button's **All** puts it in the top-left cell of a grid with every other device's
  latest image ([All devices](#all-devices) below).
- **Audio is captured.** Cameras rarely have their own microphone, so every
  camera records the default microphone, each with its own copy of the
  track. If microphone access is denied, recording continues video-only.
- Live previews are muted, so the microphone doesn't feed back.
- States:
  - **Loading:** a spinner while cameras are discovered or opened.
  - **No cameras:** "No camera found", with a Retry button.
  - **Access error:** "Could not open the camera", a sentence saying why,
    and a Retry button. Backends throw `CameraUnavailable` with that
    sentence (`describeCameraError`, [camera_feeds.dart](../presence_app/lib/camera_feeds.dart)).
    Raw errors never reach the screen: an unexpected one reads "Something
    went wrong while starting the camera." and its details go to the log.
    On web, before asking for the camera:
    - a page that isn't secure (plain HTTP other than localhost) has no
      `navigator.mediaDevices`, so the app says "The camera only works on a
      secure page. Open Presence over HTTPS." (this used to show a raw
      `TypeError`);
    - a camera permission already denied (Permissions API) says access is
      blocked and to allow it in the site settings, without prompting.

    Browser errors are named by their `DOMException`: blocked
    (`NotAllowedError`, `SecurityError`), no camera (`NotFoundError`,
    `OverconstrainedError`), or in use / couldn't start (`NotReadableError`,
    `AbortError`). Android and iOS show their plugin's message, or "Camera
    permission was denied. Allow it in Settings."
  - The error shows in the camera's view: full screen in One, in its
    top-left cell in All (one camera opens at a time).
- **A lost camera is reopened, on every platform.** When the platform
  takes the running camera away, the source's `lost` completes and
  `CameraRig` closes it, shows the error and tries to reopen it every
  10 s (`CameraRig.lostRetryDelay`) until it opens. On Android that's a
  disconnected or failed camera (see [Android](android.md)). On web the
  browser **ends the video track** (camera unplugged, taken by another
  app, permission revoked): its `ended` event reports the camera lost
  ("The camera stopped (unplugged or taken away)"), so the pill doesn't
  stay Ready on a frozen frame. Closing the camera ourselves stops the
  track without that event.
- **Web elements are released** with the camera or player that showed
  them: every `<video>` is shown through one platform view type
  (`presence-element`, `ElementView` in
  [web_dom.dart](../presence_app/lib/cameras/web_dom.dart)) and looked up
  by a key that's dropped on close, rather than a new view factory per
  open that the browser's registry would keep forever.

## All devices

The view button's **All** on the Camera tab (see
[Navigation](navigation.md)) shows a grid of every device in the
profile (`CameraFeedsView.showAll`,
[camera_feeds.dart](../presence_app/lib/camera_feeds.dart)):

- **Top left:** this device's camera, live, labeled "<device ID> · live".
  Its loading, error and no-camera states show in that cell.
- **A presence dot** leads each cell's label: green (live: answered a
  ping within 90 s, or this device connected to live sync), yellow
  (heard from or an event within 24 h), red (older, or never), with the
  reason as tooltip and screen-reader label. The grid pings the devices
  when it shows and every 30 s while it does (see [Device
  presence](device-presence.md)).
- **Then one cell per other device**, **most recently active first**
  (`byActivity`, [lib/camera/device_grid.dart](../presence_app/lib/camera/device_grid.dart)): those **live** now (green: answered a ping within 90 s)
  first, then the others by when they were last heard from over live
  sync or posted an event, whichever is later, newest first; ties by
  device ID. Live devices all answer the same ping round within a moment,
  so among them their latest event decides, and cells don't swap at
  every round. As devices' activity changes (a pong, a new clip, one
  going quiet), the cells move, sliding to their new place (300 ms, as
  the tabs). Without live sync, events alone decide. Each cell
  (`latestByDevice`) shows the thumbnail of its newest clip, shown whole,
  labeled "<device ID> · 5 min ago" (refreshed every 30 s). A device with
  events but no clip image shows a camera-off icon and the age of its
  latest event. Tapping a cell with a playable clip opens it in the clip
  player.
- **A cell's label shows the device's events:** tapping the label (this
  device's too) switches to Monitoring with the search set to the
  device's ID (tooltip "Show this device's events"; see
  [Navigation](navigation.md)); the rest of the cell keeps opening the
  clip. Without access the label lets taps through to the cell.
- **No delete button:** the cells don't delete devices; that's done from
  the account sheet's device list ([Device deletion](device-deletion.md)).
  A deleted device's cell goes.
- **Which devices:** those in the event log with a device ID other than
  this one's, from the signed-in account's [profile](profiles.md)'s events
  only (signed out and in DEV, every event's). Other devices' events reach
  this one through [cloud sync](cloud-sync.md), from the profile's folder,
  so the grid is the
  profile's devices with whatever they last uploaded (new events within
  15 s, the last two weeks on a new device). A new device shows them all
  within seconds of signing in: events, clip records and thumbnails come
  down first, the recordings after them (in the background on Android,
  when played on the web), so a cell's clip may download when tapped.
  Nothing new is uploaded or fetched for it.
- **Layout:** the columns that give the biggest 16:9 cells
  (`gridColumns`); the cells fill the screen below the app bar and above
  the buttons (the navigation bar is below them) (88 px kept clear), 1 px apart.
- **Opening the grid asks for fresh grabs:** entering All (One → All)
  sends a [Capture all](#capture-all) request, so every other device of
  the profile takes a clip and the grid soon shows what each sees now,
  not its last clip. The message pill says "Asked N devices for a fresh
  grab…" ("Asked every device for a fresh grab" when the grid has no
  other device yet), and each cell whose image is older than the request
  shows a small spinner, top right (tooltip "Asked for a fresh grab"),
  until a newer image arrives, for at most **90 s**
  (`CameraFeedsView.refreshingSince`, `HomeScreen.refreshingFor`).
  Only signed in with cloud sync (none in DEV), which carries it, and at
  most **once a minute** (see Capture all). **Clip** (the grab button)
  in the grid always asks again (see Capture all).
- The grid and the camera alone are the same widget tree, so switching
  never rebuilds or reopens the camera's preview, and recording goes on.
- Tests: `camera_all_test.dart` (which devices and images, the order
  (live first, latest activity, ties, without live sync), the grid's
  places and a device moving ahead once it takes a clip, the same preview across switches, the button, the spinner on
  older images while asked for fresh ones) and
  `camera_pause_test.dart` (the view button's cycle, the camera closed and
  no clips while off, Turn on, the setting kept).

## Capture all

**Opening the All grid, or Clip with it showing, takes a clip on every
device**, so the grid soon shows each one's current picture, not its last
clip. The "grab" each device takes is a clip (its thumbnail is the grid's
image), the same as for any other clip: the grid, cloud sync and live
sync all carry clips, and a still-only grab would need its own record
everywhere.

- **The request:** a **Capture all** event (`AppEvent.captureAll`, type
  `capture_all`, grid icon), a **system event** (it has no video: hidden
  in Monitoring while system events are, unlike the clips it asks for),
  published on the device's event bus by
  `CameraRig.askAll` when the grid opens (signed in with cloud sync) or
  Clip is pressed with it showing. **Opening the grid asks at most once
  a minute** per device (`CameraRig.askAllEvery`): opening it again
  within a minute of the last request asks nothing more. **Pressing Clip
  in the grid always asks** (`askAll(pressed: true)`), within that
  minute too, unless a request went out in the last **5 s**
  (`CameraRig.pressAllEvery`: a double tap, or the grid just opened);
  Clip still takes this camera's clip either way, and each press that
  asks shows the message pill and the cells' spinners again.
- **On this device:** opening the grid takes no clip (this camera's cell
  is live). Clip takes this camera's clip with trigger `all` (title
  "Capture all"; the message pill says "Capture all · saving the next
  10 s").
- **How it travels:** like any event. It uploads with the next [cloud
  sync](cloud-sync.md) pass (0.5 s later) and, right after its upload,
  [live sync](live-sync.md) publishes it on the profile's `events` topic
  when connected, so the other devices get it **within a second**; with
  live sync off or disconnected (local Floci, no `IOT_ENDPOINT`, Never,
  a drop), each gets it from the bucket with its next pass (within
  15 s). No new topic or permission: the `requests` topic stays reserved
  for live sync's phase 2.
- **On the others:** each other device of the profile, if the request
  came from another device and is within **5 minutes** of its clock
  either way (`CameraRig.captureAllWithin`), takes a clip of its own on
  its open camera, trigger `all` (`CameraRig.answerCaptureAll`; the
  rate limits and seen request IDs are `CaptureAll`,
  [lib/camera/capture_all.dart](../presence_app/lib/camera/capture_all.dart)). A
  request is answered **once**, however it arrives: cloud sync hands a
  live event over once and doesn't download it again from the bucket,
  and the rig also remembers the request IDs it has seen (the latest
  200). Several requests make one clip: those in one fetch, and any
  within **10 s** of the device's last Capture all clip
  (`CameraRig.answerAllEvery`), which is fresh enough (two devices
  opening their grids together). Short, so a press of Clip in a grid
  soon after it opened still gets a new clip from each device. A device without an open camera (off,
  or none) skips it. Received requests were validated as any live or
  bucket event is (the profile's own folder or topic, safe IDs, size).
- Like any clip, a Capture all clip (asked here or answered) isn't held
  back by the cooldown but starts it on that device: its Clip button
  counts down, and its motion and scheduled clips wait for the end
  ([Navigation](navigation.md)).
- That clip uploads with the device's next pass, and the asking device's
  All grid shows its thumbnail once its own pass fetches it: about 30 s
  in all.
- **Without the grid** (the default), Clip only takes this camera's clip,
  trigger `manual`, and nothing is asked of other devices.
- Requests only travel through cloud sync (and live sync), so they need a
  signed-in `presence_user` on both ends; in DEV, or with sync off,
  Capture all only clips this camera, and opening the grid asks nothing.
  Requests restored from storage, or fetched when older than 5 minutes (a
  device that was off), aren't answered.
- Tests: `capture_all_test.dart` (alone, only a manual clip; with All, one
  request and an `all` clip upload; opening All asks once, not again
  within a minute, then again, with live sync off, and takes no clip
  here; another device's fetched request takes one clip here; one over
  live sync, delivered twice, takes one clip, and its copy in the bucket
  no other; not this device's own, an old or far-future one, or other
  events; the same request twice makes one clip; requests within 10 s
  make one, a later one another; `askAll`'s minute; a press asks within
  the minute but not within 5 s of the last request; in the app, Clip
  20 s after opening All uploads a second request; the request survives
  storage and is a system event, not a grab).

## Known limitations

- Only one camera records at a time. Clips come from the camera being
  shown.
- **All** shows each other device's latest *clip* image, not a live
  picture: how old it is depends on its clips (scheduled ones every 180
  minutes by default, motion, Clip presses, or a [Capture
  all](#capture-all)).
- Capture all reaches devices only through cloud sync (live sync makes it
  faster), so a device that's closed, offline for over 5 minutes, or
  signed out never answers it, and the asking device isn't told which
  devices did: the grid's spinners stop after 90 s either way. Its
  5-minute window compares the device clocks, so a clock far off can make
  a device answer late or not at all, and a cell's spinner compares the
  other device's clip time with this device's request time.
- Each answer is a full clip (with its recording uploaded) and starts the
  answering device's cooldown, so opening the grid often costs clips:
  once a minute per asking device at most (each Clip press in the grid
  asks again, at most every 5 s), and once per 10 s per answering
  device.
