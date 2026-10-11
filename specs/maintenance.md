# Maintenance mode

Maintenance mode is **rbacr's**: a flag on rbacr's `presence` system
(rbacr's rules R11 and R12), which rbacr's roots switch. While it's on,
rbacr gives nobody a role in the system, roots included, and the app
shows every signed-in user **no UI at all**: only a sorry message.

## What people see

- **Every signed-in user** (members, premium members, admins, roots,
  people without access) sees only `MaintenanceScreen`
  ([lib/maintenance.dart](../presence_app/lib/maintenance.dart)): a
  construction icon, **"Sorry, Presence is down for maintenance."** and
  "We'll be back soon. This page comes back on its own." Nothing else: no
  tabs, app bar, camera preview, buttons or sign-in. It's shown before
  the recording consent too.
- Nobody gets past it, admins and roots included: there's no admin strip
  or message any more. The sorry screen wins over "no access": the status
  is asked together with the roles, so a user whom rbacr gives no roles
  because of maintenance sees the sorry screen, never the sign-up prompt.
- `MaintenanceGate` sits in `MaterialApp.builder`, so the sorry screen
  replaces the app's whole navigator: the home screen, and any dialog or
  sheet open on it, close. When maintenance ends, the app comes back fresh
  (the Camera tab, or the remembered tab).
- Behind the sorry screen, the app's services keep running: the camera
  (with motion and scheduled clips), cloud sync and live sync. Only the UI
  is withheld.

## Switching it

- **In rbacr**, by a root: the toggle on the `presence` system's page, or
  `PATCH /api/systems/presence` `{"maintenance": true}` (`false` to end
  it). rbacr's pages show a warning and a badge while it's on.
- Presence has no switch of its own: the Admin tab only links to rbacr
  (see [Membership](membership.md#the-admin-tab)), and the auth API has no
  maintenance routes or table.

## How apps learn it

- The app asks rbacr **`GET /api/systems/presence/status`** (the build's
  `RBACR_SYSTEM`; see [Configuration](configuration.md)) with the
  signed-in user's Google ID token, which answers `{id, name, url,
  maintenance}` (`HttpRbacrClient.maintenance` in
  [lib/auth/rbacr_client.dart](../presence_app/lib/auth/rbacr_client.dart)).
- It asks **at each roles check** (with `GET /api/me` and the auth API's
  `GET /api/auth/profile`; see [Sign-in](sign-in.md)) and then **every
  minute** (`RolesService.maintenanceCheckInterval`, with the auth API's
  health check `checkApi`), so a running app (an unattended phone)
  follows a switch within a minute (`RolesService.checkMaintenance`).
- `RolesService.inMaintenance` is rbacr's last answer. If the status
  can't be fetched, the last answer stands (it starts off). When rbacr
  says it's off again, the roles are checked again at once: the checks
  made during it got none.

## Known limitations

- **Signed-out users never see it.** rbacr answers nobody without a
  token, so a signed-out app can't ask: it shows sign-in, and after
  sign-in the sorry screen.
- **DEV never asks** rbacr: there are no accounts.
- **UI only.** The app keeps recording, and cloud sync and live sync keep
  their credentials, behind the sorry screen. But rbacr gives the auth API
  no roles in the system either meanwhile (roots aside), so its routes
  that need `presence_user` (new cloud credentials, link codes) refuse
  (403) until it ends. A user with an old, running app sees
  the sorry screen within a minute.
- **Admins and roots are shut out too**: they switch it off in rbacr, not
  in the app.
- When rbacr can't be reached at all, the roles check fails too (see
  [Sign-in](sign-in.md)), so users see "no access" (with its retries)
  rather than the sorry screen.
