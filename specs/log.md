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
  XML error>`, `Cognito <type>: <message>`, a network error) and, except
  for Cognito errors, the stack trace;
- `Presence: /api/auth/credentials answered HTTP <status>: <body>` (its
  first 300 characters), when the auth API refuses AWS credentials;
- `Presence: cloud credentials rejected, renewing: …`, when credentials
  expire during a pass and the app gets new ones.

## The Log tab

[lib/log_view.dart](../presence_app/lib/log_view.dart):

- The fourth tab (receipt icon), after Settings, shown when
  `RolesService.isAdmin`: `presence_admin` users, and DEV, whose anonymous
  user has every role up to `presence_root` (see [Execution
  mode](execution-mode.md)). See [Navigation](navigation.md).
- A header, "Log · N latest", with **Copy** and **Clear**, then the
  entries, newest first, each entry with its time (`HH:MM:SS`), in monospace; errors
  in the error color. Updates live while open. Text is selectable.
- **Copy** puts the whole log on the clipboard, oldest first, with ISO
  times. **Clear** empties it.
- "Nothing logged yet." when empty.
- Tests: `app_log_test.dart` (capacity, the tab's order and Clear) and
  `roles_test.dart` (no Log tab for a member; one in DEV; an admin opens
  it and sees a message; DEV's anonymous user `isRoot`).

## Known limitations

- Messages logged before `capture` runs, or by native code (Kotlin,
  Swift, the browser), aren't included.
