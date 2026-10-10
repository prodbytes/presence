# Sign-in

Sign in with Google, through the `google_sign_in` package
([lib/auth/](../presence_app/lib/auth)). Signing in unlocks the navigation;
there's no separate sign-in screen:

- **At launch** the app checks for a session quietly
  (`attemptLightweightAuthentication`: FedCM auto sign-in on web, Credential
  Manager's authorized accounts on Android, the saved session on iOS). The
  camera opens right away either way. On Android, a remembered account is
  signed back in first, with no UI (below).
- **Reloads keep you signed in (web).** Google Identity Services keeps no
  session on web, so the app remembers it itself:
  - on each sign-in, the user (ID, email, name, photo) and their Google ID
    token go into `localStorage` (`presence.session`; `SessionStore`,
    `SavedSession`);
  - at launch, before Google's library loads, a remembered session whose
    token has more than a minute left is restored, so the user is signed in
    at once;
  - a restored session is **not asked to sign in again**: the silent
    FedCM attempt doesn't run at launch, only five minutes before the
    token expires, to refresh it (`SavedSession.refreshIn`). Each sign-in
    schedules the next refresh. When it finds nothing, the session stays
    until the token expires. Without a restored session, the silent
    attempt runs at launch as before;
  - an expired or malformed session is dropped;
  - **Sign out** forgets it.

  iOS doesn't need this: its Google SDK keeps the session.
- **Restarts keep the same account signed in, with no UI (Android).**
  Credential Manager's quiet check auto-selects only when exactly one
  Google account on the phone has signed in to the app; with two or more
  it shows Google's "Choose an account" sheet, which nobody answers on the
  unattended phone. So:
  - each sign-in remembers the account's email in the app's preferences
    (`SilentSignIn.remember`; `googleAccount` in the `presence` shared
    preferences, through `presence/device` `rememberGoogleAccount`);
  - at launch (after a restart, force-stop, crash or watchdog relaunch),
    the app asks Play services' sign-in for **that account only**
    (`GoogleSilentSignIn.kt`: the legacy `GoogleSignInClient.silentSignIn`
    with `setAccountName(<email>)` and `requestIdToken(<web client>)`,
    `presence/device` `silentGoogleSignIn`). While the account still grants
    the app, it returns the account and a fresh ID token without UI, and
    the user is signed in as by any sign-in (same user ID, the Google
    `sub`; roles and cloud sync follow). The reply must be the account
    asked for. The log says `silent Google sign-in of a***@example.com
    succeeded` or `failed (status <code>)`: emails in the log, which is
    kept in files on the phone and may be shared, are masked to their
    first character and domain (`maskEmail`; `GoogleSilentSignIn.masked`
    on the Kotlin side); the token is never logged;
  - the hourly token refresh (five minutes before expiry) also tries this
    first, for the signed-in account. Play services returns its cached
    token until shortly before expiry, so getting the same token back
    retries a minute later;
  - **a failure is retried quietly, never with the chooser**: when the
    silent sign-in fails for a reason that may pass (Play services'
    status 8, `INTERNAL_ERROR`, seen once on the phone at an hourly
    refresh; offline), the app tries again in 1, 2, 4, 8 and then every
    15 minutes, keeping the session (the user stays signed in; cloud sync
    pauses if the token expires, and resumes on the new token). The log
    says `silent sign-in of a***@example.com failed (N in a row); trying
    again in <s> s`. The backoff starts over at a sign-in with UI and at
    sign-out. Before this, one such failure opened Credential Manager's
    chooser, which sat unanswered on the phone and cloud sync stopped;
  - only when the account **must** sign in with UI (Play services'
    `SIGN_IN_REQUIRED`, status 4: the account removed from the phone or
    its access revoked, `SilentSignInRequired`), or there's no remembered
    account, does the app fall back to Credential Manager's quiet check;
  - **Sign out** forgets the account (and signs Play services' sign-in
    out), so a restart doesn't sign it back in.

  The first launch after updating from a version without this has no
  remembered account, so it still takes one tap on the chooser if several
  accounts have signed in; after that, restarts are silent. Web and iOS
  are unchanged.
- **Before anything shows**, the app asks the auth API for the
  [execution mode](execution-mode.md). In DEV (no OIDC client) there's no
  sign-in at all, and everything below about signing in doesn't apply.
- **Signed out (RBAC):** the anonymous user (`presence_anonymous`) may only
  sign in. The camera shows full screen, always recording as
  usual, with **no buttons on it** (no view, Flip or Clip button), and the
  **navigation is hidden**: no bottom navigation bar, and the app bar
  has only **Sign in with Google**. Nothing is uploaded. You can't switch
  to Monitoring or Settings, and the clip
  message has no "View" action. On web the button is Google's own (GIS
  `renderButton` with FedCM, medium size to fit the app bar), as Google
  Identity Services requires. On Android and iOS it's an app button that
  starts Google's sign-in: Credential Manager's Sign in with Google sheet,
  or the Google SDK. While the launch check runs, the button is hidden. If
  no client ID is configured, a person icon opens a sheet saying sign-in
  isn't set up. Sign-in errors show as a message pill over the camera
  ("Sign-in failed: <reason>"; see [Navigation](navigation.md)), and are
  logged in full: `Presence: Google sign-in failed: <code>; <description>;
  details: <details>` (on Android, the details are Credential Manager's
  error, e.g. its Play services code), and `Presence: Google sign-in is
  unavailable: …` when the library can't start. See [Log](log.md).
