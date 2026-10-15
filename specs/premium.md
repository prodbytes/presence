# Premium and free

A member (`presence_user`) is either **premium** or **free**. Premium
profiles sync with the cloud (S3) and over live sync, instantly, and up to
**50 devices** show each other's events. Free profiles cost almost nothing
in AWS ([Free in AWS](#free-in-aws)): each device keeps its events and
processes them itself, and the devices share them over [live
sync](live-sync.md) (MQTT) only **every 15 minutes**; only the profile's
**first 2 devices** show each other's events. The account sheet says which
the account is, and a free member [upgrades to Premium](upgrade.md) there:
a Stripe subscription on the web (US$20 a month, the first week free), an
App Store or Google Play subscription in the iOS and Android apps.
[rbacr](https://github.com/prodbytes/rbacr), the organisation's role manager,
decides who is premium, as it decides every role ([Auth API](auth-api.md)).

## Who is premium

- **rbacr's `presence` system** has the roles `free`, `premium` and `admin`
  (rbacr adds `admin` to every system). An email holding **`premium` or
  `admin`** there is premium. That includes holding it through a grant to
  its domain, a global grant, an implied role, or being an rbacr root. Its
  `free` role alone is a free member; no role at all, no member.
- **The app** asks rbacr itself (`GET /api/me`, with the user's
  [session token](sessions.md); see [Sign-in](sign-in.md)) and maps `premium` or `admin` to
  **`presence_premium`**, so it knows (`RolesService.isPremium`).
- **The auth API**, which enforces it, asks rbacr too (`Rbacr`,
  [presence_api_auth](../presence_api_auth/AuthFunction/src/main/java/presence/auth/Rbacr.java))
  with a root's API token, server-side, for the credentials' tier. It
  sends `POST /api/roles {"email"}`, with the email in the body and never
  the URL, and reads the `presence` system's roles from the answer, which
  it turns into `presence_premium` (`Roles.PREMIUM`).
- **Store subscriptions** (iOS, Android) become a grant of `premium` in
  rbacr too: the [payments API](payments-api.md#store-purchases) verifies
  each purchase with its store and grants the role to the buyer's email
  until the paid period ends (plus 2 days), with a root's token
  (`RbacrGrantToken`).
- **Only rbacr gives it**, and never for an unverified email. In
  [DEV](execution-mode.md) the anonymous user has every role, `presence_premium`
  included, but nothing syncs there.
- **A linked account** ([profiles](profiles.md)) shares its profile owner's
  premium, as it shares the owner's membership: the profile's cloud folder
  is one (the auth API answers it in `shared`, `GET /api/auth/profile`).
  It's also premium on its own when rbacr says so of its own email.
- **Fails closed.** If rbacr doesn't answer in time (2 s), refuses the
  token, or answers something that isn't an answer, the email has no
  roles at all, premium included. The auth API reuses answers for **60 s**
  per Lambda instance; errors are never reused. The app caches nothing. A
  grant or revocation in rbacr shows in the app at its next roles check,
  and in the credentials within about a minute.
  The credentials already issued last up to an hour.
- **Without a token** (`RbacrToken` empty), the auth API gives nobody a
  role: credentials are refused, and nothing is shared.
  `scripts/deploy.sh` refuses to deploy without `RBACR_TOKEN`.
- Who is premium on release day is rbacr's to say. On 2026-10-08 its
  `presence` system had a single grant, `admin` to `@nu01.com`, so only
  nu01.com accounts were premium. Everyone else becomes free until granted
  `premium` (or a voucher for it is redeemed) in rbacr.

## How it's enforced

The bucket enforces it, not just the app:

- `POST /api/auth/credentials` (see [Profiles](profiles.md)) gets the
  profile's OpenID token from Cognito with a **`tier` principal tag**:
  `premium` with `presence_premium`, `free` otherwise. The answer says so too:
  `{"identityId", "token", "tier"}`.
- Cognito puts the tag on the session of the credentials the app trades the
  token for. The authenticated role's trust policy allows `sts:TagSession`
  for that ([identity.yaml](../presence_infra/identity.yaml)).
- The role's S3 statements (`PutObject`, `GetObject` and `ListBucket` on
  the identity's own prefix) require **`aws:PrincipalTag/tier` =
  `premium`**. Free credentials reach nothing in the bucket. So do
  credentials from a Google sign-in straight to the pool, which the pool
  still accepts for `GetId` but which carry no tag.
- Live sync's permissions (the role's `own-live-sync` and the IoT policy
  the auth API attaches) don't look at the tier: every member has them.
- A link code's token (`POST /api/auth/profile/link-code`, which only links
  the profile to its identity) is tagged `free`.
- The deploy roles may now update a role's trust policy
  (`iam:UpdateAssumeRolePolicy`, [github-deploy.yaml](../presence_infra/github-deploy.yaml)).
  That stack is applied by hand, so it must be applied again before the
  first release with this change. `scripts/deploy.sh` deploys the identity
  stack (trust and S3 statements) before the auth API (which starts tagging
  tokens), so tagged tokens never meet a role that refuses them.

## What each syncs

| | Premium | Free |
|---|---|---|
| New and changed events reach the profile's other devices | within a second (live sync), and every 15 s from the bucket | new ones only, once, final, within about 15 min: the sender's next scheduled connection, then the receiver's (its persistent session keeps them meanwhile); changes after that never |
| A clip's record and thumbnail | from the bucket | in the live message (thumbnails up to 12 KB) |
| Recordings | from the bucket, when played | only on the device that made them |
| Tagged frames | from the bucket | only on the device that made them |
| History on a new device (two weeks) | from the bucket | none: only what's published after it connects |
| This device's settings | backed up, restored at sign-in | stay on the device |
| Recognition references | every device's tags | the tags this device has |
| [Cloud recognition](cloud-recognition.md) (DINOv2-L, trained on the profile's labels) | yes | no (the APIs answer 403) |
| Devices whose events show ([below](#devices)) | the first 50 | the first 2 |

- **Free sync** (`_LivePublisher`, [cloud_sync_free.dart](../presence_app/lib/cloud/cloud_sync_free.dart)):
  - A free profile's pass never touches the bucket, and publishes
    nothing. It gets credentials (cached until they expire, about an hour:
    only for live sync and the profile's device list) and starts live
    sync.
  - Live sync runs on a free schedule (`LiveConfig.free`, from
    `LiveConfig.effective(isPremium: false)`): it connects at start, at
    sign-in, then every 15 min (or 30 or 60, as set; never more often,
    never Always), and nothing else connects it but the Sync button (at
    most every 5 min) and the [heartbeat](device-presence.md#free-devices-heartbeat).
    A new event doesn't: it waits on the device.
  - Each scheduled connection, once up, publishes the profile's events
    saved here in the last 24 h that weren't published yet
    (`LiveLink.onShare`), then drains what the broker kept and closes.
  - Each event goes **once** (`live/<event id>` in the synced store), when
    it's final: no clip, or its clip complete (or failed); one whose clip
    has no record yet goes after 10 min. A change after it went isn't
    sent.
  - A message carries the event, plus the clip's record and thumbnail
    once the clip is complete (`LiveSync.clipMessageOf`). A free device
    leaves out a thumbnail over **12 KB** (`freeMaxThumbnailBytes`, so a
    message bills as a few 5 KB units), and the clip goes without it when
    it would pass the 64 KB message limit; the event goes alone when the
    clip itself doesn't fit.
  - Receiving devices store the clip as if fetched (`LiveEvent.clip`,
    `RemoteRecords.clips`). Its thumbnail must be a JPEG or PNG of at most
    48 KB, and the record must be the event's clip and complete; otherwise
    the clip is dropped and the event kept.
  - Nothing is marked as in the cloud, so if the profile becomes premium,
    its first pass uploads everything.
- **Premium devices put the clip in their live messages too.** An account
  can be premium while its profile's owner is free, so another device of
  that profile may have no bucket. Premium receivers still take clips
  from the bucket, as before.
- **A change of tier** (rbacr changed, and the roles were checked again)
  starts the sync over with new credentials (`CloudSync.reconnect`).
  Becoming premium uploads what's here; becoming free stops using the
  bucket. What a free profile had in the bucket stays until the bucket's
  lifecycle expires it (90 days), and is found again if it becomes premium.
- **Credentials from before the bucket required the tag** (the first hour
  after the release) are refused with `AccessDenied`. A pass takes that
  like expired credentials: it renews them once and tries again
  (`S3Exception.credentialsRejected`).
- Playing a free profile's clip that came from another device: its
  recording isn't here and can't be fetched (`CloudSync.fetchRecording`
  answers false at once).

## Free in AWS

A free member's devices use their own storage and compute (local events,
the on-device pipeline); the cloud does almost nothing for them:

- **No S3** (the role's bucket statements need the `premium` tag), **no
  cloud recognition** (403 before any write: `RecognitionApi`), **no
  ingest** (streamer chunks go to the bucket).
- **Live sync, every 15 min**: a scheduled connection (persistent
  session) shares what waited and takes what was kept.
- **A heartbeat every 5 min** ([Device presence](device-presence.md#free-devices-heartbeat)):
  a retained ~150-byte message on the device's own topic, over a
  connection made just for it.
- **The auth API**: credentials about hourly (to sign the MQTT
  connections), and the anonymous check every 15 min, mostly answered by
  the CDN ([Auth API](auth-api.md)).

AWS IoT Core bills $1 per million messages (5 KB units; CONNECT,
SUBSCRIBE, PUBLISH, a retained publish twice, each delivery) and $0.08 per
million connection-minutes (one-minute minimum). Per free device and
month, at 2 clips an hour:

| | Messages | Cost |
|---|---|---|
| Heartbeat (8,640: CONNECT + PUBLISH + RETAINED) | ~25,900 | ~$0.026 |
| Scheduled connections (2,880: CONNECT + 3 SUBSCRIBE) | ~11,500 | ~$0.012 |
| Events (1,440, ≤ 17 KB: 4 units out, 4 delivered to one other device) | ~11,500 | ~$0.012 |
| Connection-minutes (~11,500) | | ~$0.001 |
| Auth API (720 credentials, Lambda; 2,880 anonymous checks, mostly CDN) | | < $0.005 |

About **$0.05 per free device per month** (2 devices ≈ $0.10; before:
≈ $0.64 for 2, when every event published at once and connected on its
own). The heartbeat alone is ≈ $0.026 per device (10 free devices ≈
$0.26). Every free device more adds its events' deliveries to each other
device (devices²), so a profile is held to 2 devices that show.

## Devices

A profile's devices past its limit (2 free, 50 premium) **still sync**:
they publish, receive and store events as before. Their events are
**hidden**, and the user is asked to [upgrade to Premium](upgrade.md).

- **Which devices count.** The auth API keeps the profile's devices in
  the order they came: the profiles table's item gets a **`devices`**
  list. `POST /api/auth/credentials` takes the device's ID as its
  (plain-text) body and adds it at the end, once, up to 50 whatever the
  tier (so a profile that becomes premium shows the devices it already
  has). A body that isn't a device ID (`adjective_adjective_thing`, at
  most 64 characters) is refused (400); an empty one (an older app)
  lists nothing. The answer adds **`deviceLimit`** (2 or 50) and
  **`devices`** (`ProfileHandler.FREE_DEVICES`, `PREMIUM_DEVICES`). The
  first `deviceLimit` of them show.
- **Every device agrees**, since the list is the auth API's, not worked
  out from events, which differ from device to device (a free device has
  no history from before it connected).
- **What's hidden** (`DeviceSlots.visibleFrom`,
  [device_slots.dart](../presence_app/lib/cloud/device_slots.dart)):
  - on a device that shows, the events of the devices that don't;
  - on a device past the limit, every other device's: only its own show.
  - The app filters its event log (`EventLog.visibleDevices`, applied to
    `EventLog.eventsOf`), so the timeline, its count and search, the map,
    the subjects and the All grid leave them out. The events are still
    stored and synced, and show at once if the device gets a place.
  - Nothing is hidden until the auth API has listed the devices (the
    first credentials after sign-in), signed out, in DEV, or with an API
    that doesn't list them.
- **A new device** that the list doesn't name while there's still room
  may be one that shows: when the profile's events name a device it
  doesn't know, the app asks for new credentials (and the list with
  them), once per device and at most every 30 s
  (`CloudSync.noticeDevices`). A device is listed before its events can
  reach another, since it needs credentials to send them. Otherwise the list is read
  again with each new set of credentials (hourly) or a change of tier.
- **Deleting a device** ([Device deletion](device-deletion.md), either
  choice) takes it off the list (`POST /api/auth/profile/devices/remove`, the device ID
  as the body; `CloudSync.releaseDevice`), so the next one takes its
  place. It's added again, last, if it asks for credentials again.

## In the app

- **The account sheet** ([Sign-in](sign-in.md)), under the profile's
  devices, a box with the plan (`PlanNotice`,
  [plan_notice.dart](../presence_app/lib/auth/plan_notice.dart)). It's
  Premium for `isPremium` or `isAdmin`, so only a free member is asked to
  upgrade; an admin never is, even if its roles lack `presence_premium`:
  - **Premium** (the `workspace_premium` icon): "Premium: cloud backup,
    and up to 50 devices sync."
  - **Free**: "Free: each device keeps its events, and up to 2 devices
    share them every 15 minutes. Premium syncs them instantly, with cloud
    backup and up to 50 devices", then by platform
    ([Upgrade to Premium](upgrade.md)): on the web ": US$20 a month, the
    first week free." with **Premium monthly** and **Premium yearly**
    buttons to the plan's Stripe checkout; on iOS and Android the App
    Store's or Google Play's plans with their own prices, Restore
    purchases, Manage subscription and the terms; elsewhere no purchase
    button. And **Check again**.
  - Past the limit, a line in the warning color: on this device, "This
    device is past your first 2: it syncs, but its events are hidden on
    your other devices, and theirs here."; otherwise how many devices are
    hidden ("1 more device syncs, but its events are hidden: Free shows
    your first 2.").
  - Each hidden device in the list is labelled **hidden** (tooltip:
    past the plan's device limit).
  - Not shown in DEV or without access.
- **The Monitoring tab** ([Monitoring](monitoring.md)), when events are
  hidden, a card above the search (`DeviceLimitNotice`): how many
  devices' events are hidden, or that the other devices' are hidden on
  this one, that Free shows the first 2, and for a free profile "Premium
  shows up to 50." and an **Upgrade** button: to the Stripe checkout on
  the web, to the Profile tab's store plans on iOS and Android, none
  elsewhere.
- **The connectivity check**: "Free: devices share events every 15 min"
  instead of "Cloud sync on".
- **The health panel's RBACR card** (🛂, `SystemHealth.rbacrOf`; see
  [Log](log.md)):
  - ✅ when the auth API has rbacr, saying whether this profile is Premium
    (cloud backup) or Free (its devices share events every 15 min);
  - ⚠️ when the API has cloud sync but no rbacr, so nobody can be premium.
    This counts as a failed check (the health warning pill);
  - ⚪ when the API doesn't say (not answered yet, or older), when there's
    no cloud sync anyway, and in DEV.

## Health checks

- **`/health`** ([Health check](health-check.md), its own module,
  `presence_health`) has an **`rbacr`** check when rbacr is configured: rbacr's own public `/health`
  must answer 200 within the budget. The central nu01-monitor polls
  it, so an rbacr outage sets off its alert email (there's no DNS
  failover), and fails a deploy's smoke test.
- **`GET /api/auth/anonymous`** reports `"rbacr": true|false` in its
  settings, as for `oidc` and `aws`, and `scripts/deploy.sh`'s smoke test
  expects `true` when it deployed a token.
- **`scripts/health-check.sh`** (the local monitor) shows 👮 RBACR (the
  local API's rbacr setting) and 💎 RBACR svc (rbacr's `/health`, at `RBACR_URL`; no token
  sent) on its one line per run.

## Configuration

- **The auth API stack**: `RbacrUrl` (default `https://rbacr.nu01.com`) and
  `RbacrToken` (NoEcho, default empty) become `RBACR_URL` and `RBACR_TOKEN`
  on `ProfileFunction`, which needs the tier (`AuthFunction` gets only
  the token, to report `rbacr: true`). The app's build gets the same URL
  and `RBACR_SYSTEM`, never the token (see
  [Configuration](configuration.md#build-time-settings-rbacr)). The health stack (`presence_health`) gets
  `RbacrUrl` only, never the token; `scripts/deploy.sh` requires a token,
  so it always passes the URL.
- **`scripts/deploy.sh`** takes `RBACR_TOKEN` and `RBACR_URL` from the
  environment, else `.env`. In CI they come from the `RBACR_TOKEN`
  repository secret (masked in logs) and the `RBACR_URL` variable.
- **The token** should belong to an admin of rbacr's `presence` system, not
  a root: a root's token reads every system's roles. It's a secret: in
  `.env` (git-ignored) and the repository secret, never in the repository.

## Known limitations

- **Hidden, not withheld.** A device past the limit still receives the
  other devices' events (and they its): the app hides them. Someone
  reading the stored data or the live messages directly sees them.
- **Which devices show** is the order they first asked for credentials
  after this release: for a profile that already had more than 2, that's
  whichever came first, not the oldest. Deleting a device frees its
  place.
- **Devices on an older app** never join the list, so the devices that
  list them hide their events until they're updated.
- **A deletion reaches the other devices' lists** with their next
  credentials (within the hour), or sooner if they see a device they
  don't know while there's room.

- **Free sync isn't a backup.** A device off for longer than its
  persistent session lasts (1 h, AWS IoT's default) misses what others
  published meanwhile. A new device starts empty, and a recording is lost
  with its device.
- **Free events are shared once, late.** An event reaches the other
  devices within about 15 min, once final; a later tag, deletion or device
  deletion doesn't reach them.
- **A premium device in a free owner's profile** uploads to the folder the
  free devices can't read. Its clips reach them through its live messages,
  but its recordings and tagged frames don't.
- **Revocation lags**: credentials issued before a change stay valid up to
  an hour; rbacr's answers are reused for a minute.
- **rbacr's outage shuts everyone out** for its duration (fail closed):
  the app's roles check fails (no access, retried), and the auth API
  gives no role, so no new credentials, until rbacr answers again and the
  roles are checked again.
- **Tested with fakes only**: Cognito's principal tags, the trust policy and
  the S3 conditions haven't run in AWS yet.
