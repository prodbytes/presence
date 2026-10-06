# Live sync

The devices of a [profile](profiles.md) tell each other about **new and
changed events within about a second**, over **MQTT** (AWS IoT Core, MQTT
3.1.1 over WebSockets), instead of waiting for the next 15 s listing of the
bucket. [Cloud sync](cloud-sync.md) still does everything it did: **S3 stays
where events and all their media are kept**, and a device that misses a
message gets the event from the bucket as before. Nothing is deleted.

This is phase 1. Phase 2 (planned, not built) adds acknowledgements from
the receiving devices, deletes an event's S3 record once three devices
acknowledged it, and asks the online devices for events at start; the
topics and messages below leave room for it.

## What a device does

`LiveSync` ([lib/cloud/live_sync.dart](../presence_app/lib/cloud/live_sync.dart)),
owned by `CloudSync`:

- **Connects** once a cloud sync pass has a session (signed in, with a
  profile and `presence_user`), with the profile's Cognito credentials (the
  same ones S3 uses, from `CloudSession.credentials`), to
  `wss://<IOT_ENDPOINT>/mqtt`, presigned with AWS Signature Version 4
  (`SigV4Signer.presignWebSocket`, service `iotdevicegateway`, only `host`
  signed, valid 1 h; the session token is appended after signing, as AWS IoT
  requires).
  - **Client ID** `<identityId>-<deviceId>-<session>`: the identity first,
    which the IoT policy requires; the [device ID](devices-users-places.md);
    and six random characters per app run, so two tabs of one browser (one
    device ID) don't take each other's connection.
  - **Subscribes** to the profile's events topic (QoS 1).
  - **Reconnects** after a drop at once (1 s), and after a refused
    connection with a back-off that doubles up to 2 min; each attempt asks
    for credentials again and signs a new URL.
  - **Renews** the connection (new credentials, new URL) 2 min before the
    credentials expire.
  - **Disconnects** on sign-out, when the profile changes (a link or
    unlink: `CloudSync.reconnect`), when credentials can't be had (cloud
    sync stops), and when the app closes.
- **Publishes** each event a pass uploads, right after its `PUT` to the
  bucket succeeds (so the bucket already holds it, and its tagged frames,
  clip record and thumbnail, which go up first), at QoS 1. Only events
  from within the restore window (two weeks), not a reconciliation's old
  ones; nothing while disconnected (the bucket carries it).
- **Receives** the profile's other devices' events: a message from this
  device's own ID is ignored; anything malformed, too big or not for this
  identity is dropped (see **Validation**). Messages are handed to cloud
  sync one at a time, in order (`CloudSync._onLive`):
  - **A new event** is handed to `onRemote` at once, as
    `RemoteRecords(events: […], live: true)`: the app stores it
    (`Persistence.importRemote`) and adds it to the event log, so
    **Monitoring** and the account sheet's devices show it immediately.
    A clip event whose clip isn't here yet shows a clip **awaiting the
    other device** (`VideoClip.awaitingRemote`: "Recording on another
    device…", no thumbnail, not playable).
  - It's **marked as synced** (the fingerprint of the stored record, and
    the ETag the sender uploaded), so it's never uploaded back, and the
    bucket's copy isn't downloaded again when a pass lists it. One that
    arrives both ways is handed over once (`CloudSync._handedOver`).
  - **An event the device has** that changed there (tags, suggestions,
    object tags): taken on as `RemoteRecords.updated`, with the tagged
    frames it lacks downloaded from the bucket; unless it changed here too
    and that isn't uploaded yet (this device's version goes up, as with the
    bucket). A message identical to the stored event is a duplicate (QoS 1
    may repeat one) and changes nothing.
  - **Its clip comes from the bucket:** when the event's clip isn't here, a
    pass starts at once and looks for the clip's record and thumbnail
    (`CloudSync._fetchWanted`). While the clip is still recording on the
    other device, there's none yet; when it completes there, its recording,
    thumbnail and record go up, then the event (now `clipState: complete`)
    is uploaded and published again, and this device fetches the clip
    then. The app shows the event again with it
    (`Persistence.showArrivedClips`, `EventLog.replace`; also for an
    event restored at launch before its clip came): its thumbnail
    appears on its card and in the Camera tab's [All](camera.md#all-devices)
    grid, and it plays. The recording follows cloud sync's usual rules
    (in the background on Android and desktop, when played on the web).
    The bucket's listing catches a missed completion: a changed event
    whose clip isn't here asks for it too.

## Topics and messages

