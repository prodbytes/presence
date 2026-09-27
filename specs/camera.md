# Camera screen

- The **Clip** floating action button starts a clip. See [Clips](clips.md).
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

## Known limitations

- Only one camera records at a time. Clips come from the camera being
  shown.
