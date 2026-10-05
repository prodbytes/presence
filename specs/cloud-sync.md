# Cloud sync

Signed-in users' **clips (videos), events and each device's settings
sync with S3**, straight from
the device, both ways: at start and **every 15 s**, events only on the
device go up, events only in the user's folder come down, and events
another device changed (such as a tag removed) come down again and
replace what's on screen, so every device of a user shows the same
events as the bucket. The auth API only
hands out credentials: the app trades the user's Google ID token for a
token for their [profile](profiles.md), and that for temporary AWS
credentials through a **Cognito identity pool**. It then makes signed S3
uploads itself ([lib/cloud/](../presence_app/lib/cloud)).

## What's uploaded, and where

Everything goes under the user's profile's **Cognito identity ID**
(`us-east-1:<uuid>`), the same for every account linked to the
[profile](profiles.md), in the user-data bucket, with JSON and media in
separate trees so the JSON can be queried on S3. The formats, fields and
an Athena table are in [Recording and data formats](data-formats.md).

| Object | Content |
|---|---|
| `<identityId>/media/<clipId>.webm` or `.mp4` | the clip's recording (the full clip, or the before part if the after part was cut short), with its MIME type |
| `<identityId>/media/<clipId>.jpg` | the thumbnail |
| `<identityId>/media/<clipId>/frames/<frameId>.jpg` | each frame people or pets were tagged on (see [Clips](clips.md#naming-people-and-pets)), uploaded once; the event JSON refers to it by `frameId`, and a fetch downloads the frames its tags use |
| `<identityId>/clips/year=<YYYY>/day=<DDD>/<clipId>.json` | the clip record: camera, window, lengths, state, media reference; in its event's day partition (the event's `time`, which is the clip's `requestedAt`) |
| `<identityId>/devices/<deviceId>/settings.json` | the device's settings for this profile: `{deviceId, profileId, updatedAt, config, location}`, every Settings value and the location set on the map (see [Configuration](configuration.md)) |
| `<identityId>/events/year=<YYYY>/day=<DDD>/<eventId>.json` | each of the user's event records (type, title, detail, time, camera, device and user IDs, the device's location, clip ID and state, and for clips the named people and pets, `annotations`, each with its position and `frameId`, without the frame images, and the object tags, `objectTags`), partitioned by the UTC day of the year of its time (`day=001` to `day=366`), Hive-style so tools such as Athena can prune by partition |

- What a device uploaded under the old layout (`clips/<clipId>.webm`,
  `.jpg`, `.json` and `clips/<clipId>/frames/`, before 2026-10-02) counts
  as uploaded: it isn't sent again under the new keys.

## When

- **Only the profile's own:** a pass uploads the events whose
  `profileId` is the signed-in account's [profile](profiles.md), and only
  the clips (and tagged frames) of those events. Events recorded signed
  out go up once the sign-in gives them its profile, moments later;
  another profile's never do. Fetched events, from the profile's folder,
  get its `profileId`. See [Devices, users and
  places](devices-users-places.md).
- **Signed out, signed in without `presence_user`, or before the auth API
  answers with the profile:** nothing is uploaded or fetched (see
  [Sign-in](sign-in.md) and [Membership](membership.md)). Sync starts once
  the roles check grants access and gives the profile; another profile
  (after a link) starts it over.
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
  recording completes (`Persistence.changes`). Passes stop after a
  credentials failure (see **Errors**).
- **Fetch:** the events in the user's folder that the device doesn't have
  are downloaded, with their clips (details, recording and thumbnail) and
  tagged frames:
  - only from the last **two weeks** (`CloudSync.restoreWindow`, 14 days),
    or the History setting when that's shorter (`CloudSync.keep`), so
    nothing the device deletes as too old comes back ([event
    retention](event-retention.md)): event keys are partitioned by UTC
    day, so older partitions aren't read, and in the window's first day
    each event's `time` decides;
  - at most **1000 events per pass** (`CloudSync.maxFetch`), the newest
    first; any rest come down in later passes;
  - only the clips those events use: each record read from its event's
    day partition (`clips/year=…/day=…/<clipId>.json`, listed first), and
    its media found by listing just its own keys (`media/<clipId>`);
  - they're marked as synced, so they aren't uploaded back, stored
    (`Persistence.importRemote`, with recordings through
    `MediaStore.saveBytes`) and added to the event log, so the
    **Monitoring** tab shows them at once.
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
    changed since its last sync, it isn't downloaded, and the upload that
    follows writes it over the other device's version.
  - Downloaded with the tagged frames the device lacks, and handed over as
    `RemoteRecords.updated`. The app (`Persistence.updateFromRemote`)
    replaces the clip's **tags, suggestions, object tags and the frames
    they use** in the event on screen (`ClipAnnotations.replaceWith`),
    so its card, the subjects map, a subject's screen and the Events
    search and count update at once, and saves it. The rest of the local
    event (its clip, location…) stays as it is here.
  - Then that version counts as synced: it isn't uploaded back, nor
    downloaded again until it changes once more.
  - **How soon:** within 15 s for events of today and yesterday (UTC),
    the partitions every pass lists; within an hour for older ones in
    the window, at the hourly full listing (see below).
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
  - every other pass, only **today's and yesterday's** partitions, where
    other devices' new events land: about 11,500 listings a day per
    device, roughly $0.06 a day at S3's $0.005 per 1000, against $0.43 for
    listing the whole window every 15 s.
- A new device (or one whose storage was cleared) therefore starts with
  two weeks of history, rather than everything in the bucket. Events from
  other devices of the same profile (any of its linked Google accounts,
  hence the same Cognito identity) come down within 15 s, and so do
  their changes to today's and yesterday's events. Older data stays in the bucket until it
  expires, and on the devices that recorded it.
- **Upload:** everything stored and not yet uploaded goes up. Clips go
  first, recordings being what matters most.
- Tests: `cloud_sync_test.dart` ("a new device gets only the last two
  weeks"; another device's event on the next pass, listing only today and
  yesterday; the hourly full listing; at most `maxFetch` per pass, newest
  first; another device's change comes down once, as `updated`, and
  doesn't go back up, then again when it changes once more; a change here
  not uploaded yet wins; events synced before ETags were kept are fetched
  at most once more), `s3_test.dart` (keys listed with their ETags, across
  pages) and `persistence_test.dart` (a session restored at launch; "every
  15 s, events from another device join the timeline"; "a tag removed on
  another device goes at the next sync": the name and the object tag
  leave the card and the map, the frame another tag uses stays, the
  other device's version isn't overwritten, and it's still gone after a
  restart).
- **Nothing twice:** the `synced` store keeps each uploaded object key with
  a fingerprint of its content (the SHA-256 of the JSON, or the media ID),
  and for events their ETag too (`etag:<object key>`, see **Changes from
  other devices**). An unchanged object is skipped. A changed one, such as a clip's event
  that's updated when the clip completes, is uploaded again.
- One pass runs at a time. A change during a pass queues one more pass.

## How

- **Credentials** (`CognitoCredentials`):
  - `POST /api/auth/credentials` on the auth API, with the Google ID token,
    answers the profile's identity ID and a developer-identity token
    (`presence_user` only; see [Profiles](profiles.md));
  - then `GetCredentialsForIdentity` with
    `Logins: {"cognito-identity.amazonaws.com": <token>}`. This call is
    unsigned: the token is the proof;
  - credentials are reused until five minutes before they expire;
  - after a link or unlink, `CloudSync.reconnect()` drops them and starts
    over, as for a new user (the folder changed).
- **Uploads** (`S3Bucket`, `SigV4Signer`): `PUT` to
  `https://<bucket>.s3.us-east-1.amazonaws.com/<key>`, signed with AWS
  Signature Version 4 in pure Dart (`crypto`, `http`). The signer is tested
  against AWS's published S3 examples.
- **Errors:**
  - if S3 rejects expired credentials, the app fetches new ones and
    continues;
  - if the auth API rejects the Google token (401, for example once it
    has expired), or Cognito rejects its token (`NotAuthorizedException`),
    the account sheet says **"Sign in again to resume uploads"**;
  - any failure to get credentials (the auth API or Cognito) **stops
    syncing**: no more passes, not even for new events or every 15 s,
    until the Google ID token changes (signing in again), the account
    sheet's **Retry** button (shown beside the error while stopped,
    `CloudSync.retry`), or `reconnect()` after a profile link. Other
    errors than a rejected token show the auth API's message (for
    example "the profile service failed");
  - other failures (S3, the network) show "Upload failed (HTTP …)" and
    the next pass tries again.
