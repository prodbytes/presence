# Roadmap

Planned work that isn't built yet. When an item ships, remove it from here
and describe it in its feature spec ([specs/](specs/README.md)).

## Only the Presence app may call the APIs (app attestation)

**Goal:** the APIs answer only the Presence app (web, Android, iOS), not a
script or another app, even one holding a valid user's session token.

**Today:** the [origin check](specs/origin-check.md) makes the APIs answer
only through the site's CloudFront (`https://presence.nu01.com/api/...`).
Their own `execute-api` hosts refuse direct calls (checked live on
2026-10-15). A script that calls through the site's domain, with no token
on the public routes or with a user's own session token on the others, is
still answered exactly like the app. Nothing a client holds can prove the
caller runs the app's code. Only platform attestation can.

**Plan:** use [Firebase App Check](https://firebase.google.com/docs/app-check)
in the Google Cloud project the sign-in already uses (`presence-492410`):

- **Android**: Play Integrity. It needs the app in the Play Console
  ([Store readiness](specs/store-readiness.md)).
- **iOS**: App Attest. It needs the paid Apple Developer enrollment, which
  is pending. Until then iOS stays unattested, like the free-team builds
  today.
- **Web**: reCAPTCHA Enterprise. This is the weakest of the three, because a
  scripted real browser can still pass.
- **The APIs** (auth, payments, health) verify the
  `X-Firebase-AppCheck` token against Firebase's public keys (issuer and
  audience the project) next to `OriginCheck`.
- **The streamer** ([presence-streamer](specs/streamer.md), Pi and Blink)
  can't attest. It stays allowed through its own device sign-in, which
  takes a user's approval, rather than through App Check.
- **Rollout**: first only log the requests that would fail (monitor), then
  refuse them with 403 from a later release, in the same two-release way
  as the origin check.

**Open questions:**

- Should public routes (`/api/auth/anonymous`, `/health`) require it too?
  External uptime monitors call `/health`.
- The AWS identity the app gets from Cognito can call S3 directly, outside
  the APIs. Its access is limited to the user's own data, but App Check on
  the APIs doesn't cover it.
- A desktop build (Linux, macOS) has no attestation provider, so it would
  need an exemption or would lose cloud access.
