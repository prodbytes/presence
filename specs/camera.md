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
  - **Access error:** for example, permission denied. Shows the error and a
    Retry button.
  - **Per-tile error:** if one camera fails to open (for example, it's in use),
    only that tile shows the error.

## Known limitations

- Only one camera records at a time. Clips come from the camera being
  shown.
