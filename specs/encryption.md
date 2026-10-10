# Media encryption

**Every image and recording is encrypted, in storage and in transit.**
Each device seals what it records with its own key before storing or
sending it. A sealed image or recording is opened only in memory, or into
a temporary file that's deleted after use, to be shown, played or
searched. Event metadata (times, types, subjects, tags, positions,
locations) isn't encrypted.

What's sealed:

- a clip's **thumbnail** (the JPEG grabbed when the clip was asked for);
- each **tagged frame** (the JPEG of the frame people or pets were
  tagged on, by someone or by recognition);
- each **recording** (the before part and the full clip: WebM on web,
  MP4 on Android and iOS).

## Device keys

- **Each device has its own key**, a random AES-256 key (32 bytes from a
  secure random generator). It's made together with the
  [device ID](devices-users-places.md), in the same transaction, and kept
  with it in the `settings` store under `device` (`{"id": …, "key":
  <base64>}`, [lib/storage/event_store.dart](../presence_app/lib/storage/event_store.dart),
  `EventStore.deviceIdentity`). A device's key never changes. On web,
  clearing the site's data makes a new device, with a new ID and key.
- **Keys are named by device ID.** Each sealed object says which device's
  key sealed it, so any device that has that key can open it.
- **The profile's devices share their keys,** so each one opens every
  other device's events:
  - with the bucket (premium): each device's key is in its settings record
    in the cloud, `devices/<deviceId>/settings.json` (`mediaKey`, base64;
    see [Cloud sync](cloud-sync.md)). Cloud sync reads the other devices'
    settings for keys it doesn't have on its first pass, at each full
    fetch (hourly), and on the next pass after an image wouldn't open for
    want of its key;
  - over [live sync](live-sync.md): each event a device publishes carries
    its key (`mediaKey`), so devices without the bucket (free) open the
    thumbnail that comes with it.
- Other devices' keys are kept on the device, in the `settings` store
  under `keys` (`{deviceId: <base64>}`), so they work offline. A known
  device's key is never replaced: a different one for it is ignored, and
  logged.
- `MediaKeys` ([lib/crypto/media_seal.dart](../presence_app/lib/crypto/media_seal.dart))
  holds them: this device's, and the others' it learned. An image whose
  key isn't known yet shows a lock, and opens as soon as the key comes.

## Sealed format

[lib/crypto/seal_format.dart](../presence_app/lib/crypto/seal_format.dart)
(`SealFormat`). A sealed object is a header, then the media in chunks,
each encrypted with **AES-256-GCM**:

| Bytes | Holds |
|-------|-------|
| 4 | magic: `PSE` and the format version, `0x01` |
| 1 | the key ID's length, n (1 to 64) |
| n | the key ID: the ID of the device whose key sealed it (ASCII, `[A-Za-z0-9_-]`) |
| 4 | the chunk size, big-endian (256 KB) |
| 7 | a random nonce prefix, new for each object |

- Each chunk is up to the chunk size of media, then its 16-byte GCM tag.
  Empty media is one empty chunk.
- A chunk's 12-byte nonce is the prefix, the chunk's index (4 bytes,
  big-endian), and a byte that's 1 for the last chunk and 0 otherwise.
  Chunks can't be reordered, dropped or cut off unnoticed.
- The header is every chunk's additional authenticated data, so its key
  ID and chunk size can't be changed either.
- Chunks let a recording be sealed and opened a piece at a time, from a
  file to a file, without holding it all in memory.
- A sealed object that doesn't open (changed, cut off, another key) fails
  with `SealBroken`; one whose device's key isn't known fails with
  `SealKeyMissing`.

**Where the work is done:** `MediaSeal` seals and opens. On the web the
browser's Web Crypto does it. Elsewhere, small media (up to 64 KB, such as
a thumbnail) is done in place, and bigger media on another isolate, so the
UI doesn't stall. A 10 MB recording takes about 0.6 s on a laptop, and a
few seconds on a phone.

## Where media is sealed and opened

- **Thumbnails** are sealed as the clip is made (`CameraRig.requestClips`):
  the clip, its record and everything after hold only the sealed bytes. A
  thumbnail that can't be sealed within 10 s (this device's key not loaded)
  is left out: a clip without a thumbnail, never one with an unsealed one.
- **Tagged frames** are sealed when they're grabbed, by the player's
  frame grab or by recognition (`ClipAnnotations.newFrame`), and kept
  sealed in the event's `frames` (`TagFrame.sealed`). An unsealed frame in
  a record isn't taken.
- **Images are shown** with `SealedImage`
  ([lib/crypto/sealed_image.dart](../presence_app/lib/crypto/sealed_image.dart)):
  opened in memory, the last 200 kept open, never stored open. Clip cards,
  the All grid, subjects, suggestions, the frame strip and the frame
  tagger all use it. Recognition opens a tagged frame in memory to find
  who a tag points at.
