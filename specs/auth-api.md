# Auth API (`presence_api_auth`)

[presence_api_auth/](../presence_api_auth) is a SAM application: four Java 25
Lambdas (arm64) behind one API Gateway HTTP API, under `/api/auth` (and
`/api/recognition`) on the
site (`/api/*` in the CloudFront distribution; see
[Production deploy](deploy.md)). It's slim: the signed-in user's **own
roles**, [maintenance mode](maintenance.md) and
[voucher codes](membership.md#voucher-codes) are
[rbacr](https://github.com/prodbytes/rbacr)'s, which the app asks
directly with the user's session token (see the roles below). The
public **`GET /health`**, which checks the API's dependencies for Route
53, is its own module, [presence_health](../presence_health) (see
[Health check](health-check.md)): the auth API stack exports its table
names (`<stack>-ProfilesTable`, `-ProfileSubjectsTable`,
`-LinkCodesTable`) for it, and CloudFormation won't remove or change
them while the health stack imports them. The API's routes:

- **`GET /api/auth/anonymous`** (`AuthHandler`, `AuthFunction`, the only
  route **without a token**): the [execution mode](execution-mode.md),
  the anonymous user's roles (in DEV every role) and which expected
  settings the stack has, `{"mode": "RBAC", "roles":
  ["presence_anonymous"], "settings": {"oidc": true, "aws": true,
  "rbacr": true}}`. The mode is DEV when the function has no
  `GOOGLE_WEB_CLIENT_ID`. Throttled to 20 requests/s (burst 50): see
  [Throttling and floods](#throttling-and-floods). `AuthHandler` answers
  no other route (404);
- **Settings** (`Settings`): `oidc` is whether `GOOGLE_WEB_CLIENT_ID` is
  set, `aws` whether both `COGNITO_IDENTITY_POOL_ID` and `USER_DATA_BUCKET`
  are (template parameters `IdentityPoolId` and `UserDataBucket`, empty by
  default), `rbacr` whether `RBACR_TOKEN` is (`RbacrToken`: without it the
  auth API can't tell a linked account's shared membership or a
  profile's tier; see the roles below). Only whether each is set is
  reported, never a value. The app
  shows them in its Settings health line (see [Settings
  screen](settings.md));
- **`GET /api/auth/profile`** (`ProfileHandler`, `ProfileFunction`): the
  signed-in user's **profile**, `{"profile": "automatic_paranoid_axolotl",
  "shared": [...], "accounts": [{email, owner, current}]}`. The profile
  is the one linked to the token's subject (`iss` and `sub`), or a new
  one created and linked at the first sign-in, for every signed-in user,
  with or without roles, so the same account gets the same profile on
  every device (a new one gets a fresh ID; `?profile=` is ignored).
  `shared` is what a linked account shares from the profile's owner
  (`presence_user` and/or `presence_premium` when the owner has them;
  never admin or root; `[]` for the owner); `accounts` the profile's
  Google accounts, the owner first. The app asks it at every sign-in,
  with rbacr's `GET /api/me` (see [Sign-in](sign-in.md)). **Data belongs
  to the profile, not the login**: see [Profiles](profiles.md).
  Throttled to 20 requests/s (burst 50), since a first sign-in writes;
- **`POST /api/auth/credentials`** and **`/api/auth/profile/*`**
  (`ProfileHandler`): a Cognito developer-identity token for the user's
  profile (and, with `IotPolicyName` set, the [live-sync](live-sync.md) IoT
  policy attached to its identity), and linking and unlinking its
  Google accounts (link and unlink answer the same as the listing). The
  credentials also list the profile's devices and
  how many show (2 free, 50 premium), and name the user-data bucket
  (`bucket`, when the stack has one: the [streamer](streamer.md), which has
  no build-time settings, reads it there); `POST
  /api/auth/profile/devices/remove` takes a deleted device off the list
  (and deletes its stream key).
  See [Profiles](profiles.md) and [Premium and free](premium.md#devices).
- **Sessions** (`SessionHandler`, `SessionFunction`; no authorizer, the
  request carries its proof): **`POST /api/auth/session`** trades a
  Google or Apple ID token for a Presence session (a KMS-signed session
  token and a refresh token), **`/api/auth/session/refresh`** rotates it,
  **`/api/auth/session/revoke`** ends it, and **`GET
  /api/auth/.well-known/openid-configuration`** and **`jwks.json`**
  publish the issuer and its key. See [Sessions](sessions.md).
- **`POST /api/auth/profile/stream-key`** (a member) and **`POST
  /api/auth/stream/credentials`** (no authorizer: the stream key is the
  proof): a Raspberry Pi's [stream key](streamer.md#the-stream-key), and
  the profile's credentials for it, with no Google sign-in on the Pi.
- **`POST /api/auth/account/delete`** (`ProfileHandler`, any verified
  account, the body the profile ID the app shows): deletes the caller's
  account. A linked account leaves the profile (its link and its own
  Feedback and Help messages); the profile's owner deletes the whole
  profile (its folder in the user-data bucket, its Feedback and Help
  conversation, its Cognito identity with live sync's IoT policy, its
  cloud recognition data, stream keys and link codes, every account's
  link and the profile). Every deleted account's sign-ins end: its
  sessions are revoked and a Sign in with Apple account's Apple tokens
  revoked at Apple (`AccountSessions`; 503, deleting nothing more, when
  Apple can't be told). Idempotent; 202 while a big folder is still
  being deleted. Throttled to 1 request/s (burst 5). See [Account
  deletion](account-deletion.md#the-api).
- No roles, maintenance or voucher routes (removed on 2026-10-10 with
  `GET /api/auth`, `POST /api/auth/voucher`, `/api/auth/vouchers`,
  `/api/auth/maintenance`, `VoucherHandler` and `AdminHandler`): the app
  asks rbacr. No request-for-access routes: people subscribe at nu01.com
  (`MembershipHandler` was removed on 2026-10-10). See
  [Membership](membership.md);
- No feedback routes: the app reads and writes Feedback and Help
  straight to its DynamoDB table with the profile's credentials
  (`FeedbackHandler` was removed on 2026-10-10). For it, `POST
  /api/auth/credentials` tags an administrator's credentials `admin`
  (from their own email's roles). See [Feedback and
  Help](feedback.md#storage-and-access-no-api);
- **`/api/recognition/*`** (`TrainingHandler`, `InferenceHandler`, in
  their own jar, `RecognitionFunction`, built by the Makefile): premium
  profiles' [cloud recognition](cloud-recognition.md) with DINOv2-L, its
  status, labels and training, and identifying a clip's people and pets;
  the `RecognitionTable` keeps each profile's labels' embeddings and
  model.

- **Authentication:** the HTTP API's **JWT authorizer**
  (`PresenceSession`) verifies the Presence session token in
  `Authorization: Bearer …`: issuer the stage's
  (`https://<DomainName>/api/auth`), audience `presence`. Google ID
  tokens are no longer accepted: the exchange verifies them (audience the
  web OAuth client, or the [streamer](streamer.md)'s device sign-in client,
  `GoogleDeviceClientId`, when set), and Apple's (audience
  `AppleClientIds`). A missing, expired, forged or foreign token gets 401
  before a function runs. The authorizer passes every claim of the token
  to the function (as strings); the functions read them in one place,
  `Caller`: `idp` and `idp_sub` (the provider's issuer and subject, so
  `<idp>#<idp_sub>` is the subject profiles were always keyed by) for the
  profile, `email` and `email_verified` for the roles, `hd` (the Google
  Workspace domain that manages the account; absent for personal and
  Apple accounts) kept with a profile's owner, and `name` for requests.
  Without `GoogleWebClientId` (DEV, local only), no Google exchange works.
- **Roles** come from **[rbacr](https://github.com/prodbytes/rbacr)**
  alone, the organisation's role manager (https://rbacr.nu01.com), which
  keeps them in its `presence` system (`RBACR_SYSTEM`):
  - **`presence_user`** uses the app; **`presence_premium`** also syncs
    with the cloud ([Premium and free](premium.md)); **`presence_admin`**
    also uses the Admin tab (feedback); **`presence_root`** is an rbacr
    root; **`presence_anonymous`** is nobody signed in;
  - they're rbacr's roles, mapped (`Roles` here, `presenceRoles` in the
    app's [lib/auth/rbacr_client.dart](../presence_app/lib/auth/rbacr_client.dart),
    the same rules): rbacr's `free`, `premium` or `admin` gives
    `presence_user`; `premium` or `admin` gives `presence_premium`;
    `admin` gives `presence_admin`. rbacr's implications (`admin` implies
    `premium` and `free`, `premium` implies `free`) give the same, but the
    mapping doesn't count on them. Other rbacr roles give nothing;
  - an **rbacr root** (rbacr's root list, `RBACR_ROOT_LIST`, default
    `@nu01.com`) gets all four of `presence_root`, `presence_admin`,
    `presence_premium` and `presence_user`. Nothing in presence makes a
    root; the root list is rbacr's configuration;
  - **the app asks rbacr for the user's own roles** (`GET /api/me`, with
    the user's session token, which rbacr trusts through its
    `RBACR_TRUSTED_ISSUERS`, identity `email`; see
    [Sessions](sessions.md#the-authorizers)), and
    its maintenance mode and vouchers the same way: see
    [Sign-in](sign-in.md), [Maintenance mode](maintenance.md) and
    [Membership](membership.md). The root rbacr token never reaches the
    app;
  - **the auth API asks rbacr** only where the app can't: a profile's
    tier and admin tags on its credentials (`POST /api/auth/credentials`)
    and what a linked account shares from its owner (`shared`). Only a
    **verified** email is asked about (lower-cased); unverified ones get
    nothing. rbacr trusts the address (its rule C1), and matches a domain
    grant or root-list domain by the address alone, with no `hd` check:
    who controls a nu01.com mailbox controls an rbacr identity there, in
    rbacr's own sign-in too;
  - **one request** per email (`Rbacr`): `POST /api/roles` with the email
    (in the body, never the URL) and no `systemId`, which answers the
    email's roles in every system and its global roles (`root` for a
    root), with a root-owned API token (`RBACR_TOKEN`), since it asks
    about other people. 2 s timeout. An answer is reused for 60 s (per
    function instance), an error never;
  - it **fails closed**: when rbacr is down, slow, refuses the token or
    answers something that isn't an answer, the email has no roles; and
    without `RBACR_TOKEN`, nobody has a role here (no shared membership,
    free credentials);
  - nothing here **grants** roles: rbacr's own pages, vouchers and
    Substack sync do;
  - **a linked subject** also gets `presence_user` and `presence_premium`
    when its profile's owner has them (`Roles.shared`; see
    [Profiles](profiles.md#the-profiles-folder-and-roles)), in every route
    and in `shared`; never the owner's `presence_admin` or
    `presence_root`, which each account gets only from its own email.
- **Sessions' tables** (`SessionsTable`, `IdentitiesTable`) and KMS keys:
  see [Sessions](sessions.md#the-tables).
- **The tables** ([`ProfilesTable` and
  `ProfileSubjectsTable`](profiles.md#where-its-kept)): on-demand,
  encrypted, with point-in-time recovery, and kept if the stack is
  deleted. Their contents (people's emails) live only in AWS.
  `LinkCodesTable` holds short-lived link codes (hashed, with a TTL).
  `StreamKeysTable` holds the streamers' keys (hashed), by
  `<profile>/<device>`, kept on stack deletion, with point-in-time
  recovery.
  Tables that left the stack but are kept in AWS (`DeletionPolicy:
  Retain`) until deleted by hand: `UserRolesTable` (the old voucher
  lockout's counts, and the roles from before rbacr) and `VoucherTable`
  (the old voucher codes), both since 2026-10-10; `MembershipTable`, with
  the access requests sent before 2026-10-10; and `FeedbackTable`, with
  the conversations from before Feedback moved to the app. `SystemTable`
  (the old maintenance mode) was deleted with the stack update.
- **Least privilege:**
  - the anonymous function (`AuthFunction`) has no IAM policies: only
    `GOOGLE_WEB_CLIENT_ID`, `COGNITO_IDENTITY_POOL_ID`, `USER_DATA_BUCKET`
    and `RBACR_TOKEN`, the last only to report `rbacr: true`;
  - the profile function has `RBACR_TOKEN`, a root's rbacr token
    (as has the anonymous one): whoever can read their configuration can
    manage rbacr as that root. It's a `NoEcho` parameter, never in the
    repository; give it an expiry and rotate it;
  - the session function signs with the stack's KMS key and reads its
    public key, keeps refresh tokens and identities in their tables, and
    reads Sign in with Apple's key from SSM; the profile function may also
    revoke sessions, read and forget identities and open their Apple
    tokens, for account deletion. See [Sessions](sessions.md#keys-and-permissions);
  - the profile function's permissions are listed in
    [Profiles](profiles.md#where-its-kept). One is broad:
    `iot:AttachPolicy` on `*` (with `IotPolicyName` set), since IAM can
    scope that action only to certificates and thing groups, not to a
    Cognito identity target or a policy. The function only ever attaches
    `IotPolicyName` to the caller's own profile identity; a compromised
    function could attach any IoT policy in the account to any principal.
    Moving it to a separate, minimal function would only narrow which
    code holds it, so it stays, documented. `iot:DetachPolicy` (account
    deletion) is the same, on `*`;
  - for [account deletion](account-deletion.md#least-privilege), the
    profile function may also delete profiles, scan the link-code and
    stream-key tables, query and delete the profile's recognition items
    and Feedback messages (`FeedbackTable`, a template parameter),
    `DeleteIdentities` in this pool, and `s3:DeleteObject` on any key of
    the user-data bucket: IAM can't narrow it to the caller's folder,
    known only at run time, so the function deletes only the caller's own
    profile's `<identity ID>/` (an identity-shaped prefix, never empty).
    A compromised function could delete any profile's cloud data.
- **AWS clients and errors:** each function makes one HTTP client and one
  DynamoDB client per instance (`Aws`), shared by its stores. When AWS (or
  anything unexpected) fails, the profile routes answer **502** `{"error":
  "the profile service failed", "cause":
  "<service> <operation>: <error code> (HTTP <status>)", "requestId"}`:
  which service and error, never AWS's message (it names ARNs); the full
  error is in the function's log under the request ID.
- **Responses** are `application/json` with `Cache-Control: no-store`, and
  CloudFront doesn't cache `/api/*` either.

## Throttling and floods

API Gateway's route throttles (`RouteSettings` in the template) are
**per route, for all callers together**, not per caller. They cap what a
flood costs (Lambda invocations, DynamoDB writes), but a flood from one
address uses up a route's budget for everyone:

- **`GET /api/auth/anonymous`** (no token, 20 requests/s, burst 50) is
  the one anybody can flood without even a Google account. While it's
  flooded, every app start gets 429 from its first check, so the app
  can't start signed-in features until the flood stops: a cheap
  denial of service. Raising the limit only raises the flood needed (and
  the bill), so it stays;
- the token routes need a session token, which anyone can get with a
  free Google account (or an Apple ID on an iPhone), so their limits (1
  request/s for making and using link codes and for deleting accounts) can
  be used up the same way, blocking those actions for everyone meanwhile;
  so can the session routes' (10 exchanges/s, 20 refreshes/s), which would
  stop sign-ins and refreshes meanwhile.

The fix is a **per-IP rate rule** (AWS WAF rate-based rules on the
CloudFront distribution, scoped to `/api/*` and `/health`, the health
check's own API), which blocks
one address's flood without touching anyone else. It isn't deployed: WAF
costs a monthly fee per web ACL and rule plus a per-request charge, which
is an infrastructure and cost decision. Until then the per-route limits
are what slow abuse. (Guessing voucher codes is rbacr's to slow: its
redeem route answers 429 when throttled, and it records every failed
attempt.)
- **Deploy:** `scripts/deploy.sh` runs `sam build` and `sam deploy` (stacks
  `presence-auth-api` and `presence-rc-auth-api`, uploading to the stage's
  own artifact bucket, `<prefix>-sam-artifacts-<account>`, and with
  `PermissionsBoundary`, the stage's boundary, on every function role; see
  [Production deploy](deploy.md#github-access)) before the site, and
  passes the stack's `ApiDomain` output to `site.yaml`. The health stack
  goes first when it already exists (so it stops importing an export the
  auth API drops in the same deploy), after the auth API for a new stage
  (see [Health check](health-check.md)). The smoke test requires
  `/api/auth/profile` to answer **401** without a token, which proves the
  route and its authorizer are live, `/api/auth/anonymous` to answer
  exactly `{"mode":"RBAC","roles":["presence_anonymous"],"settings":{"oidc":true,"aws":true,"rbacr":true}}`,
  the openid-configuration to name the stage's issuer and the JWKS to
  hold an RSA key. `deploy.sh` passes `DomainName` (the issuer) and Sign
  in with Apple's settings ([Sessions](sessions.md#deploy)).
  `deploy.sh` passes the identity pool, bucket and Feedback table
  (`FeedbackTable`, for account deletion) from their stacks' outputs,
  and exports the stage's `RBACR_URL` and `RBACR_SYSTEM` (never
  the token) for the app's build (see [Configuration](configuration.md)).
- **The app** calls it, and rbacr, after sign-in to decide what to show
  (see [Sign-in](sign-in.md)): without `presence_user`, only the account
  and sign-up.
- **Locally,** the auth API runs inside Floci (see
  [Local CDN](local-cdn.md#the-local-auth-api)): the same Lambdas and
  tables, deployed from this template at every start, behind an HTTP
  API with the same session authorizer (its issuer the local API on
  Floci's loopback address; [Sessions](sessions.md#locally)). Nothing local reaches AWS; its
  rbacr is rbacr's RC (https://rc.rbacr.nu01.com, `RBACR_RC_*` in
  `.env`), as is the local web build's, while prod's is GA rbacr
  (https://rbacr.nu01.com): `deploy.sh` refuses any other rbacr for prod.
- **Tests** (JUnit, `mvn test`):
  - profiles (`ProfilesTest`): found by subject, created and linked at a
    first sign-in, never a repeated ID, races; see
    [Profiles](profiles.md#verified);
  - the role rules (`RolesTest`): default none, rbacr's roles mapped
    (`free`, `premium`, `admin`, roots every role, other roles nothing),
    verified emails only and lower-cased, unverified ones never asked;
    what a linked account shares (membership and premium, never
    administration; nothing for the owner);
  - rbacr (`RbacrTest`, against a fake transport): one `POST /api/roles`
    per email (in the body, no `systemId`), only the presence system's
    roles, `root` only from `globalRoles`, answers reused 60 s, failures
    closed and never reused, malformed answers refused, and no token: no
    roles;
  - the execution mode: DEV only without a client; the anonymous route's
    answer in RBAC and DEV, exactly what the deploy's smoke test expects,
    with its settings (AWS needs both the pool and the bucket); the
    handler answering only that route;
  - profiles, linking, the listing (made at the first sign-in, with
    `shared`), the owner's membership and the credentials' tags, only an
    administrator's own tagged `admin` (`ProfileTest`,
    `ProfileBackendTest`; see [Profiles](profiles.md#verified));
  - account deletion: the owner's whole profile, a linked account's link
    only, retries, the profile ID check, a big folder over several
    requests, the folder deleted a page at a time and only an identity's,
    the identity and its IoT policy, the profile's records only
    (`ProfileTest`, `ProfileBackendTest`; see [Account
    deletion](account-deletion.md#tests));
  - account deletion ends every deleted account's sign-ins (the owner's
    every account's, a linked account's own), and stops with 503 when
    Apple can't be told (`ProfileTest`);
  - sessions: the exchange, the session token, refresh tokens and
    Apple's revocation (`SessionTest`; see [Sessions](sessions.md#verified));
  - a failing store answers a sanitized 502.
