# Live sync

The devices of a [profile](profiles.md) tell each other about **new and
changed events within about a second**, over **MQTT** (AWS IoT Core, MQTT
3.1.1 over WebSockets), instead of waiting for the next 15 s listing of the
bucket. [Cloud sync](cloud-sync.md) still does everything it did: **S3 stays
where events and all their media are kept**, and a device that misses a
message gets the event from the bucket as before. Nothing is deleted.

This is phase 1, plus **copy acknowledgements**: a device that has stored
a full copy of another device's event (with its media) says so with a
`copied` ack on the `acks` topic, and every device counts each event's
copies ([Event copies](event-copies.md)). Phase 2 (planned, not built)
deletes an event's S3 record once three devices acknowledged it, and asks
the online devices for events at start.

## What a device does

`LiveSync` ([lib/cloud/live_sync.dart](../presence_app/lib/cloud/live_sync.dart)),
owned by `CloudSync`:

- **Connects**, as the **Connect to live sync** setting says (see
  **When it connects**), once a cloud sync pass has a session (signed in,
  with a profile and `presence_user`), with the profile's Cognito
  credentials (the
  same ones S3 uses, from `CloudSession.credentials`), to
  `wss://<IOT_ENDPOINT>/mqtt`, presigned with AWS Signature Version 4
  (`SigV4Signer.presignWebSocket`, service `iotdevicegateway`, only `host`
  signed, valid 1 h; the session token is appended after signing, as AWS IoT
  requires). It's signed at AWS's time as best known (`AwsClock.shared`,
  corrected when S3 finds the device's clock off; see [Cloud
  sync](cloud-sync.md#how)), and the renewal below is timed by it too.
  - **Client ID**: the identity first, which the IoT policy requires, then
    the [device ID](devices-users-places.md). Always connected,
    `<identityId>-<deviceId>-<session>`, with six random characters per
    app run, so two tabs of one browser (one device ID) don't take each
    other's connection. On a schedule, `<identityId>-<deviceId>`, stable,
    so AWS IoT finds the device's persistent session again (see below).
  - **Subscribes** to the profile's events topic (QoS 1), listening before
    the subscription is acknowledged: a persistent session's queued
    messages may come first; then to its `requests` and `acks` topics for
    [device presence](device-presence.md) (a refusal there is logged and
    doesn't drop the connection).
  - **Reconnects** (always connected) after a drop at once (1 s), closing
    the dropped connection first (its socket and timers go), and after a refused
    connection with a back-off that doubles up to 2 min; each attempt asks
    for credentials again and signs a new URL. Getting the credentials and
    connecting may each take **15 s** (`LiveSync.connectTimeout`): an
    attempt that hangs (a stalled network) fails then, into the same
    back-off, and a connection that opens after its timeout is closed.
  - **Renews** the connection (new credentials, new URL) 2 min before the
    credentials expire (always connected; a scheduled connection is brief
    and signs a new URL each time).
  - **Disconnects** on sign-out, when the profile changes (a link or
    unlink: `CloudSync.reconnect`), when credentials can't be had (cloud
    sync stops), and when the app closes.
- **Publishes** each event a pass uploads, right after its `PUT` to the
  bucket succeeds (so the bucket already holds it, and its tagged frames,
  clip record and thumbnail, which go up first), at QoS 1. The pass
  uploads (and publishes) each event **as stored when its turn comes**,
  read again then, not as listed when the pass started: its clips'
  recordings go up first and take a while, and live sync may meanwhile
  have taken a newer version from another device (marked as synced, so
  it isn't uploaded at all). Only events
  from within the restore window (two weeks), not a reconciliation's old
  ones. Always connected, nothing while disconnected (the bucket carries
  it); on a schedule, between connections it **connects at once to send
  it** (waiting up to 20 s; then the bucket carries it); with Never,
  nothing is published.
- **Receives** the profile's other devices' events: a message from this
  device's own ID is ignored; anything malformed, too big or not for this
  identity is dropped (see **Validation**). Messages are handed to cloud
  sync one at a time, in order (`_LiveBridge._onLive`). One for an event a
  pass is uploading right now (its frames and JSON, `_Uploader.uploadOf`)
  waits for that upload, so the two can't cross: the pass never puts the
  older version back over the newer one. If the profile changes, the user
  signs out or sync stops while a message is being taken (its frames
  downloading), it's dropped: nothing is stored or marked as synced.
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
    (`_Fetcher.fetchWanted`). The clip stays **wanted** until it's here
    or the bucket is found not to have it: a fetch that fails (a network
    error) is tried again at the next pass, at most 5 times in a row, and
    doesn't fail the pass (rejected credentials do: the pass renews them).
    Wanting a clip again while a pass looks for it isn't undone by that
    pass. Each full fetch (the first pass after a sign-in or a restart,
    then hourly) wants again the clips of the profile's events in the
    window that the device has no record of (the newest 100;
    `_rewantClips`), so a clip that hadn't come when the app closed, or
    whose fetches all failed, still comes. While the clip is still
    recording on the other device, there's none yet; when it completes
    there, its recording,
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
  - **Once it's copied** (the event, its frames, and its clip with the
    recording), the device acks it: a `copied` message on `acks`, batched
    (see [Event copies](event-copies.md)).

## When it connects

The **Connect to live sync** setting ([Settings](settings.md), stored per
device as `live: {mode, everyMs}`, see [Configuration](configuration.md))
picks one of nine steps: **Never**, every **1, 2, 5, 10, 15, 30 or
60 min**, or **Always**. The default is **every minute**. A change applies
at once: the connection starts over in the new mode (`LiveSync.config`,
set by the app from the setting at start, when it's restored, and on every
change).

- **Always**: stays connected, reconnecting and renewing as above, with a
  clean session.
- **Never**: never connects, and publishes nothing; events reach and leave
  the device through the bucket (within 15 s). The health check shows ⚪
  off.
- **Every N minutes** (scheduled): connects with an MQTT **persistent
  session** (cleanSession off) and the stable client ID
  `<identityId>-<deviceId>`, subscribes at QoS 1, and so takes what AWS
  IoT kept for it while it was away. It stays while messages come or go,
  until **3 s pass without any** (at most **30 s**), then disconnects
  (**idle**) until the next connection.
  - **The wait** between connections is the interval plus a **random 0 to
    10 s**, picked anew each time (so 60–70 s for 1 min), so devices don't
    all connect in step (`LiveSync.nextWait`; the `Random` is injectable,
    and tests seed it). AWS IoT keeps a persistent session for **1 h**
    after the device disconnects (the account default): every step fits,
    and the 60 min step waits 59 min plus the jitter so the session is
    still there.
  - **A new event of this device** connects at once to send it (and
    anything else waiting), then drains and disconnects again, so the
    other devices still hear of it within a second. The schedule restarts
    from that connection.
  - A refused connection backs off as when always connected (1 s,
    doubling, up to 2 min); a scheduled connection dropped early (another
    tab connected with the same ID) just ends it: the session is kept.
  - **Two tabs of one browser** share the device ID and so this client
    ID: AWS IoT drops the older connection when the other connects. As the
    connections are brief, that rarely happens and only ends one early;
    the tab that connects takes the queued messages, and the other gets
    those events from the bucket. That's the trade-off for a session the
    broker can find again; always connected keeps the per-run suffix.
  - **The IoT policy** needs nothing more: `iot:Connect` on
    `client/<identityId>-*` matches both client IDs, and persistent
    sessions need only connect, subscribe and receive.

## Topics and messages

- **Topics**, per profile and stage: `presence/<stage>/<identityId>/<kind>`,
  where `<stage>` is `prod` or `rc` (the build's `PRESENCE_STAGE`; any
  other build is `prod`, as local builds use production's pool) and
  `<identityId>` the profile's Cognito identity (its folder in the
  bucket). Events go on `events`; `requests` and `acks` carry [device
  presence](device-presence.md)'s pings and pongs (small messages of
  their own, validated by `LiveSync.parsePresence`), and `acks` also the
  `copied` acks of [event copies](event-copies.md) (`parseCopied`, at
  most 1 KB and 32 event IDs each). The policies allow
  `presence/<stage>/<identityId>/*`, which covers all three.
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
    the bucket as uploaded (phase 2's deletion will refer to them),
    `event` the event record as uploaded.
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
  `iot:DescribeEndpoint`. An administrator updates that stack by hand (see
  [presence_infra/README.md](../presence_infra/README.md)); it was updated
  on 2026-10-06, and `0.6.202610061801` deployed live sync to prod and RC.

## Off

Live sync is off, and everything syncs through the bucket as before, when
the build has no `IOT_ENDPOINT` (local Floci, tests, a `.env` without it),
when cloud sync is off, and while signed out.

## Status

The health line and the Log tab's health panel have a fourth check,
**📡 Live** ([Settings](settings.md), [Log](log.md)): ⚪ not set (no
endpoint) or off (Never), ✅ connected (with the events received and sent)
or set and waiting for the first sync, ⏳ connecting, 💤 **idle** between
scheduled connections ("Idle · next in 0:42 (every 1 min; …)", the panel's
card counting down each second), ❌ failed (with the error). The account
sheet's **connectivity** row ([Sign-in](sign-in.md)) sums it up for this
device with the API and cloud sync: green only while connected, amber
when connecting, idle ("Live sync idle · next in 0:42"), off, or not set
("Live sync isn't set up in this build"), red when failed. "Sent"
(`LiveSync.sent`) counts events handed to the connection to publish at
QoS 1, not the broker's acknowledgements (PUBACK), which aren't waited
for: one sent just before a drop may not have arrived (the bucket still
has it). Only ❌ is a
failure: idle and off don't turn a run of the timeline red. Connections,
reconnections, renewals, failures (the first of a streak and every tenth),
dropped messages and publish failures are logged like cloud sync's
messages ("Presence: live sync …"), with any URL's query cut out
(`LiveSync.redact`): a connection error can quote the presigned URL, whose
query holds the session token.

## Code

- [lib/cloud/live_sync.dart](../presence_app/lib/cloud/live_sync.dart):
  `LiveSync`, `LiveConnection` (the transport), `LiveLink`, `LiveEvent`,
  `parse` and `metadataOf`; `ackCopied`, `parseCopied` and
  `CopiedMessage` ([Event copies](event-copies.md)). The connection loop
  (`_loop`) connects (`_connectOnce`), subscribes (`_subscribe`), then
  runs a scheduled connection (`_runScheduled`) or an always-on one
  (`_runAlways`).
- [lib/cloud/live_mqtt.dart](../presence_app/lib/cloud/live_mqtt.dart):
  `MqttLiveConnection`, on the `mqtt_client` package (pinned at 10.11.11):
  `MqttServerClient` with WebSockets on Android, iOS and desktop,
  `MqttBrowserClient` on the web (a conditional import), MQTT 3.1.1,
  subprotocol `mqtt`, keep-alive 60 s, a clean session or a persistent one
  (`persistent`), one attempt per connection (`LiveSync` retries).
  Received messages are buffered until listened to.
- [lib/config.dart](../presence_app/lib/config.dart): `LiveConfig`
  (`LiveMode`, the steps).
- [lib/cloud/sigv4.dart](../presence_app/lib/cloud/sigv4.dart):
  `presignWebSocket`.
- `CloudSync` (`live`), with `_LiveBridge` (`start`, `_onLive`) in
  [cloud_sync_live.dart](../presence_app/lib/cloud/cloud_sync_live.dart),
  `_Uploader.uploadOf` in
  [cloud_sync_upload.dart](../presence_app/lib/cloud/cloud_sync_upload.dart)
  and `_Fetcher` (`fetchWanted`, `rewantClips`) in
  [cloud_sync_fetch.dart](../presence_app/lib/cloud/cloud_sync_fetch.dart), and
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
    the events topic (and the presence topics, `requests` and `acks`;
    their pings and pongs are in `device_presence_test.dart`); publishes an event's metadata; hands over other
    devices' events in order, not its own, nor other topics'; reconnects
    after a drop (closing the dropped connection) and backs off while
    refused (up to the maximum); renews
    before the credentials expire, once; stops for good; a hung
    credentials request, then a hung connection, each time out into the
    back-off;
  - the setting: Never connects and publishes nothing; on a schedule, a
    persistent session with the stable client ID, disconnected once quiet
    and connected again on time; it stays while queued messages come, at
    most its maximum; a new event between connections connects at once to
    send it, then disconnects; the waits are the interval plus a new
    random jitter, within `[interval, interval + 10 s]`, the same for the
    same seed, and the 60 min step within the session's hour; a change of
    the setting applies at once (Always keeps a clean session and stays);
  - with `CloudSync`: a saved event goes up, then is published without its
    frames (which are in the bucket), with the uploaded ETag; a received
    event is handed over at once and once, and is neither uploaded back
    nor downloaded again when the bucket lists it, nor echoed; a received
    clip event gets its clip and thumbnail (not its recording) from the
    bucket when its completion arrives; a change here not uploaded yet
    wins; an update received while a pass uploads the event's recording
    isn't put back (nor published) by the pass; an event received while
    signing out (its frame still downloading) isn't taken; a wanted clip
    whose fetch fails comes at the next pass; after a restart, the first
    pass fetches the clip of an event whose clip never came; signing out
    disconnects; without an endpoint, events still go up through the
    bucket.
- `event_copies_test.dart`: `copied` acks (validation, batching, own
  ignored, repeats deduped) and the whole flow between two devices over
  an in-memory broker: a capture is uploaded, published, copied with its
  clip and recording by the other device, which acks it, and the count
  goes up on the first (see [Event copies](event-copies.md)).
- `system_health_test.dart`: the Live check is ⚪ without live sync or with
  Never, 💤 idle with its countdown between scheduled connections, ✅
  connected, ❌ failed; only ❌ fails a run.
- `config_test.dart`, `settings_test.dart`: the setting's steps, default,
  storage round-trip and backward compatibility; the slider from Never to
  Always, shown only with live sync.
- `persistence_test.dart`, at app level: the app gives live sync the
  setting (every minute and a persistent session by default); an event another device publishes
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

- Scheduled connections are tested with a fake broker and short
  intervals, not yet against AWS IoT's persistent sessions; a session
  expiry other than the 1 h default would change which intervals keep
  their queue (the bucket still carries everything).

- The automated tests use a fake broker. Live sync has been deployed to
  prod and RC since `0.6.202610061801` (2026-10-06, with the updated
  `github-deploy.yaml`, see **Infrastructure**); its real connections
  (the presigned URL, client ID and topic policies, `AttachPolicy` from
  the auth API's role, the `mqtt_client` transports on Android, desktop
  and the web) are checked by hand on the deployed apps, not by a test.
- A device whose clip is recording shows "Recording on another device…"
  until the clip completes there; one that misses the completion message
  gets the clip at the next listing that sees the event changed (within
  15 s for today's and yesterday's events). After a restart before the
  clip arrives, the event shows as a clip whose recording is missing
  until the first pass fetches the clip (`_rewantClips`), and then with
  it.
- The **sent** count doesn't wait for the broker's acknowledgement, so it
  can count a message that a drop lost (the bucket still carries it).
- Out-of-order or repeated deliveries (QoS 1) are taken as they come: a
  repeated message changes nothing, but an older version arriving after a
  newer one would be taken on until the next change.
- Each Capture all request (Clip in the All grid, or opening the grid,
  see [Camera screen](camera.md#capture-all)) reaches the other devices
  within a second as an ordinary event, so they answer sooner; one that
  then also comes from the bucket isn't answered again. It doesn't use
  the `requests` topic, which carries only presence pings.
- No deletion or start-up requests yet (phase 2); `requests` carries
  only presence pings, `acks` presence pongs and `copied` acks.
