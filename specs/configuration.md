# Configuration

All user configuration is one immutable object, **`PresenceConfig`**
([lib/config.dart](../presence_app/lib/config.dart)), grouped by area:

| Group | Values (default, range) |
|---|---|
| `clip` (`ClipConfig`) | `before` (5 s, 5–60 s, 5 s steps), `after` (10 s, 5–60 s) |
| `camera` (`CameraConfig`) | `brightness` (+1 EV, −2 to +2 in ½ EV steps) |
| `motion` (`MotionConfig`) | `enabled` (on), `threshold` (10 %, 1–50 %), `cooldown` (5 min, 1–60 min) |
| `schedule` (`ScheduleConfig`) | `enabled` (on), `every` (240 min, 30 min–24 h in 30 min steps): [scheduled clips](scheduled-clips.md) |
| `subjects` (`SubjectsConfig`) | `mapEvents` (20, 5–100 in steps of 5): events on a [subject's](subjects.md) screen |
| `history` (`HistoryConfig`) | `keep` (14 days, 1–90 days in 1-day steps): events older than this are deleted from the device ([event retention](event-retention.md)) |

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
  `config`: `{version, clip, camera, motion, schedule, subjects, updatedAt}`), where
  `updatedAt` is when the user last changed a setting (ms since the
  epoch; 0, or absent in older records, for the defaults). `fromJson` tolerates
  missing or invalid fields (defaults) and out-of-range values (clamped).
  On upgrade, the flat `clip` settings record written by earlier versions is
  read once, through `PresenceConfig.fromLegacy`.
- **Per device, in S3 too, when it's available**
  ([Cloud sync](cloud-sync.md)): `Persistence` is the cloud's
  `DeviceSettings`, and the record goes to
  `<identityId>/devices/<deviceId>/settings.json` as
  `{deviceId, updatedAt, config}`.
  - At start, the local record loads first (or the defaults). Once the
    device ID is known and sync can run, the first pass fetches the
    device's record. **The newer `updatedAt` wins**: a newer cloud record
    replaces the local settings (and is saved locally, keeping its
    `updatedAt`, which isn't a change by the user); an older one is
    overwritten by the local settings. A setting changed before that pass
    is newer, so it isn't undone.
  - Every change is uploaded within a second (the save signals sync), and
    the record is uploaded only when it differs from what the cloud
    holds.
  - A device with no record anywhere starts with the defaults and uploads
    them (`updatedAt` 0).
  - Without S3 (signed out, no access, DEV mode, or no cloud settings in
    the build) only the local database is used.
  - A record for another device ID, or a damaged one, is ignored and
    replaced.
- Internal tuning constants (the motion pixel threshold, the 2 s wait cap
  for the before part, 3 frames to trigger, frame sizes) remain code
  constants, not user configuration.
