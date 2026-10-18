# Sign-in

Sign in with Google (the `google_sign_in` package), and on iOS also with
**Sign in with Apple** (the `sign_in_with_apple` package)
([lib/auth/](../presence_app/lib/auth)). Either way the app trades the
provider's ID token for a **Presence session** at once
([Sessions](sessions.md)) and from then on uses only the session token.
Signing in unlocks the navigation; there's no separate sign-in screen:

- **At launch** the app restores the session it kept, before Google's
  library even loads (below); without one it checks for a Google session
  quietly (`attemptLightweightAuthentication`: FedCM auto sign-in on web,
  Credential Manager's authorized accounts on Android, the saved session
  on iOS), and on Android first signs a remembered account back in with no
  UI (below). The camera opens right away either way.

## Sessions

- **Every sign-in is exchanged** (`GoogleAuthService`, which also does
  Apple; `AuthSession`'s `HttpSessionApi`,
  [lib/auth/auth_session.dart](../presence_app/lib/auth/auth_session.dart)):
  Google's sign-in event, its quiet check, Android's silent sign-in and
  Apple's sign-in all send the provider's ID token to `POST
  /api/auth/session`. The user and the session token are set together,
  only once the exchange answers, so the roles check never sees a user
  without a token. A refused exchange shows as the sign-in error;
  one that can't reach the API (offline, 429, 5xx) is tried three times
  (now, after 1 s and 3 s), and a silent one backs off quietly.
- **`AuthService.idToken` is the session token**, the bearer of every
  call: the auth API (profile, credentials, linking, account deletion),
  [cloud recognition](cloud-recognition.md), [payments](payments-api.md),
  [cloud sync](cloud-sync.md)'s credentials, and rbacr. No provider's ID
  token is sent anywhere but the exchange.
- **The user** (`AuthUser`) comes from the session token's claims: `id` is
  the provider's subject (`idp_sub`: Google's `sub` as before, or
  Apple's), with its `email`, `name` and `picture`.
- **Refreshed five minutes before it expires** (it lasts an hour), with
  the refresh token, one refresh at a time; the new refresh token replaces
  the old one, which is never sent again. A refresh that can't reach the
  API keeps the session and tries again in 1, 2, 4, 8 and then every 15
  minutes. A refused refresh (the session ended: expired, revoked, or the
  refresh token used twice) falls back: for a Google session, the
  Android silent sign-in of the same account (with its backoff) or, off
  Android or when the account must sign in with UI, Google's quiet check,
  whose new token is exchanged; for an Apple session, which can't sign in
  without the user, the app signs out and says "Your session ended. Sign
  in again." Results that arrive after a sign-out or a newer sign-in are
  dropped (their refresh token revoked).
- **Kept across restarts and reloads:** `{provider, user, token,
  expiresAt, refreshToken}` (`SavedSession`,
  [lib/auth/saved_session.dart](../presence_app/lib/auth/saved_session.dart)):
  - on Android and iOS in secure storage (`flutter_secure_storage`
    11.1.1: Keystore-encrypted on Android; the Keychain on iOS, readable
    after the first unlock so a locked phone refreshes after a reboot,
    this device only, never in a backup or iCloud). An Android backup
    restored on another phone can't be decrypted there, so it falls back
    to the silent sign-in;
  - on web in `localStorage` (`presence.session`). Anything able to run
    script on the site could read the refresh token; an httpOnly cookie
    set by the API would avoid that, and isn't built.

  At launch a kept session with more than a minute left signs in at once;
  an expired one is refreshed at once (the user shows while it's asked,
  without a token, and retries with the backoff if the API can't be
  reached); a refused one is dropped and the launch goes on as without
  one. Sessions kept by builds before sessions (a Google ID token) are
  dropped.
- **Sign out** revokes the session (`POST /api/auth/session/revoke`,
  without waiting for it), forgets it, forgets Android's remembered
  account and signs out of Google.

## Sign in with Apple (iOS)

- Offered only on iOS (`appleSignInSupported`: never on web or Android),
  **beside Google with equal prominence**: the signed-out account sheet
  stacks Apple's button over Google's, both full width, 44 high (Apple's
  minimum), pill-shaped, 16 sp medium titles
  ([brand_buttons.dart](../presence_app/lib/auth/brand_buttons.dart)).
  Apple's (`AppleSignInButton`) is the app's own, per Apple's guidelines:
  black in light mode, white in dark, Apple's logo and "Sign in with
  Apple" translated (the package's button forced a 21 sp SF title that
  was too big and rendered badly). The app bar has room
  for one button at 320 dp, so on iOS it shows **Sign in**, which opens a
  sheet with both (`SignInSheet`); it closes once signed in.
