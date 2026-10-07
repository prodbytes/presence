# Navigation

The app is a Flutter app ([presence_app/](../presence_app)). The same UI
runs on Android and web. It follows Material 3 top-level navigation: **tabs
in the app bar**, which flip between full screens.

- **App bar:** **no title** (in DEV, only the "dev" label on the left; see
  [Execution mode](execution-mode.md)).
  In the top right are three icon tabs, in order **Camera**,
  **Monitoring** and **Settings**, and for admins (`presence_admin`, so
  everyone in DEV, where the anonymous user is a root) a fourth, **Log**,
  when Settings' **Show the Log tab** switch is on: on by default in DEV,
  off otherwise (see [Log](log.md)); for signed-in admins (not DEV:
  there are no accounts) an **Admin** tab last (see
  [Membership](membership.md#the-admin-tab)); then a **Login** icon
  button. The Log and Admin tabs come and go as the roles or the switch
  change (the tab controller is rebuilt, staying on the open tab, or on
  the nearest tab before it if that one goes: Settings for the Log).
  A tab's controller index is its place among the shown tabs
  (`_indexOf`), not its `HomeTab.index`: with the Log hidden, the Admin
  tab is the fourth. (The
  Device tab is gone: its map is a section of Settings, and the battery
  shows over the camera.)
  - Tabs have tooltips and semantic labels, and a 48 dp touch target each.
    Where that doesn't fit (an admin's app bar, with its Log and Admin
    tabs, on a 320 dp phone), the tabs narrow, down to 40 dp, so nothing
    overflows.
    An indicator marks the selected tab.
  - There's **no About button**: what Presence is, with a link to its
    code, is a paragraph at the end of the account sheet (see
    [About](about.md)).
  - **Account** (the last icon; your Google avatar when signed in) is an
    action, not a tab. It opens the [account sheet](sign-in.md).
- **Flipping:** tapping a tab or swiping sideways moves between screens
  (`TabBar` + `TabBarView`). While a finger is on the Settings location
  map, a sideways drag moves the map instead. The Camera screen is kept alive while other tabs
  are shown, so its live video isn't torn down.
- **A browser refresh stays on the open tab** (Camera, Monitoring,
  Settings, Log or Admin; the Log and Admin only if the user still has
  them), remembered by name: each switch is remembered in the browser tab's
  `sessionStorage` (`presence.tab`, `lib/tab_memory.dart`), and the app
  opens on it again once the tabs can show (access is known only after the
  roles load; signed out, it stays on the camera and keeps the memory for
  later). A new browser tab, or blocked storage, starts on the Camera. The
  Android and iOS apps don't refresh, so they always start on the Camera.
  Which tabs show, the open one and the remembered one are kept by
  `HomeTabs` ([lib/home_tabs.dart](../presence_app/lib/home_tabs.dart));
  the home screen (`HomeScreen`) is in
  [lib/home/home_screen.dart](../presence_app/lib/home/home_screen.dart),
  with its app bar (`HomeAppBar`, `lib/home/home_app_bar.dart`), the
  Camera tab's buttons (`CameraButtons`, `lib/home/camera_buttons.dart`)
  and the "dev" label (`DevModeLabel`, `lib/home/dev_mode_label.dart`) as
  widgets of their own in `lib/home/`; `lib/main.dart` keeps `main()` and
  the app's wiring (`PresenceApp`).
- **Camera** (the start tab): **one camera at a time** fills the **whole
  screen**, edge to edge and under the app bar, which is transparent over
  the camera, with a dark gradient scrim to keep the tabs
  readable. There are **no overlays** on the video: no camera name, and no
  list of other cameras (except in the **All** grid, below).
  - It opens **the camera last picked with Flip**, so an unattended
    phone that restarts (a crash, the watchdog, a reinstall) comes back
    to the same view. Flip keeps the choice in this device's settings
    (`camera.chosen` in [Configuration](configuration.md): the camera's
    ID from the platform, on Android the camera ID and on web the
    browser's device ID, with its label and facing). At launch the camera
    is found by its ID, else by its label and facing (an ID that
    changed), else by its facing where known (another front camera for a
    lost front one). The cameras wait for the saved settings to load (at
    most 5 s; if they come later, or from the cloud, the rig switches to
    the remembered camera then).
  - With no camera remembered, or none of these matching, it opens the
    **default camera**: the first back camera, or else the first camera
    (on web, the one the browser picks by default).
  - The **Clip** trigger is an extended floating action button (bottom
    right), shown only on the Camera tab and only when a camera is open.
    Material says to hide a FAB that can't act, rather than disable it.
    With the **All** grid showing, it's **Capture all**: this camera takes
    a clip, and every press asks every other device of the profile for one
    too (unless a request went out in the last 5 s; see
    [Camera screen](camera.md#capture-all)); otherwise only this camera.
  - **The view button** sits left of Flip, shown with access whether or
    not a camera is open. A round floating action button with only an
    icon, no text label: its icon and colors say what the tab shows, its
    tooltip and screen-reader label what a tap does, and a tap moves on,
    One → All → None → One:
    - **One** (a square; quiet): this camera, full screen. Tooltip "Show
      all devices". It's the state at launch, unless the camera was left
      off.
    - **All** (a grid; highlighted): this device's camera in the top-left
      cell and every other device of the profile with its latest image
      (see [Camera screen](camera.md#all-devices)) and a [presence
      dot](device-presence.md) on each. Opening it asks every device for
      a fresh grab (at most once a minute; see [Camera
      screen](camera.md#capture-all)). Tooltip "Turn the camera off".
    - **None** (a crossed-out camera; in the error colors): the camera
      off, nothing recorded (see [Camera screen](camera.md)). Tooltip
      "Turn the camera on".
  - **Flip camera** (the camera-switch icon) sits just left of Clip, as a
    quieter secondary button. It's shown only when the device has more than
    one camera. It switches back ↔ front where the camera's facing is known
    (skipping extra back lenses), and otherwise goes to the next camera.
    The old camera is fully closed before the next one opens, because most
    phones allow only one open camera. The new camera starts its rolling
    recording from scratch, so a clip right after a flip has less "before"
    history. The camera it switches to is remembered for this device and
    reopened at the next launch (above).
  - **Status pills, bottom left**, across from Flip and Clip
    (`CameraStatus` and `ReadinessIndicator` in
    `lib/home/camera_status.dart`): a **health warning** while a
    health check fails, the **battery**, its **temperature** (Android),
    the **readiness indicator** and, after it for 4 s, the latest
    **message**, all in one pill style (`StatusPill`), 16 px from the
    edges. On screens 600 px and wider
    they're in a row, centered on the buttons and kept clear of them.
    Narrower, they stack (the health warning, then the battery, on top), starting just above the buttons'
    row, so they never run into Flip and Clip; the readiness and the
    message share the lowest line. A label too long for the room is cut
    short with an ellipsis. See
    [Device location and battery](device-location.md) for the battery.
  - **Screen readers** read each pill's full label. Only the **message**
    and the **health warning** are live regions, read out when they show
    or change; the readiness countdown and the battery change all the
    time, so they aren't announced (they used to be, every second during
    a cooldown). A pill that does something when tapped (the message
    opening Monitoring, the health warning) is a **button** to screen
    readers too (`StatusPill.liveRegion`, `StatusPill.onTap`).
  - **Health warning** (`HealthWarningPill` in
    [lib/system_health.dart](../presence_app/lib/system_health.dart)):
    only an icon (`warning_amber_rounded`, in the error color), no label,
    first among the pills, shown with access while one of the
    [health checks](settings.md) fails (❌, or ⚠️ set on one side only),
    as they stand now (the auth API's start check and its retries, the
    Log tab's checks, the cloud sync). Its tooltip and screen-reader label
    say "Health check failed" and each failed check's explanation.
    **Tapping it** opens the Log tab's health panel when the Log tab is
    shown, Settings' health line otherwise. Gone once every check passes.
  - **Readiness indicator:** shows whether an automatic clip (motion,
    the schedule) can be taken now. It's only the colored dot, in a round
    40 dp pill, with no text label; during the cooldown the countdown
    number shows beside the dot, since it's information rather than a
    label. The tooltip and screen-reader label spell each state out:
    - **Ready** (green dot only; "Ready to clip"): shown as soon as a
      camera is open, including right after a page reload or a flip, when
      no cooldown is running. A clip in the first seconds after opening
      simply has less *before* history.
    - **"4:59"** after **any clip**, whatever took it (the Clip button,
      motion, the schedule, the startup clip, Capture all or a remote
      capture request): the **cooldown** countdown (Settings' cooldown, 5
      minutes by default), starting when the clip is grabbed. The dot is
      red while that clip's *after* part is still saving ("Clip saving;
      next automatic clip in 4:59"), then amber ("Next automatic clip in
      4:28"). Below a minute it shows "45 s". The countdown and the
      automatic triggers use the same end time (`CameraRig.cooldownEnds`):
      - **motion** is ignored until it reaches zero;
      - a **scheduled (or startup) clip** due during it is taken the
        moment it ends (a one-shot timer wakes the schedule then), ahead
        of a motion clip, so steady motion can't hold it back; the next
        one counts from then;
      - the **Clip button is never blocked**: a press during the cooldown
        takes the clip and restarts the countdown from the press.
      It applies with motion clips turned off too, as long as scheduled
      clips are on. With **both motion and scheduled clips off** there's
      no automatic clip to wait for: no cooldown and no countdown, the
      pill stays Ready (the Clip button works as always).
      A clip time later than now (a clock set back, or a stored time from
      a clock ahead) counts as now, so the cooldown never runs longer
      than its length.
    - **Not ready** (gray dot only; "Camera not ready") and **Off** (gray
      dot only; "Camera off: nothing is recorded", the view button's
      None).

    The countdown shows only the number, to keep the pill short. The
    pill refreshes twice a second.
    - **The cooldown survives restarts and page reloads.** On launch, it's
      restored from this device's latest clip of any trigger in the stored
      events (clips other devices took, fetched from the cloud, don't
      count), so the countdown continues exactly where it was and nothing
      automatic re-fires early just because the app restarted. If a clip
      was taken since launch, the later of the two wins. A stored time
      later than now counts as now.
  - **Messages on the Camera tab are a pill** (`CameraMessage`,
    `CameraMessagePill`, kept for 4 s by `CameraMessages`, all in
    `lib/home/camera_messages.dart`), never a snackbar: at the bottom, to the right of
    the readiness pill, for 4 s, so nothing over the camera moves (a
    snackbar pushed Flip and Clip up) or is covered. A newer message
    replaces it and restarts the 4 s. A label too long for the room is cut
    short; its tooltip has it all. Signed out, it's the only pill (no
    battery or readiness), bottom left. The messages:
    - **a clip starts** (the Clip button, motion, the schedule or the
      start), with the clip's icon: "Clip started · saving the next 10 s",
      "Motion detected · …", "Scheduled clip · …" or "Startup clip · …".
      **Tapping it** opens Monitoring, where the clip's event is (with
      access). On the other tabs it doesn't show. After any clip, the
      indicator carries the cooldown;
    - **a sign-in fails**: "Sign-in failed: <reason>", with the icon in
      the error color. On another tab it's still a snackbar.
- **Monitoring:** the map of every subject's events, with their names,
  beside the event stream (above it on phones), a compact search and
  count and a small system events toggle at the top, each event's device
  (tap it to see only that device) (see
  [Monitoring](monitoring.md)).
  Swiping between tabs is off there.
- **Settings:** the settings as a normal screen (no longer a drawer),
  **full width**, opening on this device's and profile's IDs (two
  columns), with this device's location map as a section (see
  [Settings screen](settings.md)).
- **Log** (admins only, when turned on): the app's latest log messages
  (see [Log](log.md)).
- **Admin** (signed-in admins only): membership requests and voucher
  codes, a page of the tabs like Settings, reached with the same slide
  and swipe; no back button (see
  [Membership](membership.md#the-admin-tab)). It used to be an app-bar
  button opening a separate screen.
- Nothing in the app bar links out: on a full-screen camera, an accidental
  tap would open a browser. The source code link is at the end of the
  account sheet ([About](about.md)).
- The Flutter demo UI was removed entirely.
