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
- **Every view change looks the same:** a sideways slide, 300 ms, eased
  (`Curves.ease`, the tabs' own). The role-gated tabs (Log, Admin) are
  tabs like the others: they only need the role to show, and flip in the
  same way. A screen pushed over the tabs (a [subject's](subjects.md))
  slides in from the right as the tabs slide out to the left, and back on
  return (`TabSlidePageTransitionsBuilder` in `lib/theme.dart`, the
  theme's page transition on every platform), instead of the platform's
  own zoom or fade. Sheets (the account sheet) and dialogs (the clip
  player) aren't view changes: they still rise over the screen.
  Test: `theme_test.dart`.
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
    right), shown on the Camera tab with access (`ClipButton`,
    `lib/home/clip_button.dart`). It's also the **readiness indicator**:
    its label's color says whether a clip can be taken (below), and it's
    **disabled**, not hidden, when none can, so the reason is in its
    tooltip. With the **All** grid showing, it's **Capture all**: this camera takes
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
    (`CameraStatus` in `lib/home/camera_status.dart`): a **health
    warning** while a health check fails, the **battery**, its
    **temperature** (Android) and, after them for 4 s, the latest
    **message**, all in one pill style (`StatusPill`), 16 px from the
    edges. (There's no separate readiness pill any more: the Clip button
    carries it.) On screens 600 px and wider they're in a row, centered
    on the buttons and kept clear of them (room is kept for Clip as wide
    as "Clip · 4:59"). Narrower, they stack (the health warning, then the
    battery, then the message), starting just above the buttons' row, so
    they never run into Flip and Clip. A label too long for the room is
    cut short with an ellipsis. See
    [Device location and battery](device-location.md) for the battery.
  - **Screen readers** read each pill's full label. Only the **message**
    and the **health warning** are live regions, read out when they show
    or change; the battery changes all the time, so it isn't announced,
    and neither is the Clip button's countdown (it isn't a live region;
    screen readers read its label and status when they reach it). A pill that does something when tapped (the message
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
  - **Clip readiness (the Clip button's text color)** (`ClipButtonStatus` and
    `ClipButtonColors` in `lib/home/clip_button.dart`, from
    `CameraRig.readiness`): the Clip button shows whether an automatic
    clip (motion, the schedule) can be taken now. The label stays short;
    the tooltip and screen-reader label spell the state out:
    - **Ready** (green; label "Clip"; tooltip "Ready"): shown as soon as
      a camera is open, including right after a page reload or a flip,
      when no cooldown is running. A clip in the first seconds after
      opening simply has less *before* history.
    - **Cooldown** (amber; label "Clip · 4:59"; tooltip "Next automatic
      clip in 4:28") after **any clip**, whatever took it (the Clip
      button, motion, the schedule, the startup clip, Capture all or a
      remote capture request): the countdown of Settings' cooldown (5
      minutes by default), starting when the clip is grabbed. Below a
      minute it shows "45 s". Where "Clip · 4:59" doesn't fit (a 320 dp
      phone with Flip, large text) the label is the time alone ("4:59"),
      and where not even that fits, the button is the icon alone (the
      tooltip still has it all). The countdown and the automatic triggers
      use the same end time (`CameraRig.cooldownEnds`,
      [lib/camera/camera_rig.dart](../presence_app/lib/camera/camera_rig.dart)):
      - **motion** is ignored until it reaches zero;
      - a **scheduled (or startup) clip** due during it is taken the
        moment it ends (a one-shot timer wakes the schedule then), ahead
        of a motion clip, so steady motion can't hold it back; the next
        one counts from then;
      - the **Clip button is never blocked**: a press during the cooldown
        takes the clip and restarts the countdown from the press.
      It applies with motion clips turned off too, as long as scheduled
      clips are on. With **both motion and scheduled clips off** there's
      no automatic clip to wait for: no cooldown and no countdown.
      A clip time later than now (a clock set back, or a stored time from
      a clock ahead) counts as now, so the cooldown never runs longer
      than its length.
    - **Saving** (red; label "Clip", or "Clip · 4:59" with the cooldown;
      tooltip "Clip saving…", followed by "Next automatic clip in 4:59"
      with the cooldown) while the latest clip's *after* part is still
      being recorded, with automatic clips on or off. It **can still be
      pressed**, as before: a press takes another clip (its own *before*
      and *after* parts) and restarts the cooldown; `requestClips` has
      never held a press back.
    - **Disabled** (grey, flat, not pressable) when no clip can be
      taken, with the reason as its tooltip: "Camera off" (the view
      button's None), "No camera", "Camera starting…" (opening, or a
      flip), "Camera unavailable" (failed to open, or lost and being
      retried), else "Camera not ready".

    Colors: **discreet**. The tone is only the **label's and icon's
    color**; the background is the same quiet neutral for every state
    (`ClipButtonColors.background`), so the button doesn't shout. On the
    dark theme the app uses, Gruvbox `bg1` (`#3C3836`, a step darker than
    Flip's) with Gruvbox Material's muted green `#A9B665`, amber
    `#D8A657`, a soft red `#EC8F82`, and a warm grey `#B0A08A` when
    disabled. A light theme gets Gruvbox's palest background `#F9F5D7`
    with `#5F6A28`, `#8F5902`, `#A6453F` and `#6F6359`. Every pair is at
    least 4.5:1 (tested), and the dark theme's are muted (saturation
    under 0.65, tested). The button refreshes twice a
    second, rebuilding only when what it shows changes.

    - **The cooldown survives restarts and page reloads.** On launch, it's
      restored from this device's latest clip of any trigger in the stored
      events (clips other devices took, fetched from the cloud, don't
      count), so the countdown continues exactly where it was and nothing
      automatic re-fires early just because the app restarted. If a clip
      was taken since launch, the later of the two wins. A stored time
      later than now counts as now.
  - **Messages on the Camera tab are a pill** (`CameraMessage`,
    `CameraMessagePill`, kept for 4 s by `CameraMessages`, all in
    `lib/home/camera_messages.dart`), never a snackbar: bottom left, after
    the battery pills, for 4 s, so nothing over the camera moves (a
    snackbar pushed Flip and Clip up) or is covered. A newer message
    replaces it and restarts the 4 s. A label too long for the room is cut
    short; its tooltip has it all. Signed out, it's the only pill (no
    battery, and no buttons), bottom left. The messages:
    - **a clip starts** (the Clip button, motion, the schedule or the
      start), with the clip's icon: "Clip started · saving the next 10 s",
      "Motion detected · …", "Scheduled clip · …" or "Startup clip · …".
      **Tapping it** opens Monitoring, where the clip's event is (with
      access). On the other tabs it doesn't show. After any clip, the
      Clip button carries the cooldown;
    - **a sign-in fails**: "Sign-in failed: <reason>", with the icon in
      the error color. On another tab it's still a snackbar.
