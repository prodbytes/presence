# Health check (`/health`)

Each deployed site (https://presence.nu01.com and
https://rc.presence.nu01.com) has a public **`GET /health`** endpoint,
which the central `nu01-monitor` (nu01 repo) polls and emails about when
it fails.

## The endpoint

- **`GET /health`** on the site's domain. CloudFront sends it, uncached,
  to its own module, [presence_health/](../presence_health): a SAM stack
  per stage (**`presence-health`**, **`presence-rc-health`**) with its own
  HTTP API (the distribution's `health` origin, like the auth API's `api`
  origin: an `execute-api` host that answers only requests carrying the
  site's origin secret; see [Origin check](origin-check.md)), where
  `HealthFunction` (`presence.health.HealthHandler`) answers it without a
  token. Throttled to 20 requests/s (burst 50). The
  [auth API](auth-api.md) no longer has a `/health` route.
- It runs every check at once, in parallel, within **1.5 s** in all, so
  a monitor gets a prompt answer. A check that takes longer fails:
  - **`settings`**: an OIDC client (so RBAC mode), the identity pool and
    the user-data bucket are configured (as in `GET /api/auth/anonymous`).
    `scripts/deploy.sh` passes the health stack the same
    `GoogleWebClientId`, `IdentityPoolId` and `UserDataBucket` it passes
    the auth API;
  - **`dynamodb`**: every auth API table (`Profiles`,
    `ProfileSubjects`, `LinkCodes`, listed in `HEALTH_TABLES`) is
    `ACTIVE`. The health stack imports their names from the auth API
    stack's exports (`<AuthStackName>-ProfilesTable`,
    `-ProfileSubjectsTable`, `-LinkCodesTable`; `AuthStackName` is
    `presence-auth-api` or `presence-rc-auth-api`), and CloudFormation
    refuses to remove or change those exports while it imports them. So
    `scripts/deploy.sh` (step 3) deploys an **existing** health stack
    **before** the auth API, so it stops importing an export the auth API
    drops in the same deploy, and a **new** stage's **after** it, once
    the exports it imports exist; once per run. An export the health
    check newly imports must therefore ship in an earlier deploy than the
    import;
  - **`s3`**: the [cloud sync](cloud-sync.md) user-data bucket answers
    `HeadBucket`;
  - **`cognito`**: the identity pool answers `DescribeIdentityPool`;
  - **`google`**: Google's token signing keys
    (`https://www.googleapis.com/oauth2/v3/certs`) load. The auth API's
    session exchange needs them to check every Google sign-in (the APIs'
    JWT authorizers check Presence's own [session tokens](sessions.md));
  - **`rbacr`**: rbacr's own `/health` answers 200. It fails when the
    health stack's `RbacrUrl` is empty (`RBACR_URL` on `HealthFunction`;
    the token never goes to the health stack). `scripts/deploy.sh` always
    passes it, since it refuses to deploy without an rbacr token: rbacr
    gives every role ([Auth API](auth-api.md)), so without it nobody who
    signs in has one. (It checks the rbacr the auth API uses; the app's
    build asks the same one.)
- **200** `{"status":"ok","checks":{"settings":"ok","dynamodb":"ok","s3":"ok","cognito":"ok","google":"ok","rbacr":"ok"},"version":"0.6.202610061200"}`
  when every check passes. Otherwise **503**, with `"status":"fail"` and
  the failing checks as `"fail"`.
- **`version`** is the release deployed (`X.Y.Z`, as in
  `/app/version.json`), passed by `scripts/deploy.sh` as the health
  stack's `Version` parameter (`PRESENCE_VERSION` on `HealthFunction`).
  The deploy updates the auth API and health stacks together (see the
  order above), right before the site, so it's the release the API runs too. It's there
  failing or not, so `curl https://rc.presence.nu01.com/health` (or
  prod's) shows which release is live. Left out when the stack has none
  (a manual deploy).
- The response only names each check and says ok or fail. Why a check
  failed goes to the function's CloudWatch log ("health check failed:
  …"), never to the public response.
- A result is reused for **20 s** per Lambda instance, so the health
  checkers don't each call every service.
- The function has 1024 MB of memory, which gives it more CPU, so a cold
  start still answers in time. Its role carries the stage's permissions
  boundary (`<prefix>-app-boundary`) and is read-only:
  `dynamodb:DescribeTable` on the three imported tables, `s3:ListBucket` on
  the bucket and `cognito-identity:DescribeIdentityPool` on the pool.
- Its Maven project, `presence_health/HealthFunction` (Java 25, the same
  AWS SDK and Lambda library versions as the auth API), has only the
  DynamoDB, S3 and Cognito Identity clients, and its own tests
  (`HealthTest`).
- **AWS only.** It isn't deployed into the local [Floci](local-cdn.md),
  whose CloudFront has no `/health` route. The identity pool and bucket in
  `.env` are AWS's, which the Lambdas running in Floci can't reach.

## Monitoring and alerts

- The site stacks no longer have their own monitoring: the central
  **`nu01-monitor`** stack (in the nu01 repo) checks every nu01 project's
  endpoints, `https://presence.nu01.com/health` and
  `https://rc.presence.nu01.com/health` among them, every 5 minutes, and
  emails **`julio+health@nu01.com`** when one fails. Its checks, schedule
  and recipients are configured there, not in this repo.
- Until 2026-10, [presence_infra/site.yaml](../presence_infra/site.yaml)
  had a Route 53 `HTTPS_STR_MATCH` health check of `/health`, a
  CloudWatch alarm on it and an SNS email topic (`HealthNotificationEmails`,
  from `PRESENCE_HEALTH_EMAILS`); they were removed to cut cost (Route 53
  bills the HTTPS and string-match options per check). The next site
  deploy of each stage deletes them.
- The deploy's smoke test also requires `/health` to answer
  `"status":"ok"` (see [Production deploy](deploy.md)).
- **Deploy permissions:** both GitHub deploy roles
  ([github-deploy.yaml](../presence_infra/github-deploy.yaml)) keep, for
  now, the Route 53 health check, `presence-*` (RC: `presence-rc-*`) alarm
  and SNS topic permissions and the `LanguageExtensions` transform, so
  that deploy can delete the old resources (and re-create them if it rolls
  back). They can be dropped once both stages have deployed.

## Known limitations

- The first deploy with the separate module moves `/health` from the
  auth API to `presence-health` in one run: the auth API update removes
  its route, and `/health` answers 404 (through the auth API origin)
  until the site stack points the distribution at the new origin, a few
  minutes later. The monitor may email a failure then.
- Putting back a release from before the split fails at its auth API
  update: it drops the table exports that `presence-health` imports.
  Delete the `<prefix>-health` stack first (an administrator, or the
  stage's deploy role), then redeploy that release.

- Putting back a release from before the monitor change re-creates the
  Route 53 health check, alarm and topic (and their cost), and needs the
  deploy roles' permissions for them; drop those permissions only once
  such releases won't be redeployed.
- Until those permissions are dropped, Route 53 health checks have no
  names to scope IAM by, so the RC deploy role can change any health check
  in the account.
