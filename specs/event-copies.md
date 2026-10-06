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
   fetches its clip record and thumbnail from S3 (the "wanted clips"), and
   its recording: in the background on Android and desktop, when played
   on the web. Without live sync, a device gets the same from the bucket's
   15 s listing.
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
  have). An event without a clip is held with its record alone. So on the
  web, where recordings come down only when played, a clip from another
  device counts as held here only after it's played.
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
while live sync was off). Deleted events (`deletedAt`) are neither counted
nor acked, and are forgotten.

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
  off, disconnected, or failed) is acked at the next full fetch.
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

- **Event cards** (the Monitoring timeline): on the row above each card,
  at the right of the device tag, a small file icon and **"3 copies"**,
  **"1 copy"**, or **"1 copy — not uploaded yet"** for an event held only
  here. The tooltip (and screen-reader label) names the holders, this
  device first, then the cloud, then devices: "This device, Cloud,
  loud_shy_kettle". It fits a 320 dp phone (the device tag and the count
  share the row, each cut short with an ellipsis if needed).
- **Event details** (the clip player): under the title, the count and the
  holders: "3 copies: This device, Cloud, loud_shy_kettle".
- **With live sync off** (no endpoint, Never, signed out): the count is
  what's known (this device, the cloud, the recording device, and acks
  heard before), and the tooltip adds "Live sync is off: other devices'
  copies are unknown".

## Code

- [lib/cloud/event_copies.dart](../presence_app/lib/cloud/event_copies.dart):
  `EventCopies`, `EventHolders`, `CopiesSummary` (count, label, tooltip).
- [lib/copies_badge.dart](../presence_app/lib/copies_badge.dart):
  `EventCopiesScope`, `EventCopiesBadge`.
- [lib/cloud/live_sync.dart](../presence_app/lib/cloud/live_sync.dart):
  `ackCopied`, `parseCopied`, `CopiedMessage`, `LiveLink.onCopied`.
- [lib/cloud/cloud_sync.dart](../presence_app/lib/cloud/cloud_sync.dart):
  `copies`, `copyOf`, `_noteCopies`, `_checkCopies`, `_onCopied`.
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
  device and the recording device not counted twice); the holders survive
  a restart, bounded to the newest;
- `copyOf`: an event without media, another device's clip (held here only
  with its recording downloaded), a clip recorded here (in the cloud once
  its recording is), tagged frames;
- two devices over an in-memory broker and a shared bucket: a capture is
  held only on its device ("1 copy — not uploaded yet") until uploaded;
  it's uploaded then published; the other device stores it, gets its
  clip and recording when it completes, and acks it; the first then shows
  "3 copies" ("This device, Cloud, phone_b"); later passes don't ack again;
- with live sync off: this device and the cloud, and the tooltip says
  other devices' copies are unknown;
- the badge on every card at 320 dp, with its tooltip, updating when an
  ack comes in; the details list the holders.

## Known limitations

- A holder stays counted once it acked: an event deleted there later (by
  its History setting) isn't un-acked. A device that joins later doesn't
  hear acks sent before it connected (beyond what a scheduled
  connection's persistent session keeps, 1 h).
- On the web, other devices' clips count as held here only once played
  (their recordings aren't downloaded before).
- Acks are best effort (QoS 1, not waited for): one lost is sent again
  only if this device's record of it says it wasn't sent.
