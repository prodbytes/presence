# Hiding a device

The Profile tab's device list ([Sign-in](sign-in.md), `ProfileDevices` in
[account_sheet.dart](../presence_app/lib/auth/account_sheet.dart)) has an
**eye button** at the end of every device's row, this device's too:

- **Shown** (the default): `visibility_outlined`, tooltip "Hide
  <device ID>'s events". A tap hides them.
- **Hidden**: `visibility_off_outlined` in the muted color, tooltip "Show
  <device ID>'s events". A tap shows them again.

Hiding is **only on this device** and deletes nothing: the device stays in
the list (so it can be shown again), its events still sync and stay
stored, and the other devices still show them. **Nothing of it shows
here**, apart from its row in the device list:

- its events leave the Monitoring timeline and its count, the subjects
  map and the Camera tab's All grid (`EventLog.eventsOf` skips
  `EventLog.hiddenDevices`; what the plan hides past its device limit is
  apart: [Premium](premium.md), `EventLog.visibleDevices`, labelled
  "hidden");
- a question about one of its clips ("Is this Rex?") goes too, even when
  another device asked it (`eventsOf` looks at the suggestion's clip);
- **recognition doesn't run here** on its clips, new or synced
  (`SubjectRecognizer` skips them, `EventLog.hidesDevice`), so nothing
  is asked about them from here. Shown again, its clips from then on are
  recognized as before.

The hidden devices are **remembered** in this device's settings store
(`Persistence.saveHiddenDevices`, key `hiddenDevices`, `{"devices":
[...]}`), loaded at start (`loadHiddenDevices`), and not synced to the
cloud. The app wires it as `ShowDevice`
([show_device.dart](../presence_app/lib/show_device.dart),
`_showDevice` in [main.dart](../presence_app/lib/main.dart)).

Beside it, every other device has a delete button
([Device deletion](device-deletion.md)), which asks whether to keep its
videos.

Signed in with a profile only (the list shows only then). The button
fits a 320 dp phone, at a 2x system font too.

## Tests

`device_delete_test.dart`:

- Every device has a hide button, this one too; no delete button.
- It fits 320 dp at 2x text (`account_sheet_test.dart`, with a long ID).
- Hide takes the device's events out of the log's profile events and
  keeps the device listed with a show button; show brings them back.
- Without a `showDevice`, no eye buttons.
- In the app: hiding from the account sheet takes the device's events out
  of the timeline and lowers the count; after a restart they're still
  hidden.
