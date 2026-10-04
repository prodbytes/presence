# Log

The app's latest log messages, on their own **Log** screen that only
admins can open. Use it to see why something failed, such as the AWS sync
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

## The Log screen

[lib/auth/log_screen.dart](../presence_app/lib/auth/log_screen.dart):

- Opened by the **Log** button (receipt icon) in the
  [Admin screen](membership.md)'s app bar, so only `presence_admin` users
  reach it, and not in DEV mode, which has no Admin screen.
- Newest first, each entry with its time (`HH:MM:SS`), in monospace; errors
  in the error color. Updates live while open. Text is selectable.
- **Copy** puts the whole log on the clipboard, oldest first, with ISO
  times. **Clear** empties it.
- "Nothing logged yet." when empty.
- Tests: `app_log_test.dart` (capacity, the screen's order and Clear) and
  `roles_test.dart` (an admin opens it from the Admin screen).

## Known limitations

- Not available in DEV mode, where there's no Admin screen.
- Messages logged before `capture` runs, or by native code (Kotlin,
  Swift, the browser), aren't included.
