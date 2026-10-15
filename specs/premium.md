# Plans: Free, Premium and Pro

A member (`presence_user`) is on one of three plans, which differ, for
now, by how many of the profile's devices sync:

| Plan | Devices | Cloud (S3, cloud recognition, streamers) |
|---|---|---|
| **Free** | the first **10** | no: [live sync](live-sync.md) (MQTT) only |
| **Premium** | the first **25** | yes |
| **Pro** | the first **50** | yes: everything Premium has |

Admins are Pro (Pro's 50 devices, and their admin features). Premium and
Pro profiles sync with the cloud (S3) and over live sync; free profiles'
devices sync with each other over live sync only. The account sheet says
which plan the account is on, and a free member
[upgrades to Premium](upgrade.md) there: a Stripe subscription on the web
(US$20 a month, the first week free), an App Store or Google Play
subscription in the iOS and Android apps. A premium member upgrades to Pro
on the web, once Pro's Stripe links are set (below).
[rbacr](https://github.com/prodbytes/rbacr), the organisation's role manager,
decides who is on which plan, as it decides every role
([Auth API](auth-api.md)).

## Who is premium, and who is Pro

- **rbacr's `presence` system** has the roles `free`, `premium`, `pro` and
  `admin` (rbacr adds `admin` to every system). An email holding
  **`premium`, `pro` or `admin`** there is premium (cloud); one holding
  **`pro` or `admin`** is also Pro. That includes holding it through a
  grant to its domain, a global grant, an implied role, or being an rbacr
  root. Its `free` role alone is a free member; no role at all, no member.
- **The `pro` role must be created in rbacr** (`presence` system), with
  its Stripe sync (below): rbacr is an external service and this repo
  doesn't change it. Until it exists, nobody but admins is Pro.
- **The app** asks rbacr itself (`GET /api/me`, with the user's
  [session token](sessions.md); see [Sign-in](sign-in.md)) and maps
  `premium`, `pro` or `admin` to **`presence_premium`**, and `pro` or
  `admin` to **`presence_pro`**, so it knows (`RolesService.isPremium`,
  `isPro`, and `plan`: Pro for `isPro` or `isAdmin`, Premium for
  `isPremium`, else Free).
- **The auth API**, which enforces it, asks rbacr too (`Rbacr`,
  [presence_api_auth](../presence_api_auth/AuthFunction/src/main/java/presence/auth/Rbacr.java))
  with a root's API token, server-side, for the credentials' tier. It
  sends `POST /api/roles {"email"}`, with the email in the body and never
  the URL, and reads the `presence` system's roles from the answer, which
  it turns into `presence_premium` (`Roles.PREMIUM`) and `presence_pro`
  (`Roles.PRO`) the same way.
- **Store subscriptions** (iOS, Android) become a grant of `premium` in
  rbacr too: the [payments API](payments-api.md#store-purchases) verifies
  each purchase with its store and grants the role to the buyer's email
  until the paid period ends (plus 2 days), with a root's token
  (`RbacrGrantToken`).
- **Only rbacr gives it**, and never for an unverified email. In
  [DEV](execution-mode.md) the anonymous user has every role, `presence_premium`
  included, but nothing syncs there.
- **A linked account** ([profiles](profiles.md)) shares its profile owner's
  premium and Pro, as it shares the owner's membership: the profile's
  cloud folder and devices are one (the auth API answers them in
  `shared`, `GET /api/auth/profile`; an admin owner shares
  `presence_premium` and `presence_pro`, never `presence_admin`). It's
  also premium or Pro on its own when rbacr says so of its own email.
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
- **Pro is tagged `premium`.** Pro always comes with `presence_premium`
  (rbacr's `pro` gives both), so a Pro profile's credentials carry
  `tier=premium` and reach the bucket exactly as Premium's do. The tag is
  the cloud access, not the plan; the plan only sets the device limit
  (below). So the IAM condition (`aws:PrincipalTag/tier` = `premium`) and
  [identity.yaml](../presence_infra/identity.yaml) are unchanged: no new
  tag value, no infra deploy, and nobody gains S3 access they didn't have
  (only holders of rbacr's `premium`, `pro` or `admin` are tagged
  `premium`).
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

Pro syncs exactly as Premium; only its device limit differs.

| | Premium (and Pro) | Free |
|---|---|---|
| New and changed events reach the profile's other devices | within a second (live sync), and every 15 s from the bucket | within a second, while both are connected (or within a scheduled device's next connection, while its persistent session keeps them) |
| A clip's record and thumbnail | from the bucket | in the live message (thumbnails up to 48 KB) |
| Recordings | from the bucket, when played | only on the device that made them |
| Tagged frames | from the bucket | only on the device that made them |
| History on a new device (two weeks) | from the bucket | none: only what's published after it connects |
| This device's settings | backed up, restored at sign-in | stay on the device |
| Recognition references | every device's tags | the tags this device has |
| [Cloud recognition](cloud-recognition.md) (DINOv2-L, trained on the profile's labels) | yes | no (the APIs answer 403) |
| [Streamers](streamer.md) (Raspberry Pi, Blink) | yes | no: the auth API refuses their keys and credentials (403) |
| Devices that sync ([below](#devices)) | the first 25 (Pro: 50) | the first 10 |

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

A profile's devices past its plan's limit (10 Free, 25 Premium, 50 Pro;
admins 50) **don't sync**: the auth API gives them no credentials, so they
neither publish nor receive. Other devices' events from them (from before)
are **hidden**, and the user is asked to upgrade: a free one to
[Premium](upgrade.md), a premium one to Pro.

- **One source of truth per side.** The auth API decides
  (`ProfileHandler.deviceLimit`: `PRO_DEVICES` 50 with `presence_pro`,
  which admins hold, `PREMIUM_DEVICES` 25 with `presence_premium`,
  `FREE_DEVICES` 10 otherwise; `MAX_DEVICES` = 50 listed). The app says
  the same (`Plan` and `DeviceSlots.freeLimit`, `premiumLimit`,
  `proLimit` in [device_slots.dart](../presence_app/lib/cloud/device_slots.dart)),
  and otherwise follows the `deviceLimit` the API answers (`Plan.ofLimit`).
- **Which devices count.** The auth API keeps the profile's devices in
  the order they came: the profiles table's item gets a **`devices`**
  list. `POST /api/auth/credentials` takes the device's ID as its
  (plain-text) body and adds it at the end, once, up to 50 whatever the
  plan (so a profile that upgrades gets the devices it already has). A
  body that isn't a device ID (`adjective_adjective_thing`, at most 64
  characters) is refused (400). The answer adds **`deviceLimit`** (10,
  25 or 50) and **`devices`**. The first `deviceLimit` of them sync.
- **Enforced by the auth API.** Only a device among the first
  `deviceLimit` gets credentials (`ProfileHandler.withinLimit`). One past
  them (listed, or past the 50 listed) gets **403** with
  `{"error", "reason": "deviceLimit", "deviceLimit", "devices"}` and no
  token. An empty body (an older app, which names no device) gets
  credentials only while the profile lists no more devices than its
  limit, since it might be one past it. The [streamer](streamer.md)'s
  `POST /api/auth/stream/credentials` checks its own device the same way
  (its Blink cameras are listed, and only hidden when past the limit).
- **In the app**, that 403 is a `CognitoException` carrying the slots
  (`pastDeviceLimit`, `deviceSlots`). Cloud sync stops on it as on any
  refusal, without trying again by itself (until sign-in, **Retry**, or a
  change of plan, which reconnects), and takes the slots, so the plan box
  and the Monitoring tab's card say this device is past the limit.
- **Every device agrees**, since the list is the auth API's, not worked
  out from events, which differ from device to device (a free device has
  no history from before it connected).
- **What's hidden** (`DeviceSlots.visibleFrom`,
  [device_slots.dart](../presence_app/lib/cloud/device_slots.dart)):
  - on a device that shows, the events of the devices that don't (those
    they synced before they were past the limit, or a streamer's cameras
    past it);
  - on a device past the limit, every other device's: only its own show.
  - The app filters its event log (`EventLog.visibleDevices`, applied to
    `EventLog.eventsOf`), so the timeline, its count and search, the map,
    the subjects and the All grid leave them out. The events already
    stored stay, and show at once if the device gets a place.
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
  [plan_notice.dart](../presence_app/lib/auth/plan_notice.dart)) for
  `RolesService.plan`: Pro for `isPro` or `isAdmin` (an admin is never
  asked to upgrade, even if its roles lack `presence_premium`), Premium
  for `isPremium`, else Free:
  - **Pro** (the `workspace_premium` icon): "Pro: cloud backup, and up to
    50 devices sync." Nothing to buy.
  - **Premium** (the same icon): "Premium: cloud backup, and up to 25
    devices sync." On the web it adds " Pro: up to 50 devices." and a
    **Pro monthly** and a **Pro yearly** button, one per Pro link the
    payments API has (none until an admin saves them; see
    [Upgrade](upgrade.md#pro)), with **Check again**. In the iOS and
    Android apps Pro isn't mentioned (not sold in the stores yet); a
    store subscriber gets **Manage subscription**.
  - **Free**: "Free: up to 10 devices sync with each other while online.
    Premium adds cloud backup and up to 25 devices", then by platform
    ([Upgrade to Premium](upgrade.md)): on the web ": US$20 a month, the
    first week free. Pro: up to 50 devices." with **Premium monthly** and
    **Premium yearly** buttons to the plan's Stripe checkout; on iOS and
    Android "." and the App Store's or Google Play's plans with their own
    prices, Restore purchases, Manage subscription and the terms;
    elsewhere no purchase button. And **Check again**.
  - Past the limit, a line in the warning color: on this device, "This
    device is past your plan's first 10: it doesn't sync, so only its own
    events show here."; otherwise how many devices are past it ("1 more
    device doesn't sync, and its events are hidden: Free syncs your first
    10.").
  - Each hidden device in the list is labelled **hidden** (tooltip: past
    the plan's device limit: it doesn't sync).
  - Not shown in DEV or without access.
- **The account roles chip** says Free Access, Premium Access, Pro Access
  or Admin Access.
- **The Monitoring tab** ([Monitoring](monitoring.md)), when events are
  hidden, a card above the search (`DeviceLimitNotice`): how many
  devices' events are hidden, or that this device doesn't sync, that the
  plan (Free, Premium) syncs the first 10 or 25, and the next plan:
  - Free: "Premium shows up to 25." and an **Upgrade** button: to the
    Stripe checkout on the web, to the Profile tab's store plans on iOS
    and Android, none elsewhere;
  - Premium, on the web only: "Pro shows up to 50." and, once a Pro
    Stripe link is set, an **Upgrade** button to Pro's checkout (its
    monthly link, else its yearly);
  - Pro: no upgrade.
- **The connectivity check**: "Free: devices sync over live sync" instead
  of "Cloud sync on".
- **The health panel's RBACR card** (🛂, `SystemHealth.rbacrOf`; see
  [Log](log.md)):
  - ✅ when the auth API has rbacr, saying whether this profile is Pro or
    Premium (cloud backup) or Free (its devices sync with each other);
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

- **Withheld from new credentials, not from old ones.** A device past the
  limit gets no new credentials, so it stops syncing within the hour its
  last credentials last (a device that was within the limit, and fell
  past it when the plan went down, keeps those). What it stored before
  stays on it and in the bucket, and the other devices hide it. A
  streamer's Blink cameras past the limit are only hidden: the streamer
  itself is checked, not each camera.
- **A device past the limit stays stopped** after a place frees up (a
  device deleted on another one) until it's retried, signed in again or
  restarted, or its plan changes.
- **Which devices count** is the order they first asked for credentials:
  for a profile that already had more than the limit, that's whichever
  came first, not the oldest. Deleting a device frees its place.
- **Devices on an older app** that send no device ID get credentials only
  while the profile has no more devices than its limit.
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
- **rbacr's outage shuts everyone out** for its duration (fail closed):
  the app's roles check fails (no access, retried), and the auth API
  gives no role, so no new credentials, until rbacr answers again and the
  roles are checked again.
- **Tested with fakes only**: Cognito's principal tags, the trust policy and
  the S3 conditions haven't run in AWS yet.
- **Pro is sold on the web only, once configured**: rbacr's `pro` role and
  its Stripe sync, and Pro's Stripe links (saved in the Admin tab), are
  set up outside this repo. There are no Pro App Store or Google Play
  products yet, so the iOS and Android apps don't offer or mention Pro.
