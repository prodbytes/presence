# Settings screen

- The **Settings** tab.
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
- **The build's version** is at the very bottom, small and centred:
  "Presence 0.3.202609271300-GA". Tagged builds (the Release and deploy
  workflows) show their tag; other `make` builds show `X.Y.Z`; the dev
  servers (`scripts/flutter-web.sh`, `flutter-run.sh`) show `X.Y-dev`,
  e.g. "Presence 0.3-dev". A bare `flutter run` or a test shows
  "development build". `scripts/make.sh` compiles it in as
  `PRESENCE_VERSION` and, when `TAG` is this build's own `X.Y.Z-<kind>`,
  `PRESENCE_TAG` ([lib/app_version.dart](../presence_app/lib/app_version.dart)).
- **All settings are persistent:** the whole `PresenceConfig` (clip lengths,
  brightness, and the motion switch, threshold and cooldown) is saved to
  local storage on every change and restored on launch.