- **Status:** the account sheet shows a line under the email: "Cloud backup
  is off", "Uploading…", "Backed up (N uploaded, M restored)", or the error.
- **Configuration** (`CloudConfig`, dart-defines like the Google client
  IDs): `AWS_REGION` (default `us-east-1`), `COGNITO_IDENTITY_POOL_ID` and
  `USER_DATA_BUCKET`. The app doesn't call the pool by ID any more (the
  auth API does), but sync is still off when either ID is empty: no cloud
  backend is created, so Cognito and S3 are never called and everything
  stays on the device. It's also off in DEV ([execution
  mode](execution-mode.md)). In production,
  `scripts/deploy.sh` sets them from the stack outputs; locally they come
  from `.env`.
- The Google ID token is issued for the web client on every platform: web
  directly, and Android and iOS through `serverClientId`. So the auth API
  and the identity pool trust that one client ID.

A failed pass is logged once with its full error (the S3 or auth API response,
not only the "Upload failed (HTTP 403)" in the health tooltip), and admins
read it on the [Log](log.md) tab.

## Infrastructure

In [presence_infra/](../presence_infra):

- **`user-data.yaml`**, stack `presence-user-data`: the bucket (its name
  is the stack output `UserDataBucketName`, `USER_DATA_BUCKET` in the
  private `.env`).
  - Private (public access blocked, owner-enforced), SSE-S3 encrypted, and
    TLS only.
  - **Kept for 3 months:** every object expires 90 days after it was
    written (a changed object that's uploaded again starts over). Being
    versioned, the bucket then keeps it as an old version for 30 more days,
    as it does for anything overwritten or deleted, so a mistake can be
    undone. After that it's gone, and a lifecycle rule clears the leftover
    delete markers. Incomplete multipart uploads go after 1 day.
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
    - the opt-in Archive and Deep Archive tiers are off: they need a restore
      before a read, which would break the fetch after sign-in;
    - objects under 128 KB, such as event JSON, stay in the Frequent tier
      with no monitoring fee.
  - CORS allows `GET`, `PUT` and `HEAD` from `https://presence.nu01.com`,
    `https://local.presence.nu01.com:8443` and `http://localhost:8080`.
- **`identity.yaml`**, stack `presence-identity`: the identity pool (the
  stack output `IdentityPoolId`, `COGNITO_IDENTITY_POOL_ID` in the private
  `.env`).
  - The auth API's developer provider (`login.presence.profiles`) for
    profiles, plus Google (`accounts.google.com` = the web client ID), which
    the API's `GetId` uses to find pre-profile identities. No guests, no
    classic flow.
  - Its authenticated role may only `PutObject` and `GetObject` (upload and
    fetch) in
    `<bucket>/${cognito-identity.amazonaws.com:sub}/*`, and `ListBucket` on
    that prefix. No deletes. That `sub` is the profile's identity, the same
    for all its linked accounts.

## Verified

- Settings: `cloud_sync_test.dart` (the settings listing only on the
  first pass, an upload when they change, another device's or a damaged
  record ignored and replaced; the profile's older record wins over
  another profile's newer settings, the profile's own newer ones stay,
  and the settings are claimed for the profile with or without a record)
  and `persistence_test.dart` (signed in, the defaults go up under the
  device ID and a change follows with its time; at start a newer cloud
  record wins and stays on the device, and an older one loses and is
  replaced; signing in to another profile restores its settings and its
  location set on the map, though the local ones were newer; moving the
  map changes the record).
- Fetch and timer tests:
  - on sign-in, a remote clip (details, video, thumbnail) and event are
    downloaded, handed over and not uploaded back, while local items are
    uploaded;
  - the fetch runs once per sign-in;
  - a periodic pass uploads an event that was saved without a change
    notification;
  - at app level, a clip from the cloud joins the Events timeline and its
    downloaded recording plays.
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
  and events upload, and the account sheet says "Backed up".
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

- Google ID tokens last about an hour, and the app has no silent refresh.
  After that, uploads stop with "Sign in again to resume uploads".
- Local development uses the production bucket and pool, each user in their
  own prefix.
- Recordings are uploaded in one `PUT`, not multipart. That's fine at about
  10 MB per clip.
- A clip deleted on one device isn't deleted elsewhere (nothing is
  deleted yet).
- Of a changed event, only its tags, suggestions and object tags are taken
  on: other fields another device changes (such as `clipState`) aren't.
- Two devices changing the same event between passes: the last upload
  wins, whole. A device holding an unsynced change uploads it over the
  other's, so the other's edit to that event is lost.
- Changes to events older than yesterday arrive within the hour, not the
  15 s.
- ETags as MD5s need single `PUT`s and SSE-S3 (or no) encryption. With
  SSE-KMS or multipart uploads they wouldn't match, and each such event
  would be downloaded once more after every upload.
