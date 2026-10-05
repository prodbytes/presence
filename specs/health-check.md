# Health check (`/health`)

Route 53 watches each deployed site (https://presence.nu01.com and
https://rc.presence.nu01.com) through a public **`GET /health`** endpoint,
and emails when it fails or recovers.

## The endpoint

- **`GET /health`** on the site's domain. CloudFront sends it, uncached,
  to the [auth API](auth-api.md)'s HTTP API, where `HealthFunction`
  (`presence.auth.HealthHandler`) answers it without a token. Throttled to
  20 requests/s (burst 50).
- It runs every check at once, in parallel, within **1.5 s** in all (Route
  53 wants an answer within 2 s of connecting). A check that takes longer
  fails:
  - **`settings`**: an OIDC client (so RBAC mode), the identity pool and
    the user-data bucket are configured (as in `GET /api/auth/anonymous`);
  - **`dynamodb`**: every auth API table (`UserRoles`, `Profiles`,
    `ProfileSubjects`, `Membership`, `Voucher`, `LinkCodes`, listed in
    `HEALTH_TABLES`) is `ACTIVE`;
  - **`s3`**: the [cloud sync](cloud-sync.md) user-data bucket answers
    `HeadBucket`;
  - **`cognito`**: the identity pool answers `DescribeIdentityPool`;
  - **`google`**: Google's token signing keys
    (`https://www.googleapis.com/oauth2/v3/certs`) load. The HTTP API's
    JWT authorizer needs them to check every sign-in.
- **200** `{"status":"ok","checks":{"settings":"ok","dynamodb":"ok","s3":"ok","cognito":"ok","google":"ok"}}`
  when every check passes. Otherwise **503**, with `"status":"fail"` and
  the failing checks as `"fail"`.
- The response only names each check and says ok or fail. Why a check
  failed goes to the function's CloudWatch log ("health check failed:
  …"), never to the public response.
- A result is reused for **20 s** per Lambda instance, so the health
  checkers don't each call every service.
- The function has 1024 MB of memory, which gives it more CPU, so a cold
  start still answers in time. Its permissions are read-only:
  `dynamodb:DescribeTable` on the six tables, `s3:ListBucket` on the
  bucket and `cognito-identity:DescribeIdentityPool` on the pool.
- **AWS only.** The local [Floci](local-cdn.md) API has no `/health`
  route. The identity pool and bucket in `.env` are AWS's, which the
  Lambdas running in Floci can't reach.

## The Route 53 check and its emails

In [presence_infra/site.yaml](../presence_infra/site.yaml), stacks
`presence-web` and `presence-rc-web`:

- **`HealthCheck`**: an `HTTPS_STR_MATCH` check of
  `https://<DomainName>/health` (port 443, SNI), every 30 s from three
  regions (us-east-1, us-west-2, eu-west-1, the fewest allowed). It is
  healthy only when the body contains `"status":"ok"`. A checker reports
  the site unhealthy after 3 failures in a row. It covers the whole path:
  DNS, CloudFront, the API and its dependencies.
- **`HealthAlarm`** (`<stack>-health`): `AWS/Route53` `HealthCheckStatus`
  (minimum) below 1 for 2 one-minute periods. Missing data counts as
  failing. It notifies both on alarm and on recovery (OK).
- **`HealthTopic`** (`<stack>-health`, SNS): one email subscription per
  address in the **`HealthNotificationEmails`** parameter
  (comma-separated; default **`julio+health@nu01.com`**). The template's
  `AWS::LanguageExtensions` `Fn::ForEach` makes the subscriptions, so
  adding or removing an address adds or removes its subscription. Each
  address must confirm AWS's "Subscription Confirmation" email before it
  receives alarms.
- [scripts/deploy.sh](../scripts/deploy.sh) passes
  `HealthNotificationEmails` from **`PRESENCE_HEALTH_EMAILS`**: the
  environment, else `.env`, else the default. The script accepts only
  comma-separated emails and logs how many there are, never the
  addresses. The Deploy and Deploy RC workflows set it from the optional
  repository variable `PRESENCE_HEALTH_EMAILS`. The site stack is
  deployed with `CAPABILITY_AUTO_EXPAND`, which the transform needs.
- The deploy's smoke test also requires `/health` to answer
  `"status":"ok"` (see [Production deploy](deploy.md)).
- **Deploy permissions:** both GitHub deploy roles
  ([github-deploy.yaml](../presence_infra/github-deploy.yaml)) may use the
  `LanguageExtensions` transform and manage Route 53 health checks, the
  `presence-*` (RC: `presence-rc-*`) alarms and the SNS topics.

## Known limitations

- Route 53 health checks have no names to scope IAM by, so the RC deploy
  role can change any health check in the account, prod's included.
- The topic uses SNS's default encryption settings (none). A KMS key
  would need a key policy that lets CloudWatch publish; alarm emails only
  carry the alarm's name and state.
- The `github-deploy.yaml` change only takes effect once an administrator
  redeploys that stack (see
  [presence_infra/README.md](../presence_infra/README.md)). Until then,
  tag deploys fail when they create the health check.
