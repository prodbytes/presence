# Clips

Pressing **Clip** records a clip from **every** open camera at once.
Motion clips are recorded the same way (see [Motion clips](motion-clips.md)).
Each clip is two recordings, never joined: a **preview** with the seconds
before the trigger, shown at once, and the **full clip**, recorded as one
file of *before* + *after* once the *after* seconds have passed.

1. For each camera, the app publishes a **`ClipRequested`** event on the bus
   once that camera's **previous 5 s** (the "before" part, by default) are
   recorded, normally within milliseconds. So the event is **playable the
   moment it appears**. Its card shows the camera's current frame as a thumbnail, the
   camera name, the time, and a status line: "Previous 5 s ready ·
   recording next 10 s…". On a narrow list the thumbnail is on top, 16:9
   at the card's width; from 600 dp on it sits beside the details, 16:9
   and 320 dp wide (`ClipEventCard.sideBySideWidth`).
   - Cameras publish independently: a slow camera doesn't hold up the
     others.
   - If a camera's before part takes longer than 2 s (`CameraRig.pastWait`),
     its event is published anyway ("Saving previous 5 s…") and becomes
     playable when the before part arrives.
2. Once the **next 10 s** (the "after" part) have been recorded, **the same
   event is updated with the full clip**, one continuous 15 s recording. No
   new event is added. The card updates in place ("15 s clip ready"), and the
   stored event record changes from `clipState: partial` to
   `clipState: complete`.
3. Tapping a playable card opens the player. It always plays the **full
   clip** when it exists. Until then it plays the **preview** on its own,
   marked "Preview" in the top-left corner, and stops at its end ("Recording
   the next 10 s…"). As soon as the full clip is recorded it **replaces the
   preview** at the same moment of the clip: playing on if the preview was
   playing or had ended, paused if it was paused. From then on only the full
   clip plays, **before + after = 15 s** by default. Seeking is kept inside
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
- **Each recording is cut to its clip** (`cutWebm` in
  [lib/cameras/webm_trim.dart](../presence_app/lib/cameras/webm_trim.dart)),
  for the preview and the full clip alike, without re-encoding:
  - Recorders ask for a **video keyframe every 5 s**
    (`videoKeyFrameIntervalDuration`). The new file starts at the last
    keyframe at or before the clip's start, stops after its last frame,
    has timestamps from zero and states its duration (`MediaRecorder`
    files state none). So a full clip's file is the clip plus at most 5 s
    of lead-in, instead of the recorder's whole history (up to 2 ×
    *before*).
  - Clips sharing a held recorder are each cut from one download of it;
    the shared file is released once every clip has its own.
  - A file the cutter doesn't understand (block groups, no video track,
    MP4 from Safari) is kept whole, as before.
- Clips are then cut to their exact window by seeking, using each
  recorder's start time. Verified in Chrome (before the files were cut
  and the player stopped joining them): the before part started exactly
  *before* seconds before the press, and playback stopped exactly at the
  end of the window.
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
- **Auto**, beside it, tags whoever it recognizes among the people and
  pets tagged before, on this device, and the clip's object tags if it has
  none yet: the clip is searched as new clips are, and it says who it
  tagged or asked about, and what objects it saw (see
  [Subject recognition](recognition.md), "Auto, in the player"). Disabled
  where recognition can't run yet (Android, iOS). On a narrow dialog the
  two buttons go under the "People and pets" title.
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
- **Where a tag came from** (`source`): someone's click (`manual`, the
  default, not stored), [recognition](recognition.md) (`detected`, with its
  `confidence`), a recognition **suggestion** waiting for an answer
  (`suggested`: not a tag, left out of this list, the card and the maps),
  or a suggestion someone confirmed (`confirmed`). Recognized tags show ✨
  and their confidence on their chip ("Rex · 86 %").
- **Stored with the event:** the clip event (`ClipRequested`) keeps a
  `ClipAnnotations`, saved in its record as
  `annotations: [{id, name, x, y, frameId, frameMs, source?, confidence?}]`
  plus `frames: {frameId: JPEG bytes}` (only frames some entry uses,
  suggestions included), and the clip's object tags as
  `objectTags: [{label, ms, score}]` once it's searched for them (see
  [Subject recognition](recognition.md), "Object tags").
  `Persistence` re-saves the event on every change and signals
  [cloud sync](cloud-sync.md), which uploads the frames as images beside the
  clip and the event JSON with the tags. Restores, including from the
  cloud, bring the frames and names back; malformed entries are skipped.
- A clip's card lists everyone tagged on it, each after a square in their
  color, then its object tags as small chips, and the **Monitoring** tab's map shows the events they're on, with
  their names (see [Subjects](subjects.md)).
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
- On the web, the browser's video controls show the clip's file, which
  starts up to 5 s before the clip (at a keyframe). Playback is still kept
  to the window. Safari's MP4 recordings aren't cut: they still hold the
  recorder's whole history.
- The 5 s keyframes make web recordings somewhat larger.
- Audio recording has been verified in unit tests and code review only. The
  in-browser run that checked recording and playback timing ran before audio
  was added.
