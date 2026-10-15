# Cloud sync

Signed-in users' **clips (videos), events and each device's settings
sync with S3**, straight from
the device, both ways: at start and **every 15 s** (every **2 min**
while [live sync](live-sync.md) works, which announces new events at
once), events only on the
device go up, events only in the user's folder come down, and events
another device changed (such as a tag removed) come down again and
replace what's on screen, so every device of a user shows the same
events as the bucket. The auth API only
hands out credentials: the app trades the user's Presence
[session token](sessions.md) for a token for their [profile](profiles.md), and that for temporary AWS
credentials through a **Cognito identity pool**. It then makes signed S3
uploads itself ([lib/cloud/](../presence_app/lib/cloud)).

With [live sync](live-sync.md) (a build with `IOT_ENDPOINT`), the profile's
devices also hear of each event as soon as it's uploaded, over MQTT, and
show it within a second; the bucket stays where everything is kept, and
the passes below run as before.

## What's uploaded, and where

Everything goes under the user's profile's **Cognito identity ID**
(`us-east-1:<uuid>`), the same for every account linked to the
[profile](profiles.md), in the user-data bucket, with JSON and media in
separate trees so the JSON can be queried on S3. The formats, fields and
an Athena table are in [Recording and data formats](data-formats.md).

| Object | Content |
|---|---|
| `<identityId>/media/<clipId>.webm` or `.mp4` | the clip's recording (the full clip, or the before part if the after part was cut short), sealed ([Media encryption](encryption.md)) |
| `<identityId>/media/<clipId>.jpg` | the thumbnail, sealed |
| `<identityId>/media/<clipId>/frames/<frameId>.jpg` | sealed, each frame people or pets were tagged on (see [Clips](clips.md#naming-people-and-pets)), uploaded once; the event JSON refers to it by `frameId`, and a fetch downloads the frames its tags use |
| `<identityId>/clips/year=<YYYY>/day=<DDD>/<clipId>.json` | the clip record: camera, window, lengths, state, media reference; in its event's day partition (the event's `time`, which is the clip's `requestedAt`) |
| `<identityId>/devices/<deviceId>/settings.json` | the device's settings for this profile: `{deviceId, mediaKey, profileId, updatedAt, config, location}`, every Settings value, the location set on the map (see [Configuration](configuration.md)) and the device's media key, which the profile's other devices read to open its media ([Media encryption](encryption.md)) |
| `<identityId>/ingest/<deviceId>/<clipId>.mp4` (and `.ingest.json`) | a [streamer](streamer.md)'s recorded chunk, sealed, only while it's searched for people and animals (on the Pi, or by the cloud detector, which its job calls): then moved to `media/` (with its records) or deleted. The app never lists `ingest/` |
| `<identityId>/encryption.json` | the marker of when the profile's media was first sealed: each device deletes, once, what's older under `events/`, `clips/` and `media/` ([Media encryption](encryption.md#deleting-unencrypted-data)) |
| `<identityId>/events/year=<YYYY>/day=<DDD>/<eventId>.json` | each of the user's event records (type, title, detail, time, camera, device and user IDs, the device's location, clip ID and state, and for clips the named people and pets, `annotations`, each with its position and `frameId`, without the frame images, and the object tags, `objectTags`), partitioned by the UTC day of the year of its time (`day=001` to `day=366`), Hive-style so tools such as Athena can prune by partition |

- What a device uploaded under the old layout (`clips/<clipId>.webm`,
  `.jpg`, `.json` and `clips/<clipId>/frames/`, before 2026-10-02) counts
  as uploaded: it isn't sent again under the new keys.

## When

- **Halted while the camera is Stopped** (the mode button's Stopped,
  `camera.paused`; see [Camera screen](camera.md)): `CloudSync.setHalted`
  cancels the pending and periodic passes, stops [live sync](live-sync.md)
  and the recording downloads, and nothing starts again (not a change,
  a sign-in or Retry) until it's left: then a pass runs at once and the
  periodic ones resume. A pass already running finishes, but doesn't
  connect live sync. A device restarted Stopped starts halted.

- **Sealed media only:** thumbnails, tagged frames and recordings go up
  and come down sealed, as stored, never opened on the way; an unsealed
  one is never uploaded, and one downloaded is skipped. Each pass first
  deletes, once per device and profile, what the folder held before media
  was sealed (`encryption.json`), and reads the media keys of the
  profile's other devices from their settings: on the first pass, at each
  full fetch, and after an image wouldn't open for want of its key. See
  [Media encryption](encryption.md).

- **Only the profile's own:** a pass uploads the events whose
  `profileId` is the signed-in account's [profile](profiles.md), and only
  the clips (and tagged frames) of those events. Events recorded signed
  out go up once the sign-in gives them its profile, moments later;
  another profile's never do. Fetched events, from the profile's folder,
  get its `profileId`. See [Devices, users and
  places](devices-users-places.md).
- **Signed out, signed in without `presence_user`, or before the roles
  check (rbacr and the auth API) answers with the profile:** nothing is uploaded or fetched (see
  [Sign-in](sign-in.md) and [Membership](membership.md)). Sync starts once
  the roles check grants access and gives the profile; another profile
  (after a link) starts it over.
- **Premium only:** everything on this page is for a **premium** profile
  (`presence_premium`, from rbacr: Premium and Pro, whose credentials are
  both tagged `tier=premium`). A free profile's credentials can't
  reach the bucket, and a free pass publishes nothing: each device keeps
  its events, and live sync's scheduled connections (at start, at
  sign-in, every 15 min) share each new event once, final, with its
  clip's record and a thumbnail of at most 12 KB. A change of tier starts
  the sync over. See [Premium and free](premium.md).
- **This device's settings:** the first pass for a user (at start, sign-in
  or a user change) lists `devices/<deviceId>/` and, if the record is
  there, downloads it. It wins when it's newer, or when the local
  settings are another profile's, so a sign-in restores what the profile
  last had on this device; then the local settings are the profile's (see
  [Configuration](configuration.md)). Every pass then uploads the local
  record if it differs from what the cloud holds. A settings change
  signals a pass, like a new event. One listing per start; other devices
  of the user don't read this device's settings.