- Only a library that can't start makes sign-in unavailable. A failed
  quiet sign-in at launch is a failed sign-in: the button stays.
- On Android, Credential Manager's account sheet expires: Play services
  makes a caller-verification token when it opens, and picking an account
  long after (minutes to hours, e.g. on a phone left asleep) fails with
  `[28473] Caller could not be verified`. Signing in again opens a fresh
  sheet.
- **Roles decide the rest** (`RolesService`, `lib/auth/roles_service.dart`).
  After sign-in, the app asks the [auth API](auth-api.md) (`GET /api/auth`,
  with the Google ID token) for the user's roles and their
  [profile](profiles.md), which the API finds by the account, or, at the
  first sign-in, takes over from the device (`RolesService.profile`):
  - **With `presence_user`,** the user gets everything below. Other roles
    alone don't count.
  - **With `presence_admin` too,** an **Admin** icon also shows, left of
    the account button (see [Membership](membership.md)). With
    `presence_root` as well (`RolesService.isRoot`), its voucher form also
    offers Admin codes. A root on a root domain (`nu01.com`) must sign in
    with that domain's Google Workspace account (the ID token's `hd`); a
    personal Google account registered with a `nu01.com` address gets no
    root roles (see [Auth API](auth-api.md)).
  - **Without `presence_user`, or if the check fails** (deny by default),
    the app shows only the camera, the account button and a **sign-up**
    icon. The icon opens "Request access", where the user writes a message
    and **Send request**s membership (see [Membership](membership.md)), and
    **Check again**, which asks the auth API once more. There are no tabs,
    no camera buttons, and no cloud sync.
  - While the check runs, a small spinner takes the sign-up icon's place.
  - The check runs when the user changes (sign-in, a session restored at
    launch, sign-out). A check that failed also runs again when a silent
    sign-in brings a new ID token, so a stale restored token or an API
    still starting doesn't leave a member on the sign-up screen.
  - **A check that failed is retried on its own**, after 5 s, 15 s, 30 s
    and then every minute, until it answers (and at once when the auth
    API's health check answers again after failing), so an unattended
    phone that rebooted offline gets its access back without anyone
    pressing Check again. These retries keep the sign-up screen up
    rather than flash the spinner; a sign-out or another account stops
    them.
  - Web asks its own origin (`/api/auth`). Android and iOS ask
    `API_BASE_URL`, `https://presence.nu01.com` by default.
- **Signed in as a `presence_user`:** all the buttons: the camera's view, Flip and Clip
  (with its readiness colors), the tabs and, last among them, the
  **Account** tab: your avatar with the tooltip "Signed in as
  <name> · <email>" (see [Navigation](navigation.md)). It opens, as a
  page of the tabs, the **account sheet**'s content: avatar, name, email,
  the user's **roles**, this device's **connectivity**, the [cloud sync](cloud-sync.md) status,
  the **profile** and its **devices**, and **Sign out**. Signing out returns to the camera and
  hides the navigation again (closing the sheet, where it's one: signed
  in without access, the app bar's account button still opens it as a
  bottom sheet). The camera keeps running.
  - **Roles**, always, right under the email (`AccountRoles`): a small
    outlined chip per role the auth API gave, named for people (Member,
    Premium, Admin, Root; another role keeps its ID), in that order, the
    role's ID as each chip's tooltip, and "Roles: Member, Admin" for screen
    readers. "No roles yet" without any (a signed-in account without
    access), "Checking roles…" while the auth API is asked. The anonymous
    role isn't shown.
  - **Connectivity** (`ConnectivityIndicator`,
    [lib/connectivity.dart](../presence_app/lib/connectivity.dart)), under
    the email: one rounded row, tinted in its color, with a dot and a
    headline for **this device**, built from the health checks
    (`SystemHealth.statusOf`, the same as the Log tab's
    [health panel](log.md)): the auth API, cloud sync (AWS) and
    [live sync](live-sync.md). The worst check decides (`Connectivity.of`):
    - 🟢 **green** only when the auth API answers, cloud sync is set (or
      syncing: its 15 s passes don't flicker it) and live sync is
      **connected**: "Online · live sync connected";
    - 🟡 **amber** when degraded: checking the API ("Checking the
      connection…"), "Connecting to live sync…", "Live sync idle · next
      in 0:42" (counting down each second), "Live sync connects once
      synced", "Live sync is off" (Never), "Live sync isn't set up in
      this build" (no `IOT_ENDPOINT`), "Cloud sync isn't set up in this
      build", or set on one side only;
    - 🔴 **red** when a check failed: "Offline: can't reach the server"
      (the auth API didn't answer), "Cloud sync failed", "Live sync
      failed". Among checks of the same color, the API speaks first, then
      cloud sync, then live sync.

    Tapping it expands (and collapses) each check's line with its emoji
    and explanation, the error included ("❌ Live: failed (…)"), and a
    note that other devices see this one live only while live sync is
    connected. Its tooltip and screen-reader label (a button, with its
    expanded state) read "Connectivity: <headline>" and the three
    explanations. It asks the auth API again (`RolesService.checkApi`)
    when the sheet opens and every 15 s (DEV) or 60 s (RBAC) while it's
    open, and updates as the checks change. It fits 320 dp at a 2x
    system font (the headline wraps).
  - **Profile:** the [profile](profiles.md) ID
    (`automatic_paranoid_axolotl`), the profile's only name, selectable to
    copy, in `titleMedium` (16 sp).
  - **Devices** ("3 devices"): every [device ID](devices-users-places.md#devices)
    found on the profile's events (`profileDevices`), the events synced
    from the profile's cloud folder included, so the same account's other
    devices and linked accounts' devices show. This device comes
    first, labelled "this device", even before it has an event; the rest
    are sorted. The list updates while the sheet is open, and scrolls when
    long. Each ID is selectable, in `bodyLarge` (16 sp); with access it's
    in the accent color and a tap **shows the device's events**: the
    sheet closes and Monitoring opens with the search set to the ID (see
    [Navigation](navigation.md)); "this device"
    sits beside it, or under it when they don't fit on one line (at 320
    dp with a 2x system font). A device shows only once one of its
    events has synced here, and drops off when its events age out of
    [event retention](event-retention.md) or it's deleted.
    - **Delete:** every device but this one has a delete button at the
      end of its row (tooltip "Delete <device ID>"); after a confirmation
      naming the device and its number of events, its events are hidden
      on every device and it leaves the list. See
      [Device deletion](device-deletion.md).
    - Each device shows its **operating system** (`profileDeviceDetails`):
      an icon before the ID (Android `Icons.android`, iOS
      `phone_iphone`, macOS `laptop_mac`, Windows `desktop_windows`,
      Linux `computer`, web `language`; `devices_other` when unknown,
      with the name in its tooltip) and, under the ID, the name and **how
      long ago its latest event was**: `Android · 5 min ago` ("just
      now", "5 min ago", "3 h ago", "2 d ago"), with the exact time
      (`2026-10-06 14:05:09`) in a tooltip on that line, or `No events`.
      The line is plain text, so a large system font scales it once and
      it still fits 320 dp. The OS is the
      one on the device's latest event that records one
      ([`os`](events.md)); this device without one shows its own. A
      device whose events are all from before events recorded an OS gets
      the generic icon and just the time.
    - A **presence dot** before each ID ([Device
      presence](device-presence.md)): green (answered a ping within 90 s;
      this device while connected to live sync), yellow (heard from or an
      event within 24 h), red (older, or never), with the reason ("Live —
      answered 5 s ago", "Last seen 3 h ago") as tooltip and screen-reader
      label. **This device's** dot is the connectivity row's color, with
      its headline as the reason ("This device — Live sync failed"),
      updating with it (`ProfileDevices.thisPresence`). Without live sync, yellow or red from the latest event, and
      the reason says live status is unavailable. The list pings the
      devices when the sheet opens and every 30 s while it's open.
    - It fits a 320 dp phone: long IDs wrap and the second line ends with
      an ellipsis.
  - The account sheet for a signed-in user without access shows the same
    profile and devices.
  - The account sheet ends with a short paragraph on what Presence is and
    a link to its source code (see [About](about.md)).
- Sign-ins and sign-outs appear on the **event stream** ("Signed in" /
  "Signed out", with the email).
- Signing in also turns on [cloud sync](cloud-sync.md): the user's Google
  ID token (`AuthService.idToken`) is exchanged, through the auth API and
  Cognito, for temporary AWS credentials for their
  [profile](profiles.md), and clips and events upload to S3.
- **Linked accounts:** the account sheet (and the sign-up sheet, for an
  account without access) opens **Linked accounts**, where a member makes
  a one-time code and another of their Google accounts enters it. That
  account then shares the profile's folder and membership
  (`presence_user`), never the owner's Admin or root roles. See
  [Profiles](profiles.md). On iOS the app now
  also passes the web client as `serverClientId`, so, as on Android and
  web, the ID token is issued for the web client.
- `AuthService` is the interface (`GoogleAuthService` in the app, a fake in
  tests).
- Known limitation: Google ID tokens last about an hour. If the refresh
  before expiry finds nothing (no FedCM auto sign-in), a reload after
  that signs out. The refresh itself may briefly show Google's FedCM
  prompt (web), or Credential Manager's chooser on Android when the
  remembered account must sign in with UI and several accounts have
  signed in to the app.

**Google Cloud:** the project's Google Cloud project (its ID, owner and the
client IDs are in the private repo, `setec-astronomy/presence.nu01`), with
OAuth clients:

| Client | Identifies | In the app |
|---|---|---|
| Web application | JavaScript origins `http://localhost:8080` and `https://local.presence.nu01.com:8443` (local HTTPS through Floci; see [Local CDN](local-cdn.md)), and later `https://presence.nu01.com`. No redirect URI: the web button signs in with Google's popup |  `GoogleConfig.webClientId`: the web client ID, and Android's server client ID |
| Android | package `com.nu01.presence` + signing-key SHA-1 | nothing: matched by package and key (its ID is kept in `.env` as `GOOGLE_ANDROID_CLIENT_ID`, for reference only) |
| iOS | bundle ID `com.nu01.presence` | `GoogleConfig.iosClientId`, plus its reversed ID as a URL scheme |

Client IDs are public identifiers, not secrets, but they're kept out of
the source anyway: they live in the repo's **`.env`** (gitignored; the
committed [.env.example](../.env.example) lists the names), a link to
`presence.nu01/.env` in the private settings repository (see
[Development environment](dev-environment.md#private-settings)). Server and device
starts load it: [scripts/flutter-web.sh](../scripts/flutter-web.sh) (used by
`devbox services up`) and [scripts/flutter-run.sh](../scripts/flutter-run.sh)
(`bash scripts/flutter-run.sh -d <device>`) pass them to Flutter as
`--dart-define`s through [scripts/dart-defines.sh](../scripts/dart-defines.sh),
which forwards **only** an allowlist (`GOOGLE_WEB_CLIENT_ID`,
`GOOGLE_IOS_CLIENT_ID`). Anything passed to Flutter ends up in the compiled
app, and the web bundle is readable, so `.env` can also hold secrets such
as the web client's secret (`GOOGLE_WEB_CLIENT_SECRET`), which the app never
uses and never receives: only a future backend would. Without `.env`, the
account sheet says sign-in isn't set up. The Android client is registered with the development Mac's debug-key
SHA-1 (recorded in the private repo). A release key will need its own
Android client.

The iOS client (its ID is `GOOGLE_IOS_CLIENT_ID` in the private `.env`) was created
with bundle ID `com.nu01.presence` and no App Store ID or Team ID (neither
exists yet; both can be added to the client later without changing it). Its
reversed form (`com.googleusercontent.apps.<id>`) is the URL scheme in
[ios/Runner/Info.plist](../presence_app/ios/Runner/Info.plist)
(`CFBundleURLTypes`, as `$(GOOGLE_REVERSED_CLIENT_ID)`). It isn't committed:
`scripts/dart-defines.sh` writes it from `.env` into the git-ignored
`ios/Flutter/Private.xcconfig`, which the Debug and Release configs
include, so Google's sign-in page can return to the app. On the
simulator, iOS offers to open that URL in Presence. A full sign-in on iOS
hasn't been run yet.

**App ID:** `com.nu01.presence` on Android (namespace and `applicationId`)
and iOS (bundle ID), replacing the `com.example` placeholders. On a device
it installs as a new app, next to any earlier test install.
