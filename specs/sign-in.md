# Sign-in

Sign in with Google, through the `google_sign_in` package
([lib/auth/](../presence_app/lib/auth)). Signing in unlocks the navigation;
there's no separate sign-in screen:

- **At launch** the app checks for a session quietly
  (`attemptLightweightAuthentication`: FedCM auto sign-in on web, Credential
  Manager's authorized accounts on Android, the saved session on iOS). The
  camera opens right away either way.
- **Reloads keep you signed in (web).** Google Identity Services keeps no
  session on web, so the app remembers it itself:
  - on each sign-in, the user (ID, email, name, photo) and their Google ID
    token go into `localStorage` (`presence.session`; `SessionStore`,
    `SavedSession`);
  - at launch, before Google's library loads, a remembered session whose
    token has more than a minute left is restored, so the user is signed in
    at once;
  - the silent FedCM attempt still runs and refreshes the token when Google
    allows. When it finds nothing, the restored session stays;
  - an expired or malformed session is dropped;
  - **Sign out** forgets it.

  Android and iOS don't need this: their Google SDKs keep the session.
- **Before anything shows**, the app asks the auth API for the
  [execution mode](execution-mode.md). In DEV (no OIDC client) there's no
  sign-in at all, and everything below about signing in doesn't apply.
- **Signed out (RBAC):** the anonymous user (`presence_anonymous`) may only
  sign in. The camera shows full screen, always recording as
  usual, with **no buttons on it** (no Flip, Clip or readiness), and the
  **navigation is hidden**: the app bar has only the "Presence" title and
  **Sign in with Google**. Nothing is uploaded. You can't switch or swipe to Events or Settings, and the clip
  message has no "View" action. On web the button is Google's own (GIS
  `renderButton` with FedCM, medium size to fit the app bar), as Google
  Identity Services requires. On Android and iOS it's an app button that
  starts Google's sign-in: Credential Manager's Sign in with Google sheet,
  or the Google SDK. While the launch check runs, the button is hidden. If
  no client ID is configured, a person icon opens a sheet saying sign-in
  isn't set up. Sign-in errors show as a message pill over the camera
  ("Sign-in failed: <reason>"; see [Navigation](navigation.md)).
- **Roles decide the rest** (`RolesService`, `lib/auth/roles_service.dart`).
  After sign-in, the app asks the [auth API](auth-api.md) (`GET /api/auth`,
  with the Google ID token) for the user's roles and their
  [profile](profiles.md), which the API finds by the account, or creates
  at the first sign-in (`RolesService.profile`):
  - **With `presence_user`,** the user gets everything below. Other roles
    alone don't count.
  - **With `presence_admin` too,** an **Admin** icon also shows, left of
    the account button (see [Membership](membership.md)).
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
  - Web asks its own origin (`/api/auth`). Android and iOS ask
    `API_BASE_URL`, `https://presence.nu01.com` by default.
- **Signed in as a `presence_user`:** all the buttons: the camera's Flip, Clip and
  readiness, the Camera / Events / Settings tabs and
  the **account button**, your avatar with the tooltip "Signed in as
  <name> · <email>". It opens a bottom sheet with avatar, name, email, the
  [cloud sync](cloud-sync.md) status and **Sign out**. Signing out closes the sheet, returns to the camera and
  hides the navigation again. The camera keeps running.
- Sign-ins and sign-outs appear on the **event stream** ("Signed in" /
  "Signed out", with the email).
- Signing in also turns on [cloud sync](cloud-sync.md): the user's Google
  ID token (`AuthService.idToken`) is exchanged with Cognito for temporary
  AWS credentials, and clips and events upload to S3. On iOS the app now
  also passes the web client as `serverClientId`, so, as on Android and
  web, the ID token is issued for the web client.
- `AuthService` is the interface (`GoogleAuthService` in the app, a fake in
  tests).
- Known limitation: Google ID tokens last about an hour. A reload after
  that, without FedCM auto sign-in, signs out.

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