- **Monitoring:** the map of every subject's events, with their names,
  beside the event stream (above it on phones), a compact search and
  count and a small system events toggle at the top, each event's device
  (tap it to see only that device) (see
  [Monitoring](monitoring.md)).
  Swiping between tabs is off there.
- **A device's name leads to its events, from anywhere.** Tapping a
  device's ID or name (an event card's device, the device in an event's
  details, the account sheet's device list, an All grid cell's label)
  closes whatever is open over the tabs (the clip player, the account
  sheet, a subject's screen), switches to **Monitoring** and sets its
  events search to the device's ID, so the field shows open with it and
  only that device's events show (see [Events](events.md)). The names
  are buttons with the tooltip "Show this device's events", in the accent
  color; selectable IDs stay selectable (a long press or a drag selects,
  a tap goes). Without access (no Monitoring tab) they're plain text and
  do nothing.
  - One app-level scope, `ShowDeviceEvents`
    ([lib/device_events.dart](../presence_app/lib/device_events.dart)),
    put by the home screen around its tabs: its `onShow` pops back to the
    tabs, `HomeTabs.animateTo(monitoring)` and
    `EventFilters.showDevice`. Dialogs and sheets are routes outside the
    home screen, so what opens them passes it on
    (`ShowDeviceEvents.capture`: the clip player, the account sheet, a
    subject's screen). Each name is a `DeviceEventsLink`.
  - Test: `device_events_test.dart`: at 320 dp, tapping the device ID in
    the account sheet, an All grid label, the device in an event's details
    and an event card's device each end on Monitoring with the search
    set to the device's ID and only its events (the count too), the sheet
    or player closed and nothing overflowing; signed in without access the
    IDs aren't tappable; the link is a button with the tooltip, and plain
    selectable text outside a scope.
- **Settings:** the settings as a normal screen (no longer a drawer),
  **full width**, opening on this device's location map, and ending
  with this device's and profile's IDs (one line each) (see
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
