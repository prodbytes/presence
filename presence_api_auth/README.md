# presence_api_auth

The Presence auth API: an [AWS SAM](https://aws.amazon.com/serverless/sam/)
application with four Java 25 Lambdas (`java25`, arm64) behind one API
Gateway **HTTP API**, served under **`/api/auth`** by the site's CloudFront
distribution.

| Route | Who | Does |
|-------|-----|------|
| `GET /api/auth` | anyone signed in | the caller's profile (found, or created at the first sign-in) and roles: `{"email": "…", "profile": "automatic_paranoid_axolotl", "roles": […]}` |

Admins are users with both `presence_user` and `presence_admin`. Users
get `presence_user` by subscribing at nu01.com (rbacr) or by redeeming a
voucher; there are no membership requests.

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
- **Roles** ([Roles.java](AuthFunction/src/main/java/presence/auth/Roles.java),
  [Rbacr.java](AuthFunction/src/main/java/presence/auth/Rbacr.java)) all
  come from [rbacr](https://github.com/prodbytes/rbacr), its `presence`
  system (`RbacrUrl`, `RbacrToken`, `RbacrSystem`):
  - `presence_user` (rbacr's `free`, `premium` or `admin`) uses the app;
    `presence_premium` (`premium` or `admin`) also syncs with the cloud;
    `presence_admin` (`admin`) also manages Member vouchers and
    maintenance mode; `presence_root` (an rbacr root, from its
    root list) gets every role and also creates Admin vouchers (nothing
    creates root ones);
  - nobody has roles by default, and only a verified email is asked
    about: one `POST /api/roles` per email, answers reused 60 s, failing
    closed (no answer, no roles);
  - the token must be an rbacr root's: it asks about anyone, and grants;
  - an account linked to a profile another account owns gets
    `presence_user` and `presence_premium` when the owner has them, never
    the owner's `presence_admin` or `presence_root`.
- **Admin routes**
  ([AdminHandler.java](AuthFunction/src/main/java/presence/auth/AdminHandler.java)):
  the function works out the caller's roles itself and answers **403**
  unless they include both roles. Roles themselves (granting, revoking,
  `premium`, domains, time limits) are changed in rbacr itself.
- The tables' contents (people's emails) live only in AWS, never in this
  repository. `UserRolesTable` now holds only the voucher lockout; its old
  `roles` were copied into rbacr by
  [scripts/migrate-roles-to-rbacr.sh](../scripts/migrate-roles-to-rbacr.sh)
  (dry run by default; `--apply` grants).

- **Least privilege:** the roles function may only use the profile
  tables; the admin function may only use the voucher, profile and
  system tables. Their rbacr token is a root's, so keep it secret and
  rotate it.

| Path | Holds |
|------|-------|
| [template.yaml](template.yaml) | The tables, the HTTP API with its Google JWT authorizer, and the functions |
| [AuthFunction/](AuthFunction) | Maven project (`presence.auth.AuthHandler`, `AdminHandler`, `Roles`, `Profiles`, `ProfileId` and its word lists) with its tests |
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
Its outputs export the tables' names (`<stack>-UserRolesTable` and so on)
for the health check, [presence_health](../presence_health) (`GET
/health`), which `deploy.sh` deploys right after it.
