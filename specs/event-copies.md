# Event copies

Every event card, and the event's details, say **how many copies of the
event there are, and where**: on this device, in the cloud (S3), and on
the profile's other devices. A device that has stored a full copy of
another device's event tells the others over [live sync](live-sync.md)
with a small **`copied` ack**.

## The flow

1. **Taken:** an event is saved on the device that recorded it; that
   device holds it at once (its clip, even while recording, is all there
   is of it).
2. **Up, then published:** the next [cloud sync](cloud-sync.md) pass
   (within about half a second) uploads the event to S3 and then
   [publishes](live-sync.md) its metadata on the profile's `events` topic.
   A clip event goes up and out twice: when it's taken (`clipState`
   recording) and when its clip completes, after the recording, thumbnail
   and clip record are in the bucket (the event's JSON changes, so it's
   uploaded and published again).
3. **Copied:** each other connected device stores the event at once, then
   fetches its clip record and thumbnail from S3 (the "wanted clips");
   its recording comes down only when it's played there, or when a copy
   is asked for ("The copies" below). Without live sync, a device gets
   the same from the bucket's 15 s listing.
4. **Acked:** once a device holds a **full copy** of another device's
   event (see below), it publishes a `copied` ack on the profile's `acks`
   topic; every device that hears it records that device as a holder.

## A full copy

`CloudSync.copyOf` decides, from the device's storage and the synced-keys
store:

- **This device** holds an event it recorded always. Another device's
  event once its record is here, with the frames its tags use, and, for a
  clip event, the clip's record with the **recording downloaded** (no
  pending `fetch:` entry), unless the clip failed there (no recording to
  have). An event without a clip is held with its record alone. So, as
  recordings come down only when played (or asked for), a clip from
  another device counts as held here only after that.
- **The cloud** holds an event once its JSON is in the bucket (uploaded
  by this device, or seen there by a fetch or a live message), with its
  tagged frames and, for a clip event, its recording (uploaded, or listed
  there). Not while the clip is still recording.
- **The device that recorded it** holds it: it's named by the event's
  `deviceId`, and needs no ack.
- **Other devices** hold it once they've acked it.

The checks run when an event is saved here, after each upload of an
event, after a fetch or a live message hands events over, after a wanted
clip arrives, after a recording downloads, and for every event of the
restore window at each full fetch (the first pass after a sign-in or
restart, then hourly), which also sends acks not sent before (such as
while live sync was off). Deleted events (`deletedAt`, see [deleting a
device](devices-users-places.md)) are neither counted nor acked, are
forgotten, and show no count (deleting one event from its details
forgets it at once, `EventCopies.forget`). Deleting a device also drops it as a holder
of every event (`EventCopies.forgetDevice`); it counts again only if it
acks again.

## The ack

On `presence/<stage>/<identityId>/acks`, shared with
[device presence](device-presence.md)'s pongs (QoS 1, JSON, at most
**1 KB**):

```json
{
  "v": 1,
  "kind": "copied",
  "deviceId": "loud_shy_kettle",
  "identityId": "us-east-1:…",
  "sentAt": 1791234567890,
  "eventIds": ["mbx1abcd2e-0abc123", "…"]
}
```

- **Batched** (`LiveSync.ackCopied`): event IDs wait **1 s**
  (`ackDelay`), then go out as few messages as fit, at most **32 IDs**
  (`maxAckIds`) and 1 KB each, one message per **1 s** (`ackEvery`), so a
  catch-up of a thousand events is about 35 messages over 35 s. At most
  1000 IDs wait (`maxAckQueue`; the oldest go). Only events of the
  signed-in profile, recorded on another device, are acked, and each once
  (`acked`, kept across restarts); one whose ack didn't go out (live sync
  off, disconnected, or failed) is acked at the next full fetch. A flush
  belongs to one run of the connection loop: a stop, a new start, or a
  change of the **Connect to live sync** setting (which starts over with
  the same link) ends it, and the acks it hadn't sent count as not sent,
  so two flushes never share the queue.
- **Validated** (`LiveSync.parseCopied`): dropped when over 1 KB, not
  JSON, not version 1 or `kind: copied`, of another identity, with a
  `deviceId` or any event ID outside `[A-Za-z0-9_.:-]{1,128}` or
  containing `..`, without an integer `sentAt`, or with no event IDs or
  more than 32. Repeated IDs count once. This device's own acks (and its
  other tabs') are ignored. A valid ack also counts as hearing from its
  sender for device presence.
- **Repeated acks** (QoS 1 may repeat one) change nothing.
- **No IoT change:** the policies already allow
  `presence/<stage>/<identity>/*`; a profile still reaches only its own
  topics.

## Kept

`EventCopies` ([lib/cloud/event_copies.dart](../presence_app/lib/cloud/event_copies.dart))
keeps, per event, whether this device and the cloud hold it, whether this
device has acked it, and the other devices that acked it with their ack's
`sentAt` (at most 32 per event). It's saved in the `settings` store as
the `copies` record (`{v: 1, events: {<eventId>: {s, c, a, d: {<deviceId>:
<sentAt>}}}}`), after each change (a burst is a few writes), loaded at
start, and bounded to the **2000** most recently changed events. One app-
wide instance, shared by cloud sync and the cards (`EventCopiesScope`).

