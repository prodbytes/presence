# Maintenance mode

Admins can put the whole system in maintenance mode. While it's on, the app
shows **no UI at all** to anyone but admins: only a sorry message.

## What people see

- **Everyone but admins** (signed out, members, premium members, people
  without access) sees only `MaintenanceScreen`
  ([lib/maintenance.dart](../presence_app/lib/maintenance.dart)): a
  construction icon, **"Sorry, Presence is down for maintenance."**, "We'll
  be back soon. This page comes back on its own.", and the admin's message
  under it when they left one. Nothing else: no tabs, app bar, camera
  preview, buttons or sign-in. It's shown before the recording consent too.
- `MaintenanceGate` sits in `MaterialApp.builder`, so the sorry screen
  replaces the app's whole navigator: the home screen, and any dialog or
  sheet open on it, close. When maintenance ends, the app comes back fresh
  (the Camera tab, or the remembered tab).
- **Admins** (`presence_admin`, signed in; the session restored at launch
  counts) keep the app, under a yellow strip: "Maintenance mode is on:
  only admins see the app." They switch it off on the Admin tab.
- Behind the sorry screen, the app's services keep running: the camera
  (with motion and scheduled clips), cloud sync and live sync. Only the UI
  is withheld.

## Switching it

- **The Admin tab** starts with a **Maintenance mode** card
  (`_MaintenanceCard` in
  [lib/auth/admin_screen.dart](../presence_app/lib/auth/admin_screen.dart)):
  a switch (On / Off, with when it was last switched and by whom), and an
  optional **Message** (up to 500 characters, three lines) shown under the
  sorry message. Switching it on sends the message; while it's on,
  **Update message** sends a new one. Switching it off clears the
  message. A snackbar confirms each switch, or says why it failed. The
  card loads with the rest of the page (Reload, or pull down).
- After a switch, the admin's app asks the auth API again at once
  (`RolesService.checkApi`), so the strip comes and goes right away.
- **Without the app** (no admin can reach the Admin tab: a signed-out
  admin sees only the sorry message, with no way to sign in),
  [scripts/maintenance.sh](../scripts/maintenance.sh) switches it with AWS
  credentials: `scripts/maintenance.sh` says whether it's on,
  `scripts/maintenance.sh on "Back at 3 pm"` and
  `scripts/maintenance.sh off` switch it (`STAGE=rc` for the RC). It writes
  the same item, with `by` the AWS caller's ARN.

## How apps learn it

- `GET /api/auth/anonymous` (no token, see [Auth API](auth-api.md))
  answers `"maintenance": {"on": true, "message": "Back at 3 pm",
  "since": <epoch ms>}` (`{"on": false, "message": ""}` when it was never
  switched; `since` only once it was). It doesn't say who switched it.
- The app asks it at start (the [start check](execution-mode.md#the-start-check))
  and then **every minute** (`RolesService.maintenanceCheckInterval`, the
  same `checkApi` the Log tab's health panel uses), so a running app (an
  unattended phone) follows a switch within a minute.
- `RolesService.maintenance` holds the last answer, and
  `RolesService.inMaintenance` is `maintenance.on && !isAdmin`. An
  unanswered check keeps the last state; an API that doesn't say (an
  older one, or none) means off.
- If the API can't read the state (DynamoDB failing), it answers **off**
  and logs it, so the start check always answers.

## The API

- **`GET /api/auth/maintenance`** and **`POST /api/auth/maintenance`**
  (`AdminHandler`, admins only: 403 otherwise). GET answers `{"on",
  "message", "since", "by"}`. POST takes the form-encoded `on` (`true` or
  `false`, 400 otherwise) and optional `message` (trimmed; control
  characters other than line breaks dropped; more than 500 characters is
  400), stamps `since` (now) and `by` (the admin's verified email), and
  answers the new state. Each switch is logged
  (`presence: maintenance mode on by …`).
- **`SystemTable`**: the system's own state, one item per setting; the
  maintenance item is `{"id": "maintenance", "on", "message", "since"
  (epoch ms), "by"}` (`Maintenance` in
  [Maintenance.java](../presence_api_auth/AuthFunction/src/main/java/presence/auth/Maintenance.java)).
  On demand, encrypted. The roles function (`AuthFunction`) may only
  `GetItem` it (a consistent read); the admin function may `GetItem` and
  `PutItem`. It's in the health check's table list.
- **The deploy's smoke test** checks that `/api/auth/anonymous` reports a
  maintenance state, then leaves it out of the exact comparison, so a
  release deploys whether maintenance is on or off.

## Known limitations

- **UI only.** The API's other routes, cloud sync and live sync keep
  working in maintenance mode, and the app keeps recording behind the
  sorry screen. A user with an old, running app sees the sorry screen
  within a minute.
- **A signed-out admin can't sign in** while it's on (the sorry screen has
  no sign-in): they use `scripts/maintenance.sh`, or an admin whose
  session is still saved switches it off.
- **DEV has no switch.** The Admin tab is hidden in DEV and the admin
  routes need a Google token, so locally maintenance mode is set only by
  writing the item to Floci's `SystemTable`.
- Admins see the sorry screen for a moment at launch, until their roles
  are checked.
