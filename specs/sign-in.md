# Sign-in

Sign in with Google, through the `google_sign_in` package
([lib/auth/](../presence_app/lib/auth)). Signing in unlocks the navigation;
there's no separate sign-in screen:

- **At launch** the app checks for a session quietly
  (`attemptLightweightAuthentication`: FedCM auto sign-in on web, Credential
  Manager's authorized accounts on Android, the saved session on iOS). The
  camera opens right away either way.
- **Signed out:** the camera shows full screen with its controls (flip,
  Clip, readiness), always recording as usual, but the **navigation is
  hidden**: the app bar has only the "Presence" title and **Sign in with
  Google**. You can't switch or swipe to Events or Settings, and the clip
  message has no "View" action. On web the button is Google's own (GIS
  `renderButton` with FedCM, medium size to fit the app bar), as Google
  Identity Services requires. On Android and iOS it's an app button that
  starts Google's sign-in: Credential Manager's Sign in with Google sheet,
  or the Google SDK. While the launch check runs, the button is hidden. If
  no client ID is configured, a person icon opens a sheet saying sign-in
  isn't set up. Sign-in errors pop a message.
- **Signed in:** all the buttons: the Camera / Events / Settings tabs and
  the **account button**, your avatar with the tooltip "Signed in as
  <name> · <email>". It opens a bottom sheet with avatar, name, email and
  **Sign out**. Signing out closes the sheet, returns to the camera and
  hides the navigation again. The camera keeps running.
- Sign-ins and sign-outs appear on the **event stream** ("Signed in" /
  "Signed out", with the email).
- Sign-in only identifies the user for now: there's no backend, and data
  stays on the device.
- `AuthService` is the interface (`GoogleAuthService` in the app, a fake in
  tests).

**Google Cloud:** project `presence-492410` (Presence, owned by
julio@nu01.com), with OAuth clients:

| Client | Identifies | In the app |
|---|---|---|
| Web application | JavaScript origins `http://localhost:8080` and `https://local.presence.nu01.com:8443` (local HTTPS through Floci; see [Local CDN](local-cdn.md)), and later `https://presence.nu01.com`. No redirect URI: the web button signs in with Google's popup |  `GoogleConfig.webClientId`: the web client ID, and Android's server client ID |
| Android | package `com.nu01.presence` + signing-key SHA-1 | nothing: matched by package and key (its ID is kept in `.env` as `GOOGLE_ANDROID_CLIENT_ID`, for reference only) |
| iOS | bundle ID `com.nu01.presence` | `GoogleConfig.iosClientId`, plus its reversed ID as a URL scheme |

Client IDs are public identifiers, not secrets, but they're kept out of
the source anyway: they live in the repo's **`.env`** (gitignored; the
committed [.env.example](../.env.example) lists the names). Server and device
starts load it: [scripts/flutter-web.sh](../scripts/flutter-web.sh) (used by
`devbox services up`) and [scripts/flutter-run.sh](../scripts/flutter-run.sh)
(`bash scripts/flutter-run.sh -d <device>`) pass them to Flutter as
`--dart-define`s through [scripts/dart-defines.sh](../scripts/dart-defines.sh),
which forwards **only** an allowlist (`GOOGLE_WEB_CLIENT_ID`,
`GOOGLE_IOS_CLIENT_ID`). Anything passed to Flutter ends up in the compiled
app, and the web bundle is readable, so `.env` can also hold secrets such
as the web client's secret (`GOOGLE_WEB_CLIENT_SECRET`), which the app never
uses and never receives: only a future backend would. Without `.env`, the
account sheet says sign-in isn't set up. The Android debug key SHA-1 on the development Mac
is `B8:90:8F:2F:A4:85:36:0D:32:34:86:22:2E:EE:B4:AD:6D:9A:42:A4`. A release
key will need its own Android client.

The iOS client is `104441697281-djrabadfdeavjb7sejfgu855duq716p6`, created
with bundle ID `com.nu01.presence` and no App Store ID or Team ID (neither
exists yet; both can be added to the client later without changing it). Its
ID goes in `.env` as `GOOGLE_IOS_CLIENT_ID`, and its reversed form,
`com.googleusercontent.apps.104441697281-djrabadfdeavjb7sejfgu855duq716p6`,
is registered in [ios/Runner/Info.plist](../presence_app/ios/Runner/Info.plist)
(`CFBundleURLTypes`) so Google's sign-in page can return to the app. On the
simulator, iOS offers to open that URL in Presence. A full sign-in on iOS
hasn't been run yet.

**App ID:** `com.nu01.presence` on Android (namespace and `applicationId`)
and iOS (bundle ID), replacing the `com.example` placeholders. On a device
it installs as a new app, next to any earlier test install.