- It asks Apple for the **email and full name**, with a **nonce**: 32
  random bytes (base64url) per sign-in, whose SHA-256 goes to Apple and
  the nonce itself to the exchange, which checks Apple's token carries its
  hash. The exchange also gets Apple's **authorization code** (so the
  auth API can revoke the user's Apple tokens when the account is deleted)
  and, at the account's very first sign-in, the **name**, which Apple
  gives only then and the auth API keeps for later sessions. Apple's
  private-relay email addresses are fine.
- Cancelling Apple's sheet isn't an error. An Apple account is its own
  [profile](profiles.md) subject (`https://appleid.apple.com#<sub>`): it
  joins a Google account's profile with a link code.
- The iOS app has `Runner.entitlements` with
  `com.apple.developer.applesignin` = `[Default]` (the Runner target's
  `CODE_SIGN_ENTITLEMENTS`); see [iOS](ios.md).

## Restarts and reloads

- **Reloads keep you signed in (web)**, from the kept session (above).
  Google Identity Services keeps no session on web: without a kept
  session, the silent FedCM attempt runs at launch.
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
  - when the session's refresh token is refused (above), this is the
    fallback, for the signed-in account: its new Google ID token is
    exchanged for a new session;
  - **a failure is retried quietly, never with the chooser**: when the
    silent sign-in fails for a reason that may pass (Play services'
    status 8, `INTERNAL_ERROR`; offline; the auth API unreachable for the
    exchange), the app tries again in 1, 2, 4, 8 and then every 15
    minutes, keeping the session (the user stays signed in; cloud sync
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

  With a kept session, a restart doesn't need any of this: the session is
  restored or refreshed. This path signs in when there's none (the first
  launch after updating to sessions, or a session that ended).
## Signed out and signed in

- **Before anything shows**, the app asks the auth API for the
  [execution mode](execution-mode.md). In DEV (no OIDC client) there's no
  sign-in at all, and everything below about signing in doesn't apply.
