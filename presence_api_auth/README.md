# presence_api_auth

The Presence auth API: an [AWS SAM](https://aws.amazon.com/serverless/sam/)
application with three Java 25 Lambdas (`java25`, arm64) behind one API
Gateway **HTTP API**, served under **`/api/auth`** by the site's CloudFront
distribution.

| Route | Who | Does |
|-------|-----|------|
| `GET /api/auth` | anyone signed in | the caller's profile (found, or created at the first sign-in) and roles: `{"email": "…", "profile": "automatic_paranoid_axolotl", "roles": […]}` |
| `POST /api/auth/membership` | anyone signed in | asks for access; the body is a plain-text message (up to 1000 characters) |
| `GET /api/auth/membership` | admins | the pending requests, oldest first: `{"requests": [{email, name, message, requestedAt}]}` |
| `POST /api/auth/membership/grant` | admins | the body is an email: adds `presence_user` to its roles and drops its request |
| `POST /api/auth/membership/dismiss` | admins | the body is an email: hides its request (the cooldown still holds) |

Admins are users with both `presence_user` and `presence_admin`.

- **Who's calling:** the HTTP API's JWT authorizer checks the Google ID
  token first: signature, expiry, issuer `https://accounts.google.com`, and
  audience the web client ID (`GoogleWebClientId`). A missing, expired,
  forged or foreign token gets **401** and never reaches a function. The
  functions read the verified `iss`, `sub`, `email`, `email_verified`,
  `hd` and `name` claims (the authorizer passes every claim through), in
  one place: [Caller.java](AuthFunction/src/main/java/presence/auth/Caller.java).
- **Profiles** ([Profiles.java](AuthFunction/src/main/java/presence/auth/Profiles.java)):
  data belongs to a **profile**, not to a login, so users can change
  emails, providers or add collaborators without losing it. Each subject
  (`<iss>#<sub>`) is linked to one profile in **`ProfileSubjectsTable`**;
  a first sign-in creates a profile in **`ProfilesTable`** and links the
  subject, so the next sign-in finds it. Profile IDs
  ([ProfileId.java](AuthFunction/src/main/java/presence/auth/ProfileId.java))
  are two different adjectives and an animal, `automatic_paranoid_axolotl`,
  from about 1.14 billion, and a conditional put guarantees no two
  profiles share one. See [specs/profiles.md](../specs/profiles.md).
- **Roles** ([Roles.java](AuthFunction/src/main/java/presence/auth/Roles.java)):
  - `presence_user` uses the app; `presence_admin` also approves
    membership requests and creates Member vouchers; `presence_root` also
    creates Admin vouchers (nothing creates root ones);
  - nobody has roles by default;
  - the **root allowlist** gets all three: a **verified** email at one of
    `PRESENCE_ROOT_DOMAINS` (parameter `RootDomains`, default `nu01.com`,
    each matched exactly after the `@`) **whose token's `hd` claim is that
    domain** (an account of that Google Workspace; a personal Google
    account registered with such an address has no `hd` and gets nothing),
    or listed in `PRESENCE_ROOT_EMAILS` (parameter `RootEmails`, default
    none; list only Gmail or Workspace addresses, which nobody else can
    register as a Google account). Both are comma-separated;
    `scripts/deploy.sh` passes them on every deploy, from the environment
    or `.env`;
  - anyone listed in the **`UserRolesTable`** DynamoDB table gets the roles
    declared there, added to any allowlist roles, except `presence_root`. The table is keyed by
    lowercase `email`, with `roles` as a string set (a list of strings, or
    one string, is read too);
  - an account linked to a profile another account owns gets
    `presence_user` when the owner has it, never the owner's
    `presence_admin` or `presence_root`.
- **Membership requests**
  ([MembershipHandler.java](AuthFunction/src/main/java/presence/auth/MembershipHandler.java)):
  one per email in **`MembershipTable`**, the latest replacing the last,
  and at most one an hour per email, dismissed or not (a **409**
  otherwise; DynamoDB checks it with a condition on `requestedAt`, in epoch
  milliseconds). The route is also throttled to 1 request a second (burst
  5; API Gateway answers **429**). Nothing is sent anywhere:
  administrators see pending requests on the Admin screen.

- **Admin routes**
  ([AdminHandler.java](AuthFunction/src/main/java/presence/auth/AdminHandler.java)):
  the function works out the caller's roles itself and answers **403**
  unless they include both roles. A grant adds `presence_user` to the
  email's string set in one atomic `ADD` (roles written by hand as a list
  or a string are first rewritten as a set, conditionally, with retries).
- The tables' contents (people's emails) live only in AWS, never in this
  repository. Roles can still be set by hand, for example:

  ```bash
  aws dynamodb put-item --table-name "<UserRolesTableName output>" \
    --item '{"email": {"S": "someone@example.com"}, "roles": {"SS": ["presence_user"]}}'
  ```

- **Least privilege:** the roles function may only read `UserRolesTable`;
  the membership function may only put items in `MembershipTable`; the
  admin function may read and update
  `UserRolesTable` and scan, update and delete in `MembershipTable`.

| Path | Holds |
|------|-------|
| [template.yaml](template.yaml) | The tables, the HTTP API with its Google JWT authorizer, and the functions |
| [AuthFunction/](AuthFunction) | Maven project (`presence.auth.AuthHandler`, `MembershipHandler`, `AdminHandler`, `Roles`, `Profiles`, `ProfileId` and its word lists) with its tests |
| [samconfig.toml](samconfig.toml) | Default `sam build` / `deploy` settings (stack `presence-auth-api`) |

## Commands

From this folder, inside devbox:

```bash
(cd AuthFunction && mvn test)   # unit tests
sam validate --lint
sam build
```

`scripts/deploy.sh` deploys it as `presence-auth-api` (or
`presence-rc-auth-api` with `STAGE=rc`), passing the site's web client ID.
