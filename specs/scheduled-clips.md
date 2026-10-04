# Scheduled clips

Besides the Clip button and [motion](motion-clips.md), the app takes clips
on its own: **one when it starts, then one every 240 minutes** by default
([lib/camera_feeds.dart](../presence_app/lib/camera_feeds.dart),
`CameraRig`).

## When

- **At start:** a **startup clip**, as soon as the camera is open and has
  recorded a full "before" part (the Clips setting, 5 s by default), so
  the clip is complete. It comes after the [recording
  consent](consent.md), like everything the camera does.
- **Then on a timer:** a **scheduled clip** every `ScheduleConfig.every`,
  counted from the last one (the startup clip first): **240 minutes** by
  default, from **30 minutes to 24 hours** in 30-minute steps. Changing the
  interval applies from the last clip.
- The schedule is checked every 5 s (`CameraRig.scheduleCheck`). A clip
  that falls due while no camera is open (it's opening, or failed) is taken
  once one is, with a full "before" part.
- Each launch takes its own startup clip and starts counting again; the
  count isn't kept across restarts.
- Scheduled clips don't touch the motion cooldown or the readiness pill,
  and motion doesn't delay them.

## Same as any clip

- They go through `CameraRig.requestClips`, the Clip button's path, with
  trigger `startup` or `scheduled` (`ClipTrigger`): the camera's current
  frame as the thumbnail, the "before" part, then the full clip; a
  `ClipRequested` event that's stored, synced to the cloud, can be tagged
  with people and pets, and shows on the [Subjects](subjects.md) maps.
- Their event reads **"Startup clip"** (power icon) or **"Scheduled
  clip"** (clock icon), and the clip message pops as for other clips
  ("Scheduled clip · saving the next 10 s").

## Settings

A **Scheduled clips** section (see [Settings screen](settings.md)), saved
with the rest of the config (`schedule` in `PresenceConfig`):

- **Clip at start and on a timer** (on by default): turns both off.
- **One clip every**, a slider shown as "30 min", "4 h", "1 h 30 min" up
  to "24 h"; off while the switch is.

## Verified

- `scheduled_clips_test.dart`: no clip before the "before" part is full,
  then one startup clip with its title and icon; the next scheduled clip
  at 240 minutes, not at 239; a 30-minute interval applies from the last
  clip; switched off, nothing in 25 hours; the interval's limits, the
  config round-trip and old configs getting the default; the labels; the
  Settings slider's ends and the switch disabling it.
- `readiness_test.dart`: a Clip press after 16 s comes after the startup
  clip, and the pill stays Ready.
