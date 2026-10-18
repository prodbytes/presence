# Device presence

Which of the profile's devices are running right now: a colored dot next
to each device in the Camera tab's [All grid](camera.md#all-devices) and
in the account sheet's [devices list](sign-in.md). Premium devices ping
each other over [live sync](live-sync.md) (MQTT, AWS IoT Core) on the
profile's reserved `requests` and `acks` topics; free devices send a
small retained heartbeat instead ([below](#free-devices-heartbeat)).

## The dot

`DevicePresence.of` ([lib/device_presence.dart](../presence_app/lib/device_presence.dart)),
drawn by `PresenceDot` (10 dp, Gruvbox colors):

- 🟢 **Green, live:** the device answered a ping within the last **90 s**
  (`DevicePresence.liveWithin`: three rounds of the 30 s pings); for a
  free profile, its last heartbeat is within **11 min**
  (`LiveSync.beatLiveWithin`: two 5-min beats and a minute; the callers
  pass `LiveSync.liveWithin` as `within`). Reason "Live — answered 5 s
  ago".
- 🟡 **Yellow, recently known:** heard from (a ping or pong, older), or
  its latest synced event, within **24 h** (`DevicePresence.recentWithin`).
  Reason "Last seen 3 h ago".
- 🔴 **Red, old:** last heard from or last event 24 h ago or more, or
  never. Reason "Last seen 4 d ago" or "Never seen".
- **This device** is green while connected to live sync, or (free) while
  its last heartbeat went within 11 min (`LiveSync.showsLive`) ("Live —
  this device, connected to live sync"); otherwise yellow ("This device — not
  connected to live sync now", or "… — live status unavailable"). In the
  account sheet's devices list it follows the sheet's
  [connectivity](sign-in.md) row instead (`Connectivity.presence`, passed
  as `ProfileDevices.thisPresence`): green only when the auth API answers,
  cloud sync is set and live sync is connected; yellow when degraded
  (connecting, idle, live sync not set up or off); red when the API,
  cloud sync or live sync failed; the reason is the row's headline ("This
  device — Live sync isn't set up in this build").
- **Without live sync** (no `IOT_ENDPOINT`, Never, signed out, no cloud
  sync): nothing can answer, so nothing is green: yellow or red from the
  latest event, the reason ending "· live status unavailable".
- The reason is the dot's tooltip and its screen-reader label
  (`Semantics`). Ages read "5 s ago", "4 min ago", "3 h ago", "2 d ago"
  (`describeSince`).
- **In the All grid** the cells are ordered by it: live devices first,
  then the most recently active (see [All devices](camera.md#all-devices)).
  The dot leads each cell's label ("● brave_fox ·
  5 min ago", "● <this device> · live"); the label's text still lets taps
  through to the cell's clip, the dot takes them for its tooltip. **In the
  devices list** it sits before the device ID, on the ID's line (which
  wraps at 320 dp with a 2x font). Both fit a 320 dp phone.
- **A deleted device** ([Device deletion](device-deletion.md)) has no
  dot: the list and the grid show only devices with events, and its last
  ping or pong is forgotten (`LiveSync.forget`). It shows again only once
  it posts new events.

## Pings and pongs

`LiveSync` ([lib/cloud/live_sync.dart](../presence_app/lib/cloud/live_sync.dart)):

- **Subscribes** to `presence/<stage>/<identityId>/requests` and `/acks`
  besides `events`, on every connection (always or scheduled). A refused
  presence subscription is logged and leaves the connection up (events
  still flow; presence just isn't known).
- **`ping()`** publishes on `requests`:
  `{"v":1,"kind":"ping","deviceId":…,"identityId":…,"sentAt":<ms>,"nonce":"<16 random [a-z0-9]>"}`.
  At most one every **25 s** (`LiveSync.pingEvery`). Sent at once when
  connected; on a schedule it connects to send it (like an event, waiting
  up to 20 s); nothing while an always-on connection is down, with Never,
  or signed out.
- **Who pings:** the All grid when it shows (entering All, or coming back
  to the Camera tab with it on) and every 30 s while it does and the
  Camera tab is on screen (`CameraFeedsView.live` / `active`); the
  account sheet's devices list when it opens and every 30 s while it's
  open (`PresencePinger`; given another live sync or interval while it
  shows, it pings that at once and keeps its interval from then on).
  Nothing pings otherwise.
- **Answering:** a device that receives another device's ping answers on
  `acks` (a [streamer](streamer.md#live-sync) too, while it leads its
  profile) with `{"v":1,"kind":"pong",…,"nonce":"<the ping's>"}`; at most
  one pong every **5 s** (`answerEvery`: pings from several devices at
  once get one answer, heard by all, as `acks` is shared), and none to a
  ping older than **2 min** by its `sentAt` (`pingFresh`: one a
  persistent session kept while the device was away).
- **Recording** (`seenOf(deviceId)`): a pong answering one of this
  device's pings from the last 2 min (`pingsKept`) counts as **now**,
  whatever the sender's clock says; any other ping or pong counts at its
  `sentAt`, never later than now (so one a persistent session kept shows
  as old, not live). The latest time per device, at most 64 devices,
  cleared when the profile (identity) changes. Not counted in live sync's
  events sent/received.
- **Own messages** (this device's ID, or another tab's on it) are
  ignored: not answered, not recorded.
- **No heartbeat on connect:** a device is only heard from when someone
  pings, or when it pings itself. A device on a schedule answers the
  pings its persistent session kept at its next connection (within its
  interval plus 10 s), so at every 1 min it can still show green.

### Free devices: heartbeat

A free profile's devices connect to live sync only every 15 min
([Live sync](live-sync.md#free)), so nobody is there to answer a ping.
Instead (`LiveSync.beat`, only with `LiveConfig.free`):

- **Each free device beats every 5 min** (`beatEvery`; the first 5 s
  after live sync starts, to ride the start's connection): a **retained**
  message on its own topic `presence/<stage>/<identityId>/beats/<deviceId>`,
  `{"v":1,"kind":"beat","deviceId","identityId","sentAt"}`, about 150
  bytes (one billed 5 KB unit). It goes over the scheduled or watching
  connection when one is open; otherwise over a connection made just for
  it: a **clean session** as `<identityId>-<deviceId>-b`, subscribed to
  nothing (so it takes no queued events and shares none), closed a second
  after. Separate from event sharing, which stays at start, sign-in and
  every 15 min.
- **Watching, only while someone looks:** for a free device, `ping()`
  (the All grid and the devices list call it when they show and every
  30 s) opens a watching connection instead, a clean session as
  `<identityId>-<deviceId>-w` subscribed to `beats/+` alone, kept until
  **75 s** after the last ping (`watchFor`), then closed. AWS IoT sends
  each device's retained last beat as it subscribes, so the dots are
  right at once, and new beats as they come. Never on the persistent
  session, which would keep every beat for the device while it's away
  (deliveries grow with devices²).
- **Recording:** a beat counts at its `sentAt` (never later than now) in
  `seenOf`, as a ping or pong does. One whose topic isn't its own device
  ID, of another identity, or malformed (as below, kind `beat`) is
  dropped; this device's own is ignored.
- **Retained, not plain** (checked against AWS IoT's pricing: a retained
  publish bills twice, as a PUBLISH and as a RETAINED; deliveries,
  CONNECT and SUBSCRIBE bill as messages too): a plain beat would be 2
  units per beat instead of 3, but a viewer opening the grid would see no
  beat for up to 5 min. With retained beats the dots are right as soon
  as the grid or list opens, for ~$0.009 more per device and month.
- **Cost, per free device and month:** 8,640 beats × 3 units (CONNECT,
  PUBLISH, RETAINED) ≈ 25,900 messages ≈ **$0.026**, plus 8,640
  connection-minutes ≈ $0.0007. **10 free devices ≈ $0.27 a month.**
  Watching adds, per viewer, one delivery per device per beat (≈ 12 an
  hour each) only while the grid or list is open.

## Validation

`LiveSync.parsePresence` drops a presence message over **1 KB**, not JSON,
not version 1, whose `kind` doesn't match its topic (`ping` on
`requests`, `pong` on `acks`), of another identity, with a `deviceId`
outside `[A-Za-z0-9_.:-]{1,128}` or containing `..`, without an integer
`sentAt`, with a `nonce` outside `[A-Za-z0-9]{8,64}`, or a ping without a
nonce. Each dropped one is logged ("Presence: live sync dropped a
malformed presence message").

`acks` also carries [event copies](event-copies.md)' `copied` acks
(`LiveSync.parseCopied`, checked first); a valid one counts as hearing
from its sender too (at its `sentAt`, never later than now).

## Permissions

The identity role's `own-live-sync` statements and the IoT policy
`presence-live-sync` allow `iot:Publish`/`iot:Receive` on
`topic/presence/<Stage>/<identity>/*` and `iot:Subscribe` on
`topicfilter/presence/<Stage>/<identity>/*`, which cover `requests`,
`acks` and `beats/<device>` (and the `beats/+` filter). A retained
publish also needs **`iot:RetainPublish`**, granted only on
`topic/presence/<Stage>/<identity>/beats/*` in both. A profile still
reaches only its own topics; client IDs `<identity>-<device>-b` and
`-w` match `client/<identity>-*`.

## Verified

`device_presence_test.dart`:

- with a fake broker: a ping goes out on `requests` with a nonce, and a
  pong answering it makes its sender live now even with its clock an hour
  behind; pings at most every 25 s; none disconnected or off; another
  device's ping is answered on `acks` with its nonce and its sender seen
  at its `sentAt`; own pings neither answered nor seen; two pings at once
  get one pong; a 3-min-old ping is seen then, not answered; a pong dated
  in the future counts as now; invalid messages (no or bad nonce, other
  identity, other version, wrong kind for the topic, unsafe device ID,
  no `sentAt`, not JSON, over 1 KB) are dropped;
- the thresholds: green under 90 s, yellow under 24 h (the newer of answer
  and event), red at 24 h or never; never green without live sync, which
  the reason says; this device green while connected;
- the All grid at 320 dp: this device and an answering device green, one
  with a 2 h old event yellow, a 3 d old one red, with tooltips and
  semantics; it pings when shown and again 30 s later;
- the devices list at 320 dp: green, green and red, with tooltips, and a
  ping when it shows; without live sync, yellow from events and "live
  status unavailable".

Free (`live_sync_test.dart`, "free (LiveConfig.free)"): a beat is
retained on the device's own beats topic, over a clean connection of its
own that subscribes to nothing and closes, under 512 bytes, and makes
this device show live for 11 min; beats start soon after live sync; a
ping watches `beats/+` on a clean `-w` connection, records another
device's beat at its `sentAt`, drops a beat on another device's topic or
of another identity and ignores its own, reuses the watch for more pings
and for its own beat, and closes it on stop; a premium device never
beats. `device_presence_test.dart`: a 9-min-old beat is green with the
free threshold, 12 min yellow.

## Known limitations

- Not yet verified against AWS IoT (the fake broker stands in, as for the
  rest of live sync), including retained messages on a wildcard
  subscription and `iot:RetainPublish`.
- A deleted free device's retained beat stays on its topic (it isn't
  cleared); it's ignored, as the list and grid show only devices with
  events.
- Green needs both devices on live sync; a device on a long schedule
  (say every 30 min) answers late, so it shows yellow most of the time.
- A device whose clock runs far behind shows older than it is when heard
  from outside an answer to this device's ping.
