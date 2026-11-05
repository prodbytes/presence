# Event files: download and upload one event

One event can leave the app as a file, and a file can bring an event in.
Code: [`lib/storage/event_file.dart`](../presence_app/lib/storage/event_file.dart)
(the format), [`lib/event_transfer.dart`](../presence_app/lib/event_transfer.dart)
(the buttons, saving and picking the file). Test: `event_file_test.dart`.

## Download (each event card)

- **Where:** in every event card's header, first in the row of the card's
  buttons (`event-actions-<id>`), before the indicators and delete
  ([Events](events.md)): a download icon (`event-download-<id>`, tooltip
  "Download event"), the same size as delete. It's there whenever the app
  gives it a way to export (`EventDetailsScope.exportEvent`), for every
  event shown, signed in or not.
- **What it does:** `Persistence.exportEvent` builds the file; the button
  spins while it does. A recording that isn't on this device yet (fetched
  from the cloud without it) is downloaded first
  (`Persistence.fetchMissingMedia`); one that still can't be had is left
  out, and the clip keeps its thumbnail and tags. A deleted event, or one
  not stored here, isn't exported. Failing (its media doesn't open here,
  for one), it says "Couldn't download the event".
- **Where the file goes:** the browser's download on the web; the share
  sheet on iOS and Android (Save to Files, AirDrop, another app; on an
  iPad it points at the button); a save dialog on the desktop (Linux).
  Named `presence-event-<event id>.json`.

## Upload (the events' top row)

- **Where:** in the [Monitoring](monitoring.md) top row, just before
  Delete all: an upload icon (`events-upload`, tooltip "Upload an
  event"), there whenever the app can take events in
  (`EventDetailsScope.importEvent`). It spins while it works.
- **What it does:** it opens the system's file picker (JSON files,
  `file_selector`) and gives the file to `Persistence.importEvent`:
  - The event joins the **signed-in profile** (its `profileId` is set to
    it; signed out, as in DEV, it has none), so the events list shows it,
    and it's **undeleted** (`deletedAt` dropped). The rest of its record
    (its device, its time, its tags) is kept as it was.
  - Its frames, its clip's thumbnail and its recordings are **sealed with
    this device's key** ([Encryption](encryption.md)) and stored; the
    event and clip records go in as cloud sync's do
    (`Persistence.importRemote`).
  - The event is named changed (`Persistence.changes`), so cloud sync
    uploads it to the profile like an event recorded here.
  - It shows in the list at once (`EventLog.addHistory`); an event
    already here is replaced by the uploaded one.
  - Then "Event uploaded"; a file that isn't an event file says "That
    file isn't a Presence event", any other failure "Couldn't upload the
    event". Cancelling the picker does nothing.

## The file

JSON, UTF-8:

```json
{
  "format": "presence-event",
  "version": 1,
  "exportedAt": 1793869200000,
  "event": { "...the event record...": "", "frames": { "<frameId>": "<JPEG, base64>" } },
  "clip": { "...the clip record...": "", "thumbnail": "<JPEG, base64>" },
  "media": { "<mediaId>": "<the recording, base64>" }
}
```

- `event` is the stored event record ([data formats](data-formats.md)),
  and `clip` its clip's record, without the local thumbnail-check
  fields; `clip` is left out when the event has no clip here.
- **Everything is opened** (not sealed): the frames, the thumbnail and
  each recording (`past`, `full`) are plain JPEG and video bytes, so the
  file reads anywhere, in another profile too. Anyone holding the file
  can see the clip.
- An upload refuses a file whose `format` isn't `presence-event`, whose
  `version` is newer than the app's, whose event has no safe ID
  (`Records.isSafeId`) or integer `time`, or whose clip isn't the event's
  (`clip.id` ≠ `event.clipId`). A recording whose `mediaId` isn't safe
  (`Records.isSafeMediaId`: it names a file on Android) is left out, never
  written.
