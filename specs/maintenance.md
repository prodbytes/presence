# Maintenance mode

While the system is in maintenance mode, the app shows **no UI at all** to
anyone but roots: only a sorry message.

## What decides it: rbacr

[rbacr](https://github.com/prodbytes/rbacr), which gives every role, decides
it, along with its health check (`Rbacr.maintenance`):

1. **rbacr's health check** (`GET <rbacr>/health`, no token: the probe the
   API's own [health check](health-check.md) runs as its `rbacr` check).
   If it fails (not 200, no answer within 2 s) or rbacr isn't configured
   (no `RBACR_TOKEN`), the system is **in maintenance, automatically**
   (`"reason": "rbacr-unreachable"`): nobody's roles can be known then.
2. Otherwise **rbacr's maintenance flag** on the app's system (rbacr's
   R11, `GET /api/systems/presence` with the API's root token, its
   `maintenance`): on is maintenance (`"reason": "rbacr"`), off is the
   standard mode. An answer that isn't the system (refused token, an error,
   another system) counts as unreachable; a system without the field (an
   rbacr from before maintenance mode) is off.

The answer, either way, is reused for 10 s (`Rbacr.MODE_CACHE_FOR`) per
function instance, so a down rbacr isn't waited for at every app start.
**DEV** asks no rbacr: never in maintenance.

