# Streamer leadership

A profile can have several [streamers](streamer.md) (Raspberry Pis running
`presence-streamer`), but **at most one streams to the cloud at a time:
the leader**. The others wait, recording nothing, until they're granted
the leadership. When the leader dies (offline for more than an hour) or is
deleted, a waiting streamer takes its place.

## Who leads

The auth API decides, and keeps the leader on the profile's item in the
profiles table (`streamLeader`, the device ID, and `streamLeaderSeenAt`,
when it was last heard from, epoch ms):

- **A streamer is granted the leadership** when it asks (its credentials,
  or a lease, below) and the profile has **no leader**, it **leads
  already**, or the leader has been **silent for more than an hour**
  (`ProfileHandler.LEADER_SILENCE`). Asking while it leads renews it (seen
  now). The grant is one conditional write (`Profiles.Store.claimLeader`),
  so two streamers taking over a silent leader at once can't both win.
- **Only a device of the profile within the plan's device limit** can lead
  ([Plans](premium.md#devices)): a streamer past it gets the same 403 as
  its credentials, so it can't hold the place without streaming.
- **Deleting the leader** in the app (`POST
  /api/auth/profile/devices/remove`) drops its leadership with its stream
  key: the next streamer to ask leads at once. Deleting the profile drops
  it with the profile.
- **Phones and other apps never lead**: `POST /api/auth/credentials` reads
  the leader but never claims it.

## The routes

- **`POST /api/auth/stream/credentials`** (the stream key): as before,
  but only the leader gets credentials. Asking claims the leadership; when
  another streamer leads, the answer is **409**, `{"error", "reason":
  "notLeader", "streamLeader": {"device", "seenAt"}}`, with no token. The
  streamer still joins the profile's devices first.
- **`POST /api/auth/stream/lease`** (the stream key, no authorizer; the
  body `<profile ID> <device ID>`, as the credentials'): asks for or renews
  the leadership. Always 200 once the key checks out:
  `{"leader": true|false, "streamLeader": {"device", "seenAt"},
  "silenceMs": 3600000}`. Throttled to 2 requests/s (burst 10).
- **`POST /api/auth/profile/stream-lease`** (a session token; the body the
  device ID): the same for a streamer signed in with Google. The caller
  must be premium (or pro).
- **`streamLeader`** is also in `POST /api/auth/credentials`' answer (and
  the stream credentials', and `devices/remove`'s), next to `devices`, so
  the app knows the leader. It's left out when the profile has none.

## On the streamer

- **Standby until it leads.** After setup checks its key (or Google
  sign-in), `lead` asks for the lease (`waitToLead`) **every 5 minutes**
  (`leaseEvery`), saying who leads once ("waiting: brave_little_lamp leads
  this profile's streamers…"), and only then gets its credentials and
  starts the camera, the uploads and its [Blink cameras](blink.md). Waiting,
  it records and uploads nothing. A network error is retried after 5 s,
  doubling to 5 minutes.
- **Leading, it renews the lease every 5 minutes** (`keepLease`). It stops
  streaming (the recorder, the pipelines and Blink stop; the spool stays)
  and waits again when:
  - the lease says another leads (it was silent past the hour, and was
    replaced);
  - its credentials or an upload get the 409 (`session.Standby`);
  - it couldn't renew the lease for 55 minutes (`session.ErrLeaseLapsed`),
    before a waiting streamer could take over at the hour, so two never
    stream at once.
- **Setup** with a key while another leads still succeeds (the key is
  good): "Ready: device … of profile … waits: another streamer, …, leads
  this profile. It streams once it leads…". The service starts and waits.
- **Restarts** (an upgrade, a reboot) keep the leadership: the leader asks
  again within the hour and is still the leader.
- Signed in with Google, the streamer leases the same way (`POST
  /api/auth/profile/stream-lease`); see the limitation below.

## In the app

The profile view's device list (the account sheet, [Sign-in](sign-in.md))
labels the leader **"leader"** (`profile-device-leader-<id>`, in the
accent color) under its ID, beside "this device" and "hidden", with a
tooltip: "The profile's leading streamer: the only one that streams to the
cloud. The others wait, and one takes its place when it's been offline for
an hour." The leader comes from the credentials answer
(`DeviceSlots.leader`). English, Spanish and Portuguese.

[Blink cameras](blink.md)' streamer list puts the leader first.

## Tests

- Auth API (`ProfileTest`): the first streamer to ask leads and the second
  gets the 409 with no token (still a device of the profile); the lease
  says the same to each; phones' credentials name the leader and never
  take it; a lease needs the device's key; a leader silent for exactly an
  hour still leads, one second more and the waiting streamer takes over
  and the old one, back, waits; deleting a waiting streamer leaves the
  leader, deleting the leader frees the place at once; a Google-signed-in
  streamer leases with its session (not before it's a device of the
  profile, not when free).
- Streamer (`go test ./...`): the 409 read as `NotLeaderError` with the
  leader, standby and not an exit; the lease with a key and with a Google
  sign-in; `waitToLead` asks until the leader's gone, saying who leads
  once, and stops with its context; `keepLease` stops streaming when
  another leads and when the lease lapses.
- App (`stream_leader_test.dart`): the leader read from the answer (and
  none from a missing or malformed one); the device list labels it, with
  its tooltip; Blink's streamers, the leader first.

## Known limitations

- **Takeover takes up to 65 minutes**: an hour of silence, then the
  waiting streamers' next ask (every 5 minutes). Deleting the dead leader
  in the app frees its place within 5 minutes.
- **The app's label can be an hour old**: the leader comes with the
  credentials, which the app renews hourly (and when a device is deleted).
- **A Google-signed-in streamer's credentials aren't gated** (`POST
  /api/auth/credentials` is the phones' too): it keeps to the leadership
  itself, through its lease.
- **No way to pick the leader** in the app; the first streamer to ask
  leads. Deleting the leader makes way for the others.
- **Blink's login stays on the streamer that logged in.** When another
  streamer takes the lead, connect Blink again (it's the first in Blink's
  list).
- A standby streamer doesn't record: the time before a takeover isn't
  kept by anyone.
