# Settings screen

- The **Settings** tab, **full width** (no 560 px readable width).
- **Motion** section:
  - A **Clip automatically on motion** switch (default on).
  - **Motion threshold**, 1–50% of the picture (default 10%).
  - A **live motion meter** showing the open camera's current score, with a
    marker at the threshold, to help calibrate it.
  - **At most one automatic clip every** 1–60 minutes (default 5).
- **Camera** section: a **Brightness** slider from −2 to +2 EV in ½ EV
  steps, default **+1 EV**. It's applied live to the open camera, and to its
  recordings, as auto-exposure compensation. Cameras opened later, after a
  flip or restart, get the current value. On Android it's clamped to what
  the camera supports (the S40: −2 to +2 EV). On web it uses the browser's
  `exposureCompensation` constraint, where the camera supports it, and does
  nothing elsewhere.
- **Clips** section, with two sliders from 5 s to 60 s in 5 s steps:
  - **Before the press**, default 15 s. This also sets how much history the
    cameras keep recording.
  - **After the press**, default 15 s.
- It shows the total clip length, and notes that a new "before" value takes
  up to that long to apply fully.
- **Scheduled clips** section (see [Scheduled clips](scheduled-clips.md)):
  - A **Clip at start and on a timer** switch (default on).
  - **One clip every**, 30 min to 24 h in 30-minute steps, default
    **4 h**, shown as "30 min", "4 h", "1 h 30 min"; off while the switch
    is.
- **Subjects** section: **Latest events on a subject's map**, 5–100 in
  steps of 5, default **20**: how many of a subject's latest events its
  screen lists and maps (see [Subjects](subjects.md)).
- **Location** section, after Subjects: this device's position (labeled,
  with where it came from) over a map with a center pin; moving the map
  sets the location, with zoom and My location buttons on the map. See
  [Device location and battery](device-location.md).
- **The build's version** is at the very bottom, small and centred: only
  `X.Y.Z`, e.g. "Presence 0.3.202609271247", with no `-RC`/`-GA` suffix.
  `scripts/make.sh` compiles it in as `PRESENCE_VERSION` (the same version
  as `--build-name`). The dev servers (`scripts/flutter-web.sh`,
  `flutter-run.sh`) pass it too, with Z the time they started. A bare
  `flutter run` or a test has none, and shows no label
  ([lib/app_version.dart](../presence_app/lib/app_version.dart)).
- **The device ID**, under the version, as small and quiet, and
  selectable to copy, e.g. `automatic_paranoid_gadget` (see [Devices,
  users and places](devices-users-places.md)).
- **Health line**, under the device ID, as small
  ([lib/system_health.dart](../presence_app/lib/system_health.dart)):
  `🔌 API ✅ · ☁️ AWS ⚪ · 🔑 OIDC ✅`, each with a tooltip. For AWS and
  OIDC, the [auth API](auth-api.md)'s start check says whether its
  expected settings are set (`settings` in `GET /api/auth/anonymous`), and
  the app checks that against its own build:
  - API: ✅ the start check answered (with the mode), ❌ it didn't (the
    error), ⏳ still checking;
  - AWS (the identity pool and bucket): ⚪ set on neither side (events stay
    on this device), ⚠️ set on one side only (the tooltip says which), and
    set on both: ✅ synced or waiting for sign-in, 🔄 syncing, ❌ the last
    sync failed;
  - OIDC (the Google client ID): ✅ set on both sides, ⚪ on neither
    (sign-in is off), ⚠️ on one only;
  - when the API didn't answer, or is older and doesn't report settings,
    the build's own settings decide.
- **All settings are persistent, per device:** the whole `PresenceConfig`
  (clip lengths, brightness, the motion switch, threshold and cooldown,
  the schedule switch and interval, and the events per subject) is saved
  to the local database on every
  change and restored on launch. **When S3 is available** (cloud sync
  configured, and a signed-in user with access), it's also kept in the
  user's folder under the device ID, fetched at start and uploaded on
  every change; otherwise the local database alone holds it. With
  neither, the device starts with the defaults. See
  [Configuration](configuration.md) and [Cloud sync](cloud-sync.md).
