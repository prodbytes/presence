# Sessions

Presence signs its users in with its own **session tokens**. A sign-in
with Google or Apple gives the app the provider's ID token once; the app
trades it at the [auth API](auth-api.md) for a Presence session, and from
then on sends only the Presence token, to every Presence API (the auth
API, [recognition](cloud-recognition.md), [payments](payments-api.md)) and
to [rbacr](https://github.com/prodbytes/rbacr). The app refreshes it
with a refresh token, so no provider has to be asked again while the
session lasts.

Why: Sign in with Apple ([App Store 4.8](store-readiness.md)) gives ID
tokens that last about 10 minutes and that the app can't renew without
the user (and Apple throttles checking its refresh tokens to about once a
day), while Presence used the sign-in's ID token as the bearer of every
API and renewed Google's every hour. A session of Presence's own works
the same for any provider.

## The session token

An RS256 JWT, signed by the auth stack's **KMS key** (below), valid
**1 hour**:

| Claim | Value |
|---|---|
| `iss` | `https://<site>`: `https://presence.nu01.com` (prod), `https://rc.presence.nu01.com` (RC), from the stack's `DomainName` |
| `aud` | `presence` |
| `sub` | the identity's Presence subject: `p_` and 32 hex digits of SHA-256 of `<idp>#<idp_sub>`, stable, and saying nothing of the provider's ID |
| `idp`, `idp_sub` | the provider's issuer (`https://accounts.google.com`, `https://appleid.apple.com`) and subject |
| `email`, `email_verified` | the address the provider verified (Apple's private-relay addresses too); always `true` |
| `name`, `picture` | when known (Google's, or the name Apple gave at the first sign-in) |
| `hd` | Google Workspace's domain, when Google gave one |
| `iat`, `exp` | issued, and an hour later |

- **The identity is the provider's.** The APIs find a
  [profile](profiles.md) by `<idp>#<idp_sub>` (`Caller`), exactly the
  `<iss>#<sub>` profiles were keyed by when the bearer was Google's ID
  token, so **every existing profile keeps its links**. The token's own
  `iss` and `sub` never name a profile's subject. A Sign in with Apple
  account is another subject (`https://appleid.apple.com#<sub>`): it gets
  its own profile at its first sign-in, and joins another with a
  [link code](profiles.md#linking).
- **rbacr** knows the user by `email`, as before.
- **The issuer publishes** at the site's root, as static files:
  `https://<site>/.well-known/openid-configuration` (`issuer`, `jwks_uri`
  `https://<site>/.well-known/jwks.json`, RS256) and `jwks.json` (the
  public key as a JWK, `kid` its RFC 7638 thumbprint). The auth API makes
  them (public routes `GET /api/auth/.well-known/openid-configuration`
  and `jwks.json`, `Cache-Control: public, max-age=3600`), and every
  deploy copies them to the site's bucket (`publish_session_issuer` in
  `scripts/deploy.sh`: `max-age=300`, CloudFront's copies invalidated).
  API Gateway's JWT authorizers fetch `<issuer>/.well-known/openid-configuration`
  and the keys from there; rbacr fetches the keys too.
  - **Why not the auth API's own routes:** API Gateway fetches the
    document while it imports an API, and silently drops an authorizer it
    can't fetch, with every route behind it (the stack still says it
    updated). An API being imported can't serve its own document: on
    2026-10-14 the auth API lost its protected routes that way (the
    payments API, imported a minute later from the same document, kept
    them). The issuer was `https://<site>/api/auth` until then.

## The routes

On the auth API, **without an authorizer** (each request carries its own
proof), throttled per route:

| Route | Body | Answer |
|---|---|---|
| `POST /api/auth/session` (10/s, burst 20) | `{"provider": "google" \| "apple", "idToken", "nonce"?, "authorizationCode"?, "name"?, "refresh"?}` | `{"token", "expiresAt" (epoch s), "refreshToken"}`; 400 malformed, 401 the token isn't good, 403 no verified email, 503 the provider has no clients |
| `POST /api/auth/session/refresh` (20/s, burst 50) | `{"refreshToken"}` | the same, with a new refresh token; 401 when the session ended |
| `POST /api/auth/session/revoke` (5/s, burst 10) | `{"refreshToken"}` | 204, whatever the token |

**The exchange verifies the provider's ID token itself**
(`ProviderTokens`): RS256 only, no `crit`, signed by a key of the
provider's JWKS found by `kid` (Google's
`https://www.googleapis.com/oauth2/v3/certs`, Apple's
`https://appleid.apple.com/auth/keys`; kept for their `max-age`, at most a
day; an unknown `kid` fetches again at most once a minute); `iss` the
provider's (Google's `https://accounts.google.com` or
`accounts.google.com`, both recorded as the first); `aud` one of the
stack's clients (Google: the web client, which every platform's app asks
tokens for, and the [streamer](streamer.md)'s device client; Apple:
`AppleClientIds`, the bundle ID `com.nu01.presence`); `exp` in the future
and `iat`/`nbf` not, a minute of skew; a `sub`; a verified `email`. For
Apple, the token's `nonce` must be the SHA-256 (hex) of the `nonce` the
app sends, which the app made for that sign-in. The reason a token is
refused is logged; no token ever is.