- **Signed out (RBAC):** the anonymous user (`presence_anonymous`) may only
  sign in. The camera shows full screen, always recording as
  usual, with **no buttons on it** (no view, Flip or Clip button), and the
  **navigation is hidden**: no bottom navigation bar, and the app bar
  has only **Sign in with Google** (on iOS, **Sign in**, for Apple and
  Google; above). Nothing is uploaded. You can't switch
  to Monitoring or Settings, and the clip
  message has no "View" action. On web the button is Google's own (GIS
  `renderButton` with FedCM, medium size to fit the app bar), as Google
  Identity Services requires. On Android and iOS it's an app button that
  starts Google's sign-in: Credential Manager's Sign in with Google sheet,
  or the Google SDK. That button (`GoogleSignInButton`) follows Google's
  branding guidelines: the four-colour "G" (painted from Google's SVG)
  and "Sign in with Google", on white with a `#747775` border and
  `#1F1F1F` text in light mode, on `#131314` with a `#8E918F` border and
  `#E3E3E3` text in dark; pill-shaped, 40 high with a 14 sp title in the
  app bar (it fits beside the account actions at 360 dp), 44 high in the
  account sheet. While the launch check runs, the button is hidden. If
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
  After sign-in, the app asks two places at once, with the session token
  (`HttpRolesClient`):
  - **rbacr** (`GET /api/me`, `Authorization: Bearer <session token>`;
    `HttpRbacrClient` in
    [lib/auth/rbacr_client.dart](../presence_app/lib/auth/rbacr_client.dart))
    for the user's **own roles**: rbacr's roles in the build's system
    (`RBACR_SYSTEM`, default `presence`; see
    [Configuration](configuration.md)) mapped as the auth API maps them
    (`presenceRoles`): `presence_user` for `free`, `premium` or `admin`,
    `presence_premium` for `premium` or `admin`, `presence_admin` for
    `admin`, and all four (`presence_root` too) for an rbacr root
    (`root: true`). rbacr accepts Presence's session tokens (its
    `RBACR_TRUSTED_ISSUERS`; see [Sessions](sessions.md#the-authorizers));
  - the [auth API](auth-api.md) (`GET /api/auth/profile`) for their
    [profile](profiles.md) (`RolesService.profile`), which it finds by
    the account or makes at the first sign-in, and `shared`, the
    membership a linked account shares from the profile's owner
    (`presence_user` and/or `presence_premium`; the app takes nothing
    else from it);
  - the roles are the own ones plus the shared ones. **Both must
    answer**, or the check fails; nothing is cached. At the same time it
    asks rbacr whether the system is in
    [maintenance](maintenance.md), so the sorry screen, not "no access",
    shows while it is.
  - **With `presence_user`,** the user gets everything below. Other roles
    alone don't count.
  - **With `presence_admin` too,** the **Admin** tab also shows (see
    [Membership](membership.md#the-admin-tab)). `presence_root`
    (`RolesService.isRoot`) adds nothing more in the app. Every role comes
    from rbacr, roots from its root list (see [Auth API](auth-api.md)).
  - **Without `presence_user`, or if the check fails** (deny by default),
    the app shows only the camera, the account button and a **sign-up**
    icon. The icon opens the sign-up sheet, which offers **Join free** in
    the iOS and Android apps (the payments API grants rbacr's `free`) or
    sends the user to subscribe at nu01.com on the web and desktop, takes
    a voucher code (see [Membership](membership.md)), and
    has **Check again**, which asks rbacr and the auth API once more. There are no tabs,
    no camera buttons, and no cloud sync.
  - While the check runs, a small spinner takes the sign-up icon's place.
  - The check runs when the user changes (sign-in, a session restored at
    launch, sign-out). A check that failed also runs again when a silent
    sign-in or refresh brings a new token, so a stale restored token or an API
    still starting doesn't leave a member on the sign-up screen.
  - **A check that failed is retried on its own**, after 5 s, 15 s, 30 s
    and then every minute, until it answers (and at once when the auth
    API's health check answers again after failing; that check runs every
    15 min, on resume and soon after a failure, see
    [Maintenance](maintenance.md)), so an unattended
    phone that rebooted offline gets its access back without anyone
    pressing Check again. These retries keep the sign-up screen up
    rather than flash the spinner; a sign-out or another account stops
    them.
  - The check's errors say which side failed: "Auth API HTTP n" or
    "rbacr HTTP n".
  - Web asks the auth API on its own origin (`/api/auth/profile`).
    Android and iOS ask `API_BASE_URL`, `https://presence.nu01.com` by
    default. rbacr is the build's `RBACR_URL` (GA
    https://rbacr.nu01.com by default; tokens go only to https, or http
    to localhost).
- **Signed in as a `presence_user`:** all the buttons: the camera's view, Flip and Clip
  (with its readiness colors), the tabs and, last among them, the
  **Profile** tab: your avatar with the tooltip "Signed in as
  <name> · <email>" (see [Navigation](navigation.md)). It opens, as a
  page of the tabs, the **account sheet**'s content: avatar, name, email,
  the user's **roles**, this device's **connectivity**, the [cloud sync](cloud-sync.md) status,
  the **profile** and its **devices**, and **Sign out**. Signing out returns to the camera and
  hides the navigation again (closing the sheet, where it's one: signed
  in without access, the app bar's account button still opens it as a
  bottom sheet). The camera keeps running.
  - **Roles**, always, right under the email (`AccountRoles`): a small
    outlined chip with the account's **access**, as rbacr's `presence`
    system gives it ([Premium and free](premium.md)): **Free Access**,
    **Premium Access** or **Admin Access**, with the rbacr role
    ("rbacr: admin") as its tooltip. The app maps rbacr's roles to its own
    (see below), so it reads the rbacr role back from them (admin
    if `presence_admin`, else premium if `presence_premium`, else free if
    `presence_user`). A linked account shows its profile owner's premium
    ([Profiles](profiles.md)). After it, a chip per other role: **Root**,
    or another role's ID, with the ID as its tooltip. "Roles: Admin
    Access, Root" for screen readers. "No roles yet" without any (a
    signed-in account without access), "Checking roles…" while rbacr and the
    auth API are asked. The anonymous role isn't shown.
  - **No live sync or cloud backup line** here: they show on the other
    pages (the Events tab's sync, the Log tab's
    [health panel](log.md)). This device's **dot** in the device list
    still takes its color from the same checks (`Connectivity.of`,
    [lib/connectivity.dart](../presence_app/lib/connectivity.dart):
    `SystemHealth.statusOf` for the auth API, cloud sync and
    [live sync](live-sync.md); the worst decides, the API first among
    equals): 🟢 when the API answers, cloud sync is set and live sync is
    connected; 🟡 when degraded (checking, connecting, idle, off, not set
    up in this build); 🔴 when a check failed. Its tooltip reads "This
    device — <headline>" ("Live sync idle", "Offline: can't reach the
    server"…).
  - **Devices** ("3 devices"): every [device ID](devices-users-places.md#devices)
    found on the profile's events (`profileDevices`), the events synced
    from the profile's cloud folder included, so the same account's other
    devices and linked accounts' devices show, and every device the auth
    API lists for the profile (`DeviceSlots.devices`, with the
    credentials), so a device shows before its first event (a Raspberry Pi
    streamer that hasn't seen anyone yet: no OS, no latest event). This device comes
    first, labelled "this device", even before it has an event; the rest
    go **most recently active first** (`recentFirst`): the newer of the
    device's latest event and its latest answer over live sync, then
    those never active, by ID. The list updates while the sheet is open, and scrolls when
    long. A row is small: each ID is selectable, 11 sp
    (`ProfileDevices.deviceIdSize`) on one line beside its presence dot,
    scaled down to fit when it's still too long (at a large system font)
    rather than broken mid-word; "this device", "leader" (the profile's
    leading streamer, `DeviceSlots.leader`, in the accent color, with a
    tooltip: [Streamer leadership](streamer-leader.md)) and "hidden" go under it in
    `bodySmall` (12 sp), its details in `labelSmall` (11 sp), its OS icon 16
    px; with access the ID is
    in the accent color and a tap **shows the device's events**: the
    sheet closes and Monitoring opens with the search set to the ID (see
    [Navigation](navigation.md)); "this device"
    sits beside it, or under it when they don't fit on one line (at 320
    dp with a 2x system font). A device shows only once one of its
    events has synced here, and drops off when its events age out of
    [event retention](event-retention.md).
    - **Hide/show:** every device, this one too, has an eye button at
      the end of its row: it hides the device's events on this device,
      or shows them again; the device stays listed. See
      [Hiding a device](device-hiding.md).
    - **Delete:** every device but this one has a delete button beside
      the eye; it asks whether to keep the device's videos (it only leaves
      the list) or delete them (its events are hidden on every device).
      See [Device deletion](device-deletion.md).
    - Each device shows its **operating system** (`profileDeviceDetails`):
      an icon before the ID (Android `Icons.android`, iOS
      `phone_iphone`, macOS `laptop_mac`, Windows `desktop_windows`,
      Linux `computer`, web `language`; `devices_other` when unknown,
      with the name in its tooltip) and, under the ID, the name, its
      **memory** when it says (`Android · 3.5 GB · 5 min ago`: whole or
      half GB, MB under one, `formatMemory`; from its latest event that
      records it, [`memoryMb`](data-formats.md)), and **how
      long ago its latest event was** ("just
      now", "5 min ago", "3 h ago", "2 d ago"), with the exact time
      (`2026-10-06 14:05:09`) in a tooltip on that line, or `No events`.
      The line is plain text, so a large system font scales it once and
      it still fits 320 dp. The OS is the
      one on the device's latest event that records one
      ([`os`](events.md)); this device without one shows its own. A
      device whose events are all from before events recorded an OS gets
      the generic icon and just the time.
    - A **presence dot** before each ID ([Device
      presence](device-presence.md)): green (active within 5 sync
      timeouts; this device while connected to live sync), yellow
      (within 10), red (older, or never), with the reason ("Live —
      answered 5 s ago", "Last seen 7 min ago") as tooltip and screen-reader
      label. **This device's** dot is the connectivity row's color, with
      its headline as the reason ("This device — Live sync failed"),
      updating with it (`ProfileDevices.thisPresence`). Without live sync, yellow or red from the latest event, and
      the reason says live status is unavailable. The list pings the
      devices when the sheet opens and every 30 s while it's open.
    - It fits a 320 dp phone: long IDs wrap and the second line ends with
      an ellipsis.
  - Devices past the plan's limit are labelled **hidden**; under the list,
    when any are, one small muted line says how many ("3 devices hidden",
    or "This device doesn't sync"), with a discreet **Upgrade** link on
    the web ([Premium and free](premium.md#in-the-app)). Below it a box
    says whether the account is **Free** or **Premium**, what
    that gives, and for Free how to buy Premium (on the web **Premium
    monthly** and **Premium yearly**, the plans' Stripe checkouts; on iOS
    and Android the App Store's or Google Play's plans, Restore purchases
    and Manage subscription) and **Check again**; see [Premium and free](premium.md#in-the-app)
    and [Upgrade to Premium](upgrade.md).
  - Under it, for a premium profile (or an admin), a **Stream from a
    Raspberry Pi** box: the command that installs the
    [streamer](streamer.md) on a Pi for this profile, `curl -fsSL
    https://sh.presence.nu01.com/streamer | sh -s -- <profile>`, with
    **Copy command** (see [Install script](install-script.md#streamer)).
  - The account sheet for a signed-in user without access shows the same
    profile and devices.
  - Under **Sign out**, once the auth API has answered with the profile,
    **Delete account** (error-colored), which asks first and deletes the
    account, or with it the whole profile for its owner, then signs out
    (see [Account deletion](account-deletion.md)); for signed-in users
    without access too.
  - **Profile:** at the bottom, above About, discreet: "Profile
    `automatic_paranoid_axolotl`" in `labelSmall` (11 sp), muted, centred,
    the [profile](profiles.md) ID (the profile's only name) selectable to
    copy.
  - The account sheet ends with a short paragraph on what Presence is and
    a link to its source code (see [About](about.md)).
- Sign-ins and sign-outs appear on the **event stream** ("Signed in" /
  "Signed out", with the email; a deleted account's sign-out is "Account
  deleted", without it).
- Signing in also turns on [cloud sync](cloud-sync.md): the session token
  (`AuthService.idToken`) is exchanged, through the auth API and
  Cognito, for temporary AWS credentials for their
  [profile](profiles.md), and clips and events upload to S3.
- **Linked accounts:** the account sheet (and the sign-up sheet, for an
  account without access) opens **Linked accounts**, where a member makes
  a one-time code and another of their accounts (Google or Apple) enters it. That
  account then shares the profile's folder and membership
  (`presence_user`), never the owner's Admin or root roles. See
  [Profiles](profiles.md). On iOS the app now
  also passes the web client as `serverClientId`, so, as on Android and
  web, the ID token is issued for the web client.
- `AuthService` is the interface (`GoogleAuthService` in the app, Google
  and Apple, a fake in tests). Sign-in problems it knows
  (`AuthService.problem`: refused, no verified email, not set up, the
  server unreachable, the session ended) show translated; others as
  "Sign-in failed: <reason>".
- Known limitations: a session ends after 60 days without a refresh, at
  sign-out, or when its refresh token is used twice (a copy, or a retry
  more than a minute after a lost answer). Then a Google session falls
  back to Google, which may briefly show Google's FedCM prompt (web), or
  Credential Manager's chooser on Android when the remembered account
  must sign in with UI and several accounts have signed in to the app;
  an Apple session must sign in again.

## Verified

- `session_test.dart`: the kept session's encoding, validity and refresh
  time, malformed and pre-session ones dropped; `HttpSessionApi`'s
  requests (Apple's nonce, code and trimmed name) and how answers are
  classified (400/401/403 refused; 429, 5xx, offline and malformed
  retried); a kept session at launch, and sign-out revoking and
  forgetting it; an expired token refreshed at launch and rotated; a
  refused one dropped; the API unreachable at launch keeping the user
  without a token and backing off; refresh before expiry with rotation
  (no refresh token sent twice); a failed refresh keeping the session;
  an Apple session refused signing out with "session ended"; a refused
  exchange's problem; the exchange's quick retries; a refresh answering
  after sign-out revoked; no token in the log.
- `silent_sign_in_test.dart`: Android's silent sign-in at launch, the
  quiet check without a remembered account, the backoff without the
  chooser, `SIGN_IN_REQUIRED`, sign-out, all through the exchange; a dead
  refresh token falling back to the same account's silent sign-in; the
  exchange unreachable retried quietly, refused not retried; off Android,
  the quiet check's token exchanged.
- `apple_sign_in_test.dart`: Apple offered on iOS only; both buttons the
  same size (44 high) on iOS, Google alone on Android and web; Apple's
  button black and Google's white with their logos in light mode, Apple's
  white and Google's `#131314` in dark mode, translated in Spanish; at 320 dp the app bar's
  **Sign in** opens both and closes once signed in.
- `flutter build ios --simulator --debug` builds with the entitlement.

## Clients

**Apple:** Sign in with Apple needs the capability on the App ID
`com.nu01.presence` (Apple Developer, Identifiers), which the
entitlement asks for: a build signed for a team without it fails to
sign (the simulator doesn't check). The auth API accepts Apple ID tokens
for the bundle ID (`AppleClientIds`). Revoking users' Apple tokens when
they delete their account needs a Sign in with Apple key (Apple
Developer, Keys) in SSM; see [Sessions](sessions.md#sign-in-with-apples-revocation).

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
`GOOGLE_IOS_CLIENT_ID`, the cloud and live-sync IDs, and rbacr's
`RBACR_URL` and `RBACR_SYSTEM`; see
[Configuration](configuration.md#build-time-settings-rbacr)). Anything passed to Flutter ends up in the compiled
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