- **Every pass fetches, then uploads.** A pass runs at every app start
  with a signed-in `presence_user` (a new sign-in, or a session restored
  at launch, e.g. a reload), whenever the user changes, **every 15 s**
  (`CloudSync.interval`), and 0.5 s after an event is saved or a clip's
  recording completes (`Persistence.changes`).
- **While live sync works, the timer's passes are a backstop.** When
  [live sync](live-sync.md) is connected, or idle between scheduled
  connections (its broker keeps what comes meanwhile), the timer starts a
  pass only **2 min** after the last pass (`CloudSync.liveInterval`, the
  timer still ticking every 15 s): other devices' new events and
  completed clips are announced over live sync, and each one starts a
  pass at once for its clip (see [Live sync](live-sync.md)). Without live
  sync (no IoT endpoint in the build, set to Never, or failing: its error
  state, and the reconnect attempts after it) the timer passes every 15 s
  as before; a reconnect attempt doesn't change which applies. Saves
  here, received events, the **Sync** button and **Retry** start passes
  at once either way, and any pass restarts the 2 min. A pass started by
  a save here or a live message **lists nothing** while the last listing
  is under 2 min old (`CloudSync._mustList`, the age against
  `liveInterval`): the message brought the event, and its clip is got by
  its known keys (wanted, see **Fetch**). The timer's passes, the hourly
  full fetch, the Sync button, Retry, a sign-in and a failed pass's retry
  always list. 2 min is live
  sync's own slowest retry and its devices' "seen lately" window, and the
  slowest default scheduled connection (every minute) still comes within
  it; with live sync set to connect every 5 min or more, events missed
  by it can take up to 2 min to come from the bucket.
- After a failed pass the
  timer **backs off**: each failure in a row doubles the wait (15 s,
  30 s, 1 min, 2 min, then 4 min at most, `CloudSync.maxBackoff`; at
  least the 2 min while live sync works), and
  saves during the wait don't start passes either (they're kept for the
  next). A successful pass, **Retry** or a new sign-in ends it. Passes
  stop after a credentials failure (see **Errors**).
