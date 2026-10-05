# Navigation

The app is a Flutter app ([presence_app/](../presence_app)). The same UI
runs on Android and web. It follows Material 3 top-level navigation: **tabs
in the app bar**, which flip between full screens.

- **App bar:** the title **Presence** (accent color, plain text) on the left.
  In the top right are three icon tabs, in order **Camera**,
  **Monitoring** and **Settings**, and for admins (`presence_admin`, so
  everyone in DEV, where the anonymous user is a root) a fourth, **Log**;
  then a **Login** icon button. The Log tab comes and goes as the roles
  change (the tab controller is rebuilt, staying on the open tab, or on
  Settings if it was the Log). (The
  Device tab is gone: its map is a section of Settings, and the battery
  shows over the camera.)
  On 320 dp phones the title shortens to make room.
  - Tabs have tooltips and semantic labels, and a 48 dp touch target each.
    Where that doesn't fit (an admin's app bar, with its Log tab, Admin
    and About buttons, on a 320 dp phone), the tabs narrow, down to 40 dp, so nothing
    overflows.
    An indicator marks the selected tab.
  - **About** (`info_outline`), just before Account (or before Sign in
    when signed out), is **always shown**: signed out, signed in without
    access, with access, and in DEV. It opens the [About](about.md)
    screen.
  - **Account** (the last icon; your Google avatar when signed in) is an
    action, not a tab. It opens the [account sheet](sign-in.md).
- **Flipping:** tapping a tab or swiping sideways moves between screens
  (`TabBar` + `TabBarView`). While a finger is on the Settings location
  map, a sideways drag moves the map instead. The Camera screen is kept alive while other tabs
  are shown, so its live video isn't torn down.
- **A browser refresh stays on the open tab** (Camera, Monitoring,
  Settings or Log; the Log only if the user still has it): each switch is remembered in the browser tab's
  `sessionStorage` (`presence.tab`, `lib/tab_memory.dart`), and the app
  opens on it again once the tabs can show (access is known only after the
  roles load; signed out, it stays on the camera and keeps the memory for
  later). A new browser tab, or blocked storage, starts on the Camera. The
  Android and iOS apps don't refresh, so they always start on the Camera.
- **Camera** (the start tab): **one camera at a time** fills the **whole
  screen**, edge to edge and under the app bar, which is transparent over
  the camera, with a dark gradient scrim to keep the title and tabs
  readable. There are **no overlays** on the video: no camera name, and no
  list of other cameras (except in the **All** grid, below).
  - It opens the **default camera**: the first back camera, or else the
    first camera (on web, the one the browser picks by default).
  - The **Clip** trigger is an extended floating action button (bottom
    right), shown only on the Camera tab and only when a camera is open.
    Material says to hide a FAB that can't act, rather than disable it.
    With the **All** grid showing, it's **Capture all**: every device of
    the profile takes a clip (see
    [Camera screen](camera.md#capture-all)); otherwise only this camera.
  - **All** (a grid icon and the label "All") sits left of Flip, as a
    quiet secondary button, shown with access whether or not a camera is
    open. It toggles a grid: this device's camera in the top-left cell and
    every other device of the profile with its latest image (see
    [Camera screen](camera.md#all-devices)). While the grid shows, the
    button is highlighted and its tooltip reads "Show only this camera".
    It's off at launch.
  - **Flip camera** (the camera-switch icon) sits just left of Clip, as a
    quieter secondary button. It's shown only when the device has more than
    one camera. It switches back ↔ front where the camera's facing is known
    (skipping extra back lenses), and otherwise goes to the next camera.
    The old camera is fully closed before the next one opens, because most
    phones allow only one open camera. The new camera starts its rolling
    recording from scratch, so a clip right after a flip has less "before"
    history.
  - **Status pills, bottom left**, across from Flip and Clip
    (`_CameraStatus` in `lib/main.dart`): a **health warning** while a
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
  - **Health warning** (`HealthWarningPill` in
    [lib/system_health.dart](../presence_app/lib/system_health.dart)):
    only an icon (`warning_amber_rounded`, in the error color), no label,
    first among the pills, shown with access while one of the
    [health checks](settings.md) fails (❌, or ⚠️ set on one side only),
    as they stand now (the auth API's start check and its retries, the
    Log tab's checks, the cloud sync). Its tooltip and screen-reader label
    say "Health check failed" and each failed check's explanation.
    **Tapping it** opens the Log tab's health panel for admins, Settings'
    health line for everyone else. Gone once every check passes.
  - **Readiness indicator:** shows whether a clip taken now would be
    complete:
    - **"Ready"** (green dot): shown as soon as a camera is open, including
      right after a page reload or a flip. Only **automatic (motion)
      clips** start a countdown. A **Clip button press doesn't**: the pill
      stays Ready while its *after* part records, and the clip message
      beside it says it's saving. A clip in the first seconds after opening simply has less
      *before* history.
    - **"4:59"** after a **motion** clip: the **motion cooldown** countdown
      (5 minutes by default), starting when motion grabs the clip. The dot
      is red while that clip's *after* part is still saving, then amber.
      Motion can take another clip **only once this reaches zero**: the
      countdown and the trigger use the same end time
      (`CameraRig.motionCooldownEnds`). Below a minute it shows "45 s". A Clip
      press during the cooldown leaves the countdown as it is; the Clip
      button is never blocked. With motion clips turned off there's no
      cooldown.

    The countdown shows only the number, to keep the pill short. The
    pill refreshes twice a second, and its tooltip and screen-reader label
    spell the state out ("Motion can clip again in 4:28").
    - **The motion cooldown survives restarts and page reloads.** On
      launch, it's restored from the last motion clip in the stored events,
      so the countdown continues exactly where it was, and motion doesn't
      re-fire early just because the app restarted. Verified in Chrome: a
      reload 6 s after "4:28" showed "4:22", matching the stored event
      time.
  - **Messages on the Camera tab are a pill** (`CameraMessage`,
    `CameraMessagePill`), never a snackbar: at the bottom, to the right of
    the readiness pill, for 4 s, so nothing over the camera moves (a
    snackbar pushed Flip and Clip up) or is covered. A newer message
    replaces it and restarts the 4 s. A label too long for the room is cut
    short; its tooltip has it all. Signed out, it's the only pill (no
    battery or readiness), bottom left. The messages:
    - **a clip starts** (the Clip button, motion, the schedule or the
      start), with the clip's icon: "Clip started · saving the next 10 s",
      "Motion detected · …", "Scheduled clip · …" or "Startup clip · …".
      **Tapping it** opens Monitoring, where the clip's event is (with
      access). On the other tabs it doesn't show. For motion clips, the
      indicator carries the cooldown after it;
    - **a sign-in fails**: "Sign-in failed: <reason>", with the icon in
      the error color. On another tab it's still a snackbar.
- **Monitoring:** the map of every subject's events, with their names,
  beside the event stream (above it on phones), and **Only this device**
  (unchecked by default: every device shows) at the top (see [Monitoring](monitoring.md)).
  Swiping between tabs is off there.
- **Settings:** the settings as a normal screen (no longer a drawer),
  **full width**, with this device's location map as a section (see
  [Settings screen](settings.md)).
- **Log** (admins only): the app's latest log messages (see [Log](log.md)).
- The title no longer links to presence.nu01.com. On a full-screen camera,
  an accidental tap would open a browser. The links are on the
  [About](about.md) screen instead (`url_launcher`).
- The Flutter demo UI was removed entirely.