- **Topics**, per profile and stage: `presence/<stage>/<identityId>/<kind>`,
  where `<stage>` is `prod` or `rc` (the build's `PRESENCE_STAGE`; any
  other build is `prod`, as local builds use production's pool) and
  `<identityId>` the profile's Cognito identity (its folder in the
  bucket). Phase 1 uses `events`; `acks` and `requests` are reserved for
  phase 2, and the policies already allow `presence/<stage>/<identityId>/*`.
- **An event message** (JSON, UTF-8, at most 64 KB; AWS IoT allows
  128 KB):

  ```json
  {
    "v": 1,
    "kind": "event",
    "deviceId": "automatic_paranoid_gadget",
    "identityId": "us-east-1:…",
    "sentAt": 1791234567890,
    "key": "events/year=2026/day=279/<eventId>.json",
    "etag": "<MD5 of the event JSON uploaded, hex>",
    "event": { "id": "…", "type": "clip_requested", "time": 1791234567000,
               "clipId": "…", "clipState": "partial", "annotations": […], … }
  }
  ```

  - `deviceId` is the **sender**, `key` and `etag` the event's object in
    the bucket as uploaded (phase 2's acknowledgements and deletion will
    refer to them), `event` the event record as uploaded.
  - **Metadata only, never media:** `event` carries references (`clipId`,
    `frameId`s in `annotations`, `cameraId`), never frames, thumbnails or
    video. Before publishing, `LiveSync.metadataOf` removes `frames`,
    `thumbnail`, `recording`, `bytes` and `data`, and any value that is
    raw bytes (a byte array, or a list of more than 16 integers). The media
    is always in the bucket.

### Validation

`LiveSync.parse` drops a message that is over 64 KB, isn't JSON, isn't
version 1 or `kind: event`, names another identity, has a `deviceId`,
event `id` or `clipId` outside `[A-Za-z0-9_.:-]{1,128}` or containing
`..` (they go into object keys), an event without an integer
`time`, a `type` over 64 characters, or an `etag` that isn't 32 hex digits.
Inline media in a received event is stripped the same way. Cloud sync then
also ignores an event of another `profileId`, and one older than the
restore window, and gives the event the profile's ID. The IoT policy
already keeps other profiles off the topic.

## Infrastructure and permissions

- **The identity pool's authenticated role** (`own-live-sync` in
  [identity.yaml](../presence_infra/identity.yaml)): `iot:Connect` on
  `client/${cognito-identity.amazonaws.com:sub}-*`, `iot:Publish` and
  `iot:Receive` on `topic/presence/<Stage>/${…:sub}/*`, `iot:Subscribe` on
  `topicfilter/presence/<Stage>/${…:sub}/*`. A profile reaches only its
  own topics, as with its S3 prefix.
- **The IoT policy** `presence-live-sync` (`presence-rc-live-sync` for the
  RC; `LivePolicy`, output `LivePolicyName`): the same statements, with the
  identity as a policy variable. AWS IoT requires a policy attached to an
  authenticated Cognito identity besides its role, so **the auth API
  attaches it** at `POST /api/auth/credentials` (`iot:AttachPolicy`, target
  the identity ID; idempotent, and skipped while the function instance has
  already attached it for that identity). A failure is logged and doesn't
  fail the credentials: sync still works through the bucket. The auth
  API's function gets `iot:AttachPolicy` on `*` (AWS IoT can scope it only
  to certificates and thing groups, not to a Cognito identity or a
  policy); it only ever attaches `IotPolicyName`. Without `IotPolicyName`
  (local Floci), nothing is attached and the permission is on a
  certificate that doesn't exist.
