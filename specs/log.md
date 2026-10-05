# Log

The app's latest log messages, in their own **Log** tab in the nav bar,
which only admins see (and everyone in DEV, where the anonymous user is a
root). Use it to see why something failed, such as the AWS sync
the Settings health line marks ❌, without a browser console or `adb`.

## What's captured

[lib/app_log.dart](../presence_app/lib/app_log.dart): `main()` runs the app
inside `AppLog.capture`, which adds to `AppLog.instance`:

- every `debugPrint`: every `Presence: …` message in the app goes through
  it;
- every `print`, through the zone the app runs in (packages' too);
- Flutter errors (`FlutterError.onError`: build, layout and paint errors),
  with their stack trace, marked as errors;
- errors nothing caught (`PlatformDispatcher.onError`), with their stack
  trace, marked as errors.

Each message still goes where it went before (the console, `adb logcat`).
The log holds the latest **500** entries, in memory only: it starts empty
at every launch and isn't uploaded.

## Cloud sync messages

So a failed sync says why (see [Cloud sync](cloud-sync.md)):

- `Presence: cloud sync failed: …`, with the error (`S3 HTTP 403: <S3's
  XML error>`, a network error) and its stack trace;
- `Presence: cloud sync failed, stopped until sign-in or retry: Cognito
  <type>: <message> (<detail>)`, once, when credentials can't be had. For
  the auth API, `<type>` is `HTTP <status> from /api/auth/credentials`
  (or `NotAuthorizedException` for a 401), and `<detail>` is its `cause`
  and `requestId` (`cause: CognitoIdentity GetId: AccessDeniedException
  (HTTP 400); request <id>`, with the failed operation; see
  [Profiles](profiles.md)), or the first 300 characters of a body that
  isn't JSON;
- `Presence: cloud credentials rejected, renewing: …`, when credentials
  expire during a pass and the app gets new ones.

## Auth API health messages

So the health line's 🔌 API ❌ can be explained (each with how long it
took):

- `Presence: auth API answered the start check in <ms> ms (<mode> mode)`;
- `Presence: could not ask the execution mode (after <ms> ms; checking
  again): <error>`, when the start check fails or times out (5 s);
- `Presence: auth API health check failed after <ms> ms: <error>`, every
  failed check after that (the retries and the health panel's);
- `Presence: auth API health check answered in <ms> ms, after failing:
  <error>`, the first answer after a failure.

Google sign-in failures are logged too (`Presence: Google sign-in failed:
<code>; <description>; details: <details>`; see [Sign-in](sign-in.md)).
On Android, `devbox run android-log` reads these from the phone (see
[Android](android.md)).

## The Log tab

[lib/log_view.dart](../presence_app/lib/log_view.dart):

- The fourth tab (receipt icon), after Settings, shown when
  `RolesService.isAdmin`: `presence_admin` users, and DEV, whose anonymous
  user has every role up to `presence_root` (see [Execution
  mode](execution-mode.md)). See [Navigation](navigation.md).
- At the top, the **health panel** (see below), then a header, "Log · N
  latest", with **Copy** and **Clear**, then the
  entries, newest first, each entry with its time (`HH:MM:SS`), in monospace; errors
  in the error color. Updates live while open. Text is selectable.
- **Copy** puts the whole log on the clipboard, oldest first, with ISO
  times. **Clear** empties it.
- "Nothing logged yet." when empty.
- **Admins only in OIDC (RBAC) mode**: the tab needs a granted roles
  check with `presence_user` and `presence_admin` (`RolesService.isAdmin`).
  Signed out, signed in without a role, a member, an admin without
  `presence_user` and a failed roles check get no Log tab, and a refresh
  remembered on the Log tab doesn't reopen it for them. Losing the role
  removes the tab at the next roles check (sign-in, Check again, a
  reload), and signing out removes it at once.
- Tests: `system_health_test.dart` (the health panel), `app_log_test.dart` (capacity, the tab's order and Clear) and
  `roles_test.dart` ("the Log tab": an admin and a root see it with the
  log; nobody else does; no return to it after a refresh; it goes with the
  admin role or on sign-out; DEV's anonymous root sees it).

## Health panel

`HealthPanel` in
[lib/system_health.dart](../presence_app/lib/system_health.dart), a card
at the top of the Log tab:

- **Health**, with "Last update HH:MM:SS" (when the auth API was last
  asked; "Checking…" before the start check is done).
- The same health line as [Settings](settings.md): `🔌 API · ☁️ AWS ·
  🔑 OIDC`, with the same statuses and tooltips.
- **📱 Devices N**: how many distinct devices recorded the events the
  user has (`HealthPanel.devicesIn`): the device IDs of the signed-in
  user's events and those recorded signed out, as the Events tab counts
  them (`EventTimeline.ofUser`), local and synced from the cloud; events
  not saved yet count as this device. It updates as events arrive or are
  deleted.
- **Every 30 s**, and when the tab opens, it checks again:
  `RolesService.checkApi` asks `GET /api/auth/anonymous` (15 s timeout)
  whether the API answers and which settings it has, and updates the
  API status and those settings; the execution mode stays the one the
  start check decided (which also retries on its own when it failed; see
  [Execution mode](execution-mode.md)). Checks are logged (below).
  AWS shows the cloud sync's latest pass, which runs on its own every
  15 s ([Cloud sync](cloud-sync.md)). The checks stop while the tab is
  closed.
- **History**: after each check, a small brick, oldest first, wrapping
  into rows: green when every check passed, red (the error color) when
  any is ❌ or ⚠️ (⚪ not set, ⏳ and 🔄 count as passed). Tap a brick to
  show that check's time, result and the three statuses with what they
  mean (selectable); tap it again to hide them. `HealthHistory.instance`
  keeps the latest 120 (an hour) in memory: they outlast closing the
  tab, not a restart.

## Known limitations

- The log is kept on every device, whoever signs in; only showing it is
  limited to admins.
- The health history only grows while the Log tab is open, and starts
  empty at every launch.
- Messages logged before `capture` runs, or by native code (Kotlin,
  Swift, the browser), aren't included.