- **Fetch:** the events in the user's folder that the device doesn't have
  are downloaded, with their clips (details and thumbnail) and tagged
  frames, but **not their recordings** (see **Recordings** below):
  - only from the last **two weeks** (`CloudSync.restoreWindow`, 14 days),
    or the History setting when that's shorter (`CloudSync.keep`), so
    nothing the device deletes as too old comes back ([event
    retention](event-retention.md)): event keys are partitioned by UTC
    day, so older partitions aren't read, and in the window's first day
    each event's `time` decides;
  - at most **1000 events per pass** (`CloudSync.maxFetch`), the newest
    first; any rest come down in later passes;
  - only the clips those events use: each record read from its event's
    day partition (`clips/year=…/day=…/<clipId>.json`), and its thumbnail
    (`media/<clipId>.jpg`) and tagged frames (`media/<clipId>/frames/…`),
    all **got by their known keys, never listed** (a LIST costs $0.005
    per 1000, 12 times a GET's $0.0004). The role may list the folder, so
    a missing key answers **404**: "not there yet", not an error. Should
    S3 answer `AccessDenied` (403) instead, that one key is listed to tell
    a missing object from refused credentials (`_Fetcher._getIfThere`);
  - they're handed over **in batches of 25 events**
    (`CloudSync.fetchBatch`, with their clips, thumbnails and frames),
    marked as synced, so they aren't uploaded back, stored
    (`Persistence.importRemote`) and added to the event log, so the
    **Monitoring** tab, the Camera tab's [All](camera.md#all-devices) grid
    and the account sheet's devices show them as each batch lands. A new
    device downloads a few kilobytes per event this way (a profile's 159
    thumbnails were 4.5 MB in all), so every device shows within seconds
    of signing in.
- **Recordings** (about 6 MB each: the same profile's 123 were 756 MB)
  come down **only when wanted**, never with their events, on every
  platform:
  - when a fetched clip is complete (only complete clips go up), its
    recording's key, from the clip record's `mimeType`
    (`media/<clipId>.mp4` for MP4, else `.webm`, as its device uploads
    it; there now, or still going up), is **marked as synced** at once,
    since it's in the
    cloud, so a reconciliation never tries to upload a recording that
    isn't here; and it's noted as **pending** in the `synced` store, as
    `fetch:<object key>` = `<event time>:<mediaId>`;
  - **nothing downloads them in the background**: no device prefetches
    the others' recordings. With 5 devices each recording was downloaded
    4 times, the biggest AWS cost per profile (S3 data transfer out, about
    576 GB and $52 a month for a heavy profile; see request 436);
  - **a recording comes down when its clip needs it** (any platform):
    every use of a stored clip's recording goes through
    `ClipMedia.acquireUrl`, whose load (`Persistence._restoreMedia`) calls
    `Persistence.fetchMissingMedia` (set to `CloudSync.fetchRecording`)
    when the media store doesn't have it. That's playing it in the clip
    player (native and web), and reading its frames for tagging, Auto
    tagging and recognition (`recognition/frames_*.dart`). It's
    downloaded through the signed-in session (from its `fetch:` entry, or
    by listing `media/<clipId>.`), stored (`MediaStore.saveBytes`), marked
    synced, its `fetch:` entry dropped (`EventStore.unmarkSynced`), and
    then used from storage; it's **kept** like a local one (until the
    event ages out), so it isn't downloaded again. Meanwhile the player
    shows a spinner; if it can't be had (signed out, a free profile, not
    in the cloud, offline), "Couldn't load this clip" (frame reading
    fails the same way), and trying again retries. A download that meets
    expired credentials (or a request AWS refused as signed at the wrong
    time) is made again at once with new credentials (or the corrected
    clock); one that's **archived** says so instead (see **Archived
    recordings** below);
  - **asked for a copy** ([Event copies](event-copies.md), "Tap to sync a
    copy to every device"): a device that already has the event unchanged
    downloads its pending recording then (`_Recordings.fetchPending`),
    so it holds it in full and acks it;
  - one download per recording at a time (`_Recordings._inFlight`).
- **Archived recordings (cold storage):** the bucket's lifecycle moves
  objects over 128 KB and under 500 MB (clip recordings, a streamer's
  media and ingest chunks) to **S3 Glacier Deep Archive 67 days after
  upload**, and erases everything 365 days after upload; smaller objects
  (event JSON, clip records, thumbnails, tagged frames) stay readable
  until then. S3 answers a GET of an archived object **HTTP 403 with the
  error code `InvalidObjectState`**, which the app tells from refused
  credentials by the error's XML `<Code>` (`S3Exception.code`,
  `archived`; `credentialsRejected` is `AccessDenied`, `ExpiredToken` or
  `InvalidToken` only, by their words only when the body has no code):
  - an archived object **never counts as rejected credentials**: nothing
    renews them (`backend.reset`), and sync never stops or backs off
    because of one;
  - **playing a clip** whose recording is archived:
    `CloudSync.fetchRecording` returns `RecordingFetch.archived` (it
    returns `stored`, `missing` or `archived`), the load
    (`Persistence._restoreMedia`) fails with `RecordingArchived`, and the
    player shows **"Archived: this video is in cold storage"** (in the
    theme's aqua, not the failure's red) instead of "Couldn't load this
    clip". The key is remembered as archived while the app runs
    (`_Recordings._archived`), so playing it again asks S3 nothing; its
    `fetch:` entry stays (it's still in the cloud). Frame reading
    (tagging, Auto, recognition) fails the same way, as for any
    recording that can't be had;
  - **in a pass** (the full fetch, changed events, wanted clips, the
    media keys), an archived object is skipped like a gone one
    (`_Fetcher._getOrSkip`, `_getIfThere`): a thumbnail or tagged frame
    that can't be read is left out, logged, and the pass goes on. A
    pass never downloads recordings, and the full fetch covers 15 days,
    so only an old event changed elsewhere (its tagged frames) could meet
    one; synced-clip recognition takes clips under a day old; a copy
    asked for (`fetchPending`) goes through `fetchRecording`;
  - **restoring from the archive isn't supported yet**: an archived
    recording can't be played from the cloud (a device that downloaded it
    before still plays its own copy). The [event copies](event-copies.md)
    indicators say a clip older than 67 days is in cold storage.
