# Configuration

All user configuration is one immutable object, **`PresenceConfig`**
([lib/config.dart](../presence_app/lib/config.dart)), grouped by area:

| Group | Values (default, range) |
|---|---|
| `clip` (`ClipConfig`) | `before` (15 s, 5–60 s, 5 s steps), `after` (15 s, 5–60 s) |
| `camera` (`CameraConfig`) | `brightness` (+1 EV, −2 to +2 in ½ EV steps) |
| `motion` (`MotionConfig`) | `enabled` (on), `threshold` (10 %, 1–50 %), `cooldown` (5 min, 1–60 min) |

- Each group owns its defaults and limits. `copyWith` clamps values into
  range. Groups and the whole config have value equality.
- **`ConfigController`** (a `ChangeNotifier`, owned by the app) holds the
  current config. Change it with `update((c) => c.copyWith(…))`; it
  notifies only on real changes. The Settings screen, the camera rig
  (clip windows, brightness, motion), motion detection and persistence all
  read it.
- Settings controls apply each change to the **current** config at call
  time. Two changes before the next rebuild (for example, quick successive
  drags) both stick.
- **Stored** as one versioned JSON record (`settings` store, key
  `config`: `{version, clip, camera, motion}`). `fromJson` tolerates
  missing or invalid fields (defaults) and out-of-range values (clamped).
  On upgrade, the flat `clip` settings record written by earlier versions is
  read once, through `PresenceConfig.fromLegacy`.
- Internal tuning constants (the motion pixel threshold, the 2 s wait cap
  for the before part, 3 frames to trigger, frame sizes) remain code
  constants, not user configuration.
