# Settings screen

- The **Settings** tab, **full width** (no 560 px readable width).
- The sections, in order: Location, Camera, Motion, Clips, Scheduled
  clips, Recognition, History, Live sync (with live sync in the build),
  Advanced (admins only), Subjects; then the version, the health line,
  Add a device, and last the device and profile IDs.
- **Each section is a group** (`SettingsSection` in
  [lib/settings.dart](../presence_app/lib/settings.dart)), as in most
  phone apps' settings (Strava was the reference): its name as a short
  **bold heading** (`titleMedium`, weight 700), 16 dp in, then its
  controls on a **block a step lighter than the page** (a `Card`, bg1),
  **edge to edge** and square, with the controls 16 dp in; 16 dp of page
  between groups. The version, health line, Add a device and the IDs
  follow the groups on the page itself, 16 dp in. Test:
  `settings_test.dart` (at 320 and 1280 dp).
- **Sliders change their setting when let go.** While one is dragged,
  its thumb and the value beside its name follow the finger; the setting
  changes once, on release (or on each keyboard or screen-reader step), so
  a drag saves the settings, and syncs them, once rather than on every
  frame.
- **Location** section, first: a map with a center pin and, to its right,
  this device's position (labeled, with where it came from), so a drag
  beside the map scrolls the list; moving the map sets the location, with
  zoom and My location buttons on the map. Under the map, a **Paste a
  position** box takes a latitude and longitude copied from elsewhere
  ("38.7223, -9.1393", or Google Maps' `38°43'20.3"N 9°08'21.5"W`) and
  sets the location to it, as moving the map does. **Pin position**,
  between them, fixes this device's position to the one shown: every
  event then uses it, the device's GPS or browser geolocation isn't asked,
  and moving the map only looks around; **Unpin** goes back to the
  automatic location. See
  [Device location and battery](device-location.md#pinning-the-position).
- **Camera** section: a **Brightness** slider from −2 to +2 EV in ½ EV
  steps, default **+1 EV**. Once the slider is let go, it's applied to the
  open camera, and to its recordings, as auto-exposure compensation; then,
  0.8 s later, the camera view restarts (closes and reopens) with
  the new value, so one drag restarts it once. The restart drops the
  camera's rolling "before" history, as a flip does. Cameras opened later,
  after a flip or restart, get the current value. On Android it's clamped to what
  the camera supports (the S40: −2 to +2 EV). On web it uses the browser's
  `exposureCompensation` constraint, where the camera supports it, and does
  nothing elsewhere.
- **Motion** section:
  - A **Clip automatically on motion** switch (default on).
  - **Motion threshold**, 1–50% of the picture (the share of pixels that
    must change), default **15%**. Stored values are kept; only the
    default changed (it was 10%).
  - A **live motion meter** showing the open camera's current score, with a
    marker at the threshold, to help calibrate it.
  - **At most one automatic clip every** 1–60 minutes (default 5): the
    cooldown after any clip, during which motion and scheduled clips wait
    (see [Navigation](navigation.md)). It stays adjustable with motion
    clips off, since it holds scheduled clips back too.
- **Clips** section, with two sliders from 5 s to 60 s in 5 s steps,
  **side by side**, each half the width (8 px apart), with compact labels
  so they fit a 320 dp phone:
  - **Before press**, on the left, default 5 s. This also sets how much
    history the cameras keep recording.
  - **After press**, on the right, default 10 s.
- It shows the total clip length, and notes that a new "before" value takes
  up to that long to apply fully.
- **Scheduled clips** section (see [Scheduled clips](scheduled-clips.md)):
  - A **Clip at start and on a timer** switch (default on).
  - **One clip every**, 30 min to 24 h in 30-minute steps, default
    **3 h**, shown as "30 min", "3 h", "1 h 30 min"; off while the switch
    is.
  - Under it, while the switch is on, a countdown to the next clip,
    refreshed every second ("Next clip in 2 h 59 min 58 s").
- **Recognition** section (see [Subject recognition](recognition.md)):
  - A **Recognize subjects in new clips** switch (default on). Where there's
    no runtime (iOS for now) it's off and disabled, and says
    "Not available on this device yet".
  - A **Tag objects in new clips** switch (default on), "Human, cat, dog,
    bicycle, bottle… for search": the [object tags](recognition.md).
    Disabled the same way where there's no runtime.
  - **Tag automatically when at least** 50–95 % sure, in 5 % steps,
    default **90 %**, off while the subjects switch is. Under it, "Less
    sure than that, it asks you whether it's them.": there's no separate
    "Ask me" level any more; anyone recognized below it (from 50 %, the
    floor) is asked about.
  - Stored as `recognition: {enabled, objects, autoTag}`; an `ask` value
    in older records is ignored. A stored 85 % (the old default, never
    changed) reads as the new 90 %; a stored level under 50 % reads as
    50 %.
- **History** section (see [Event retention](event-retention.md)): **Keep
  events for**, 1–90 days in 1-day steps, default **2 weeks**, shown as
  "1 day", "10 days", "2 weeks" or "90 days", with a note that older
  events and their clips are deleted from this device when the app starts
  and every 3 hours. Stored as `history: {keepMs}`.
- **Live sync** section, for everyone, shown when the build has
  [live sync](live-sync.md) (an IoT endpoint and cloud sync): **Connect to
  live sync**, a slider of **Never**, every **30 s**, every **1, 2, 5, 10,
  15, 30, 60 min**, **Always**, default **every 1 min**, shown as "Never",
  "Every 30 s", "Every 1 min" … "Always", with a note on what it does. A
  change applies at once. Stored as `live: {mode, everyMs}`. It depends on
  the roles (`SettingsView.liveAdmin`, see [live sync](live-sync.md#when-it-connects)):
  - **members** slide from Never to every 60 min (every 30 s the most
    often); a saved Always shows, and connects, as every 30 s;
  - **admins** see **Always**, locked (the slider disabled), with the
    note "Always connected for admins, so this device is always reachable:
    other devices' events arrive within a second." Their saved setting is
    kept for if they stop being admins.

  It's here, not in Advanced (admins only), because it's about every
  user's devices and their data use.
- **Advanced** section, for admins only (everyone in DEV): **Show the Log
  tab**, on by default in DEV and off otherwise. Stored as `log: {show}`,
  unset until flipped (see [Log](log.md)).
- **Subjects** section, the last setting: **How many events to load at
  once**, 10–500 in steps of 10, default **100**: how many of a subject's
  latest events its screen lists and maps, and each subject's on the
  Subjects map (see [Subjects](subjects.md)). Stored values are kept
  (raised to 10 if below).
- **The build's version** is after the sections, centred, quiet
  (`onSurfaceVariant`) at `bodyMedium` (14 sp, as the IDs at the bottom): only
  `X.Y.Z`, e.g. "Presence 0.4.202610011900", with no `-RC`/`-GA` suffix.
  `scripts/make.sh` compiles it in as `PRESENCE_VERSION` (the same version
  as `--build-name`). The dev servers (`scripts/flutter-web.sh`,
  `flutter-run.sh`) pass it too, with Z the time they started. A bare
  `flutter run` or a test has none, and shows no label
  ([lib/app_version.dart](../presence_app/lib/app_version.dart)).
- **Health line**, under the version, as small
  ([lib/system_health.dart](../presence_app/lib/system_health.dart)):
  `🔌 API ✅ · ☁️ AWS ⚪ · 🔑 OIDC ✅ · 📡 Live ⚪`, each with a tooltip. For AWS and
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
  - Live ([live sync](live-sync.md), MQTT): ⚪ the build has no IoT
    endpoint (or no cloud sync), or **Connect to live sync** is Never, so
    events arrive with each sync; ✅ connected (the tooltip counts the
    events received and sent), or set and waiting for the first sync; ⏳
    connecting; 💤 idle between scheduled connections (the tooltip: "idle
    · next in 0:42 (every 1 min; …)", or "every 30 s"); admins, always
    connected, show ✅; ❌ the connection failed (the
    error; it retries, and the bucket still syncs everything). Idle and
    off aren't failures;
  - when the API didn't answer, or is older and doesn't report settings,
    the build's own settings decide.
  - Here it shows the start check's answer; the [Log](log.md) tab's
    health panel shows the same line, checked again every 15 s in DEV and 60 s in RBAC, with a
    history.
  - While a check fails, a warning icon pill shows over the camera too
    ([Navigation](navigation.md)).
- **Add a device**, under the health line, shown in place
  (no dialog): a QR code of a link, the link, and **Share** and **Copy
  link**, to open Presence on another device as a new device of the same
  user (see [Add a device](add-device.md)).
- **The device and profile IDs, always, the last thing** on the page,
  under Add a device, in **one column**: one centred line each, a bold
  label then the ID, selectable to copy. Quiet (`onSurfaceVariant`) and
  the same size as the version (`bodyMedium`, 14 sp). When a line doesn't
  fit (e.g. 320 dp at 2x text), the ID wraps under its label; nothing
  overflows.
  - **Device** `automatic_paranoid_gadget` (see [Devices, users and
    places](devices-users-places.md)), or *loading…* until it's known;
  - **Profile** `huge_wavy_darter`, the signed-in account's
    [profile](profiles.md), the same on every device; *none until signed
    in* signed out, in DEV, and until the auth API answers a sign-in.
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