- **Changes from other devices:** an event the device has that another
  device changed since (a tag added, renamed or removed, a suggestion
  confirmed, object tags) comes down again in the same pass, within the
  same 1000:
  - **Spotted from the listing, not by downloading:** the listing gives
    each key's **ETag**, which for this bucket (single `PUT`s, SSE-S3) is
    the MD5 of the object's bytes (`CloudSync.etagOf`). The `synced`
    store keeps, as `etag:<object key>`, the ETag of each event as this
    device last uploaded or downloaded it. A listed event whose ETag
    differs, at the key this device uploads it to, has changed elsewhere.
  - **A change here not uploaded yet wins:** if the device's own copy
    changed since its last sync, the upload that follows writes it over
    the other device's version. It's downloaded only to see whether the
    other version is **deleted** (`deletedAt`,
    [Device deletion](device-deletion.md)): a deletion wins, and is taken
    on instead.
  - **Kept out of the cloud:** an event deleted from the cloud from its
    cloud indicator (`offcloud:<eventId>` in the synced-keys store, see
    [Event copies](event-copies.md#tapped)) isn't uploaded, nor its clip,
    until it's put back there.
  - **Deleted stays deleted:** a changed copy that isn't deleted, of an
    event deleted here, has its tags taken on but the event stays deleted,
    and its synced fingerprint is forgotten so the next pass uploads it
    deleted again. Live sync follows the same two rules. The clips of
    deleted events aren't fetched or wanted.
  - Downloaded with the tagged frames the device lacks, and handed over as
    `RemoteRecords.updated`. The app (`Persistence.updateFromRemote`)
    replaces the clip's **tags, suggestions, object tags and the frames
    they use** in the event on screen (`ClipAnnotations.replaceWith`),
    so its card, the subjects map, a subject's screen and the Events
    search and count update at once, and saves it. The rest of the local
    event (its clip, location…) stays as it is here.
  - Then that version counts as synced: it isn't uploaded back, nor
    downloaded again until it changes once more.
  - If its clip isn't on the device (it was still recording when the
    event came down, or over [live sync](live-sync.md)), the same pass
    looks for the clip's record and thumbnail, and the app shows the event
    with them (`Persistence.showArrivedClips`).
  - **A new event fetched before its clip's record is up** (its device
    uploads the record only once the clip completes, after the event)
    wants its clip too. A wanted clip not in the bucket yet is looked for
    at each pass for **10 minutes** after the first pass that missed it
    (a time, not a count of passes, since passes come every 15 s or
    every 2 min; before 2026-10-15 it was 40 passes), then again when its
    event changes or at the next full fetch. Until it comes the event is
    kept as "Clip recording missing" (a system event, hidden by default),
    and it shows with its clip as soon as the clip arrives. Before
    2026-10-12 a new event's missing clip wasn't wanted and a wanted one
    was dropped at its first miss, so a phone's clip could stay missing
    on the web for up to an hour.
  - **How soon:** within 15 s for events of today and yesterday (UTC),
    the partitions every pass lists (at once over live sync, and within
    2 min from the bucket for what it missed, while it works); within an
    hour for older ones in the window, at the hourly full listing (see
    below).
  - Events synced before ETags were kept: one this device uploaded is
    recognized by its bytes; one it downloaded (stored with its profile
    ID, so different bytes) is downloaded once more, to learn its ETag.
- **What a pass lists** (`ListObjectsV2`, billed per request, so kept
  small):
  - the first pass for a user (at start, sign-in or a user change) lists
    all of `events/`, which also finds flat keys from before partitioning
    (read to learn their time, and skipped if older);
  - once an hour (`CloudSync.fullFetchEvery`), each day of the window (15
    listings), to catch events a device uploaded late, after being
    offline;
  - while the first pass's or an hourly fetch runs,
    `CloudSync.fetchingHistory` is set, and the events list shows a
    spinner below its cards (see [Events](events.md));
  - every other pass, only **today's and yesterday's** partitions, where
    other devices' new events land; except a pass for a save here or a
    live message within 2 min of the last listing, which lists nothing
    (see above). Every 15 s that's about 11,500 listings a day per device
    (about 345,000 a month, $1.73 at S3's $0.005 per 1000; $0.43 a day
    for listing the whole window every 15 s). While live sync works, at
    most one listing (2 LISTs) per 2 min, however busy: about 1,440 a day
    (43,200 a month, about $0.22), plus the hourly full listings (15 an
    hour, about 10,800 a month, $0.05). A clip, its own or received, adds
    no LIST: before 2026-10-15 each pass a save or a live message started
    listed again, and each received clip had its record and its media
    listed, about 6 LISTs per own clip and 7 per received one (about
    $0.25 a month per device at 2 clips an hour each among 5 devices, so
    about $1.20 for the profile). Now a received clip costs GETs: its
    record and thumbnail, plus one per pass while it's wanted and not up
    yet (about $0.007 a month per device at the same rate).
- A new device (or one whose storage was cleared) therefore starts with
  two weeks of history, rather than everything in the bucket. Events from
  other devices of the same profile (any of its linked Google accounts,
  hence the same Cognito identity) come down within 15 s (over live
  sync at once, and from the bucket within 2 min while it works), and so do
  their changes to today's and yesterday's events. Older data stays in the bucket until it
  expires, and on the devices that recorded it.
- **Upload:** what's stored and not yet uploaded goes up. Clips go
  first, recordings being what matters most.
  - **Only what changed:** `Persistence.changes` names the events it
    saves (a new event, its clip completing, a tag, the events a sign-in
    claims; none for a settings change). An ordinary pass reads just
    those events and their clips (`EventStore.getEvent`,
    `clipsOfEvent`), so its cost doesn't grow with the history. A failed
    pass keeps them for the next.
  - **A reconciliation** looks at every stored event of the profile and
    its clips, to catch anything saved without a notification: on the
    first pass for a user (at start, sign-in or a user change), with each
    hourly full listing, and after a change notification that names
    nothing (null). It lets frames through every 20 records, so the UI
    doesn't stall on a long history.
  - **Recordings are streamed:** read from storage as they're sent
    (an MP4 file on Android, `MediaStore.read`) with a `Content-Length`,
    rather than read whole into memory, and signed with
    `x-amz-content-sha256: UNSIGNED-PAYLOAD` (allowed by S3 over HTTPS,
    which the bucket requires), so they aren't hashed first. JSON and
    images are small and keep a signed SHA-256 payload.
