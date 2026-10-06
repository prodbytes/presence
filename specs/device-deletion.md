# Device deletion

A signed-in user can **delete another device of their profile**: every
event it recorded moves to a **deleted** state and is hidden on every
device of the profile. It's a soft delete: nothing in the cloud or on the
devices is destroyed by it.

## Where

- **The account sheet's device list** ([Sign-in](sign-in.md)): each
  device other than this one has a delete button (`delete_outline`,
  tooltip "Delete <device ID>") at the end of its row
  (`ProfileDevices.onDelete`,
  [account_sheet.dart](../presence_app/lib/auth/account_sheet.dart)).
- **The Camera tab's All grid** ([Camera screen](camera.md#all-devices)):
  each other device's cell has the same button, top left, on a
  translucent round background (`CameraFeedsView.onDeleteDevice`,
  [camera_feeds.dart](../presence_app/lib/camera_feeds.dart)), clear of
  the "Asked for a fresh grab" spinner (top right) and the label with its
  [presence dot](device-presence.md) (bottom). A cell smaller than 96 x
  84 dp (`_Cell.deleteRoom`, many devices on a small phone) leaves the
  button out rather than overlap them; the device list still deletes.
  Its cell goes once the device is deleted.
- Both ask first, in a dialog ([delete_device.dart](../presence_app/lib/delete_device.dart),
  `DeleteDeviceDialog`): **"Delete device brave_phone? Its 12 events will
  be hidden on every device."** (the count is that device's events in the
  profile now shown, `deviceEventCount`), with a smaller line, "Its clips
  stay in the cloud. If it records again, it shows again with its new
  events.", and **Cancel** / **Delete** (error-colored). After Delete a
  snack bar says "Deleted brave_phone: 12 events hidden".
- Signed in with a profile only (the list and the grid show only then);
  not in DEV. It fits a 320 dp phone, at a 2x system font too.

## This device

**This device can't be deleted:** its row and its (live) cell have no
delete button, and `Persistence.deleteDevice` does nothing for its own
ID. Its next event (an app start, a clip) would bring it straight back.
To stop a device appearing, sign out on it (or uninstall it), then
delete it from another device.

## What it does

`Persistence.deleteDevice(deviceId, profileId:)`
([persistence.dart](../presence_app/lib/storage/persistence.dart)):

- Every stored event of that device in the signed-in profile that isn't
  deleted yet gets **`deletedAt`** (ms since the epoch, the time of the
  deletion), and so do the **"Is this Rex?" suggestions about its clips**
  (whatever device asked them). The records stay, with the field
  (`AppEvent.deletedAt`, [Data formats](data-formats.md)).
- They leave the event log at once (`EventLog.remove`), so **nothing shows
  them**: the timeline, its count and search, the device filter, the
  subjects and their map, the All grid, the device list and recognition's
  references all read the event log. A device with no events left drops
  off the device list and the grid.
- They're saved and named as changed, so [cloud sync](cloud-sync.md)
  uploads each one's JSON again, deleted, and [live sync](live-sync.md)
  publishes those from the last two weeks: the profile's other devices
  hide them within a second (live sync connected), 15 s (today's and
  yesterday's), or at the hourly full listing (older ones).
- Downloads still pending of their clips' recordings are dropped (nothing
  will play them).
- Its **presence** goes too: the device list and the grid only list
  devices with events, so it has no [presence dot](device-presence.md),
  and live sync forgets when it last heard from it (`LiveSync.forget`).
  Answering pings alone doesn't bring it back; once it posts new events it
  reappears, its dot from the pings and pongs heard from then on.
- Returns how many events it deleted.

## Deleted stays deleted

- **At launch**, deleted records aren't restored into the event log.
- **From the cloud**, a deleted event that's new to the device is stored
  (so it isn't fetched again) but not shown, and its clip isn't fetched.
- **A deleted copy wins.** A copy from another device (the bucket or live
  sync) that is deleted, of an event shown here, hides it here too
  (`Persistence.updateFromRemote`), even when the event changed here and
  that isn't uploaded yet (otherwise this device's change would win and
  bring it back everywhere).
- **A copy that isn't deleted doesn't bring it back.** The deleted device,
  still running, may upload its own copy again (say a tag there): its tags
  are taken on, the event stays deleted, and this device uploads it again
  deleted (`CloudSync` forgets its synced fingerprint, so the next pass
  sends it).
- **A device that keeps recording reappears**: its new events (new IDs,
  after the deletion) show normally, so it's back in the list and grid
  with only those.

## Media

Clips, thumbnails, tagged frames and recordings stay, on the devices and
in the bucket: the deletion only hides their events. They go the usual
way: [event retention](event-retention.md) deletes old events (deleted or
not) with their clips and recordings from each device after the History
setting, and the bucket expires every object after 90 days
([Production deploy](deploy.md)). There's no hard delete.

## Tests

`device_delete_test.dart`:

- `deletedAt` round-trips through the stored record and JSON;
  `deviceEventCount`.
- The account sheet: a delete button on every other device, none on this
  one; it fits 320 dp at 1x and 2x text; the dialog's wording and count;
  Cancel keeps the device; Delete deletes it and it leaves the list.
- The All grid: a delete button on each other device's cell, none on this
  device's; the dialog; the cell goes.
- In the app: deleting from the account sheet hides the device's events
  from the timeline and lowers the count.
- With storage and cloud sync (real `Persistence`, `CloudSync`,
  `LiveSync` on fakes): the device's events and the suggestion about its
  clip are marked deleted and leave the log, the devices list, the grid's
  devices and the profile's count; they upload deleted and are published
  with `deletedAt`; they stay hidden after a full fetch and a restart.
  This device can't be deleted. A deleted copy in the bucket hides the
  event; a later copy that isn't deleted doesn't bring it back, and the
  deleted one goes up again. A deleted copy wins over a change here not
  uploaded yet (a start pass that reconciles doesn't upload over it).
  Over live sync, a deleted copy hides the event at once, even changed
  here, and the device's new events show it again.

## Known limitations

- Events the deleted device recorded **before** the deletion but uploads
  only after it (it was offline) show: nothing remembers the deletion of
  a device, only of events.
- Events older than the cloud sync window (two weeks, or the History
  setting when shorter) that a device keeps for longer aren't marked
  deleted there unless that device hears of them: the other device still
  shows those.
- No undo; the events stay deleted until retention removes them.