While the flag is on, rbacr itself gives nobody a role in the system, and
roots keep theirs (rbacr's global `root`). So in maintenance **only roots**
have the admin role and keep the app; other admins see the sorry message
too. While rbacr is unreachable nobody has a role, so everyone does.

## What people see

- **Everyone without the admin role** (signed out, members, premium
  members, people without access, and admins while rbacr's flag strips
  their role) sees only `MaintenanceScreen`
  ([lib/maintenance.dart](../presence_app/lib/maintenance.dart)): a
  construction icon, **"Sorry, Presence is down for maintenance."**, "We'll
  be back soon. This page comes back on its own.", and the root's message
  under it when they left one. Nothing else: no tabs, app bar, camera
  preview, buttons or sign-in. It's shown before the recording consent too.
- `MaintenanceGate` sits in `MaterialApp.builder`, so the sorry screen
  replaces the app's whole navigator: the home screen, and any dialog or
  sheet open on it, close. When maintenance ends, the app comes back fresh
  (the Camera tab, or the remembered tab).
- **Roots** (signed in; the session restored at launch counts) keep the
  app, under a yellow strip: "Maintenance mode is on: only roots see the
  app." They switch it off on the Admin tab.
- Behind the sorry screen, the app's services keep running: the camera
  (with motion and scheduled clips), cloud sync and live sync. Only the UI
  is withheld.

## Switching it

- **The Admin tab** starts with a **Maintenance mode** card
  (`_MaintenanceCard` in
  [lib/auth/admin_screen.dart](../presence_app/lib/auth/admin_screen.dart)):
  a switch (On / Off, with when it was last switched here and by whom),
  saying it's rbacr's flag and turns on by itself while rbacr fails its
  health check, and an optional **Message** (up to 500 characters, three
  lines) shown under the sorry message. Switching it on sends the
  message; while it's on, **Update message** sends a new one. Switching
  it off clears the message. A snackbar confirms each switch, or says why
  it failed. The card loads with the rest of the page (Reload, or pull
  down).
- **Only roots** switch it (`presence_root`); other admins see the card
  with the switch, field and button disabled, and "Only roots switch it."
  An admin who switched it on couldn't switch it off: rbacr's flag takes
  their role.
- After a switch, the root's app applies the new state at once
  (`RolesService.maintenanceSwitched`), so the strip comes and goes right
  away; the next check confirms it.
- **In rbacr itself**: the presence system's page in rbacr has its own
  toggle. A switch there shows no message here (a message is only shown
  with a switch made here that put it on).
- **Without the app**:
  [scripts/maintenance.sh](../scripts/maintenance.sh) uses the rbacr root
  token (`RBACR_TOKEN`, from the environment or `.env`) and AWS
  credentials: `scripts/maintenance.sh` prints rbacr's health and flag and
  the last switch made here; `scripts/maintenance.sh on "Back at 3 pm"`
  and `scripts/maintenance.sh off` PATCH rbacr's flag, then write the
  message (`STAGE=rc`, with `RBACR_URL=https://rc.rbacr.nu01.com`, for the
  RC).

## How apps learn it

- `GET /api/auth/anonymous` (no token, see [Auth API](auth-api.md))
  answers `"maintenance": {"on": true, "message": "Back at 3 pm",
  "since": <epoch ms>, "reason": "rbacr"}`, or `{"on": false, "message":
  ""}` in the standard mode. `message` and `since` are the switch made
  here, given only when rbacr's flag is on and that switch put it on.
  It doesn't say who switched it.
- The app asks it at start (the [start check](execution-mode.md#the-start-check))
  and then **every minute** (`RolesService.maintenanceCheckInterval`, the
  same `checkApi` the Log tab's health panel uses), so a running app (an
  unattended phone) follows within a minute and 10 s.
- `RolesService.maintenance` holds the last answer, and
  `RolesService.inMaintenance` is `maintenance.on && !isAdmin`. An
  unanswered check keeps the last state; an API that doesn't say (an
  older one, or none) means off.
- If the message can't be read (DynamoDB failing), it's left out; the
  start check still answers.

## The API

- **`GET /api/auth/maintenance`** (`AdminHandler`, admins: 403 otherwise)
  answers `{"on", "message", "since", "reason", "by", "rbacr"}`: `on` is
  rbacr's decision (on when it can't say), the message, time and email
  are the last switch made here, and `rbacr` whether rbacr answered.
- **`POST /api/auth/maintenance`** (roots only: 403 for other admins)
  takes the form-encoded `on` (`true` or `false`, 400 otherwise) and
  optional `message` (trimmed; control characters other than line breaks
  dropped; more than 500 characters is 400). It switches rbacr's flag
  first (`PATCH /api/systems/presence {"maintenance": on}`; 502 when rbacr
  refuses or doesn't answer, and nothing is kept), then keeps the switch:
  `since` (now), `by` (the root's verified email) and the message. Each
  switch is logged (`presence: maintenance mode on by …`).
- **`SystemTable`** keeps the last switch made here: `{"id":
  "maintenance", "on", "message", "since" (epoch ms), "by"}` (`Maintenance`
  in
  [Maintenance.java](../presence_api_auth/AuthFunction/src/main/java/presence/auth/Maintenance.java)).
  It doesn't decide anything: rbacr does. On demand, encrypted. The roles
  function (`AuthFunction`) may only `GetItem` it (a consistent read); the
  admin function may `GetItem` and `PutItem`. It's in the health check's
  table list.
- **The deploy's smoke test** checks that `/api/auth/anonymous` reports a
  maintenance state, then leaves it out of the exact comparison, so a
  release deploys whether maintenance is on or off.

## Known limitations

- **UI only.** The API's other routes, cloud sync and live sync keep
  working in maintenance mode (as far as rbacr's roles let them), and the
  app keeps recording behind the sorry screen.
- **A signed-out root can't sign in** while it's on (the sorry screen has
  no sign-in): they switch it in rbacr, with `scripts/maintenance.sh`, or
  from an app whose session is still saved.
- **An rbacr blip is a maintenance blip.** A failed health check puts
  every app that asks within the next 10 s on the sorry screen until its
  next check, a minute later.
- **rbacr's GA may predate maintenance mode** (rbacr's R11, in its RC
  first): its answer has no flag, read as off, and a switch from here
  fails (502) until it's released there.
- **DEV has no switch, and no maintenance**: no rbacr is asked.
  **Local RBAC without an rbacr token** (`RBACR_RC_TOKEN` unset in `.env`)
  is always in maintenance, since rbacr can't be asked.
- Admins see the sorry screen for a moment at launch, until their roles
  are checked. Plain admins may keep the app for up to a minute after the
  flag goes on, while the API reuses their roles.