- Tests: `cloud_sync_test.dart` ("a new device gets only the last two
  weeks"; another device's event on the next pass, listing only today and
  yesterday; a pass for a save skips the listing while the last is under
  2 min old, a retry still lists, and a save 2 min later lists; the
  hourly full listing; at most `maxFetch` per pass, newest
  first; another device's change comes down once, as `updated`, and
  doesn't go back up, then again when it changes once more; a change here
  not uploaded yet wins; events synced before ETags were kept are fetched
  at most once more; a fetch in batches; only the events named as changed
  go up, with their clips, a quiet change at the next reconciliation;
  each full fetch reconciles; failed passes back off, log the stack once
  and keep what was to go up; every event, clip and thumbnail handed
  over but no recording, not by later passes nor a full fetch, and
  nothing uploaded back; a recording downloaded by `fetchRecording`
  (played), stored, marked synced and not downloaded again, false when
  signed out or not in the cloud; a failed one tried again when played
  again; expired credentials renewed),
  `s3_test.dart` (keys listed with their ETags, across pages; a full
  1000-key page parsed off the UI isolate; a streamed upload with
  `UNSIGNED-PAYLOAD` and signed headers) and `persistence_test.dart` (a
  session restored at launch; "every
  15 s, events from another device join the timeline"; "a tag removed on
  another device goes at the next sync": the name and the object tag
  leave the card and the map, the frame another tag uses stays, the
  other device's version isn't overwritten, and it's still gone after a
  restart).
