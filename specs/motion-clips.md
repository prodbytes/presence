# Motion clips

When enough of the picture moves, the app takes a clip automatically, the
**same way as pressing Clip**: same camera, before and after windows,
immediate before part, full clip update and storage. Its event card says
**"Motion detected"** (with a running-figure icon) instead of "Clip
requested", and its stored event has `trigger: "motion"`.

- **Measuring motion** (`MotionDetector`,
  [lib/motion.dart](../presence_app/lib/motion.dart), shared by all
  platforms):
  - Cameras supply 64×48 grayscale frames, about 5 per second.
  - The score is the **percentage of pixels whose brightness changed by
    more than 24/255** since the previous frame.
  - Overall brightness shifts (auto-exposure, a light switching on) are
    removed first, by subtracting the **median** per-pixel change. A moving
    object covering less than half the picture doesn't shift the median,
    unlike a mean.
  - The first 3 s after a camera opens or flips are ignored while exposure
    settles.
- **Triggering:** the score must be at or above the threshold for **3
  consecutive frames** (0.6 s). A one-frame glitch changes only two frames
  (appearing, then disappearing), so it doesn't count.
- **Cooldown:** at most **one automatic clip per 5 minutes** (configurable),
  counted from the moment motion grabs a clip. The readiness indicator
  shows it as a countdown, and motion retriggers only once it reaches zero.
  Manual clips are never limited.
- **Frames per platform:**
  - **Web:** the live `<video>` is drawn into a 64×48 canvas every 200 ms,
    and converted to luma.
  - **Android:** a third camera stream, a small YUV `ImageReader` (160×96
    on the S40), is sampled to 64×48 luma natively and sent over the
    `presence/motion` event channel. If a camera refuses three streams, it
    falls back to preview + recording only, and motion is unavailable for
    that camera.
