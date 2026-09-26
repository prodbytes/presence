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

## Known limitations

- Always-on recording runs about 4 video encoders per camera, which uses
  noticeable CPU with several cameras.
- The browser's native video controls show the whole recording file, which
  can be longer than the clip window. Playback is still kept to the window.
- Audio recording has been verified in unit tests and code review only. The
  in-browser run that checked recording and playback timing ran before audio
  was added.