- **Apple's name** comes to the app only at the account's first Sign in
  with Apple. The app sends it (`name`), the auth API keeps it
  (`IdentitiesTable`, cleaned: no control characters, at most 100), and
  every later token of that identity (other devices, refreshes) carries
  it.
- **`"refresh": false`** answers no refresh token: the
  [streamer](streamer.md), which keeps Google's own refresh token,
  exchanges a fresh Google ID token each time.

## Refresh tokens

- **Opaque**, `prt_` and 256 random bits (base64url), kept only as their
  SHA-256 (`SessionsTable`), with who they sign in.
- **60 days, sliding:** each refresh starts the 60 days over.
- **Rotated on every use:** a refresh answers a new refresh token and uses
  the old one up (a DynamoDB transaction: the old one only if unused, the
  family only if not revoked).
- **Reuse is theft:** every sign-in starts a *family*; a used refresh
  token presented again (two copies of it exist) revokes the whole
  family, so the app falls back to signing in again (below), and whoever
  copied it gets nothing.
- **Sign-out** revokes the session's family. **Account deletion** revokes
  every family of the identity (`AccountSessions.end`, below).
- Session tokens already issued stay valid until they expire (at most an
  hour): every API verifies them offline.

## Sign in with Apple's revocation

Apple requires apps that offer Sign in with Apple to revoke the user's
Apple tokens when they delete their account.

