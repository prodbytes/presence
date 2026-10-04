# Camera screen

- The **Clip** floating action button starts a clip. See [Clips](clips.md).
  With the All grid showing, it asks every device for one
  ([Capture all](#capture-all) below).
- On load, once the device's [recording consent](consent.md) is given or found, the app lists the device's cameras and opens the default one. Before that, no camera opens. On web, the browser asks for camera and microphone
  permission first, in a single prompt. The app owns the open cameras
  (`CameraRig`), so they stay open, and keep recording, across rebuilds.
- One camera shows at a time, full screen (see [Navigation](navigation.md)).
  **All** puts it in the top-left cell of a grid with every other device's
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
  - **Per-tile error:** if one camera fails to open (for example, it's in use),
    only that tile shows the error.

## All devices

The **All** button on the Camera tab (see [Navigation](navigation.md))
switches between the camera alone and a grid of every device in the
profile (`CameraFeedsView.showAll`,
[camera_feeds.dart](../presence_app/lib/camera_feeds.dart)):

- **Top left:** this device's camera, live, labeled "<device ID> · live".
  Its loading, error and no-camera states show in that cell.
- **Then one cell per other device**, sorted by device ID so cells don't
  move (`latestByDevice`): the thumbnail of its newest clip, shown whole,
  labeled "<device ID> · 5 min ago" (refreshed every 30 s). A device with
  events but no clip image shows a camera-off icon and the age of its
  latest event. Tapping a cell with a playable clip opens it in the clip
  player.
- **Which devices:** those in the event log with a device ID other than
  this one's, from the signed-in user's events only (in DEV, every
  event's). Other devices' events reach this one through
  [cloud sync](cloud-sync.md), from the user's folder, so the grid is the
  profile's devices with whatever they last uploaded (new events within
  15 s, the last two weeks on a new device). Nothing new is uploaded or
  fetched for it.
- **Layout:** the columns that give the biggest 16:9 cells
  (`gridColumns`); the cells fill the screen below the app bar and above
  the buttons (88 px kept clear), 1 px apart.
- The grid and the camera alone are the same widget tree, so switching
  never rebuilds or reopens the camera's preview, and recording goes on.
- Tests: `camera_all_test.dart` (which devices and images, the grid's
  places, the same preview across switches, the button).

## Capture all

**Clip with the All grid showing takes a clip on every device**, so the
grid soon shows each one's current picture, not its last clip:

- **On this device:** the press publishes a **Capture all** event
  (`AppEvent.captureAll`, type `capture_all`, grid icon) and takes this
  camera's clip with trigger `all` (title "Capture all"; the message pill
  says "Capture all · saving the next 10 s").
- **On the others:** the event uploads with the next [cloud
  sync](cloud-sync.md) pass (0.5 s later). Each other device of the
  profile fetches it with its next pass (within 15 s) and, if it came from
  another device and is under **5 minutes** old
  (`CameraRig.captureAllWithin`), takes a clip of its own on its open
  camera, trigger `all` (`CameraRig.answerCaptureAll`). Several requests
  in one fetch make one clip. A device without an open camera skips it.
- That clip uploads with the device's next pass, and the asking device's
  All grid shows its thumbnail once its own pass fetches it: about 30 s
  in all.
- **Without the grid** (the default), Clip only takes this camera's clip,
  trigger `manual`, and nothing is asked of other devices.
- Requests only travel through cloud sync, so they need a signed-in
  `presence_user` on both ends; in DEV, or with sync off, Capture all only
  clips this camera. Requests restored from storage, or fetched when
  older than 5 minutes (a device that was off), aren't answered.
- Tests: `capture_all_test.dart` (alone, only a manual clip; with All, the
  request and an `all` clip upload; another device's fetched request takes
  one clip here; not this device's own, an old one, or other events; the
  request survives storage and counts as a grab).

## Known limitations

- Only one camera records at a time. Clips come from the camera being
  shown.
- **All** shows each other device's latest *clip* image, not a live
  picture: how old it is depends on its clips (scheduled ones every 240
  minutes by default, motion, Clip presses, or a [Capture
  all](#capture-all)).
- Capture all reaches devices only through cloud sync, so a device that's
  closed, offline for over 5 minutes, or signed out never answers it, and
  the asking device isn't told which devices did. Its 5-minute window
  compares the device clocks, so a clock far off can make a device answer
  late or not at all.
