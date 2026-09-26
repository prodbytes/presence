# Presence — software specification

The current specification of the product, one file per feature. Update the
feature files a request changes, and add a file when a request adds a
feature. [requests.md](requests.md) holds the history of requests that shaped
it.

## Product

Presence is a surveillance app. It shows live camera feeds and a stream of
events detected from them. The cameras are always recording, video and
audio, so a clip can include the moments before someone pressed Clip.

## Features

**App**

- [Navigation](navigation.md): app bar, tabs, and the full-screen Camera tab
  with its Clip, Flip and readiness controls.
- [Theme](theme.md): the Gruvbox dark palette.
- [Camera screen](camera.md): opening cameras, audio capture and states.
- [Events](events.md): the event timeline and the app-wide event bus.
- [Clips](clips.md): before + after clips and always-on recording on web.
- [Motion clips](motion-clips.md): automatic clips when the picture moves.
- [Sign-in](sign-in.md): Google sign-in and the OAuth clients.
- [Configuration](configuration.md): `PresenceConfig` and how it's stored.
- [Settings screen](settings.md): the motion, camera and clip settings.
- [Storage](storage.md): IndexedDB stores and how clips are saved.
- [App icon](app-icon.md): the icon masters and generated icons.

**Platforms**

- [Platforms](platforms.md): camera layers and feature parity.
- [Android](android.md): the native Camera2 recording layer.
- [iOS](ios.md): the native AVFoundation recording layer.

**Backend**

- [Events API](events-api.md): the `presence_api_events` SAM module (Java 25
  Lambda behind API Gateway).
- [Tenant infrastructure](tenant-infra.md): the `presence_infra_tenant` CDK
  app (Java 25).

**Project**

- [Development environment](dev-environment.md): devbox, the dev container,
  and the Android and iOS toolchains.

## Workflow

- Every new feature or bug fix starts on a new branch from `main`, with its
  own pull request. Nothing is pushed directly to `main`, and PRs are merged
  only when the user says so. See [CLAUDE.md](../CLAUDE.md).
- Every request updates the affected feature specs and the
  [request log](requests.md) in the same PR.
- Each feature file ends with its own **Known limitations**, where it has
  any.
