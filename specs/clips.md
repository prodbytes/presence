# Clips

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
  page refresh. See [Storage](storage.md).

## Naming people and pets

Under the player, the clip's **People and pets** list names whoever is in
the video, as many as needed. Each name is on a frame of the clip, at the
spot clicked
([lib/annotations.dart](../presence_app/lib/annotations.dart),
`ClipPlayerDialog` in `lib/clips.dart`):

- **Click someone on the video** to tag them: on the web, a click on the
  picture (not on the browser's controls bar at the bottom, nor on the
  letterbox bars). On Android and iOS, **long-press** instead, since a tap
  plays and pauses. The click pauses the player and grabs the frame it
  shows. The frame then takes the player's place, and **"Who is this?"**
  asks for the name for that spot. Save tags it (a blank name, or Cancel,
  goes back to the video). Further clicks on the frame tag more people.
  **Done** brings the video back.
- **Tag this frame** grabs the frame the same way, without a first name.
  This is also how tagging works with a screen reader, whose layer covers
  the `<video>`.
- The frame is grabbed as a JPEG at most 960 px wide
  (`ClipPlayerController.captureFrame`):
  - **web:** the `<video>` is drawn onto a canvas (`toBlob`, JPEG 0.85), at
    its `currentTime`;
  - **Android:** `MediaMetadataRetriever.getFrameAtTime` (closest frame,
    rotated upright), through the `frameAt` method of the `presence/cameras`
    channel;
  - **iOS:** `AVAssetImageGenerator`, through the same channel method.
- While a frame is tagged, the player is hidden, not disposed: on the web a
  hidden `<video>` leaves the page, so it can't take the frame's clicks.
  Clicks on the video itself reach the app through a `click` listener on
  the `<video>`. It maps the point onto the video frame
  (`ClipPlayerController.pictureFraction`) and cancels the click's
  play/pause toggle.
- **Positions** are fractions (0 to 1) of the video frame itself
  (letterboxing excluded), so they land on the same spot on any screen.
  Markers (a dot with the name) are drawn on the frame.
- Tags are listed by frame: the frame's thumbnail and time (click it to tag
  more on that frame), then a chip per name: click to **rename**, × to
  **remove**. A frame is dropped once its last tag is removed.
- **Stored with the event:** the clip event (`ClipRequested`) keeps a
  `ClipAnnotations`, saved in its record as
  `annotations: [{id, name, x, y, frameId, frameMs}]` plus
  `frames: {frameId: JPEG bytes}` (only frames some tag uses).
  `Persistence` re-saves the event on every change and signals
  [cloud sync](cloud-sync.md), which uploads the frames as images beside the
  clip and the event JSON with the tags. Restores, including from the
  cloud, bring the frames and names back; malformed entries are skipped.
- Everyone tagged is listed on the **Subjects** tab, with a map of the
  events they're on (see [Subjects](subjects.md)).
- Tests: the model (add, rename, remove and frame dropping, clamping, a
  JSON round-trip that skips bad entries), and at app level a frame grabbed
  and clicked twice, restored after a refresh with its image, positions and
  names, and stored in the event record; a click on the video tagging that
  frame (and a cancelled one tagging nothing); the letterbox mapping.
  Tried in headless Chrome with a fake camera: a click on the playing
  video froze the frame over the player and tagged the spot, and tags
  were still there after a reload. The Android and iOS
  debug builds compile; frame grabbing hasn't been tried on a device.

## Known limitations

- Always-on recording runs about 4 video encoders per camera, which uses
  noticeable CPU with several cameras.
- The browser's native video controls show the whole recording file, which
  can be longer than the clip window. Playback is still kept to the window.
- Audio recording has been verified in unit tests and code review only. The
  in-browser run that checked recording and playback timing ran before audio
  was added.
