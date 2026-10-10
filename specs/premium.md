# Premium and free

A member (`presence_user`) is either **premium** or **free**. Premium
profiles sync with the cloud (S3) and over live sync, and up to **50
devices** show each other's events; free profiles' devices sync with each
other over [live sync](live-sync.md) (MQTT) only, and only the profile's
**first 2 devices** show each other's events. The account sheet says which
the account is, and how to sign up for Premium (at nu01.com).
[rbacr](https://github.com/prodbytes/rbacr), the organisation's role manager,
decides who is premium, as it decides every role ([Auth API](auth-api.md)).

## Who is premium

- **rbacr's `presence` system** has the roles `free`, `premium` and `admin`
  (rbacr adds `admin` to every system). An email holding **`premium` or
  `admin`** there is premium. That includes holding it through a grant to
  its domain, a global grant, an implied role, or being an rbacr root. Its
  `free` role alone is a free member; no role at all, no member.
- The auth API asks rbacr (`Rbacr`,
  [presence_api_auth](../presence_api_auth/AuthFunction/src/main/java/presence/auth/Rbacr.java))
  with a root's API token, server-side. It sends `POST /api/roles
  {"email"}`, with the email in the body and never the URL, and reads the
  `presence` system's roles from the answer, which it turns into
  **`presence_premium`** (`Roles.PREMIUM`) next to the app's other roles
  (all of them rbacr's). `GET /api/auth` lists it, so the app knows
  (`RolesService.isPremium`).
- **Only rbacr gives it**, and never for an unverified email. In
  [DEV](execution-mode.md) the anonymous user has every role, `presence_premium`
  included, but nothing syncs there.
- **A linked account** ([profiles](profiles.md)) shares its profile owner's
  premium, as it shares the owner's membership: the profile's cloud folder
  is one. It's also premium on its own when rbacr says so of its own email.
- **Fails closed.** If rbacr doesn't answer in time (2 s), refuses the
  token, or answers something that isn't an answer, the email has no
  roles at all, premium included. Answers are reused for **60 s** per Lambda instance; errors are
  never reused. A grant or revocation in rbacr shows within about a minute.
  The credentials already issued last up to an hour.
- **Without a token** (`RbacrToken` empty), nobody has a role.
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
| New and changed events reach the profile's other devices | within a second (live sync), and every 15 s from the bucket | within a second, while both are connected (or within a scheduled device's next connection, while its persistent session keeps them) |
| A clip's record and thumbnail | from the bucket | in the live message (thumbnails up to 48 KB) |
| Recordings | from the bucket, on demand or in the background | only on the device that made them |
| Tagged frames | from the bucket | only on the device that made them |
| History on a new device (two weeks) | from the bucket | none: only what's published after it connects |
| This device's settings | backed up, restored at sign-in | stay on the device |
| Recognition references | every device's tags | the tags this device has |
| Devices whose events show ([below](#devices)) | the first 50 | the first 2 |

- **Free sync** (`_LivePublisher`, [cloud_sync_free.dart](../presence_app/lib/cloud/cloud_sync_free.dart)):
  - A free profile's pass never touches the bucket. It gets credentials
    (for live sync) and starts live sync, then publishes the profile's
    events saved since the last pass. On the first pass for the profile,
    it publishes those of the last 24 h not published yet.
  - Each event goes once per version (`live/<event id>` in the synced
    store): again when it changes, or when its clip completes.
  - A message carries the event, plus the clip's record and thumbnail
    once the clip is complete (`LiveSync.clipMessageOf`). The clip goes
    without its thumbnail when that would pass 48 KB or the 64 KB message
    limit, and the event goes alone when the clip itself doesn't fit.
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

## Devices

A profile's devices past its limit (2 free, 50 premium) **still sync**:
they publish, receive and store events as before. Their events are
**hidden**, and the user is asked to sign up for Premium.

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
- **Deleting a device** ([Device deletion](device-deletion.md)) takes it
  off the list (`POST /api/auth/profile/devices/remove`, the device ID
  as the body; `CloudSync.releaseDevice`), so the next one takes its
  place. It's added again, last, if it asks for credentials again.

## In the app

- **The account sheet** ([Sign-in](sign-in.md)), under the profile's
  devices, a box with the plan (`PlanNotice`,
  [plan_notice.dart](../presence_app/lib/auth/plan_notice.dart)):
  - **Premium** (the `workspace_premium` icon): "Premium: cloud backup,
    and up to 50 devices sync."
  - **Free**: "Free: up to 2 devices sync with each other while online.
    Sign up for Premium at nu01.com for cloud backup and up to 50
    devices.", and a **Sign up at nu01.com** button that opens
    https://nu01.com (copied when it can't open).
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
  this one, that Free shows the first 2, and for a free profile a
  **Sign up** button to nu01.com.
- **The account sheet's** sync line, for a free profile: "Your devices
  sync with each other while online" (`CloudSyncStatus`).
- **The connectivity check**: "Free: devices sync over live sync" instead
  of "Cloud sync on".
- **The health panel's RBACR card** (🛂, `SystemHealth.rbacrOf`; see
  [Log](log.md)):
  - ✅ when the auth API has rbacr, saying whether this profile is Premium
    (cloud backup) or Free (its devices sync with each other);
  - ⚠️ when the API has cloud sync but no rbacr, so nobody can be premium.
    This counts as a failed check (the health warning pill);
  - ⚪ when the API doesn't say (not answered yet, or older), when there's
    no cloud sync anyway, and in DEV.

## Health checks

- **`/health`** ([Health check](health-check.md), its own module,
  `presence_health`) has an **`rbacr`** check when rbacr is configured: rbacr's own public `/health`
  must answer 200 within the budget. The site's Route 53 health check polls
  it, so an rbacr outage sets off the health alarm email (there's no DNS
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
  on the functions that need roles with premium (`AuthFunction`,
  `ProfileFunction`). The health stack (`presence_health`) gets
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

- **Free sync isn't a backup.** A device that's off, or not connected, when
  another publishes doesn't get that event later, beyond what a scheduled
  device's persistent session keeps. A new device starts empty, and a
  recording is lost with its device.
- **Free profiles' events change only while connected.** A tag, a deletion
  or a device deletion reaches the other devices only if they hear it then.
- **A premium device in a free owner's profile** uploads to the folder the
  free devices can't read. Its clips reach them through its live messages,
  but its recordings and tagged frames don't.
- **Revocation lags**: credentials issued before a change stay valid up to
  an hour; rbacr's answers are reused for a minute.
- **rbacr's outage makes everyone free** for its duration (fail closed):
  syncs fall back to live sync alone, until rbacr answers again and the
  roles are checked again.
- **Tested with fakes only**: Cognito's principal tags, the trust policy and
  the S3 conditions haven't run in AWS yet.
