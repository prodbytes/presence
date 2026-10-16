# presence_api_auth

The Presence auth API: an [AWS SAM](https://aws.amazon.com/serverless/sam/)
application with Java 25 Lambdas (`java25`, arm64) behind one API
Gateway **HTTP API**, served under **`/api/auth`** by the site's CloudFront
distribution.

| Route | Who | Does |
|-------|-----|------|
| `GET /api/auth/anonymous` | anyone (no token) | the execution mode, the anonymous user's roles and which settings are set: `{"mode": "RBAC", "roles": ["presence_anonymous"], "settings": {"oidc": true, "aws": true, "rbacr": true}}` |
| `POST /api/auth/session` | anyone (no token: the provider's ID token is the proof) | trades a Google or Apple ID token for a Presence session: `{"token", "expiresAt", "refreshToken"}` (no refresh token with `"refresh": false`) |
| `POST /api/auth/session/refresh` | anyone (the refresh token is the proof) | a new session token and a new refresh token; the old one is used up |
| `POST /api/auth/session/revoke` | anyone (the refresh token is the proof) | ends that session (sign-out); 204 |
| `GET /api/auth/.well-known/openid-configuration`, `/jwks.json` | anyone | the session issuer's documents and public key, for the APIs' JWT authorizers and rbacr |
| `GET /api/auth/profile` | anyone signed in | the caller's profile (found, or created at the first sign-in), the roles it shares from the profile's owner and its accounts: `{"profile": "automatic_paranoid_axolotl", "shared": ["presence_premium", "presence_user"], "accounts": [{"email", "owner", "current"}]}` |
| `POST /api/auth/credentials` | `presence_user` | the profile's Cognito token for cloud sync |
| `POST /api/auth/profile/link-code`, `/link`, `/unlink`, `/devices/remove` | signed in | link accounts to a profile, and its devices |
| `POST /api/auth/account/delete` | signed in | deletes the caller's account (the owner's whole profile, or a linked account alone) and ends its sign-ins: every Presence session, and its Sign in with Apple tokens at Apple (503, deleting nothing more, when Apple can't be told) |

The app asks [rbacr](https://rbacr.nu01.com) directly, with the user's
Presence session token, for the user's own roles, maintenance mode and voucher
redemption; admins manage vouchers and maintenance in rbacr. Users get
`presence_user` by subscribing at nu01.com or redeeming a voucher (both
rbacr's), or by Join free in the iOS and Android apps (the payments API
grants rbacr's `free`); there are no membership requests.

- **Sessions** ([specs/sessions.md](../specs/sessions.md)): the session
  function trades a Google or Apple ID token for a Presence **session
  token** (RS256 JWT, 1 hour, issuer `https://<site>/api/auth`, audience
  `presence`, with `email`, `email_verified`, `name`, `picture`, `idp` and
  `idp_sub`) and a rotating **refresh token** (60 days, sliding; a reused
  one ends its whole family). Google tokens must be for the web client or
  the streamer's device client (`GoogleWebClientId`,
  `GoogleDeviceClientId`), Apple's for `AppleClientIds`. Its classes:
  `SessionHandler` (the routes), `ProviderTokens` (verifies the
  provider's ID token against its JWKS), `Sessions` (sign-in, refresh,
  revoke), `SessionTokens` (the token's claims), `SessionSigner` (signs
  with KMS, publishes the JWKS), `DynamoSessions` (the tables),
  `AppleAccounts` (Apple's refresh token, kept encrypted, and its
  revocation) and `AccountSessions` (ends an identity's sign-ins).
- **Who's calling:** the HTTP API's JWT authorizer (`PresenceSession`)
  checks the session token first: signature, expiry, the stage's issuer,
  and audience `presence`. A missing, expired, forged or foreign token
  (Google's own ID tokens included) gets **401** and never reaches a
  function. The functions read the verified `idp`, `idp_sub`, `email`,
  `email_verified`, `hd` and `name` claims (the authorizer passes every
  claim through), in one place:
  [Caller.java](AuthFunction/src/main/java/presence/auth/Caller.java).
- **Profiles** ([Profiles.java](AuthFunction/src/main/java/presence/auth/Profiles.java)):
  data belongs to a **profile**, not to a login, so users can change
  emails, providers or add collaborators without losing it. Each subject
  (`<idp>#<idp_sub>`, the provider's issuer and subject, as profiles were
  keyed when the bearer was Google's ID token) is linked to one profile in **`ProfileSubjectsTable`**;
  a first sign-in creates a profile in **`ProfilesTable`** and links the
  subject, so the next sign-in finds it. Profile IDs
  ([ProfileId.java](AuthFunction/src/main/java/presence/auth/ProfileId.java))
  are two different adjectives and an animal, `automatic_paranoid_axolotl`,
  from about 1.14 billion, and a conditional put guarantees no two
  profiles share one. See [specs/profiles.md](../specs/profiles.md).
- **Roles** ([Roles.java](AuthFunction/src/main/java/presence/auth/Roles.java),
  [Rbacr.java](AuthFunction/src/main/java/presence/auth/Rbacr.java)) all
  come from [rbacr](https://github.com/prodbytes/rbacr), its `presence`
  system (`RbacrUrl`, `RbacrToken`, `RbacrSystem`):
  - `presence_user` (rbacr's `free`, `premium` or `admin`) uses the app;
    `presence_premium` (`premium` or `admin`) also syncs with the cloud;
    `presence_admin` (`admin`) also administers it (vouchers and
    maintenance mode are managed in rbacr); `presence_root` (an rbacr
    root, from its root list) gets every role;
  - nobody has roles by default, and only a verified email is asked
    about: one `POST /api/roles` per email, answers reused 60 s, failing
    closed (no answer, no roles);
  - the token must be an rbacr root's: it asks about anyone (a profile's
    owner, for its linked accounts);
  - an account linked to a profile another account owns gets
    `presence_user` and `presence_premium` when the owner has them, never
    the owner's `presence_admin` or `presence_root` (`Roles.shared`, the
    listing's `shared`); credentials use the caller's own roles plus
    those.
- The tables' contents (people's emails) live only in AWS, never in this
  repository. The old `UserRolesTable`, `VoucherTable` (both retained) and
  `SystemTable` are no longer part of the stack: vouchers and maintenance
  mode are rbacr's.
- **Cognito:** a profile without an identity gets a new one made for its
  developer identifier (`GetOpenIdTokenForDeveloperIdentity`, the profile
  ID as the login); the API never sees a Google token, so it no longer
  calls `GetId`.
- **Account deletion ends sign-ins:** `POST /api/auth/account/delete`
  calls `AccountSessions.end` for each deleted account, which revokes its
  session families, revokes its Sign in with Apple refresh token at Apple
  and forgets the identity.
- **Least privilege:** the anonymous function uses no table and only
  reports whether its settings are set; the session function may only
  sign with `SessionSigningKey` and read its public key, use
  `SessionsTable` and `IdentitiesTable`, and (with Apple's key) read the
  `.p8`'s SSM parameter and use `SessionDataKey`; the profile function may
  only use the profile, subject, link-code, stream-key, session and
  identity tables, the identity pool, the bucket listing and IoT's
  AttachPolicy (and, for account deletion, the folder's objects, the
  recognition and feedback tables, IoT's DetachPolicy, deleting the
  identity, and Apple's key). The rbacr token is a root's, so keep it
  secret and rotate it.
- **Keys and tables for sessions:** `SessionSigningKey` (KMS, RSA_2048,
  SIGN_VERIFY: the private key never leaves KMS), `SessionDataKey` (KMS,
  symmetric, only with Apple's key: seals Apple's refresh tokens),
  `SessionsTable` (refresh tokens, as SHA-256 hashes, and their families)
  and `IdentitiesTable` (Apple's name and encrypted refresh token per
  identity; point-in-time recovery, kept if the stack is deleted).

| Path | Holds |
|------|-------|
| [template.yaml](template.yaml) | The tables, the KMS keys, the HTTP API with its session JWT authorizer, and the functions |
| [AuthFunction/](AuthFunction) | Maven project (`presence.auth.AuthHandler`, `ProfileHandler`, `SessionHandler` and the session classes, `Roles`, `Profiles`, `ProfileId` and its word lists) with its tests |
| [samconfig.toml](samconfig.toml) | Default `sam build` / `deploy` settings (stack `presence-auth-api`) |

## Commands

From this folder, inside devbox:

```bash
(cd AuthFunction && mvn test)   # unit tests
sam validate --lint
sam build
```

`scripts/deploy.sh` deploys it as `presence-auth-api` (or
`presence-rc-auth-api` with `STAGE=rc`), passing the site's web client ID,
its domain (the session issuer) and Sign in with Apple's settings; its
`SessionIssuer` output goes to the payments stack.
Its outputs export the tables' names (`<stack>-ProfilesTable`,
`-ProfileSubjectsTable`, `-LinkCodesTable`) for the health check,
[presence_health](../presence_health) (`GET /health`). CloudFormation
won't remove an export another stack imports, so `deploy.sh` deploys an
existing health stack before this one (and a new stage's after it).
