# Production deploy

Pushing a **`*GA` tag** (`bash scripts/release-ga.sh`, `X.Y.Z-GA`) deploys
that version to **https://presence.nu01.com**. The
[Deploy workflow](../.github/workflows/deploy.yml) runs
[scripts/deploy.sh](../scripts/deploy.sh). The [Release
workflow](release.md) runs on the same tag and publishes the binaries.

## What runs where

One CloudFront distribution serves the whole site, laid out like the local
[Floci distribution](local-cdn.md):

| Path | Origin |
|---|---|
| `/` | S3 `index.html`, the [site index](site-index.md), which redirects to `/app/` |
| `/app*` | S3 `app/`: the Flutter web build (`--base-href /app/`). A CloudFront Function redirects `/app` to `/app/` and maps directory URIs to `index.html` |
| `/api/*` | The [auth API](auth-api.md)'s HTTP API (no origin path). Not cached, with every viewer header but `Host` forwarded, `Authorization` included |

- **Infrastructure as code:**
  - [presence_infra/user-data.yaml](../presence_infra/user-data.yaml) and
    [identity.yaml](../presence_infra/identity.yaml), stacks
    `presence-user-data` and `presence-identity`: the bucket and identity
    pool for [cloud sync](cloud-sync.md).
  - [presence_infra/site.yaml](../presence_infra/site.yaml), stack
    `presence-web`: an ACM certificate for `presence.nu01.com`
    (DNS-validated in the `nu01.com` zone), a private S3 bucket readable
    only by the distribution (OAC), the distribution (HTTP/2 and HTTP/3,
    HTTPS only, TLS 1.2+, AWS's managed security-headers policy), and
    Route 53 A/AAAA aliases.
  - [presence_sh/template.yaml](../presence_sh/template.yaml), stack
    `presence-sh`: https://sh.presence.nu01.com, the
    [install URL](install-url.md), deployed after the site by
    [scripts/deploy-sh.sh](../scripts/deploy-sh.sh).
  - Everything is in `us-east-1`, in the account recorded in the private
    repo (`setec-astronomy`, `presence.nu01/README.md`).
- **Content:** files are uploaded with `Cache-Control: no-cache`, because
  Flutter's web files aren't content-hashed, and every deploy invalidates
  `/*`. Unknown paths return 404 (the bucket policy allows `ListBucket` for
  the distribution).
- **`scripts/deploy.sh`** first deploys `user-data.yaml` and
  `identity.yaml` ([cloud sync](cloud-sync.md)). It then builds the web app
  for `/app/` (`make web` with `WEB_BASE_HREF=/app/`), with the version from
  the tag and the identity pool and bucket IDs. After that it deploys the
  [auth API](auth-api.md) with SAM, then `site.yaml` (with the API's
  domain), uploads, invalidates, and **smoke-tests the live site**:
  `/app/version.json` must report the tag's version, `/` must be the index
  page, `/app/` must answer, and `/api/auth` must refuse a request without a
  token (401), and `/api/auth/anonymous` must answer RBAC with only
  `presence_anonymous`, and report the OIDC client and AWS settings set. It retries for up to 10 minutes.

## Release candidates (rc.presence.nu01.com)

Every pushed **`*RC*` tag** (`bash scripts/release-rc.sh`, `X.Y.Z-RC<n>`),
or a manual run of the [Deploy RC workflow](../.github/workflows/deploy-rc.yml)
with an optional `tag` input, deploys that version to
**https://rc.presence.nu01.com**. It runs the same
[scripts/deploy.sh](../scripts/deploy.sh) with `STAGE=rc`.

- **Isolated from prod:** the RC has its own stacks, from the same
  templates:
  - `presence-rc-user-data` (its own bucket, CORS only for
    `https://rc.presence.nu01.com`);
  - `presence-rc-identity` (its own identity pool, `presence-rc`, trusting
    the same Google web client);
  - `presence-rc-web` (its own certificate, bucket, distribution and
    `rc.presence.nu01.com` alias records).

  RC data never reaches the prod bucket, and an RC deploy never touches the
  prod site.
- **Per-stage templates:** `user-data.yaml` exports
  `${AWS::StackName}-bucket(-arn)`, and `identity.yaml` imports its bucket
  by `UserDataStackName` and names the pool `IdentityPoolName`. The defaults
  keep prod's names, and a change set against the prod stacks showed no
  changes.
- **Its own GitHub role,** `presence-github-deploy-rc` (in
  `github-deploy.yaml`, repository variable `AWS_DEPLOY_RC_ROLE_ARN`):
  - it trusts only `*RC*` tag runs and manual runs from `main`;
  - it's limited to `presence-rc-*` stacks, buckets, functions and roles;
  - in Route 53 it may change only `rc.presence.nu01.com` and
    `*.rc.presence.nu01.com` (the certificate's validation record), through
    `route53:ChangeResourceRecordSetsNormalizedRecordNames`;
  - CloudFront, ACM and Cognito identity pools can't be scoped by name in
    advance, so those stay account-wide, as for the prod role.
- **Smoke test:** the same checks against `https://rc.presence.nu01.com/`.
- Google sign-in on the RC needs `https://rc.presence.nu01.com` among the
  web OAuth client's authorized JavaScript origins.

## GitHub access

- The workflow has no AWS keys. It exchanges GitHub's OIDC token for the
  `presence-github-deploy` role
  ([presence_infra/github-deploy.yaml](../presence_infra/github-deploy.yaml)),
  whose ARN is the repository variable `AWS_DEPLOY_ROLE_ARN`.
- The role trusts only `repo:prodbytes/presence:ref:refs/tags/*GA`, so the
  job has no `environment:`, which would change that subject. Its
  permissions are limited to the Presence stacks: CloudFormation, S3,
  `presence-*` IAM roles, Lambda functions, HTTP APIs, DynamoDB tables,
  Cognito identity pools,
  CloudFront, ACM and the `nu01.com` zone. The RC role gets the same,
  limited to `presence-rc-*`.
- An administrator deploys that stack once (it creates IAM resources); the
  commands are in [presence_infra/README.md](../presence_infra/README.md).
  It's deployed.
- The repository uses GitHub's **immutable OIDC subject claims**
  (`use_immutable_subject`), so tokens identify it as
  `repo:prodbytes@<owner id>/presence@<repo id>:ref:…` rather than
  `repo:prodbytes/presence:ref:…`. Both roles trust both forms
  (`GitHubImmutableRepository` and `GitHubRepository`).
- The Google web client ID comes from the repository variable
  `GOOGLE_WEB_CLIENT_ID`.

## Verified

- The Deploy RC workflow, on the tag `0.2.202609270725-RC`: it logged in
  through OIDC as `presence-github-deploy-rc`, deployed the four RC stacks,
  and its smoke test passed. The live check found `version.json` at
  `0.2.202609270725`, `/`, `/app/` and `/api/events` (since removed)
  returning 200, and the
  app rendering in headless Chrome.


- `TAG=0.1.0-GA bash scripts/deploy.sh`, run by hand with admin
  credentials, created both stacks, uploaded, and passed its smoke test.
- On the live site:
  - `/`, `/app/`, `/app/version.json` (`0.1.0`) and `/api/events` (since
    removed)
    (`{"events":[]}`) return 200;
  - `/app` returns 301 to `/app/`, `http://` redirects to `https://`, and
    unknown paths return 404;
  - responses carry HSTS, `X-Frame-Options`, `X-Content-Type-Options` and
    `Referrer-Policy`;
  - headless Chrome opening https://presence.nu01.com/ ended on `/app/`,
    with the app rendered (camera view, Clip, Ready) and no failed requests.

## Known limitations

- Google sign-in on the live site needs `https://presence.nu01.com` among
  the web OAuth client's authorized JavaScript origins.