**MQTT only, not in S3:** the holders are not written into the event's
JSON in the bucket. Every ack would change the event's JSON, so its
fingerprint and ETag, making each device upload and publish it again, and
each of those would be taken as a change elsewhere: update churn, and
loops between devices. A device without live sync knows only this device,
the cloud and the recording device.

## On screen

Each event has **indicators**, small icons with a tooltip each
(`EventIndicators`), in this order. They're **22 dp** icons (the copies
number in `labelMedium`), each at least 44 dp tall and 36 dp wide (7 dp
of padding each side), with 4 dp between them, so they're easy to tap;
each is a button that does something (see [Tapped](#tapped)). They keep
that size on a narrow card: the device's name beside them gives way
(ellipsized).

- **Recognition** (clips only): how far recognition ran. See [Subject
  recognition](recognition.md#on-the-event-card).
- **The cloud** (`EventCloudBadge`), in three states:
  - **Not synced yet:** a crossed-out cloud, **disabled** (the surface's
    color at 38 %), when the cloud holds no copy ("Not in the cloud").
  - **Synced:** a cloud in the theme's **primary** color (Gruvbox yellow)
    when the cloud and this device both hold one ("In the cloud").
  - **Archived**, the goal: the same cloud in the theme's **secondary**
    color (Gruvbox aqua) when the cloud holds a copy and this device
    doesn't, or not in full, e.g. another device's clip whose recording
    isn't downloaded here ("Archived in the cloud (not on this device)").
  - **Cold storage:** for a clip recorded more than **67 days** ago
    (`EventCopies.coldStorageAfter`, `inColdStorage`) that the cloud
    holds, the tooltip adds "Its recording is in cold storage: it can't
    be played from the cloud": the bucket's lifecycle moved its
    recording to S3 Glacier Deep Archive, and restoring isn't supported
    yet (see [Cloud sync](cloud-sync.md), "Archived recordings"). It's
    judged by the clip's time (its recording goes up soon after), at
    display (`CopiesSummary.coldStorage`, from `summaryOf(clipTime:)`);
    `copyOf` still counts it as a cloud copy.
- **Copies:** an icon and **just the number of devices** holding a copy,
  this device and others; the cloud isn't counted, since it has its own
  indicator (`EventCopiesBadge`, `CopiesSummary.devices`). The tooltip and
  the screen-reader label say it ("On 2 devices") and list every holder,
  this device first, then the cloud, then devices ("This device, Cloud,
  loud_shy_kettle"). One icon for one device, another for more. The
  cloud is "Cloud (cold storage)" there for a clip in cold storage.

### Tapped

Each indicator is a button (screen readers say so), and its tooltip ends
with what a tap does. While what it started runs, a spinner stands in for
its icon; it then says how it went at the bottom of the screen. Taps on
the cloud and the copies go to cloud sync (`EventCopyActions`, which
`CloudSync` implements, given to the cards by `EventCopiesScope`); without
it they aren't buttons.

- **Recognition:** runs it again. See [Subject
  recognition](recognition.md#on-the-event-card).
- **The cloud, not in it** ("Tap to put it in the cloud"): puts it there
  (`CloudSync.putInCloud`). What was sent of it before is forgotten (its
  JSON, ETag, clip record, recording, thumbnail and tagged frames, in
  either layout), and a pass starts at once to send it all. "Putting it
  in the cloud…"; or "Couldn't put it in the cloud: that takes a premium
  profile and a full copy on this device." (signed out, a free profile,
  syncing stopped, or this device doesn't hold it in full: what isn't here
  can't go up).
- **The cloud, in it** ("Tap to delete it from the cloud"): asks first
  ("Delete from the cloud?"), warning, when this device doesn't hold a
  full copy (archived), that it's gone for good unless another device
  does. Confirmed, it deletes the event from the bucket
  (`CloudSync.deleteFromCloud`): its JSON, clip record, recording,
  thumbnail and every tagged frame listed under its clip, in either
  layout, and forgets them as sent. It marks the event as **kept out of
  the cloud** first (`offcloud:<eventId>` in the synced-keys store), so no
  pass of this device uploads it again, a reconciliation included, and it
  shows as not in the cloud, until it's put back. "Deleted from the
  cloud", or "Couldn't delete it from the cloud".
- **The copies** ("Tap to sync a copy to every device"): asks the
  profile's other devices to take a copy (`CloudSync.shareCopies`). Not in
  the cloud and held here, it's put there first, and the upload publishes
  it (even if it isn't recent). Otherwise it's published again on the
  `events` topic at once, with the ETag it has in the bucket (and its clip
  record, for devices without the bucket). Each device that hears it
  stores what it lacks, fetches its clip, and acks it once it holds it in
  full; one that has it unchanged downloads its recording now, if it
  hasn't (`_Recordings.fetchPending`), and acks it. A device that didn't
  have the event gets its record and clip, not the recording: a second
  tap brings that down too. "Asked the other devices to take a copy", or
  "Couldn't reach the other devices: live sync is off or not connected".
  Devices whose restore window it's older than ignore it.

They show:

- **On event cards** (the Monitoring timeline): in each card's header row,
  at the right of the device tag. They fit a 320 dp phone.
- **In the event's details** (the clip player): under the title.
- **With live sync off** (no endpoint, Never, signed out): the count is
  what's known (this device, the cloud, the recording device, and acks
  heard before), and the tooltip adds "Live sync is off: other devices'
  copies are unknown".
- Not on a deleted event (but recognition, for a clip).

## Code

- [lib/cloud/event_copies.dart](../presence_app/lib/cloud/event_copies.dart):
  `EventCopies`, `EventHolders`, `CopiesSummary` (count, synced, label,
  tooltip).
- [lib/copies_badge.dart](../presence_app/lib/copies_badge.dart):
  `EventCopiesScope`, `EventIndicators`, `EventCopiesBadge`,
  `EventCloudBadge`, `EventRecognitionBadge`.
- [lib/cloud/live_sync.dart](../presence_app/lib/cloud/live_sync.dart):
  `ackCopied`, `parseCopied`, `CopiedMessage`, `LiveLink.onCopied`.
- [lib/cloud/cloud_sync_actions.dart](../presence_app/lib/cloud/cloud_sync_actions.dart):
  the taps' `putInCloud`, `deleteFromCloud`, `shareCopies`
  (`_EventActions`, `offCloudKey`); `EventCopyActions` is in
  [event_copies.dart](../presence_app/lib/cloud/event_copies.dart).
- [lib/cloud/cloud_sync.dart](../presence_app/lib/cloud/cloud_sync.dart):
  `copies`, `copyOf`; the checks and acks in `_CopyTracker`
  ([cloud_sync_copies.dart](../presence_app/lib/cloud/cloud_sync_copies.dart):
  `note`, `_check`, `onCopied`).
- [lib/storage/event_store.dart](../presence_app/lib/storage/event_store.dart):
  `getClip`.

## Verified

`event_copies_test.dart`:

- acks parse; wrong version, kind, identity, unsafe device or event IDs,
  no or too many IDs, a non-integer `sentAt`, over 1 KB and non-JSON are
  rejected; 40 IDs go out as two messages of at most 1 KB; own acks are
  ignored, another's handed over (and its sender seen), an invalid one
  dropped; nothing is sent with live sync off;
- a repeated ack changes nothing; the count, label and tooltip (this
  device and the recording device not counted twice; "1 copy" for one only
  in the cloud, "2 copies" for one received from its device and not
  uploaded from here, "Not synced" for one held only here or not known); the holders survive
  a restart, bounded to the newest;
- a clip older than 67 days held by the cloud is in cold storage ("This
  device, Cloud (cold storage)"), one of 66 days isn't, nor an event
  without a clip or one not in the cloud; its cloud indicator's and copies'
  tooltips say so;
- `copyOf`: an event without media, another device's clip (held here only
  with its recording downloaded), a clip recorded here (in the cloud once
  its recording is), tagged frames;
- two devices over an in-memory broker and a shared bucket: a capture is
  held only on its device ("Not synced") until uploaded;
  it's uploaded then published; the other device stores it and gets its
  clip when it completes, but not its recording (not held yet); asked for
  a copy, it downloads the recording and acks it; the first then shows
  "3 copies" ("This device, Cloud, phone_b"); later passes don't ack again;
- with live sync off: this device and the cloud, and the tooltip says
  other devices' copies are unknown;
- deleted events are forgotten and never acked, and a deleted device no
  longer counts as a holder;
- the indicators on every card at 320 dp: the number of devices (the
  cloud not counted) with the holders in its tooltip, and the cloud in the
  primary color, disabled, or in the secondary color for one only in the
  cloud, both updating when an ack comes in and the cloud takes it; none on a deleted event; the details list the holders;
- tapped: the cloud puts one not in it, asks before deleting one in it
  (warning for an archived one), the copies share, each saying how it
  went; without cloud sync, no buttons and no hints;
- over two devices: deleted from the cloud, an event is gone from the
  bucket and stays out (a reconciliation doesn't upload it again); put
  back, it goes up; shared, it's published again with its ETag, and
  shared while not in the cloud, it goes up first; another device's event
  not held here can't be put, and nothing is shared with live sync off.

`recognition_test.dart`: asked to run again, a clip searched for objects
is searched again.

## Known limitations

- A holder stays counted once it acked: an event deleted there later (by
  its History setting) isn't un-acked. A device that joins later doesn't
  hear acks sent before it connected (beyond what a scheduled
  connection's persistent session keeps, 1 h).
- Other devices' clips count as held here only once played or asked for
  (their recordings aren't downloaded before).
- Deleting from the cloud is this device's: the other devices still
  count the cloud as a holder (they don't hear of it), and one that
  changes the event (its tags) uploads it again; then this device still
  shows it as not in the cloud until it's put back here.
- Acks are best effort (QoS 1, not waited for): one lost is sent again
  only if this device's record of it says it wasn't sent.