- **Nothing twice:** the `synced` store keeps each uploaded object key with
  a fingerprint of its content (the SHA-256 of the JSON, or the media ID),
  and for events their ETag too (`etag:<object key>`, see **Changes from
  other devices**). An unchanged object is skipped. A changed one, such as a clip's event
  that's updated when the clip completes, is uploaded again. A
  thumbnail's fingerprint is `thumbnail`, or `thumbnail@<thumbnailRedone>`
  once it was made again from the recording ([Clips](clips.md)), so a
  new thumbnail goes up again (with the clip's record); the local
  `thumbnailCheck` isn't uploaded, so checking one sends nothing. Devices
  that already have the clip keep the thumbnail they fetched, and check
  it themselves. The sync
  keeps that store in memory, read again at each reconciliation, rather
  than reading it every pass; [retention](event-retention.md) prunes the
  entries of the events it deletes.
- **Light on the device:** a pass reads only event and clip IDs to find
  what's missing, and a stored event only when its listed ETag differs.
  A listing page over 64 KB (a full one is up to 1000 keys) is parsed on
  another isolate (`compute`). The status notifies listeners only when
  it changes.
- One pass runs at a time. A change during a pass queues one more pass.
- **A pass belongs to one profile** (`_Pass`): it captures the session,
  the store and the profile when it starts, stamps fetched events with
  that profile (never whichever is signed in by then), hands over,
  uploads and filters events for it alone, and checks before each step
  (each batch, download, hand-over and upload) that it's still current.
  Signing out, the account moving to another profile, `reconnect()` or a
  stop starts syncing over (`CloudSync._epoch`), and a pass of the one
  before ends at its next step, quietly, without an error or giving its
  events back to the next profile's sync. One upload under way finishes.
- **One damaged object doesn't stop syncing.** Records from the bucket
  go through one codec (`Records`, [lib/storage/records.dart](../presence_app/lib/storage/records.dart),
  shared with `Persistence`): an event needs a string `id` and an integer
  `time` (an integral double, such as `6.0`, counts), a clip record a
  string `id`, a recording reference a media ID of `[A-Za-z0-9_-]`; text
  fields of the wrong type are dropped. Event, clip and frame IDs from the
  bucket must be safe (`Records.isSafeId`, as over live sync), and an
  event's `id` must be its key's. An object that isn't JSON, or fails
  these, is **skipped and logged**, the rest of the pass goes on (the
  other events, the uploads), and it isn't downloaded again until its
  listed ETag changes (a clip record: until the next start); an object
  deleted between listing and download (404) is skipped too, as is a
  clip's record, thumbnail or frame not there (yet). A clip
  whose recording reference is damaged comes without it. Settings in the
  cloud that aren't JSON, or have no `config`, count as none: the local
  ones are uploaded over them.
- **Live sync** ([live-sync.md](live-sync.md)): after a successful pass,
  `CloudSync` starts `LiveSync` with the session's identity and
  credentials. Each event a pass uploads (from the last two weeks) is then
  published, metadata only, right after its `PUT`; each event another
  device publishes is handed to `onRemote` at once (`RemoteRecords.live`),
  marked as synced with the sender's ETag, and its clip and thumbnail are
  fetched from the bucket by a pass started for them
  (`_Fetcher.fetchWanted`) once the clip is there. An event that arrives
  both ways is handed over once.
- **Copies** ([Event copies](event-copies.md)): `CloudSync.copies`
  (`EventCopies`, the app's instance) records whether this device and the
  cloud hold each event (`copyOf`), checked when an event is saved here,
  uploaded, handed over by a fetch or live sync, when its clip arrives or
  its recording downloads (played, or a copy asked for), and for the
  whole window at each full fetch;
  another device's event held here in full is acked over live sync
  (`LiveSync.ackCopied`), once. Other devices' acks add them as holders.

## How

- **Code** ([lib/cloud/](../presence_app/lib/cloud)): `CloudSync`
  ([cloud_sync.dart](../presence_app/lib/cloud/cloud_sync.dart)) is the
  public API and runs the passes (when, backoff, stop and retry, the
  profile and its epoch); its parts, one file each (`part of` the same
  library, sharing its private state):
  - [cloud_sync_pass.dart](../presence_app/lib/cloud/cloud_sync_pass.dart):
    `_Pass`, one pass's session, store and profile, checked at each step;
  - [cloud_sync_fetch.dart](../presence_app/lib/cloud/cloud_sync_fetch.dart):
    `_Fetcher`, new and changed events, their clips and frames, wanted
    clips, and the device's settings;
  - [cloud_sync_upload.dart](../presence_app/lib/cloud/cloud_sync_upload.dart):
    `_Uploader`, what goes up, and publishing it over live sync;
  - [cloud_sync_recordings.dart](../presence_app/lib/cloud/cloud_sync_recordings.dart):
    `_Recordings`, downloads of recordings, when played or a copy is asked for;
  - [cloud_sync_live.dart](../presence_app/lib/cloud/cloud_sync_live.dart):
    `_LiveBridge`, starting live sync and taking the events it brings;
  - [cloud_sync_copies.dart](../presence_app/lib/cloud/cloud_sync_copies.dart):
    `_CopyTracker`, who holds each event;
  - [cloud_sync_keys.dart](../presence_app/lib/cloud/cloud_sync_keys.dart):
    object keys, JSON and fingerprints.

  `CloudSession`, `CloudBackend` and `AwsCloudBackend` are in
  [cloud_backend.dart](../presence_app/lib/cloud/cloud_backend.dart)
  (exported by `cloud_sync.dart`).
- **Credentials** (`CognitoCredentials`):
  - `POST /api/auth/credentials` on the auth API, with the
    [session token](sessions.md), answers the profile's identity ID and a developer-identity token
    (`presence_user` only; see [Profiles](profiles.md));
  - then `GetCredentialsForIdentity` with
    `Logins: {"cognito-identity.amazonaws.com": <token>}`. This call is
    unsigned: the token is the proof;
  - credentials are reused until five minutes before they expire (by
    AWS's time, see **Clock**); callers asking at once (a pass, live
    sync, a playback download) share one fetch, and one that a sign-out
    or reset cleared meanwhile isn't kept;
  - after a link or unlink, `CloudSync.reconnect()` drops them and starts
    over, as for a new user (the folder changed).
- **Uploads** (`S3Bucket`, `SigV4Signer`): `PUT` to
  `https://<bucket>.s3.us-east-1.amazonaws.com/<key>`, signed with AWS
  Signature Version 4 in pure Dart (`crypto`, `http`). The signer is tested
  against AWS's published S3 examples. Recordings go with `putStream`
  (`UNSIGNED-PAYLOAD`, the body streamed with its `Content-Length`; the
  headers, storage class included, are still signed); the rest with a
  signed SHA-256 of the body.
- **Clock** (`AwsClock`, [sigv4.dart](../presence_app/lib/cloud/sigv4.dart)):
  requests are signed with the device's time, and AWS refuses one more
  than 15 min off its own (S3's `RequestTimeTooSkewed`). When S3 says
  so, `S3Bucket` takes AWS's time from the answer (its `ServerTime`, or
  else its `Date` header) and from then on signs with the device's clock
  corrected by that offset (`AwsClock.shared`, used by S3, the credentials'
  expiry and [live sync](live-sync.md)'s connection URL); the pass that
  met it runs again at once. If it still fails, the error says
  **"This device's clock is off by N min: set it to the right time to
  sync"**. AWS IoT's own refusal isn't recognized (its WebSocket handshake
  doesn't say why), but live sync signs with the clock S3 corrected.
- **Errors:**
  - if S3 rejects expired credentials, the app fetches new ones and
    continues;
  - an archived object (403 `InvalidObjectState`) isn't an error of the
    credentials or of the pass: see **Archived recordings**;
  - if S3 refuses a request as signed at the wrong time, see **Clock**;
  - if the auth API rejects the session token (401, for example once
    the session has ended and couldn't be refreshed), or Cognito rejects its token (`NotAuthorizedException`),
    the account sheet says **"Sign in again to resume uploads"**;
  - any failure to get credentials (the auth API or Cognito) **stops
    syncing**: no more passes, not even for new events or every 15 s,
    until the session token changes (its hourly refresh, or signing in
    again), the account
    sheet's **Retry** button (shown beside the error while stopped,
    `CloudSync.retry`), or `reconnect()` after a profile link. Other
    errors than a rejected token show the auth API's message (for
    example "the profile service failed");
  - other failures (S3, the network) show "Upload failed (HTTP …)" and a
    later pass tries again, after the back-off (see **When**).
- **Status:** not on the account sheet (the Profile tab); the other pages
  show it (the Events tab's sync, the Log tab's
  [health panel](log.md)).
- **Configuration** (`CloudConfig`, dart-defines like the Google client
  IDs): `AWS_REGION` (default `us-east-1`), `COGNITO_IDENTITY_POOL_ID` and
  `USER_DATA_BUCKET`, and for [live sync](live-sync.md) `IOT_ENDPOINT`
  (the account's AWS IoT data endpoint; empty, live sync is off). The app doesn't call the pool by ID any more (the
  auth API does), but sync is still off when either ID is empty: no cloud
  backend is created, so Cognito and S3 are never called and everything
  stays on the device. It's also off in DEV ([execution
  mode](execution-mode.md)). In production,
  `scripts/deploy.sh` sets them from the stack outputs (and
  `IOT_ENDPOINT` from `aws iot describe-endpoint`); locally they come
  from `.env`.
- The auth API takes only Presence session tokens. The Google ID token
  the app trades for one is issued for the web client on every platform
  (web directly, Android and iOS through `serverClientId`), so that one
  client ID is what the session exchange accepts for Google and what the
  identity pool lists for Google.

The first failed pass of a streak is logged with its full error and stack
(the S3 or auth API response, not only the "Upload failed (HTTP 403)" in
the health tooltip); each further one in a row gets one line, with the
count and the wait before the next try, and the first pass that works
again logs that it recovered. Admins read them on the [Log](log.md) tab.

## Infrastructure

In [presence_infra/](../presence_infra):

- **`user-data.yaml`**, stack `presence-user-data`: the bucket (its name
  is the stack output `UserDataBucketName`, `USER_DATA_BUCKET` in the
  private `.env`).
  - Private (public access blocked, owner-enforced), SSE-S3 encrypted, and
    TLS only.
  - **Readable 67 days, archived, erased after 365** (the same
    everywhere): 67 days after it was written, an object over 128 KB (a
    recording, streamer video) moves to **Glacier Deep Archive**, the
    coldest class, where it can't be read without a restore (hours; not
    supported by the app yet: the player says it's archived). Smaller
    objects (events, clip records, thumbnails, frames) stay readable. Every
    object expires 335 days after it was written (a changed object that's
    uploaded again starts over); being versioned, the bucket then keeps it
    as an old version for 30 more days, as it does for anything overwritten
    or deleted, so a mistake can be undone, and it's erased for good 365
    days after it was written. A lifecycle rule clears the leftover delete
    markers; incomplete multipart uploads go after 1 day.
  - A new device, or one whose storage was cleared, restores only the last
    two weeks anyway (see "When" above). Devices keep their own copies of older
    events, and the app doesn't upload expired ones again (it remembers
    what it uploaded).
  - **S3 Intelligent-Tiering:**
    - uploads carry `x-amz-storage-class: INTELLIGENT_TIERING` (signed);
    - a lifecycle rule moves any other object, old versions included, to
      that class on day 0;
    - objects then move by themselves between the Frequent, Infrequent
      (after 30 days unread) and Archive Instant Access (after 90 days)
      tiers, and all stay readable at once;
    - Intelligent-Tiering's own opt-in Archive and Deep Archive tiers are
      off (they'd archive by idle time, including recent clips); instead a
      lifecycle rule moves objects over 128 KB to the Glacier Deep Archive
      class at 67 days, by age (above), which the app knows how to show
      ("Archived recordings");
    - objects under 128 KB, such as event JSON, stay in the Frequent tier
      with no monitoring fee.
  - CORS allows `GET`, `PUT`, `HEAD` and `DELETE` from `https://presence.nu01.com`,
    `https://local.presence.nu01.com:8443` and `http://localhost:8080`.
- **`identity.yaml`**, stack `presence-identity`: the identity pool (the
  stack output `IdentityPoolId`, `COGNITO_IDENTITY_POOL_ID` in the private
  `.env`).
  - The auth API's developer provider (`login.presence.profiles`) for
    profiles, plus Google (`accounts.google.com` = the web client ID),
    left from before profiles: the API no longer calls `GetId` with a
    Google token (it never sees one; see [Sessions](sessions.md)). No
    guests, no classic flow.
  - Its authenticated role may only `PutObject`, `GetObject` and
    `DeleteObject` (upload, fetch, and the one-time deletion of what was
    stored unencrypted, see [Media encryption](encryption.md)) in
    `<bucket>/${cognito-identity.amazonaws.com:sub}/*`, and `ListBucket` on
    that prefix. That `sub` is the profile's identity, the same for all its
    linked accounts.
  - For [live sync](live-sync.md), the role may also connect to AWS IoT
    with client IDs starting with that identity and publish, receive and
    subscribe on `presence/<Stage>/<identity>/*`; the `presence-live-sync`
    IoT policy (output `LivePolicyName`) grants the same, and the auth API
    attaches it to each identity.

## Verified

- Integrity: `cloud_sync_test.dart` (signing out mid-pass uploads nothing
  more; a pass that outlives its profile hands over and uploads nothing
  for the next one, nor into the old folder; non-JSON, ID-less, wrongly
  typed, unsafe or mismatched objects are skipped, not downloaded again
  until they change, and the rest syncs; an unsafe frame ID isn't
  fetched; a damaged recording reference is dropped; a clock-skewed
  request is made again, and a persistent one says the clock is off; a
  recording download that meets expired credentials succeeds with new
  ones in the same run; an archived recording, the fake S3 answering 403
  `InvalidObjectState`, is `RecordingFetch.archived`, not asked for
  again, and neither renews the credentials nor stops sync, nor do
  archived objects met by a pass), `persistence_test.dart` (an archived
  cloud clip, played, shows "Archived: this video is in cold storage",
  its load fails with `RecordingArchived`, the credentials kept),
  `s3_test.dart` (the clock corrected from
  `ServerTime` or the `Date` header, the next request signed with it,
  other errors leave it; `InvalidObjectState` is archived, never
  rejected credentials, even with other codes' words in its message;
  the credentials rejected by their codes), `profile_test.dart` (one credentials fetch for
  callers at once; a cleared one isn't kept) and
  `record_integrity_test.dart` (the codec).
- Settings: `cloud_sync_test.dart` (the settings listing only on the
  first pass, an upload when they change, another device's, a damaged or
  a non-JSON record ignored and replaced; the profile's older record wins over
  another profile's newer settings, the profile's own newer ones stay,
  and the settings are claimed for the profile with or without a record)
  and `persistence_test.dart` (signed in, the defaults go up under the
  device ID and a change follows with its time; at start a newer cloud
  record wins and stays on the device, and an older one loses and is
  replaced; signing in to another profile restores its settings and its
  location set on the map, though the local ones were newer; moving the
  map changes the record).
- Fetch and timer tests:
  - on sign-in, a remote clip (details, thumbnail) and event are
    downloaded and handed over, its video not (until played), and none
    of them uploaded back, while local items are uploaded;
  - the fetch runs once per sign-in;
  - periodic passes run without a change, but upload an event saved
    without a change notification only at the next reconciliation (a
    null notification, or each full fetch);
  - at app level, a clip from the cloud joins the Events timeline and its
    recording is downloaded when played (`persistence_test.dart`, "a
    cloud clip whose recording isn't here yet downloads it when played").
- Against AWS, the app's `S3Bucket` uploaded a 300 KB recording and an event
  to the real bucket, listed the prefix (both keys) and downloaded the
  recording byte-for-byte. It was cleaned up afterwards.
- Event keys: `CloudSync.eventKey` puts 2026-09-26 at `day=269`, 1 January
  at `day=001`, 31 December 2024 at `day=366`, and splits days at UTC
  midnight. The fetch reads both partitioned keys and the flat
  `events/<id>.json` ones from before partitioning.
- The earlier unit tests:
  - SigV4 against AWS's GET and PUT Object examples;
  - `CloudSync` with a fake backend: nothing while signed out; everything on
    sign-in, under the identity; no duplicates; changed events again; new
    events; renewed credentials; "sign in again"; sign-out stops uploads.
- An app-level test: signed in, a finished clip's video, thumbnail, details
  and events upload.
- Against AWS:
  - the app's `S3Bucket` uploaded to the real bucket (a key containing `:`
    and a space) with session credentials: 200, stored encrypted;
  - CORS preflights from the three origins return 200, and another origin
    gets 403;
  - the identity pool rejects a forged Google token and guest access.
- Not yet verified: a real Google sign-in exchanging its token and
  uploading. That needs an interactive sign-in. IAM's policy simulator
  doesn't substitute `${cognito-identity.amazonaws.com:sub}`, so the prefix
  rule was checked with a literal-identity variant of the same policy: the
  own prefix is allowed, another's and deletes are denied.

## Known limitations

- Uploads stop with "Sign in again to resume uploads" only when the
  [session](sessions.md) ends (sign-out elsewhere, a reused refresh token,
  60 days unused): the app refreshes its session token before it expires.
- Local development uses the production bucket and pool, each user in their
  own prefix.
- Recordings are uploaded in one `PUT`, not multipart. That's fine at about
  10 MB per clip.
- A downloaded recording is held whole in memory until it's stored (one
  at a time, about 6 MB); only uploads stream. Streaming downloads into
  the media store would need a streaming `get` on `CloudSession` and a
  streaming `saveBytes` on `MediaStore` (IndexedDB keeps whole values
  anyway), so it's left as is. Playing one that isn't here yet waits
  for the whole download (no streaming playback from S3), with a spinner
  and no progress.
- A recording downloaded to be played stays on the device (IndexedDB on
  the web) like a local one (until the event ages out); the others stay
  in the cloud. So another device's clip plays at once only once it's
  been played (or its copy asked for) there; offline, one never played
  can't be.
- Not yet verified on a real device: on-demand playback over mobile data,
  and in a phone browser, against the real bucket.
- An event changed in storage without a `Persistence.changes`
  notification goes up only at the next reconciliation, within the hour.
- A reconciliation still encodes and hashes every stored event and clip
  record (letting frames through as it goes), once an hour.
- A clip deleted on one device isn't deleted elsewhere: retention deletes
  per device, and [deleting a device or an event](device-deletion.md) only hides events
  (`deletedAt`), synced, without deleting anything.
- Of a changed event, only its tags, suggestions and object tags are taken
  on: other fields another device changes (such as `clipState`) aren't,
  though a clip that completed since comes down with it.
- Two devices changing the same event between passes: the last upload
  wins, whole. A device holding an unsynced change uploads it over the
  other's, so the other's edit to that event is lost.
- Changes to events older than yesterday arrive within the hour, not the
  15 s.
- ETags as MD5s need single `PUT`s and SSE-S3 (or no) encryption. With
  SSE-KMS or multipart uploads they wouldn't match, and each such event
  would be downloaded once more after every upload.
