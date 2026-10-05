# Settings screen

- The **Settings** tab, **full width** (no 560 px readable width).
- Sections, in order: Location, Camera, Motion, Clips, Scheduled clips,
  Subjects, Recognition, History.
- **Location** section, first: a map with a center pin and, to its right,
  this device's position (labeled, with where it came from), so a drag
  beside the map scrolls the list; moving the map sets the location, with
  zoom and My location buttons on the map. See
  [Device location and battery](device-location.md).
- **Camera** section: a **Brightness** slider from −2 to +2 EV in ½ EV
  steps, default **+1 EV**. It's applied live to the open camera, and to its
  recordings, as auto-exposure compensation; then, once the slider has
  stayed put for 0.8 s, the camera view restarts (closes and reopens) with
  the new value, so one drag restarts it once. The restart drops the
  camera's rolling "before" history, as a flip does. Cameras opened later,
  after a flip or restart, get the current value. On Android it's clamped to what
  the camera supports (the S40: −2 to +2 EV). On web it uses the browser's
  `exposureCompensation` constraint, where the camera supports it, and does
  nothing elsewhere.
- **Motion** section:
  - A **Clip automatically on motion** switch (default on).
  - **Motion threshold**, 1–50% of the picture (default 10%).
  - A **live motion meter** showing the open camera's current score, with a
    marker at the threshold, to help calibrate it.
  - **At most one automatic clip every** 1–60 minutes (default 5).
- **Clips** section, with two sliders from 5 s to 60 s in 5 s steps:
  - **Before the press**, default 5 s. This also sets how much history the
    cameras keep recording.
  - **After the press**, default 10 s.
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
- **Recognition** section (see [Subject recognition](recognition.md)):
  - A **Recognize subjects in new clips** switch (default on). Where there's
    no runtime (iOS for now) it's off and disabled, and says
    "Not available on this device yet".
  - A **Tag objects in new clips** switch (default on), "Human, cat, dog,
    bicycle, bottle… for search": the [object tags](recognition.md).
    Disabled the same way where there's no runtime.
  - **Tag automatically when at least** 30–95 % sure, in 5 % steps,
    default **80 %**.
  - **Ask me when at least** 30–95 % sure, default **50 %**; never above
    the first (raising it past it stops at it, and lowering the first
    lowers it).
  - Both sliders are off while the subjects switch is. Stored as
    `recognition: {enabled, objects, autoTag, ask}`.
- **History** section (see [Event retention](event-retention.md)): **Keep
  events for**, 1–90 days in 1-day steps, default **2 weeks**, shown as
  "1 day", "10 days", "2 weeks" or "90 days", with a note that older
  events and their clips are deleted from this device when the app starts
  and every 3 hours. Stored as `history: {keepMs}`.
- **The build's version** is at the very bottom, small and centred: only
  `X.Y.Z`, e.g. "Presence 0.4.202610011900", with no `-RC`/`-GA` suffix.
  `scripts/make.sh` compiles it in as `PRESENCE_VERSION` (the same version
  as `--build-name`). The dev servers (`scripts/flutter-web.sh`,
  `flutter-run.sh`) pass it too, with Z the time they started. A bare
  `flutter run` or a test has none, and shows no label
  ([lib/app_version.dart](../presence_app/lib/app_version.dart)).
- **The device and profile IDs, always**, under the version, as small and
  quiet, one labelled line each, the IDs selectable to copy:
  - **Device** `automatic_paranoid_gadget` (see [Devices, users and
    places](devices-users-places.md)), or *loading…* until it's known;
  - **Profile** `huge_wavy_darter`, the signed-in account's
    [profile](profiles.md), the same on every device; *none until signed
    in* signed out, in DEV, and until the auth API answers a sign-in.
- **Health line**, under the IDs, as small
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
  - Here it shows the start check's answer; the [Log](log.md) tab's
    health panel shows the same line, checked again every 15 s in DEV and 60 s in RBAC, with a
    history.
  - While a check fails, a warning icon pill shows over the camera too
    ([Navigation](navigation.md)).
- **Add a device**, the last thing, under the health line, shown in place
  (no dialog): a QR code of a link, the link, and **Share** and **Copy
  link**, to open Presence on another device as a new device of the same
  user (see [Add a device](add-device.md)).
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
