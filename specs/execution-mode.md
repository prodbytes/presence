# Execution mode

The system runs in one of two modes, decided by whether an OIDC client (the
Google web client, `GOOGLE_WEB_CLIENT_ID`) is configured. There's no
separate setting, so a system with sign-in can't be opened by mistake.

| Mode | When | The anonymous user | Signed-in users |
|---|---|---|---|
| **RBAC** | An OIDC client is configured (always in AWS) | Role `presence_anonymous` only: may only sign in | Their roles, as before (see [Sign-in](sign-in.md)) |
| **DEV** | No OIDC client (local development) | Every role: `presence_anonymous`, `presence_user`, `presence_admin`, `presence_root` | Nobody can sign in |

## The start check

- Before showing anything, the app asks the [auth API](auth-api.md)
  `GET /api/auth/anonymous`, without a token, for the mode and the
  anonymous user's roles. It shows a spinner meanwhile (up to 5 s).
- If the API doesn't answer (it isn't deployed, or the app runs on the
  Flutter dev server at `http://localhost:8080/app/`, which has no
  `/api/*`), the app decides by its own build: **DEV without a Google
  client ID, else RBAC**. A production build always has one, so it can't
  fall back to DEV.
- An unanswered start check is **checked again** (`RolesService.checkApi`,
  15 s timeout) after 5 s, 15 s, 30 s and then every minute, until the
  API answers, so the health line's ❌ clears on its own. The mode stays
  the one the start check decided. A phone's first HTTPS request can take
  ~10 s while the app starts (seen on Android with a debug build: the
  request reached the API 4 s after the 5 s start check gave up).
- `RolesService` (`lib/auth/roles_service.dart`) holds the result:
  `ExecutionMode` (`dev`, `rbac`), `AccessState.starting` until it's
  known, and `apiError` when the API didn't answer.

## DEV in the app

- The anonymous user is a **root** (every role, as the table says), so
  every feature shows: the Camera, Monitoring, Settings and Log tabs (the
  Log on by default here, and it can be turned off in Settings), and
  the camera's view, Flip and Clip (with its readiness colors) buttons.
- What only makes sense with accounts is hidden: **Sign in with Google**,
  the account button and sheet, the sign-up icon and the **Admin** tab.
- An outlined **"dev"** label sits on the left of the app bar (there's no
  title), in 14 sp
  text (`labelLarge`; it was 11 sp, `labelSmall`). When
  the build has a version, it shows it too: **"dev 0.4.202610011728"**
  (`DevModeLabel`, from `AppVersion.version`). Where there's no room, as on
  a narrow phone, it's cut short with an ellipsis. Its tooltip says
  sign-in isn't configured, so everything is open, with the version.
- Cloud sync never runs in DEV, even with a session saved from before:
  access doesn't come from signing in.

## RBAC in the app

Unchanged: signed out, the anonymous user sees the camera and **Sign in
with Google** only; after sign-in, `GET /api/auth` decides the rest.

## Safety

- The API reads the mode from `GOOGLE_WEB_CLIENT_ID` alone
  (`presence.auth.ExecutionMode`). `scripts/deploy.sh` refuses to deploy
  without it, and its smoke test requires `/api/auth/anonymous` to answer
  exactly
  `{"mode":"RBAC","roles":["presence_anonymous"],"settings":{"oidc":true,"aws":true,"rbacr":true}}`
  (`"rbacr":false` when it deployed without an rbacr token).
- DEV only changes what the app shows. The API's other routes still need a
  Google ID token (in DEV the authorizer's audience is `no-oidc-client`, so
  none passes), and cloud sync needs a Google sign-in.
- Known gap: a manual `sam deploy` of a new auth API stack without
  `GoogleWebClientId` would come up in DEV.

## Verified

Locally without `.env` (`devbox services up`): Floci deployed the API in
DEV (`/api/auth/anonymous` answered DEV with every role, `/api/auth` was
404), and Chrome showed the "dev" label, all three tabs and Clip, no
sign-in or account button, and the Settings health line `🔌 API ✅ ·
☁️ AWS ⚪ · 🔑 OIDC ⚪`. RBAC is covered by the unit and widget tests; it
wasn't run live.
