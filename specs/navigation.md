# Navigation

The app is a Flutter app ([presence_app/](../presence_app)). The same UI
runs on Android and web. It follows Material 3 top-level navigation: **tabs
in the app bar**, which flip between full screens.

- **App bar:** the title **Presence** (accent color, plain text) on the left.
  In the top right are three icon tabs, in order **Camera**, **Events** and
  **Settings**, then a **Login** icon button.
  - Tabs have tooltips and semantic labels, and a 48 dp touch target each.
    An indicator marks the selected tab.
  - **Account** (the last icon; your Google avatar when signed in) is an
    action, not a tab. It opens the [account sheet](sign-in.md).
- **Flipping:** tapping a tab or swiping sideways moves between screens
  (`TabBar` + `TabBarView`). The Camera screen is kept alive while other tabs
  are shown, so its live video isn't torn down.
- **Camera** (the start tab): **one camera at a time** fills the **whole
  screen**, edge to edge and under the app bar, which is transparent over
  the camera, with a dark gradient scrim to keep the title and tabs
  readable. There are **no overlays** on the video: no camera name, and no
  list of other cameras.
  - It opens the **default camera**: the first back camera, or else the
    first camera (on web, the one the browser picks by default).
  - The **Clip** trigger is an extended floating action button (bottom
    right), shown only on the Camera tab and only when a camera is open.
    Material says to hide a FAB that can't act, rather than disable it.
  - **Flip camera** (the camera-switch icon) sits just left of Clip, as a
    quieter secondary button. It's shown only when the device has more than
    one camera. It switches back ↔ front where the camera's facing is known
    (skipping extra back lenses), and otherwise goes to the next camera.
    The old camera is fully closed before the next one opens, because most
    phones allow only one open camera. The new camera starts its rolling
    recording from scratch, so a clip right after a flip has less "before"
    history.
  - **Readiness indicator:** the last item on the right of the button row
    (Flip, Clip, then readiness). It shows whether a clip taken now would be
    complete:
    - **"Ready"** (green dot): shown as soon as a camera is open, including
      right after a page reload or a flip. Only **automatic (motion)
      clips** start a countdown. A **Clip button press doesn't**: the pill
      stays Ready while its *after* part records, and the snackbar says it's
      saving. A clip in the first seconds after opening simply has less
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

    The countdown shows only the number.
    That keeps Flip, Clip and the pill on one row on a 320 dp phone. The
    pill refreshes twice a second, and its tooltip and screen-reader label
    spell the state out ("Motion can clip again in 4:28").
    - **The motion cooldown survives restarts and page reloads.** On
      launch, it's restored from the last motion clip in the stored events,
      so the countdown continues exactly where it was, and motion doesn't
      re-fire early just because the app restarted. Verified in Chrome: a
      reload 6 s after "4:28" showed "4:22", matching the stored event
      time.
  - **When any clip starts** (the Clip button or motion), a brief snackbar
    (4 s) says "Clip started · saving the next 15 s" or "Motion detected ·
    saving the next 15 s", with a **View** action that jumps to Events. It's
    set not to persist (Flutter otherwise keeps snackbars with actions until
    dismissed). For motion clips, the indicator carries the cooldown after it.
- **Events:** the event stream, full screen. On wide screens it's centered
  at a readable width (max 560 px), so clip thumbnails don't stretch across
  the desktop.
- **Settings:** the clip settings as a normal screen (no longer a drawer),
  same 560 px readable width.
- The title no longer links to presence.nu01.com. On a full-screen camera,
  an accidental tap would open a browser. `url_launcher` was removed.
- The Flutter demo UI was removed entirely.
