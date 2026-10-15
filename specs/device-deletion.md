# Device deletion

A signed-in user can **delete another device of their profile** from the
Profile tab's device list, choosing whether to **keep its videos**. Its
events can be **deleted**: every event it recorded moves to a
**deleted** state and is hidden on every device of the profile. It's a
soft delete: nothing in the cloud or on the devices is destroyed by it.
**One event** is deleted this way, from the end of its details or its
card in the events list ([One event](#one-event)), and **the events
shown** all at once ([Delete all](#delete-all)).

## Where

- **The account sheet's device list** ([Sign-in](sign-in.md)): each
  device other than this one has a delete button (`delete_outline`,
  tooltip "Delete <device ID>") at the end of its row, beside its
  hide/show eye ([Hiding a device](device-hiding.md); `ProfileDevices.onDelete`,
  [account_sheet.dart](../presence_app/lib/auth/account_sheet.dart)).
  The Camera tab's All grid ([Camera screen](camera.md#all-devices)) has
  none.
- It asks first ([delete_device.dart](../presence_app/lib/delete_device.dart),
  `DeleteDeviceDialog`): **"Delete brave_phone from your devices? It has
  12 events."** (its events in the profile now shown,
  `deviceEventCount`), a smaller line saying what each choice does, and
  three buttons (they wrap onto their own lines on a phone):
  - **Cancel**: nothing.
  - **Keep videos**: the device **leaves the list** only; its events and
    videos stay, everywhere. The snack bar says "Removed brave_phone from
    the list; its videos stay".
  - **Delete videos** (error-colored): its events are deleted too, as
    below, on every device. "Deleted brave_phone: 12 events hidden".
- Either way it leaves this device's list (`EventLog.removedDevices`,
  with the time, saved in the settings store as `removedDevices`, only
  here, loaded at start) until it has an event newer than that
  (`EventLog.removedFromList`): a device that records again shows again.
  Its slot is released at the auth API (`CloudSync.releaseDevice`, see
  [Premium](premium.md)) so the next device takes its place, and its
  presence dot is forgotten.
- Signed in with a profile only (the list shows only then); not in DEV.
  The dialog fits a 320 dp phone.

## This device

**This device can't be deleted:** its row has no delete button, and
`Persistence.deleteDevice` does nothing for its own ID: its next event (an
app start, a clip) would bring it straight back.

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
- It's taken off the profile's device list at the auth API
  (`CloudSync.releaseDevice`), so the next device takes its place among
  those whose events show ([Premium and free](premium.md#devices)).
- Returns how many events it deleted.

## One event

Two places delete one event, signed in with the event's profile only
(not in DEV, where there's no profile, as for devices;
`EventDetailsScope.canDelete`):

- the clip player (the event's details, [Clips](clips.md)) ends with a
  **Delete event** button;
- each card in the [events list](events.md) has a small **delete icon**
  (`delete_outline`, 18 dp, tooltip "Delete event", key
  `event-delete-<id>`, `EventDeleteButton`) in its header, beside its
  indicators, at the right end.

Both ask "Delete this event? It will be hidden on every device." with
**Cancel** / **Delete**; Delete deletes it (closing the player, from
there) and a snack bar says "Event deleted on every device"
([event_details.dart](../presence_app/lib/event_details.dart)).

`Persistence.deleteEvent(id, profileId:)` does for one event what
`deleteDevice` does for a device's (the same code, `_softDelete`): the
event, if it's stored, in the profile and not deleted yet, and the "Is
this Rex?" suggestions about its clip get `deletedAt`, leave the event
log, have their pending recording downloads dropped, and are named
changed so cloud sync uploads them deleted and live sync publishes them.
The app also forgets its copies (`EventCopies.forget`). Any device's
event can be deleted, this device's too: a deleted ID never comes back,
and the device's next events are new ones. The device stays (its other
events show). It returns whether it deleted it ("Event already deleted"
otherwise, and the player stays). Everything under
[Deleted stays deleted](#deleted-stays-deleted) and [Media](#media)
holds for it too.

## Delete all

At the far right of the Monitoring tab's top row, the search's row
([Monitoring](monitoring.md)), a **Delete all** icon button
(`delete_sweep_outlined`, tooltip "Delete the events shown", key
`events-delete-all`, `DeleteShownEvents`) deletes **the events the list
shows** that can be deleted (the signed-in profile's): every one without
a filter, only the matching ones with a search, a device or system
events hidden. It asks "Delete N events?" ("Delete all the events shown?
They will be hidden on every device.", their clips staying in the cloud
until they expire) with **Cancel** / **Delete**, and a snack bar then
says "N events deleted on every device". Signed out (or in DEV) it isn't
there; with nothing of the profile's shown, it's disabled.

`Persistence.deleteEvents(ids, profileId:)` deletes them at once, as
`deleteEvent` does one (`deleteEvent` uses it): one pass over the stored
events, those not in the profile or deleted already left out, the
suggestions about their clips with them. It returns how many of the IDs
it deleted. The app forgets their copies, notifying once
(`EventCopies.forgetAll`).

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
setting, and the bucket archives videos after 67 days and erases every object after 365
([Production deploy](deploy.md)). There's no hard delete.

## Tests

`device_delete_test.dart`:

- `deletedAt` round-trips through the stored record and JSON.
- The account sheet's hide/show buttons ([Hiding a device](device-hiding.md#tests)).
- In the app, for each choice: the delete button beside the eye; the
  dialog's wording and count, fitting 320 dp; the device leaves the list
  and stays off it after a restart; Keep videos keeps its events in the
  timeline, Delete videos hides them, after a restart too.
- A device deleted keeping its videos is listed again once it has a newer
  event.
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

`event_details_test.dart` (one event):

- The player's end: a located event's map, its pin and caption (a
  pinned one says so); "No location for this event" without one; the
  device's OS icon, ID, OS name and presence dot; signed out, no dot and
  no delete button; none for another profile's event; Cancel keeps it,
  Delete deletes it, closes the player and says so; nothing deleted keeps
  the player; it fits 320 dp at 1x and 2x text.
- In the app: deleting an event hides it from the timeline and lowers the
  count.
- With storage and cloud sync: the event and the suggestion about its
  clip are marked deleted and leave the log (the device's other event
  stays); they upload deleted and the event is published with
  `deletedAt`; still hidden after a full fetch and a restart; deleting
  again does nothing. This device's own event can be deleted; another
  profile's or an unknown one isn't. A deleted copy from another device
  hides it; a later copy that isn't deleted doesn't bring it back.

## Known limitations

- Events the deleted device recorded **before** the deletion but uploads
  only after it (it was offline) show: nothing remembers the deletion of
  a device, only of events.
- Events older than the cloud sync window (two weeks, or the History
  setting when shorter) that a device keeps for longer aren't marked
  deleted there unless that device hears of them: the other device still
  shows those.
- No undo; the events stay deleted until retention removes them.
- Only clip events have a details screen, so plain events (an app start,
  a sign-in) can't be deleted one by one.
