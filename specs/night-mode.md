# Night mode

For seeing animals in the wild at night: when the picture stays dark, the
camera is made as bright as it goes, motion detection gets more sensitive,
and while a clip records the scene is lit, by the camera's torch or, with
none, by the screen when it faces the scene. **Off by default**: the
**Night mode** switch in Settings' Camera section turns it on
(`CameraConfig.night`, saved as `nightMode`; see [Settings](settings.md)).
It was on by default, and devices saved that as `night: true`; that old
key is ignored, so every device starts with it off until someone turns it
on.

## Telling night

`NightDetector` ([night_mode.dart](../presence_app/lib/camera/night_mode.dart)),
fed by the open camera's motion frames (64×48 luma, about 5 a second, the
same as [motion clips](motion-clips.md)'):

- The mean brightness of each frame, averaged over the last **40 frames**
  (some 8 seconds).
- **Night** when that falls **below 40/255**. Auto-exposure keeps a lit
  scene near mid-gray, so a picture that stays this dark is one it can't
  brighten any more.
- At night the camera is made brighter, which lifts the mean. So the
  picture's level is measured again once that has taken (its first full
  window after night began, `nightLevel`), and **day** comes back only
  above **1.5 times** it, at least 110 and at most 200 (`dayAbove`): dawn
  or a lamp ends it, not the brighter exposure, and dusk doesn't flicker.
- While the app lights the scene, and for 3 s after (`lightSettle`), its
  frames don't count: that light isn't the day's.
- Another camera (a flip, a reopen) starts over, as day.
- Switching night or day is logged ("Presence: night (mean brightness
  12)").

## At night

`CameraRig` ([camera_rig.dart](../presence_app/lib/camera/camera_rig.dart);
`night`):

- **As bright as it goes:** the camera's exposure compensation goes to
  **+2 EV** (the Brightness slider's top), live, whatever the slider says
  (clamped to what the camera supports); back to the slider's value by
  day, or when night mode is switched off.
- **Motion follows the dark:** the motion step shrinks with the light, to
  4/255 in the dark ([Motion clips](motion-clips.md)). That's always so,
  night mode or not.
- **A clip lights the scene while it records** (any trigger: motion, the
  Clip button, scheduled), from the request until its full recording is
  saved (`_lightWhile`):
  - the camera's **torch** (`CameraSource.setLight`: Android's
    `FLASH_MODE_TORCH` on cameras with a flash, iOS's `torchMode`, the
    browser's `torch` constraint where it offers one, as Chrome on an
    Android phone's back camera);
  - with none, and a camera facing the same way as the screen (a phone's
    front camera, a laptop's, or unknown), the **screen**
    (`screenLight`): the whole app turns white
    ([screen_light.dart](../presence_app/lib/screen_light.dart),
    `ScreenLightOverlay`, taking no taps) at full brightness
    (`setScreenLight` on the `presence/cameras` channel: Android's window
    brightness, kept on even with [Screen off](camera.md); iOS's
    `UIScreen.brightness`, restored after; a browser can't change it);
  - a back camera with no flash: nothing.
  - The "before" part was recorded dark; the light reaches the "after".
  - Motion is reset when the light goes on and off (its warm-up ignores
    the jump), so the light doesn't trigger a clip.
- A **Night** pill (a moon) shows with the status pills at the top left
  of the camera, after the battery and its temperature (`CameraStatus`;
  tooltip "Night mode: as bright as it goes, and lit while a clip
  records"), while it's night with night mode on. It was a chip at the
  bottom left of the preview, where it sat among the camera's buttons.

## Tests

`night_mode_test.dart`: night after the window, not before; the brighter
night picture doesn't end it, dawn does; dusk around the threshold
doesn't flicker; paused frames don't count; the motion steps, and a dim
animal in the dark is motion while the same change by day isn't; the
setting is off by default and the old `night` key is ignored; the rig
(night mode on) at night is at +2 EV and back with night mode off; a clip at night lights
the torch until it's recorded, or the screen for a front camera without
one, and nothing for a back camera without one or by day; the screen
light is white over everything and lets taps through; the Night pill
shows in the status pills (`camera-status`) once it's night.

## Not yet

- Measured on synthetic frames only; the thresholds (40, 1.5×) need a
  real night on the phones.
- No infrared: a phone's camera filters it out.
