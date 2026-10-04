# Auth API (`presence_api_auth`)

[presence_api_auth/](../presence_api_auth) is a SAM application: four Java 25
Lambdas (arm64) behind one API Gateway HTTP API, under `/api/auth` on the
site (`/api/*` in the CloudFront distribution; see
[Production deploy](deploy.md)):

- **`GET /api/auth`** (`AuthHandler`): the signed-in user's **profile**
  and roles, `{"email": "...", "profile": "automatic_paranoid_axolotl",
  "roles": [...]}`. The profile is the one linked to the token's subject
  (`iss` and `sub`), or a new one created and linked at the first
  sign-in, for every signed-in user, with or without roles. The new one
  takes the app's own profile ID (`?profile=<id>`) when it's well-formed
  and free, so the first sign-in claims the profile the app made. **Data belongs
  to the profile, not the login**: see [Profiles](profiles.md). Throttled
  to 20 requests/s (burst 50), since a first sign-in writes;
- **`GET /api/auth/anonymous`** (`AuthHandler`, the only route **without a
  token**): the [execution mode](execution-mode.md), the anonymous
  user's roles (in DEV every role) and which expected settings the stack
  has, `{"mode": "RBAC", "roles": ["presence_anonymous"], "settings":
  {"oidc": true, "aws": true}}`. The mode is DEV when the function has no
  `GOOGLE_WEB_CLIENT_ID`. Throttled to 20 requests/s (burst 50);
- **Settings** (`Settings`): `oidc` is whether `GOOGLE_WEB_CLIENT_ID` is
  set, `aws` whether both `COGNITO_IDENTITY_POOL_ID` and `USER_DATA_BUCKET`
  are (template parameters `IdentityPoolId` and `UserDataBucket`, empty by
  default). Only whether each is set is reported, never a value. The app
  shows them in its Settings health line (see [Settings
  screen](settings.md));
- **`POST /api/auth/membership`** (`MembershipHandler`): a request for
  access, and **`GET /api/auth/membership`**, **`POST …/grant`** and
  **`POST …/dismiss`** (`AdminHandler`, admins only: both roles): the
  Admin screen's. See [Membership](membership.md);
- **`POST /api/auth/voucher`** (`VoucherHandler`): redeems the voucher code
  in the plain-text body for its role, `{"role": "...", "granted":
  [...], "discount": 100}` when its discount is 100%; 402 `{"error",
  "discount"}` for a valid code with less (nothing granted or counted:
  the rest would be paid, which isn't built); or 404 for any code that
  can't be redeemed;
  throttled to 1 request/s (burst 5). **`GET /api/auth/vouchers`**,
  **`POST /api/auth/vouchers`** (form-encoded `role`, `expiresAt`
  ISO-8601, `maxUses`, and optionally `startsAt` ISO-8601, before
  `expiresAt` and at most 366 days ago, now when absent; `code`, random when absent or
  blank, 409 when taken; and `discount`, a percentage, 100 when absent;
  answers 201 with the new voucher) and **`POST
  …/vouchers/delete`** (`AdminHandler`, admins only) manage them. See
  [Membership](membership.md#voucher-codes);
- **`POST /api/auth/credentials`** and **`/api/auth/profile/*`**
  (`ProfileHandler`): a Cognito developer-identity token for the user's
  profile, and listing, linking and unlinking its Google accounts. See
  [Profiles](profiles.md).

- **Authentication:** the HTTP API's **JWT authorizer** verifies the Google
  ID token in `Authorization: Bearer …`: issuer `https://accounts.google.com`,
  and audience the web OAuth client, so tokens for other apps are refused.
  `GoogleWebClientId` may be empty only for local development: the
  audience is then `no-oidc-client`, which no token matches.
  Otherwise it answers 401 before a function runs. The functions only read
  the verified claims (`iss` and `sub` for the profile, `email`,
  `email_verified`, and `name` for requests).
- **Roles:**
  - **`presence_user`** uses the app; **`presence_admin`** also approves
    membership requests and creates Member vouchers; **`presence_root`**
    also creates Admin vouchers; **`presence_anonymous`** is nobody signed
    in;
  - nobody has roles by default;
  - the **root allowlist** gets all three of `presence_root`,
    `presence_admin` and `presence_user`: a verified email whose domain is
    exactly one of `PRESENCE_ROOT_DOMAINS`, or that is one of
    `PRESENCE_ROOT_EMAILS` (both comma-separated, case-insensitive). They're
    the functions' environment, from the template parameters `RootDomains`
    (default `nu01.com`) and `RootEmails` (default none), which
    `scripts/deploy.sh` passes on every deploy from the same-named
    environment variables or `.env` (in GitHub Actions, repository
    variables), so a stack never keeps an old value. Only the number of
    root emails is logged;
  - the **`UserRolesTable`** DynamoDB table declares roles per user, keyed by
    lowercase `email`, with `roles` as a string set (a list or a string
    is read too; a grant rewrites them as a set). They're added to any
    allowlist roles, except `presence_root`, which the table can't give.
    The table starts empty; the Admin screen's grants fill it.
  - Unverified emails get nothing. `sub.nu01.com`, `evilnu01.com` and
    `nu01.com.example` don't count as the domain.
  - **A linked subject** also gets the roles of its profile's owner (see
    [Profiles](profiles.md#the-profiles-folder-and-roles)), in every route.
- **The tables** (`UserRolesTable`, `MembershipTable`, `VoucherTable`, and
  [`ProfilesTable` and `ProfileSubjectsTable`](profiles.md#where-its-kept)):
  on-demand, encrypted, with point-in-time recovery, and kept if the stack
  is deleted. Their contents (people's emails) live only in AWS.
  `LinkCodesTable` holds short-lived link codes (hashed, with a TTL).
- **Least privilege:**
  - the roles function may only read `UserRolesTable`, get and put in
    `ProfileSubjectsTable`, and get, put and update in `ProfilesTable`;
  - the membership function may only put items in `MembershipTable`;
  - the voucher function may get and update items in `VoucherTable`, and read and
    update `UserRolesTable`;
  - the admin function may read and update `UserRolesTable`, scan, update
    and delete in `MembershipTable`, put, scan and delete in
    `VoucherTable`, and get items from both profile tables;
  - the profile function's permissions are listed in
    [Profiles](profiles.md#where-its-kept).
- **Responses** are `application/json` with `Cache-Control: no-store`, and
  CloudFront doesn't cache `/api/*` either.
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
  API with the same Google JWT authorizer. Nothing local reaches AWS.
- **Tests** (JUnit, `mvn test`):
  - profiles (`ProfilesTest`): found by subject, created and linked at a
    first sign-in, never a repeated ID, races; see
    [Profiles](profiles.md#verified);
  - the role rules: default none, the exact domains, verification, table
    roles, case and whitespace;
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
    only; creation's role, start, expiry, uses, code and discount checks; a
    taken code (409); the discount stored and answered; a partial
    discount answered 402, granting nothing and counting no use; newest first; deletion; redeeming once
    per email, running out, not yet started, expiring, unknown codes, verified emails, an
    Admin voucher also granting `presence_user`, a failed grant giving the
    use back, only roots creating Admin vouchers, and no root vouchers;
  - the root allowlist: domains and whole emails, verified only, and the
    table never giving `presence_root`;
  - profiles, linking and the owner's roles (`ProfileTest`; see
    [Profiles](profiles.md#verified)).
  - the whole flow: a nu01.com user gets all three roles; another domain's
    user gets none, asks, is granted by an admin, and becomes a
    `presence_user` only.