- **Recordings** are sealed as they're saved (`MediaStore.save`):
  - on web, read from the recorder's in-memory URL, sealed, and stored in
    IndexedDB's `media` store; opened in memory into a Blob URL to play;
  - on Android and iOS, the recorder's file is sealed into
    `clips/<id>.sealed` (written beside it as `.part`, then moved into
    place). The unsealed file is deleted once nothing plays or searches
    it. To play or search one, it's opened into a temporary file in the
    cache (`open/<id>-<n>.mp4`), deleted once the player or frame sampler
    lets it go (`MediaUrls`, which deletes files there as it revokes Blob
    URLs on web).
  - At start, the native store deletes what's unsealed: `.mp4` recordings
    an older version stored, opened copies, and live recordings an earlier
    run left in the cache that never got sealed.
- **Cloud sync** uploads and downloads sealed bytes as they are: nothing is
  opened to go up or come down. Thumbnails, frames and recordings go up as
  `application/octet-stream` (a recording's type is in its clip's record).
  An unsealed image is never uploaded, and one downloaded is skipped
  (logged), as is an unsealed recording (dropped from the pending
  downloads). See [Cloud sync](cloud-sync.md).
- **Live sync** sends a clip's thumbnail only sealed, and takes only a
  sealed one. See [Live sync](live-sync.md).

## Deleting unencrypted data

Data stored before this version is deleted, on the device and in the
cloud:

- **On the device:** a device with an ID and no key ran a version that
  stored media unsealed. Its key is made at its next start, and in the
  same transaction every event, clip, recording and synced-store entry it
  stored is deleted (`DeviceIdentity.purged`); then its recording files.
  Its settings, consent, location and ID stay.
- **In the cloud**, once per device and profile, on the first sync pass,
  before anything is fetched or uploaded (`_Sealing.purgeUnsealed`):
  - the first device that seals for the profile writes a marker at the
    root of the profile's folder, `encryption.json`, if it isn't there
    (`If-None-Match: *`). Its time, S3's, is the cutover;
  - each device deletes every object under `events/`, `clips/` and
    `media/` written before the marker. Devices' settings (`devices/`)
    stay: they hold the keys. Devices that seal upload only after the
    marker is there, so nothing of theirs is deleted;
  - a device remembers it's done (`sealed` in the `settings` store). One
    that's interrupted or refused tries again in its next run; a failure
    never fails the pass.
  - The profile's credentials may delete in its own folder
    (`s3:DeleteObject` in [presence_infra/identity.yaml](../presence_infra/identity.yaml)),
    and the bucket's CORS allows `DELETE`.

## Tests

- `media_seal_test.dart`: sealing and opening media of every size, chunk
  by chunk; nothing sealed twice the same way; changed, cut off,
  renamed-key and other-key objects don't open; keys to text and back;
  other devices' keys learned and never replaced; files sealed and opened,
  with nothing left behind by one that doesn't open.
- `encryption_test.dart`: the key made with the device ID, and an older
  install's unsealed data deleted when it gets its key; recordings
  stored sealed (IndexedDB and files) and opened to play; cloud sync's
  purge (only what's older than the marker, once); another device's key
  fetched from its settings and used to open its thumbnail; live events
  carrying the sender's key.

## Known limitations

- **Keys are stored next to the data on the device.** Anyone who can read
  the app's storage (a rooted phone, the browser profile's files) can open
  its media. The keys aren't in the Android Keystore or iOS Keychain yet.
- **Keys sit in the same bucket as the media.** Credentials that can read
  a profile's folder can open its media. Encryption protects media that
  leaves the folder without its `devices/` (a copied object, a backup, a
  log of uploads), not against the profile's own credentials.
- **The cloud purge leaves old versions.** The bucket is versioned: a
  deleted object stays as an old version for 30 days, then the lifecycle
  rule removes it. Deleting old versions at once needs an admin with
  `s3:DeleteObjectVersion`.
- **A device that hasn't updated** keeps uploading unsealed media after the
  cutover. Other devices skip it; it isn't deleted until that device
  updates and wipes its own copy (the cloud copy then stays until it
  expires).
- **While the purge can't delete** (the infrastructure isn't deployed
  yet), a device fetches the old events' metadata again; their unsealed
  thumbnails, frames and recordings are skipped.
- **Recordings are sealed after they're recorded:** the recorder writes an
  unsealed file, which lasts until the clip is saved and nothing plays it,
  and the before-roll is held unsealed in memory.
- Pure Dart AES-GCM on Android and iOS: a few seconds per 10 MB recording,
  on another isolate. Platform crypto (`cryptography_flutter`) would be
  faster.
- A device's key never changes: there's no rotation, nor a way to revoke a
  removed device's key.
