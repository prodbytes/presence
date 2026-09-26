# Cloud sync

Signed-in users' **clips (videos) and events are uploaded to S3**,
straight from the device, as they're saved. There's no backend in between:
the app trades the user's Google ID token for temporary AWS credentials
through a **Cognito identity pool**, and makes signed S3 uploads itself
([lib/cloud/](../presence_app/lib/cloud)).

## What's uploaded, and where

Everything goes under the user's **Cognito identity ID**
(`us-east-1:<uuid>`), in the user-data bucket:

| Object | Content |
|---|---|
| `<identityId>/clips/<clipId>.webm` or `.mp4` | the clip's recording (the full clip, or the before part if the after part was cut short), with its MIME type |
| `<identityId>/clips/<clipId>.jpg` | the thumbnail |
| `<identityId>/clips/<clipId>.json` | the clip record: camera, window, lengths, state, media reference |
| `<identityId>/events/<eventId>.json` | each event record (type, title, detail, time, camera, clip ID and state) |

## When

- **Signed out:** nothing is uploaded (and the camera shows no buttons; see
  [Sign-in](sign-in.md)).
- **On sign-in:** everything stored and not yet uploaded goes up. Clips go
  first, recordings being what matters most.
- **While signed in:** each event goes up as soon as it's saved. A clip goes
  up once its recording is complete: `Persistence.changes` fires after both,
  and a sync pass follows 0.5 s later.
- **Nothing twice:** the `synced` store keeps each uploaded object key with
  a fingerprint of its content (the SHA-256 of the JSON, or the media ID).
  An unchanged object is skipped. A changed one, such as a clip's event
  that's updated when the clip completes, is uploaded again.
- One pass runs at a time. A change during a pass queues one more pass.

## How

- **Credentials** (`CognitoCredentials`): `GetId`, then
  `GetCredentialsForIdentity`, with `Logins: {"accounts.google.com": <ID
  token>}` (the enhanced flow). These calls are unsigned; the Google token
  is the proof. Credentials are reused until five minutes before they
  expire.
- **Uploads** (`S3Bucket`, `SigV4Signer`): `PUT` to
  `https://<bucket>.s3.us-east-1.amazonaws.com/<key>`, signed with AWS
  Signature Version 4 in pure Dart (`crypto`, `http`). The signer is tested
  against AWS's published S3 examples.
- **Errors:**
  - if S3 rejects expired credentials, the app fetches new ones and
    continues;
  - if Cognito rejects the Google token (`NotAuthorizedException`, for
    example once it has expired), the account sheet says **"Sign in again
    to resume uploads"**;
  - other failures show "Upload failed (HTTP …)".
- **Status:** the account sheet shows a line under the email: "Cloud backup
  is off", "Uploading…", "Backed up (N uploaded)", or the error.
- **Configuration** (`CloudConfig`, dart-defines like the Google client
  IDs): `AWS_REGION` (default `us-east-1`), `COGNITO_IDENTITY_POOL_ID` and
  `USER_DATA_BUCKET`. Sync is off when either ID is empty. In production,
  `scripts/deploy.sh` sets them from the stack outputs; locally they come
  from `.env`.
- The Google ID token is issued for the web client on every platform: web
  directly, and Android and iOS through `serverClientId`. So the identity
  pool trusts that one client ID.

## Infrastructure

In [presence_infra/](../presence_infra):

- **`user-data.yaml`**, stack `presence-user-data`: the bucket (its name
  is the stack output `UserDataBucketName`, `USER_DATA_BUCKET` in the
  private `.env`).
  - Private (public access blocked, owner-enforced), SSE-S3 encrypted, and
    TLS only.
  - Versioned: old versions expire after 30 days, and incomplete multipart
    uploads after 1 day.
  - CORS allows `GET`, `PUT` and `HEAD` from `https://presence.nu01.com`,
    `https://local.presence.nu01.com:8443` and `http://localhost:8080`.
- **`identity.yaml`**, stack `presence-identity`: the identity pool (the
  stack output `IdentityPoolId`, `COGNITO_IDENTITY_POOL_ID` in the private
  `.env`).
  - Google only (`accounts.google.com` = the web client ID), no guests, no
    classic flow.
  - Its authenticated role may only `PutObject` and `GetObject` in
    `<bucket>/${cognito-identity.amazonaws.com:sub}/*`, and `ListBucket` on
    that prefix. No deletes.

## Verified

- Unit tests:
  - SigV4 against AWS's GET and PUT Object examples;
  - `CloudSync` with a fake backend: nothing while signed out; everything on
    sign-in, under the identity; no duplicates; changed events again; new
    events; renewed credentials; "sign in again"; sign-out stops uploads.
- An app-level test: signed in, a finished clip's video, thumbnail, details
  and events upload, and the account sheet says "Backed up".
- Against AWS:
  - the app's `S3Bucket` uploaded to the real bucket (a key containing `:`
    and a space) with session credentials: 200, stored encrypted;
  - CORS preflights from the three origins return 200, and another origin
    gets 403;
  - the identity pool rejects a forged Google token and guest access.
- Not yet verified: a real Google sign-in exchanging its token and
  uploading. That needs an interactive sign-in. IAM's policy simulator
  doesn't substitute `${cognito-identity.amazonaws.com:sub}`, so the prefix
  rule was checked with a literal-identity variant of the same policy: the
  own prefix is allowed, another's and deletes are denied.

## Known limitations

- Google ID tokens last about an hour, and the app has no silent refresh.
  After that, uploads stop with "Sign in again to resume uploads".
- Local development uses the production bucket and pool, each user in their
  own prefix.
- Recordings are uploaded in one `PUT`, not multipart. That's fine at about
  10 MB per clip.
- Nothing is downloaded back yet: the cloud is a backup, and the device
  stays the source of truth.
