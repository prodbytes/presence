# Auth API (`presence_api_auth`)

[presence_api_auth/](../presence_api_auth) is a SAM application: three Java 25
Lambdas (arm64) behind one API Gateway HTTP API, under `/api/auth` on the
site (`/api/*` in the CloudFront distribution; see
[Production deploy](deploy.md)):

- **`GET /api/auth`** (`AuthHandler`): the signed-in user's roles,
  `{"email": "...", "roles": [...]}`;
- **`POST /api/auth/membership`** (`MembershipHandler`): a request for
  access, and **`GET /api/auth/membership`**, **`POST …/grant`** and
  **`POST …/dismiss`** (`AdminHandler`, admins only: both roles): the
  Admin screen's. See [Membership](membership.md).

- **Authentication:** the HTTP API's **JWT authorizer** verifies the Google
  ID token in `Authorization: Bearer …`: issuer `https://accounts.google.com`,
  and audience the web OAuth client, so tokens for other apps are refused.
  Otherwise it answers 401 before a function runs. The functions only read
  the verified claims (`email`, `email_verified`, and `name` for requests).
- **Roles:**
  - **`presence_user`** uses the app; **`presence_admin`** also approves
    membership requests;
  - nobody has roles by default;
  - a verified email whose domain is exactly one of `AllowedDomains`
    (comma-separated; `nu01.com` for now) gets `DomainRoles`, both roles;
  - the **`UserRolesTable`** DynamoDB table declares roles per user, keyed by
    lowercase `email`, with `roles` as a string set (a list or a string
    is read too; a grant rewrites them as a set). They're added to any domain
    roles. The table starts empty; the Admin screen's grants fill it.
  - Unverified emails get nothing. `sub.nu01.com`, `evilnu01.com` and
    `nu01.com.example` don't count as the domain.
- **The tables** (`UserRolesTable`, `MembershipTable`): on-demand,
  encrypted, with point-in-time recovery, and kept if the stack is deleted.
  Their contents (people's emails) live only in AWS.
- **Least privilege:** the roles function may only read `UserRolesTable`;
  the membership function may only put items in `MembershipTable` and
  publish to `MembershipTopic`; the admin function may read and update
  `UserRolesTable` and scan, update and delete in `MembershipTable`.
- **Responses** are `application/json` with `Cache-Control: no-store`, and
  CloudFront doesn't cache `/api/*` either.
- **Deploy:** `scripts/deploy.sh` runs `sam build` and `sam deploy` (stacks
  `presence-auth-api` and `presence-rc-auth-api`) before the site, and passes
  the stack's `ApiDomain` output to `site.yaml`. The smoke test requires
  `/api/auth` to answer **401** without a token, which proves the route and
  its authorizer are live.
- **The app** calls it after sign-in to decide what to show (see
  [Sign-in](sign-in.md)): without `presence_user`, only the account and
  sign-up.
- **Locally,** the auth API runs inside Floci (see
  [Local CDN](local-cdn.md#the-local-auth-api)): the same Lambdas, tables
  and topic, deployed from this template at every start, behind an HTTP
  API with the same Google JWT authorizer. Nothing local reaches AWS.
- **Tests** (JUnit, `mvn test`):
  - the role rules: default none, the exact domains, verification, table
    roles, case and whitespace;
  - the handler's JSON: roles, no roles, no claims, escaping;
  - membership requests: verified email, empty and long messages, base64
    bodies, the hourly cooldown;
  - the admin routes: 403 without both roles, listing, grant, dismiss
    (which keeps the cooldown), bad emails, unknown routes;
  - a failed SNS publish still keeps the request; profile names are
    cleaned.
  - the whole flow: a nu01.com user gets both roles; another domain's
    user gets none, asks, is granted by an admin, and becomes a
    `presence_user` only.
