# Presence — software specification

The current specification of the product, one file per feature. Update the
feature files a request changes, and add a file when a request adds a
feature. [requests.md](requests.md) holds the history of requests that shaped
it.

## Product

Presence is a surveillance app. It shows live camera feeds and a stream of
events detected from them. The cameras are always recording, video and
audio, so a clip can include the moments before someone pressed Clip.

**Data belongs to profiles, not logins.** There's always a
[profile](profiles.md) (`automatic_paranoid_axolotl`): the app makes one
at its first start, owned by nobody, and the first sign-in claims it.
Later sign-ins load the profile linked to the subject they sign in with.
The profile owns the user's cloud folder and roles, and several Google
accounts can be linked to it with a one-time code. So users can change
emails, add accounts or switch providers without losing their data.
(Events still carry the Google account ID; see
[Profiles](profiles.md#known-limitations).)

## Features

**App**

- [Navigation](navigation.md): app bar, tabs (Log for admins), and the full-screen Camera tab
  with its All, Clip, Flip and readiness controls.
- [Theme](theme.md): the Gruvbox dark palette.
- [Camera screen](camera.md): opening cameras, audio capture and states,
  and the All grid: this camera top left, then every device in the
  profile with its latest image.
- [Monitoring](monitoring.md): one tab with the subjects' map, the
  subjects and the events.
- [Events](events.md): the event timeline and the app-wide event bus.
- [Recording consent](consent.md): asked once per device, before anything
  shows or records: the right to record, and faces as biometric data under
  the GDPR, in plain terms, with a verification hash.
- [Devices, users and places](devices-users-places.md): the device ID
  (`automatic_paranoid_gadget`) and user ID on every event, and a sign-in
  taking over the events recorded signed out; places (device groups) are
  defined, not built.
- [Clips](clips.md): before + after clips, always-on recording on web, and
  tagging people and pets by clicking them on the video, or with Auto.
- [Motion clips](motion-clips.md): automatic clips when the picture moves.
- [Scheduled clips](scheduled-clips.md): a clip at start, then one every
  240 minutes (30 min to a day, in Settings).
- [Profiles](profiles.md): **the owner of a user's data.** Made by the
  app at its first start, owned by nobody, and claimed by the first
  sign-in; later sign-ins load the profile linked to their subject
  (`<iss>#<sub>`); IDs like `automatic_paranoid_axolotl`, never repeated.
- [Sign-in](sign-in.md): Google sign-in, the role-gated UI and the OAuth
  clients.
- [Membership](membership.md): users without access ask for it or redeem
  a voucher code; admins grant requests and create voucher codes (role,
  expiry, uses) on the Admin screen.
- [Execution mode](execution-mode.md): DEV (no OIDC client: the anonymous
  user gets every role, a "dev" label shows) or RBAC (sign in for roles),
  asked of the auth API before the app shows anything.
- [Configuration](configuration.md): `PresenceConfig` and how it's stored.
- [Subjects](subjects.md): the people and pets tagged on clips, each with
  its latest frame, and a map of their latest events, fading with age.
- [Subject recognition](recognition.md): new clips (and any clip, with the
  player's Auto) searched in two segments (TensorFlow Lite models,
  TensorFlow.js on web): subjects, the people and pets tagged before
  (tagged when sure, "Is this Rex?" when unsure), and object tags (human,
  cat, bicycle, bottle…) for search.
- [Device location and battery](device-location.md): the Settings location map, the battery over the camera, setting
  the location by moving it, and the location on every event.
- [Settings screen](settings.md): the motion, camera, clip, schedule,
  subject, recognition and history settings.
- [Add a device](add-device.md): a QR code, the link and a Share button,
  shown at the end of Settings, that open Presence on another device as a new device of the
  same user, after a sign-in checked against the link.
- [Storage](storage.md): IndexedDB stores and how clips are saved.
- [Event retention](event-retention.md): events older than the History
  setting (two weeks; 1 day to 3 months) deleted from the device, with
  their clips, at load and every 3 hours.
- [Cloud sync](cloud-sync.md): signed-in users' clips and events upload to
  S3, with credentials for their profile (the auth API, then a Cognito
  identity pool).
- [Recording and data formats](data-formats.md): the video codecs and
  containers per platform, the JSON records, and the S3 layout (JSON and
  media in separate trees, partitioned by day) for querying with Athena.
- [Log](log.md): the admins' Log tab (DEV's too) with the app's latest
  500 log messages and errors, such as why the AWS sync failed.
- [App icon](app-icon.md): the icon masters and generated icons.

**Platforms**

- [Platforms](platforms.md): camera layers and feature parity.
- [Android](android.md): the native Camera2 recording layer.
- [iOS](ios.md): the native AVFoundation recording layer.

**Backend**

- [Auth API](auth-api.md): `GET /api/auth`, the signed-in user's
  [profile](profiles.md) and roles
  (`presence_user`, `presence_admin`, and `presence_root` for the root
  allowlist: `PRESENCE_ROOT_DOMAINS`, `PRESENCE_ROOT_EMAILS`),
  `GET /api/auth/anonymous` (the
  execution mode and which settings are set, no token), the
  membership and voucher routes and the [profile](profiles.md) routes (SAM,
  Java 25; Google JWT authorizer; roles by domain or a DynamoDB table).
- [Local CDN](local-cdn.md): Floci as the local CloudFront in front of the
  index, the app and the API.
- [Site index](site-index.md): the `presence_index` root page, which
  redirects to `/app/`.

**Project**

- [Development environment](dev-environment.md): devbox, the dev container,
  and the Android and iOS toolchains.
- [Install script](install-script.md): `curl … | sh` downloads, verifies
  and runs the latest release's native Linux bundle (x64 or arm64), or
  opens the web app when there isn't one or it can't run.
- [Install URL](install-url.md): https://sh.presence.nu01.com serves the
  install script (`presence_sh/`: certificate, bucket, CloudFront, DNS),
  deployed on `*GA` tags.
- [Release builds](release.md): the GitHub Actions workflow that builds the
  binaries and publishes a release for `*QA` / `*RC*` tags and manual runs.
- [Production deploy](deploy.md): `*GA` tags deploy to
  https://presence.nu01.com, and `*RC*` tags (or manual runs) to
  https://rc.presence.nu01.com (CloudFront, S3, API Gateway).

## Workflow

- Every new feature or bug fix starts on a new branch from `main`, with its
  own pull request. Nothing is pushed directly to `main`, and PRs are merged
  only when the user says so. See [CLAUDE.md](../CLAUDE.md).
- Every request updates the affected feature specs and the
  [request log](requests.md) in the same PR.
- Each feature file ends with its own **Known limitations**, where it has
  any.
