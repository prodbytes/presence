# Device presence

Which of the profile's devices are running right now: a colored dot next
to each device in the Camera tab's [All grid](camera.md#all-devices) and
in the account sheet's [devices list](sign-in.md). Devices ping each other
over [live sync](live-sync.md) (MQTT, AWS IoT Core) on the profile's
reserved `requests` and `acks` topics.

## The dot

`DevicePresence.of` ([lib/device_presence.dart](../presence_app/lib/device_presence.dart)),
drawn by `PresenceDot` (10 dp, Gruvbox colors):

- 🟢 **Green, live:** the device answered a ping within the last **90 s**
  (`DevicePresence.liveWithin`: three rounds of the 30 s pings). Reason
  "Live — answered 5 s ago".
- 🟡 **Yellow, recently known:** heard from (a ping or pong, older), or
  its latest synced event, within **24 h** (`DevicePresence.recentWithin`).
  Reason "Last seen 3 h ago".
- 🔴 **Red, old:** last heard from or last event 24 h ago or more, or
  never. Reason "Last seen 4 d ago" or "Never seen".
- **This device** is green while connected to live sync ("Live — this
  device, connected to live sync"); otherwise yellow ("This device — not
  connected to live sync now", or "… — live status unavailable").
- **Without live sync** (no `IOT_ENDPOINT`, Never, signed out, no cloud
  sync): nothing can answer, so nothing is green: yellow or red from the
  latest event, the reason ending "· live status unavailable".
- The reason is the dot's tooltip and its screen-reader label
  (`Semantics`). Ages read "5 s ago", "4 min ago", "3 h ago", "2 d ago"
  (`describeSince`).
- **In the All grid** the dot leads each cell's label ("● brave_fox ·
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
  open (`PresencePinger`). Nothing pings otherwise.
- **Answering:** a device that receives another device's ping answers on
  `acks` with `{"v":1,"kind":"pong",…,"nonce":"<the ping's>"}`; at most
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

### Validation

`LiveSync.parsePresence` drops a presence message over **1 KB**, not JSON,
not version 1, whose `kind` doesn't match its topic (`ping` on
`requests`, `pong` on `acks`), of another identity, with a `deviceId`
outside `[A-Za-z0-9_.:-]{1,128}` or containing `..`, without an integer
`sentAt`, with a `nonce` outside `[A-Za-z0-9]{8,64}`, or a ping without a
nonce. Each dropped one is logged ("Presence: live sync dropped a
malformed presence message").

## Permissions

Nothing new: the identity role's `own-live-sync` statements and the IoT
policy `presence-live-sync` already allow `iot:Publish`/`iot:Receive` on
`topic/presence/<Stage>/<identity>/*` and `iot:Subscribe` on
`topicfilter/presence/<Stage>/<identity>/*`, which cover `requests` and
`acks`. A profile still reaches only its own topics.

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

## Known limitations

- Not yet verified against AWS IoT (the fake broker stands in, as for the
  rest of live sync).
- Green needs both devices on live sync; a device on a long schedule
  (say every 30 min) answers late, so it shows yellow most of the time.
- A device whose clock runs far behind shows older than it is when heard
  from outside an answer to this device's ping.
