# Configuration

All user configuration is one immutable object, **`PresenceConfig`**
([lib/config.dart](../presence_app/lib/config.dart)), grouped by area:

| Group | Values (default, range) |
|---|---|
| `clip` (`ClipConfig`) | `before` (5 s, 5–60 s, 5 s steps), `after` (10 s, 5–60 s) |
| `camera` (`CameraConfig`) | `brightness` (+1 EV, −2 to +2 in ½ EV steps), `paused` (false: the view button's None, the camera off; see [Camera screen](camera.md)), `chosen` (none: the camera last picked with Flip, `{id, label, facing}`, reopened at launch; see [Navigation](navigation.md)) |
| `motion` (`MotionConfig`) | `enabled` (on), `threshold` (15 % of the picture, 1–50 %), `cooldown` (5 min, 1–60 min) |
| `schedule` (`ScheduleConfig`) | `enabled` (on), `every` (180 min, 30 min–24 h in 30 min steps): [scheduled clips](scheduled-clips.md) |
| `subjects` (`SubjectsConfig`) | `mapEvents` (100, 10–500 in steps of 10): "How many events to load at once", events per subject on the [subjects](subjects.md) screens |
| `recognition` (`RecognitionConfig`) | `enabled` (on), `objects` (on), `autoTag` (85 %, 30–95 % in 5 % steps): below it, from `askFloor` (30 %), it asks ([recognition](recognition.md)); the old `ask` field is ignored |
| `log` (`LogConfig`) | `show` (unset: follows the execution mode): the [Log](log.md) tab |
| `history` (`HistoryConfig`) | `keep` (14 days, 1–90 days in 1-day steps): events older than this are deleted from the device ([event retention](event-retention.md)) |
| `live` (`LiveConfig`) | `mode` (`never`, `scheduled` or `always`; scheduled) and `every` (1 min; 30 s, 1, 2, 5, 10, 15, 30 or 60 min, a stored value snapping to the nearest): **Connect to live sync** ([live sync](live-sync.md)); the slider's steps are Never, the intervals, Always (`LiveConfig.ofStep`, `step`). What's stored is the user's choice; how live sync connects also depends on the roles (`LiveConfig.effective`: admins always, others at most every 30 s), and that is never written back. Missing in older records: the default |

- Each group owns its defaults and limits. `copyWith` clamps values into
  range. Groups and the whole config have value equality.
- **`ConfigController`** (a `ChangeNotifier`, owned by the app) holds the
  current config. Change it with `update((c) => c.copyWith(…))`; it
  notifies only on real changes. The Settings screen, the camera rig
  (clip windows, brightness, motion), motion detection, the subject
  screens and persistence all read it.
- Settings controls apply each change to the **current** config at call
  time. Two changes before the next rebuild (for example, quick successive
  drags) both stick.
- **Stored** as one versioned JSON record (`settings` store, key
  `config`: `{version, clip, camera, motion, schedule, subjects,
  recognition, history, log, live, updatedAt, profileId}`), where `updatedAt` is when
  the user last changed a setting (ms since the epoch; 0, or absent in
  older records, for the defaults), setting this device's location on the
  map (or going back to **My location** from there) included, and
  `profileId` is the [profile](profiles.md) the settings were last synced
  with (absent until the first sync). `fromJson` tolerates
  missing or invalid fields (defaults) and out-of-range values (clamped).
  On upgrade, the flat `clip` settings record written by earlier versions is
  read once, through `PresenceConfig.fromLegacy`.
- **Per profile and device, in S3 too, when it's available**
  ([Cloud sync](cloud-sync.md)): `Persistence` is the cloud's
  `DeviceSettings`, and the record goes to the profile's folder,
  `<identityId>/devices/<deviceId>/settings.json`, as
  `{deviceId, profileId, updatedAt, config, location}`: every setting on
  the Settings screen, and `location`, the location set on the map
  ([Device location](device-location.md)), pinned or not (`pinned: true`), or null when the device's own
  position is used. A reading of the device's position isn't a setting:
  it's read again at each launch, and doesn't change the record.
  - At start, the local record loads first (or the defaults). Once the
    device ID is known and sync can run, the first pass for a profile (at
    start, or at each sign-in) fetches the device's record from that
    profile's folder. **A sign-in restores what the profile last had on
    this device**: the cloud record replaces the local settings when it's
    newer, or when the local settings are **another profile's** (synced
    with it last), however recent. Otherwise (the same profile, or
    settings never synced) the newer `updatedAt` wins, so a setting
    changed signed out, or before that pass, isn't undone.
  - Taking on the cloud's record saves it locally, keeping its
    `updatedAt` (it isn't a change by the user); its location, set on the
    map, shows at once ("Set on the map"); with none set there, a location
    set on the map here gives way to **My location**. A record from before
    the location synced (no `location` field) leaves this device's alone.
  - Then the settings are the profile's (`profileId`), and the record is
    uploaded over the cloud's if it differs. So signing in to profile A,
    then B, then A on one device brings back A's settings, then B's, then
    A's; a profile with no record for this device takes on the settings
    in use.
  - Every change is uploaded within a second (the save signals sync), and
    the record is uploaded only when it differs from what the cloud
    holds.
  - A device with no record anywhere starts with the defaults and uploads
    them (`updatedAt` 0).
  - The record is keyed by the device ID, which lives in the device's
    storage: a reinstall, or clearing the browser's site data, makes a new
    device with the defaults, and the old device's record isn't read.
  - Without S3 (signed out, no access, DEV mode, or no cloud settings in
    the build) only the local database is used.
  - A record for another device ID, or a damaged one, is ignored and
    replaced.
- Internal tuning constants (the motion pixel threshold, the 2 s wait cap
  for the before part, 3 frames to trigger, frame sizes) remain code
  constants, not user configuration.