- When the app sends the sign-in's `authorizationCode` and the stack has
  Apple's key (`AppleTeamId`, `AppleKeyId`, and the `.p8` in the SSM
  SecureString `AppleKeyParameter`), the exchange trades the code at
  `https://appleid.apple.com/auth/token` for Apple's refresh token and
  keeps it **encrypted with the stack's KMS data key** (`SessionDataKey`,
  the identity as encryption context) in `IdentitiesTable`. A failure is
  logged (Apple's error code only) and the sign-in goes on.
- Each call to Apple carries a client secret: an ES256 JWT signed with the
  `.p8` (`iss` the team, `sub` the bundle ID, `aud`
  `https://appleid.apple.com`, five minutes). The key is read from SSM
  when first needed, never logged, never in the repository or a template.
- **[Account deletion](account-deletion.md)** (`POST
  /api/auth/account/delete`) calls **`AccountSessions.end(subject)`** for
  every deleted account (a linked account's own; for the owner, every
  account of the profile): it revokes every session of the identity,
  revokes the Apple refresh token at `https://appleid.apple.com/auth/revoke`
  and forgets the identity. It answers false (and keeps the Apple token,
  to retry) when Apple can't be told; the deletion then answers 503 having
  deleted nothing more, and the app's retry finishes it. The profile
  function has the settings and permissions for it (revoking families,
  reading and forgetting identities, Apple's key and the data key's
  `kms:Decrypt`).
- Without Apple's key, nothing is kept or revoked: Apple sign-in works,
  but deleting an account can't revoke its Apple tokens.

## Keys and permissions

- **`SessionSigningKey`**: KMS, RSA_2048, SIGN_VERIFY. The private key
  never leaves KMS. Its key policy keeps administration with the account
  (IAM decides who), and allows `kms:Sign` and `kms:GetPublicKey` only to
  this stack's roles (`aws:PrincipalArn` `role/<stack>-*`) that IAM also
  allows: the session function's. Tagged `presence:stack`.
- **`SessionDataKey`** (only with Apple's key): KMS, symmetric, rotated
  yearly; `kms:Encrypt`/`kms:Decrypt` the same way.
- **The profile function** (account deletion) may: get and update
  `SessionsTable` items and query its `subject` index (revoking
  families), get, update and delete `IdentitiesTable` items, read Apple's
  key's parameter (through SSM) and decrypt with the data key.
- **The session function** may: sign with the signing key and read its
  public key; get, put, update and condition-check `SessionsTable` items
  and query its `subject` index; get, update and delete
  `IdentitiesTable` items; `ssm:GetParameter` on Apple's key's parameter
  only, decrypted through SSM (`kms:ViaService`); and use the data key.
  Without Apple's key, those name a parameter and key that don't exist.
- **The stage's permissions boundary** (`presence_infra/github-deploy.yaml`)
  allows those KMS actions only on keys tagged `presence:stack` with the
  stage's prefix, SSM parameters under `/<prefix>/`, and SSM's
  decryption; the deploy role may create KMS keys only tagged so, and
  manage only those. An administrator must deploy that stack before the
  first deploy with sessions.
- **Rotating the signing key** (asymmetric keys don't rotate in KMS):
  publish the new key beside the old in the JWKS for at least an hour
  before signing with it, then drop the old one. Not automated: today the
  JWKS has the one key, and replacing it signs everyone's session tokens
  anew within the hour (refresh tokens are unaffected).

## The tables

| Table | Key | Holds |
|---|---|---|
| `SessionsTable` | `id`: `t#<SHA-256 of a refresh token>` or `f#<family>`; index `subject` on `familySubject` | tokens: `family`, `idp`, `idpSub`, `email`, `name`, `picture`, `hd`, `used`, `expiresAt` (TTL); families: `familySubject`, `revoked`, `expiresAt` (TTL) |
| `IdentitiesTable` | `subject` (`<idp>#<sub>`) | `name` (Apple's), `appleClientId`, `appleRefreshToken` (KMS ciphertext), `updatedAt` |

Both are on-demand and encrypted, with emails (AWS only).
`IdentitiesTable` has point-in-time recovery and is kept if the stack is
deleted; losing `SessionsTable` only signs everyone out.

## The authorizers

Every Presence API's JWT authorizer trusts only session tokens: issuer
the stage's, audience `presence`.

- The auth API's (`PresenceSession`), for its routes and
  `/api/recognition/*`.
- The payments API's (`SessionIssuer`, from the auth stack's output).
- rbacr: its `RBACR_TRUSTED_ISSUERS` (built in rbacr alongside this) lists
  `[{"issuer": "https://presence.nu01.com", "jwks":
  "https://presence.nu01.com/.well-known/jwks.json",
  "audiences": ["presence"]}]` and the RC's (both stages' rbacr list both,
  and the former `…/api/auth` issuers, unused),
  and takes `email` as the identity on its self-service routes. The APIs'
  own server-side calls to rbacr (a root's API token) are unchanged.
- Google ID tokens are no longer accepted as bearers anywhere in Presence.
- **The first deploy** (`SessionAuthorizer`): API Gateway fetches an
  authorizer's `<issuer>/.well-known/openid-configuration` when it imports
  the API, and when it can't, it silently drops the authorizer and every
  route behind it (the stack still says it updated). The issuer's document
  comes from the auth API, so on a stage whose site doesn't serve it yet,
  `scripts/deploy.sh` first deploys the auth API with
  `SessionAuthorizer=bootstrap` (the same `PresenceSession` authorizer,
  on Google's issuer and the web client), copies the documents to the
  site, waits up to 5 minutes for them to be served, then deploys it again
  with `on`. Every later deploy finds the document and deploys once, `on`
  (and copies the documents again). A new stage needs its site stack
  first: the copy goes to its bucket.
  During the minutes between, the APIs take Google ID tokens, which the
  functions (reading the session claims) mostly refuse.
  - Found on 2026-10-14: the first release with session tokens
    (`0.6.202610142035`) lost those routes on both stages, the issuer's
    document not yet existing; the stage's
    throttling settings then named routes that didn't exist, the update
    failed and so did its rollback (`UPDATE_ROLLBACK_FAILED`, finished by
    hand with `continue-update-rollback`, skipping the stage, whose live
    settings were the old ones). Reproduced on a throwaway stack: an
    issuer without the document drops the routes; `bootstrap` then `on`
    keeps them and switches the issuer in place. The next release
    (`0.6.202610142110`) lost them again at `on`, the document being
    served by the API under import; the issuer moved to the site's root.
    Both times production went back to the release before.

## Clients

- **The app**: see [Sign-in](sign-in.md#sessions). Every bearer it sends
  (`AuthService.idToken`) is the session token.
- **The streamer**'s Google device sign-in: it exchanges each Google ID
  token for a session token (`"refresh": false`), cached until a minute
  before it expires, before `GET /api/auth/profile` and
  `POST /api/auth/credentials` (`presence_streamer/internal/presence`).
  Its stream-key path (`POST /api/auth/stream/credentials`) is unchanged.
  See [Streamer](streamer.md).
- **Cognito:** the auth API no longer sees a Google ID token, so it no
  longer asks Cognito for an account's Google identity (`GetId`). A
  profile without an identity gets a new one made for its developer
  identifier (`GetOpenIdTokenForDeveloperIdentity` without an identity,
  the profile ID as the login). Every profile that had credentials or a
  link code already had its identity, linked to it; see
  [Profiles](profiles.md).

## Deploy

[scripts/deploy.sh](../scripts/deploy.sh) passes `DomainName` (the
issuer), `AppleClientIds` (`APPLE_CLIENT_IDS`, default
`com.nu01.presence`) and, when the key is set, `AppleTeamId`,
`AppleKeyId` and `AppleKeyParameter` (`APPLE_TEAM_ID`, as for the App
Store build, `APPLE_SIGNIN_KEY_ID` and `APPLE_SIGNIN_KEY_PARAMETER`, a
parameter under `/<prefix>/`; environment, `.env`, or in CI the
repository variables of the same names, the RC's parameter being
`APPLE_SIGNIN_KEY_PARAMETER_RC`), checks the stack's
`SessionIssuer` output is `https://<site>`, and passes it to the
payments stack. Its smoke test requires the site's
`/.well-known/openid-configuration` to name that issuer and its
`jwks_uri`, and the JWKS to hold an RSA key.

**Order, the first time:**

1. An administrator deploys `presence-github-deploy` (the boundary's and
   deploy role's KMS and SSM permissions), and, for Apple's revocation,
   puts the `.p8` in SSM:
   `aws ssm put-parameter --type SecureString --name /presence/apple-signin-key --value file://AuthKey_<KEYID>.p8`
   (`/presence-rc/…` for the RC).
2. **rbacr** with `RBACR_TRUSTED_ISSUERS` naming the stage's issuer
   (rbacr fetches the JWKS lazily, so it may go first).
3. **Presence** (`deploy.sh`: the auth API, then payments, then the site
   and the web app).
4. **The Android and iOS builds.** Builds from before sessions send
   Google ID tokens, which every API now refuses (401) until they're
   updated; the web app updates with the deploy.

## Locally

The local stack (Floci, [Local CDN](local-cdn.md#the-local-auth-api)):

- makes the signing key with the KMS API (Floci's CloudFormation makes
  symmetric keys whatever the `KeySpec`) and passes it as `SigningKeyArn`;
  Floci keeps nothing, so each start has a new key and everyone signs in
  again;
- uses the local HTTP API's path form on Floci's loopback address as the
  issuer (`http://127.0.0.1:4566/execute-api/presence/$default/api/auth`):
  Floci's JWT authorizer fetches the issuer's documents from inside its
  container, and fetches from HTTP or private addresses only with
  `FLOCI_SECURITY_ALLOW_PRIVATE_JWT_TARGETS` (set in
  [compose.yaml](../presence_floci/compose.yaml); Floci listens on
  127.0.0.1 only) and a literal IP;
- has the session routes and the `PresenceSession` authorizer.

## Verified

- `SessionTest` (JUnit, 21 tests): a Google sign-in's session token,
  verified with the published JWKS, has every claim above; a profile's
  subject comes from `idp`/`idp_sub` only; Google's two issuer spellings
  are one identity; tokens with another audience, expired, issued in the
  future, from another issuer, without a subject, signed by another key,
  with an unknown `kid`, unsigned or malformed are refused (401), and an
  Apple token isn't Google's; an unverified email is 403; malformed
  requests 400, a provider without clients 503; `"refresh": false`
  starts no session; Apple's nonce must match; Apple's first name is kept
  and in later sessions and refreshes; an authorization code keeps
  Apple's refresh token sealed for the identity, and account deletion
  revokes it at Apple (with a valid ES256 client secret), ends every
  session of that identity only, and forgets it; Apple refusing keeps the
  token to retry; without Apple's key nothing is traded; Apple's token
  endpoint failing doesn't fail the sign-in; refreshes rotate and slide
  60 days; a reused refresh token ends the family; unused ones expire
  after 60 days; sign-out revokes; the issuer's documents; provider keys
  cached, an unknown `kid` fetching at most once a minute.
- The other auth API tests (`ProfileTest`, `ProfilesTest`,
  `ProfileBackendTest`, `LocalCloudBackendTest`, `RolesTest`) with the
  provider identity in `idp`/`idp_sub`, and a profile's identity made for
  it; recognition's and payments' tests with session claims.
- `sam validate --lint` for both stacks.

## Known limitations

- **rbacr can't verify local session tokens** (its RC can't reach the
  local issuer), so locally the app's own roles check (rbacr's
  `GET /api/me`) fails and a signed-in user sees the sign-up screen. Run
  the app against the RC (`API_BASE_URL`) to try signed-in features.
- **No absolute session lifetime:** a device that refreshes at least every
  60 days stays signed in indefinitely, until sign-out, reuse or account
  deletion.
- **Revoking a session** doesn't end its current session token, which
  lasts up to an hour.
- **Web keeps the refresh token in `localStorage`** (see
  [Sign-in](sign-in.md#sessions)): script injected into the site could
  read it. An httpOnly cookie set by the API would avoid that.
- **The local stack hasn't run end to end with sessions** (the shared
  local instance wasn't restarted for this change). Checked in Floci: the
  template deploys, the session function signs with a KMS key made by the
  API and answers the openid-configuration and JWKS, and the path-form
  issuer URL answers. Not checked: Floci's JWT authorizer accepting a
  session token, which needs the restart with
  `FLOCI_SECURITY_ALLOW_PRIVATE_JWT_TARGETS` (without it, Floci refuses
  HTTP and private issuers and every token gets 401).