- **The endpoint** is the account's `iot:Data-ATS` endpoint: not a
  CloudFormation attribute, so [scripts/deploy.sh](../scripts/deploy.sh)
  looks it up (`aws iot describe-endpoint --endpoint-type iot:Data-ATS`,
  checked to look like `<id>-ats.iot.<region>.amazonaws.com`) and passes it
  to the web build as `IOT_ENDPOINT` (a public dart-define, in
  `scripts/dart-defines.sh`'s allowlist). Android and local builds take it
  from `.env` (`IOT_ENDPOINT`, see `.env.example`).
- **The deploy roles** (`github-deploy.yaml`) may manage `presence-*` (RC:
  `presence-rc-*`) IoT policies and their versions, and call
  `iot:DescribeEndpoint`. An administrator must update that stack by hand
  before the first deploy with live sync (see
  [presence_infra/README.md](../presence_infra/README.md)).

## Off

Live sync is off, and everything syncs through the bucket as before, when
the build has no `IOT_ENDPOINT` (local Floci, tests, a `.env` without it),
when cloud sync is off, and while signed out.

## Status

The health line and the Log tab's health panel have a fourth check,
**📡 Live** ([Settings](settings.md), [Log](log.md)): ⚪ not set, ✅
connected (with the events received and sent) or set and waiting for the
first sync, ⏳ connecting, ❌ failed (with the error). Connections,
reconnections, renewals, failures (the first of a streak and every tenth),
dropped messages and publish failures are logged like cloud sync's
messages ("Presence: live sync …"), with any URL's query cut out
(`LiveSync.redact`): a connection error can quote the presigned URL, whose
query holds the session token.

## Code

- [lib/cloud/live_sync.dart](../presence_app/lib/cloud/live_sync.dart):
  `LiveSync`, `LiveConnection` (the transport), `LiveLink`, `LiveEvent`,
  `parse` and `metadataOf`.
- [lib/cloud/live_mqtt.dart](../presence_app/lib/cloud/live_mqtt.dart):
  `MqttLiveConnection`, on the `mqtt_client` package (pinned at 10.11.11):
  `MqttServerClient` with WebSockets on Android, iOS and desktop,
  `MqttBrowserClient` on the web (a conditional import), MQTT 3.1.1,
  subprotocol `mqtt`, keep-alive 60 s, clean session, one attempt per
  connection (`LiveSync` retries).
- [lib/cloud/sigv4.dart](../presence_app/lib/cloud/sigv4.dart):
  `presignWebSocket`.
- `CloudSync` (`live`, `_startLive`, `_onLive`, `_fetchWanted`) and
  `CloudConfig.iotEndpoint` / `liveStage`.

## Verified

- `live_sync_test.dart`, with a fake broker and connections:
  - the presigned URL matches an independent implementation of AWS's
    sample (Python `hashlib`/`hmac`) for fixed credentials and time;
  - messages parse; inline media is stripped on receipt and never
    published; malformed, foreign, other-version and oversized messages
    are dropped;
  - off without an endpoint (nothing connects, nothing is published);
    connects with a signed URL, a client ID starting with the identity, to
    the events topic; publishes an event's metadata; hands over other
    devices' events in order, not its own, nor other topics'; reconnects
    after a drop and backs off while refused (up to the maximum); renews
    before the credentials expire, once; stops for good;
  - with `CloudSync`: a saved event goes up, then is published without its
    frames (which are in the bucket), with the uploaded ETag; a received
    event is handed over at once and once, and is neither uploaded back
    nor downloaded again when the bucket lists it, nor echoed; a received
    clip event gets its clip and thumbnail (not its recording) from the
    bucket when its completion arrives; a change here not uploaded yet
    wins; signing out disconnects; without an endpoint, events still go
    up through the bucket.
- `persistence_test.dart`, at app level: an event another device publishes
  shows in the Events tab at once, as recording on another device, with an
  inline thumbnail dropped; when its completion arrives, the event shows
  with its clip and thumbnail from the bucket.
- `ProfileTest` / `ProfileBackendTest` (auth API): credentials attach the
  live-sync policy to the identity (`AttachPolicy` with the policy name
  and the identity ID), once per function instance, retried after a
  failure that doesn't fail the credentials; nothing without a policy.
- `sam validate --lint` and `aws cloudformation validate-template` pass
  for the templates; `aws iot describe-endpoint` answers in the
  `<id>-ats.iot.us-east-1.amazonaws.com` form the deploy script checks.

## Known limitations

- **Not yet verified against AWS:** a real connection with a profile's
  Cognito credentials (the presigned URL, the client ID and topic
  policies, `AttachPolicy` from the auth API's role, and the
  `mqtt_client` transports on Android, desktop and the web). That needs a
  deploy with the updated `github-deploy.yaml`.
- A device whose clip is recording shows "Recording on another device…"
  until the clip completes there; one that misses the completion message
  gets the clip at the next listing that sees the event changed (within
  15 s for today's and yesterday's events). After a restart before the
  clip arrives, the event shows as a clip whose recording is missing
  until the clip comes down, and then with it.
- Out-of-order or repeated deliveries (QoS 1) are taken as they come: a
  repeated message changes nothing, but an older version arriving after a
  newer one would be taken on until the next change.
- Each Capture all request now reaches the other devices within a second,
  so they answer sooner; nothing else about answering changes.
- No acknowledgements, deletion or start-up requests yet (phase 2).
