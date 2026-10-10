# Auth API (`presence_api_auth`)

[presence_api_auth/](../presence_api_auth) is a SAM application: six Java 25
Lambdas (arm64) behind one API Gateway HTTP API, under `/api/auth` on the
site (`/api/*` in the CloudFront distribution; see
[Production deploy](deploy.md)), plus the public **`GET /health`**
(`HealthHandler`), which checks the API's dependencies for Route 53 (see
[Health check](health-check.md)):

- **`GET /api/auth`** (`AuthHandler`): the signed-in user's **profile**
  and roles, `{"email": "...", "profile": "automatic_paranoid_axolotl",
  "roles": [...]}`. The profile is the one linked to the token's subject
  (`iss` and `sub`), or a new one created and linked at the first
  sign-in, for every signed-in user, with or without roles, so the same
  account gets the same profile on every device. A new one gets a fresh
  ID (or `?profile=<id>` when it's well-formed and free, which the app no
  longer sends). **Data belongs
  to the profile, not the login**: see [Profiles](profiles.md). Throttled
  to 20 requests/s (burst 50), since a first sign-in writes;
- **`GET /api/auth/anonymous`** (`AuthHandler`, the only route **without a
  token**): the [execution mode](execution-mode.md), the anonymous
  user's roles (in DEV every role) and which expected settings the stack
  has, `{"mode": "RBAC", "roles": ["presence_anonymous"], "settings":
  {"oidc": true, "aws": true, "rbacr": true}}`. The mode is DEV when the function has no
  `GOOGLE_WEB_CLIENT_ID`. Throttled to 20 requests/s (burst 50): see
  [Throttling and floods](#throttling-and-floods);
- **Settings** (`Settings`): `oidc` is whether `GOOGLE_WEB_CLIENT_ID` is
  set, `aws` whether both `COGNITO_IDENTITY_POOL_ID` and `USER_DATA_BUCKET`
  are (template parameters `IdentityPoolId` and `UserDataBucket`, empty by
  default), `rbacr` whether `RBACR_TOKEN` is (`RbacrToken`: rbacr gives every
  role; see the roles below). Only whether each is set is
  reported, never a value. The app
  shows them in its Settings health line (see [Settings
  screen](settings.md));
- **`POST /api/auth/membership`** (`MembershipHandler`): a request for
  access, and **`GET /api/auth/membership`**, **`POST …/grant`** and
  **`POST …/dismiss`** (`AdminHandler`, admins only: both roles): the
  Admin tab's. See [Membership](membership.md);
- **`POST /api/auth/voucher`** (`VoucherHandler`): redeems the voucher code
  in the plain-text body for its role, `{"role": "...", "granted":
  [...], "discount": 100}` when its discount is 100%; 402 `{"error",
  "discount"}` for a valid code with less (nothing granted or counted:
  the rest would be paid, which isn't built; so a 402 does reveal that a
  partial-discount code exists); or the same 404 for any other code that
  can't be redeemed. Throttled to 1 request/s (burst 5), and **per
  email**: after 10 wrong codes (404s) within an hour of the first, the
  email gets **429** until that hour is over, even for a good code (the
  count is kept in `UserRolesTable`, which holds nothing else now).
  **`GET /api/auth/vouchers`**,
  **`POST /api/auth/vouchers`** (form-encoded `role`, `expiresAt`
  ISO-8601, `maxUses`, and optionally `startsAt` ISO-8601, before
  `expiresAt` and at most 366 days ago, now when absent; `code`, random
  when absent or blank, at least 10 letters and digits when chosen, never
  chosen for `presence_admin` (400), 409 when taken; and `discount`, a
  percentage, 100 when absent; answers 201 with the new voucher) and
  **`POST …/vouchers/delete`** (`AdminHandler`, admins only) manage them.
  A `presence_admin` voucher's code is listed (`"code": null, "hidden":
  true` otherwise) and deleted (403 otherwise) only for a
  `presence_root`. See [Membership](membership.md#voucher-codes);
- **`POST /api/auth/credentials`** and **`/api/auth/profile/*`**
  (`ProfileHandler`): a Cognito developer-identity token for the user's
  profile (and, with `IotPolicyName` set, the [live-sync](live-sync.md) IoT
  policy attached to its identity), and listing, linking and unlinking its
  Google accounts. See [Profiles](profiles.md).

- **Authentication:** the HTTP API's **JWT authorizer** verifies the Google
  ID token in `Authorization: Bearer …`: issuer `https://accounts.google.com`,
  and audience the web OAuth client, so tokens for other apps are refused.
  `GoogleWebClientId` may be empty only for local development: the
  audience is then `no-oidc-client`, which no token matches.
  Otherwise it answers 401 before a function runs. The authorizer passes
  every claim of the token to the function (as strings); the functions
  read them in one place, `Caller`: `iss` and `sub` for the profile,
  `email` and `email_verified` for the roles, `hd` (the Google Workspace
  domain that manages the account; absent for personal accounts) kept
  with a profile's owner, and `name` for requests.
- **Roles** come from **[rbacr](https://github.com/prodbytes/rbacr)**
  alone (`Rbacr`, `Roles`), the organisation's role manager
  (https://rbacr.nu01.com), which keeps them in its `presence` system
  (`RBACR_SYSTEM`):
  - **`presence_user`** uses the app; **`presence_premium`** also syncs
    with the cloud ([Premium and free](premium.md)); **`presence_admin`**
    also approves membership requests and creates Member vouchers;
    **`presence_root`** also creates Admin vouchers;
    **`presence_anonymous`** is nobody signed in;
  - they're rbacr's roles, mapped: rbacr's `free`, `premium` or `admin`
    gives `presence_user`; `premium` or `admin` gives `presence_premium`;
    `admin` gives `presence_admin`. rbacr's implications (`admin` implies
    `premium` and `free`, `premium` implies `free`) give the same, but the
    mapping doesn't count on them. Other rbacr roles give nothing;
  - an **rbacr root** (rbacr's root list, `RBACR_ROOT_LIST`, default
    `@nu01.com`) gets all four of `presence_root`, `presence_admin`,
    `presence_premium` and `presence_user`. Nothing in presence makes a
    root; the root list is rbacr's configuration;
  - nobody has roles by default. Only a **verified** email is asked about
    (lower-cased); unverified ones get nothing. rbacr trusts the address
    (its rule C1), and matches a domain grant or root-list domain by the
    address alone, with no `hd` check: who controls a nu01.com mailbox
    controls an rbacr identity there, in rbacr's own sign-in too;
  - **one request** per email: `POST /api/roles` with the email (in the
    body, never the URL) and no `systemId`, which answers the email's
    roles in every system and its global roles (`root` for a root), with
    a root-owned API token (`RBACR_TOKEN`), since it asks about other
    people. 2 s timeout. An answer is reused for 60 s (per function
    instance), an error never;
  - it **fails closed**: when rbacr is down, slow, refuses the token or
    answers something that isn't an answer, the email has no roles, so
    nobody gets in or administers until it answers again; and without
    `RBACR_TOKEN`, nobody has a role;
  - **grants** go to rbacr: an approved membership is a grant of `free`,
    a redeemed voucher one of its role's (`free` or `admin`), each to the
    address, from now on and for good (`POST
    /api/systems/presence/grants`). rbacr keeps a grant that already does
    (its G2). A grant forgets that email's reused answer; other function
    instances see it within 60 s. Revoking, domain and global grants, and
    who is premium are managed in rbacr itself;
  - **a linked subject** also gets `presence_user` and `presence_premium`
    when its profile's owner has them (see
    [Profiles](profiles.md#the-profiles-folder-and-roles)), in every route;
    never the owner's `presence_admin` or `presence_root`, which each
    account gets only from its own email.
  - Before rbacr, the root allowlist (`PRESENCE_ROOT_DOMAINS`,
    `PRESENCE_ROOT_EMAILS`) and `UserRolesTable`'s `roles` gave them.
    `scripts/migrate-roles-to-rbacr.sh` copies the table's roles into
    rbacr (`presence_user` as `free`, `presence_admin` as `admin`); the
    API no longer reads them.
- **The tables** (`UserRolesTable`, `MembershipTable`, `VoucherTable`, and
  [`ProfilesTable` and `ProfileSubjectsTable`](profiles.md#where-its-kept)):
  on-demand, encrypted, with point-in-time recovery, and kept if the stack
  is deleted. Their contents (people's emails) live only in AWS.
  `LinkCodesTable` holds short-lived link codes (hashed, with a TTL).
  `UserRolesTable` now holds only the voucher lockout's counts (and the
  roles from before rbacr, unread).
- **Least privilege:**
  - the roles function may only get and put in `ProfileSubjectsTable`,
    and get, put and update in `ProfilesTable`;
  - the membership function may only put items in `MembershipTable`;
  - the voucher function may get and update items in `VoucherTable` and
    in `UserRolesTable` (the lockout);
  - the admin function may scan, update and delete in `MembershipTable`,
    put, scan and delete in `VoucherTable`, and get items from both
    profile tables;
  - the roles, voucher, admin and profile functions have `RBACR_TOKEN`, a
    root's rbacr token: whoever can read their configuration can manage
    rbacr as that root. It's a `NoEcho` parameter, never in the
    repository; give it an expiry and rotate it;
  - the profile function's permissions are listed in
    [Profiles](profiles.md#where-its-kept). One is broad:
    `iot:AttachPolicy` on `*` (with `IotPolicyName` set), since IAM can
    scope that action only to certificates and thing groups, not to a
    Cognito identity target or a policy. The function only ever attaches
    `IotPolicyName` to the caller's own profile identity; a compromised
    function could attach any IoT policy in the account to any principal.
    Moving it to a separate, minimal function would only narrow which
    code holds it, so it stays, documented.
- **AWS clients and errors:** each function makes one HTTP client and one
  DynamoDB client per instance (`Aws`), shared by its stores. When AWS (or
  anything unexpected) fails, every handler answers **502** `{"error":
  "the <auth|membership|voucher|admin|profile> service failed", "cause":
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
- the token routes need a valid Google ID token for the web client, which
  anyone can get with a free Google account, so their limits (1 request/s
  for membership requests, vouchers and link codes) can be used up the
  same way, blocking those actions for everyone meanwhile.

The fix is a **per-IP rate rule** (AWS WAF rate-based rules on the
CloudFront distribution, scoped to `/api/*` and `/health`), which blocks
one address's flood without touching anyone else. It isn't deployed: WAF
costs a monthly fee per web ACL and rule plus a per-request charge, which
is an infrastructure and cost decision. Until then the per-route limits,
the voucher lockout per email and the membership cooldown per email are
what slow abuse.
- **Deploy:** `scripts/deploy.sh` runs `sam build` and `sam deploy` (stacks
  `presence-auth-api` and `presence-rc-auth-api`) before the site, and passes
  the stack's `ApiDomain` output to `site.yaml`. The smoke test requires
  `/api/auth` to answer **401** without a token, which proves the route and
  its authorizer are live, and `/api/auth/anonymous` to report RBAC with
  both settings set. `deploy.sh` passes the identity pool and bucket from
  their stacks' outputs.
- **The app** calls it after sign-in to decide what to show (see
  [Sign-in](sign-in.md)): without `presence_user`, only the account and
  sign-up.
- **Locally,** the auth API runs inside Floci (see
  [Local CDN](local-cdn.md#the-local-auth-api)): the same Lambdas and
  tables, deployed from this template at every start, behind an HTTP
  API with the same Google JWT authorizer. Nothing local reaches AWS; the
  roles still come from the rbacr `.env` names.
- **Tests** (JUnit, `mvn test`):
  - profiles (`ProfilesTest`): found by subject, created and linked at a
    first sign-in, never a repeated ID, races; see
    [Profiles](profiles.md#verified);
  - the role rules (`RolesTest`): default none, rbacr's roles mapped
    (`free`, `premium`, `admin`, roots every role, other roles nothing),
    verified emails only and lower-cased, unverified ones never asked;
  - rbacr (`RbacrTest`, against a fake transport): one `POST /api/roles`
    per email (in the body, no `systemId`), only the presence system's
    roles, `root` only from `globalRoles`, answers reused 60 s, failures
    closed and never reused, malformed answers refused; grants (`POST
    …/grants`), a grant forgetting the reused answer, refused or failed
    grants throwing, and no token: no roles, no grants;
  - `UserRoles` (`UserRolesTest`, against a fake table): the lockout's
    window, writing only its counts;
  - a failing store answers a sanitized 502;
  - the execution mode: DEV only without a client; the anonymous route's
    answer in RBAC and DEV, with its settings (AWS needs both the pool and
    the bucket);
  - the handler's JSON: profile, roles, no roles, no claims, escaping;
  - membership requests: verified email, empty and long messages, base64
    bodies, the hourly cooldown;
  - the admin routes: 403 without both roles, listing, grant, dismiss
    (which keeps the cooldown), bad emails, unknown routes;
  - profile names are cleaned to one short line;
  - vouchers: the code format and loose typing, chosen codes; admins
    only; creation's role, start, expiry, uses, code and discount checks
    (chosen codes of at least 10 letters and digits, never for
    `presence_admin`); Admin codes hidden from, and not deletable by,
    non-roots; the per-email lockout (402s don't count; others aren't
    locked; it ends with its hour); a
    taken code (409); the discount stored and answered; a partial
    discount answered 402, granting nothing and counting no use; newest first; deletion; redeeming once
    per email, running out, not yet started, expiring, unknown codes, verified emails, an
    Admin voucher granting rbacr's `admin` (`presence_user`,
    `presence_premium` and `presence_admin`), a Member one `free`, a failed grant giving the
    use back (and answering 502), only roots creating Admin vouchers, and
    no root vouchers;
  - profiles, linking and the owner's membership (`ProfileTest`; see
    [Profiles](profiles.md#verified)).
  - the whole flow: an rbacr root gets every role; another user gets
    none, asks, is granted `free` by an admin, and becomes a
    `presence_user` only.
