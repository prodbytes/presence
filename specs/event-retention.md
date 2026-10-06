# Event retention

Events don't pile up forever: each device deletes its own events older
than the **History** setting, **two weeks** by default
([lib/storage/retention.dart](../presence_app/lib/storage/retention.dart)).

## When

- **When the app loads**, once the saved history is restored, and then
  **every 3 hours** while it runs (`EventRetention.defaultEvery`).
- A changed setting applies on the next of those runs, not while its
  slider is dragged, so passing over "1 day" on the way somewhere else
  deletes nothing.
- One run at a time. A failed run (a storage error) is logged and deletes
  nothing; the next run tries again.

## What

- Every event whose `time` is before *now − History*: this device's and
  other devices' events fetched from the cloud, of any user stored on the
  device.
- With each deleted clip event go its **clip record** (window, thumbnail),
  its **recordings** (the before part and the full clip: IndexedDB `media`
  on web, MP4 files on Android) and any **"Is this Rex?" suggestion**
  about it, however recent. Tagged frames live in the event record and go
  with it.
- What [cloud sync](cloud-sync.md) remembers of them goes too: their
  entries in the `synced` store (each uploaded or downloaded object key
  of the event and its clip, the event's `etag:` entry and a recording's
  pending `fetch:` entry, in the
  current layout and the old one; `EventStore.deleteSynced`,
  `CloudSync.isSyncedKeyOf`), so that store doesn't grow forever.
- The events and clip records go in one transaction
  (`EventStore.deleteEvents`), then their `synced` entries, then the
  recordings
  (`MediaStore.delete`). Then they leave the event log, so the Monitoring
  tab and the [events count](events.md) drop them at once
  (`Persistence.deleteEventsBefore`, `EventLog.remove`).
- **Only on the device.** Nothing is deleted from the cloud: S3 keeps
  what was uploaded until the bucket expires it.

## Cloud sync

- A fetch never brings back what retention deletes: its window
  ([Cloud sync](cloud-sync.md), two weeks) shrinks to the History setting
  when that's shorter (`CloudSync.keep`). With History at 3 days, a new
  device gets 3 days of history.
- A longer setting doesn't widen the window: a new device still gets two
  weeks from the cloud, and keeps events it records or fetches for as long
  as the setting says.

## Setting

- Settings → **History** → **Keep events for**: 1 to 90 days in 1-day
  steps, default 14, shown as "1 day", "10 days", "2 weeks" (whole weeks up
  to 8 read as weeks) or "90 days". Stored as `history: {keepMs}` (see
  [Configuration](configuration.md)), and synced with this device's
  settings like the others.

## Tests

- `retention_test.dart`: the deletion of old events with their clips,
  recordings, suggestions and `synced` entries (not the device's
  settings', nor the kept events'), keeping the rest (store and log); runs at
  start and every 3 h with the setting current at each run; one run at a
  time; a failed run allows the next; the slider's range and labels.
- `persistence_test.dart`: in the app, an event three weeks old is gone
  after a reload, from storage too, and one aged past two weeks while the
  app runs goes at the next 3-hourly run.
- `cloud_sync_test.dart`: with History at 3 days, a 5-day-old event in the
  bucket isn't downloaded.
- `config_test.dart`: default, range and JSON round trip.
