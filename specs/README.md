# Presence — software specification

The current specification of the product, one file per feature. Update the
feature files a request changes, and add a file when a request adds a
feature. [requests.md](requests.md) holds the history of requests that shaped
it.

## Product

Presence is a surveillance app. It shows live camera feeds and a stream of
events detected from them. The cameras are always recording, video and
audio, so a clip can include the moments before someone pressed Clip.

**Data belongs to profiles, not logins.** A [profile](profiles.md)
(`automatic_paranoid_axolotl`) exists only once someone signs in: the
first sign-in of an account makes it, and every later one, on any device,
loads the same profile. Signed out there's no profile, and nothing syncs.
At sign-in, the events recorded on the device without a profile become
the profile's. The profile owns the events, the cloud folder and roles,
and several Google accounts can be linked to it with a one-time code. So
users can change emails, add accounts or switch providers without losing
their data.

## Features

**App**

- [Navigation](navigation.md): app bar (no title), tabs (Log for admins who turn it on, Admin for signed-in admins), and the full-screen Camera tab
  with its view (One / All / None), Flip and Clip buttons (Clip's color is its readiness).
- [About](about.md): what Presence is, in a short paragraph with a link
  to its source code, at the end of the account sheet.
- [Theme](theme.md): the Gruvbox dark palette.
- [Camera screen](camera.md): opening cameras, audio capture and states;
  the view button (One / All / None: this camera, the All grid, or the
  camera off); the All grid: this camera top left, then every device in the
  profile with its latest image; Clip there is Capture all, a clip on
  every device, asked through cloud sync.
- [Monitoring](monitoring.md): one tab with the subjects' map, the
  subjects and the events.
- [Events](events.md): the event timeline and the app-wide event bus.
- [Event flags](event-flags.md): flags on an event's card, worked out from
  its data; a yellow **unidentified** flag on a clip showing a person or
  pet (cat, dog) nobody's named, with **Identify** to name them.
- [Recording consent](consent.md): asked once per device, before anything
  shows or records: the right to record, and faces as biometric data under
  the GDPR, in plain terms, with a verification hash.
- [Device deletion](device-deletion.md): delete another device of the
  profile from the account sheet's device list or its All grid cell, after
  a confirmation: its events move to a deleted state (`deletedAt`), synced,
  and are hidden on every device; media stay; this device can't be
  deleted, and a device that records again reappears. One event is
  deleted the same way from the end of its details (the clip player).
- [Devices, users and places](devices-users-places.md): the device ID
  (`automatic_paranoid_gadget`) and user ID on every event, and a sign-in
  taking over the events recorded signed out; places (device groups) are
  defined, not built.
- [Clips](clips.md): before + after clips, always-on recording on web, and
  tagging people and pets by clicking them on the video, or with Auto;
  the details end with the event's map, its device and Delete event.
- [Motion clips](motion-clips.md): automatic clips when the picture moves.
- [Scheduled clips](scheduled-clips.md): a clip at start, then one every
  3 hours (30 min to a day, in Settings, with a countdown).
- [Profiles](profiles.md): **the owner of a user's data and events.**
  None signed out; an account's first sign-in makes it and later ones, on
  any device, load it (by subject, `<iss>#<sub>`); IDs like
  `automatic_paranoid_axolotl`, never repeated.
- [Sign-in](sign-in.md): Google sign-in, the role-gated UI, the account
  sheet (the profile ID and its devices, from events) and the OAuth
  clients.
- [Membership](membership.md): users without access ask for it or redeem
  a voucher code; admins grant requests and create voucher codes (their
  own or a suggested `AUTUMN-OTTER-4821`, role, validity dates (the
  current season by default), uses, discount)
  on the Admin tab.
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
  the location by moving it, pinning it, and the location on every event.
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
  S3, and each device's settings per profile (restored at sign-in), with
  credentials for their profile (the auth API, then a Cognito identity
  pool).
- [Live sync](live-sync.md): new and changed events reach the profile's
  other devices within a second over MQTT (AWS IoT Core, WebSockets signed
  with the profile's credentials), metadata only; S3 keeps everything, and
  clips and thumbnails still come from it.
- [Device presence](device-presence.md): devices ping each other over
  live sync; a green (answered within 90 s), yellow (heard from or an
  event within 24 h) or red dot by each device in the All grid and the
  account sheet's devices list.
- [Event copies](event-copies.md): each event card and the event's
  details count the copies of the event (this device, the cloud, other
  devices) with the holders in a tooltip; devices ack copies over live
  sync (`copied` on `acks`).
- [Recording and data formats](data-formats.md): the video codecs and
  containers per platform, the JSON records, and the S3 layout (JSON and
  media in separate trees, partitioned by day) for querying with Athena.
- [Log](log.md): the admins' Log tab, shown by default only in DEV and
  otherwise turned on in Settings: a health panel (a
  card per check, API, AWS, OIDC, Live, checked every 15 s in DEV and 60 s in RBAC, a card with the
  devices in the events, and a scrolling timeline of the runs with their
  times), then the app's latest 500 log messages and errors, such as why
  the AWS sync failed.
- [App icon](app-icon.md): the icon masters and generated icons, and the
  app's name, Presence, wherever it's shown.

**Platforms**

- [Platforms](platforms.md): camera layers and feature parity.
- [Android](android.md): the native Camera2 recording layer, keep-alive
  (watchdog, crash and boot restart) and log files on the phone
  (`devbox run android-pull`).
- [iOS](ios.md): the native AVFoundation recording layer.
- [Raspberry Pi camera](raspberry-pi.md): the `.deb` that runs Presence
  full screen from boot (cage on tty1, the web app in Chromium, since the
  native Linux app has no camera layer or Google sign-in yet).

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
- [Health check](health-check.md): `GET /health` checks the settings,
  tables, user-data bucket, identity pool and Google's keys; a Route 53
  health check polls it and emails `HealthNotificationEmails` (default
  julio+health@nu01.com) when it fails or recovers.

## Workflow

- Every new feature or bug fix starts on a new branch from `main`, with its
  own pull request. Nothing is pushed directly to `main`, and PRs are merged
  only when the user says so. See [CLAUDE.md](../CLAUDE.md).
- Every request updates the affected feature specs and the
  [request log](requests.md) in the same PR.
- Each feature file ends with its own **Known limitations**, where it has
  any.
