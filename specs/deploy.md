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
| `/health` | The same HTTP API's public [health check](health-check.md), not cached |

- **Infrastructure as code:**
  - [presence_infra/user-data.yaml](../presence_infra/user-data.yaml) and
    [identity.yaml](../presence_infra/identity.yaml), stacks
    `presence-user-data` and `presence-identity`: the bucket and identity
    pool for [cloud sync](cloud-sync.md), and the IoT policy for [live
    sync](live-sync.md) (`presence-live-sync`).
  - [presence_infra/site.yaml](../presence_infra/site.yaml), stack
    `presence-web`: an ACM certificate for `presence.nu01.com`
    (DNS-validated in the `nu01.com` zone), a private S3 bucket readable
    only by the distribution (OAC), the distribution (HTTP/2 and HTTP/3,
    HTTPS only, TLS 1.2+, its own [response headers
    policies](#response-headers) with a Content Security Policy), Route
    53 A/AAAA aliases, and the Route 53 [health check](health-check.md)
    of `/health` with its alarm and email topic (`HealthNotificationEmails`,
    from `PRESENCE_HEALTH_EMAILS`, default `julio+health@nu01.com`). The
    certificate and distribution carry the tag `presence:stage` (`Stage`:
    `prod` or `rc`), which the deploy roles are scoped by.
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
- **`scripts/deploy.sh`** first checks that the stage's permissions
  boundary and SAM artifact bucket exist (from `presence-github-deploy`,
  see [GitHub access](#github-access)), then deploys `user-data.yaml` and
  `identity.yaml` ([cloud sync](cloud-sync.md), with `Stage` for [live
  sync](live-sync.md)'s topics), and looks up the account's AWS IoT data
  endpoint (`aws iot describe-endpoint --endpoint-type iot:Data-ATS`). It
  then builds the web app for `/app/` (`make web` with
  `WEB_BASE_HREF=/app/`), with the version from the tag, the identity pool
  and bucket IDs and the IoT endpoint (`IOT_ENDPOINT`). After that it
  deploys the [auth API](auth-api.md) with SAM (with `IotPolicyName`, the
  live-sync policy it attaches to each identity), then `site.yaml` (with the API's
  domain), uploads, invalidates, and **smoke-tests the live site**:
  `/app/version.json` must report the tag's version, `/` must be the index
  page, `/app/` must answer, and `/api/auth` must refuse a request without a
  token (401), and `/api/auth/anonymous` must answer RBAC with only
  `presence_anonymous`, and report the OIDC client and AWS settings set
  (and a [maintenance](maintenance.md) state, whatever it is),
  and `/health` must answer `"status":"ok"` with this release's
  `"version"` (see [Health check](health-check.md)). It retries for up to 10 minutes.
- **On failure** (any step, the smoke test included), `deploy.sh` prints
  the version that was live before it started (read from
  `/app/version.json` at the start), the version live now, and how to put
  the previous one back: re-running the Deploy workflow for its tag
  (`gh run list --workflow deploy.yml --branch <X.Y.Z-GA>`, then `gh run
  rerun`), or for the RC `gh workflow run deploy-rc.yml -f tag=<tag>`, or
  by hand `git checkout <tag> && TAG=<tag> bash scripts/deploy.sh`. A
  failed stack update rolls itself back; the content upload isn't undone,
  so the redeploy is what restores it.

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
    the same Google web client, and its own IoT policy,
    `presence-rc-live-sync`, on `presence/rc/…` topics);
  - `presence-rc-web` (its own certificate, bucket, distribution and
    `rc.presence.nu01.com` alias records).

  RC data never reaches the prod bucket, and the RC role can't change the
  prod stacks, buckets, functions, tables, roles, distribution, certificate
  or identity pool (see [Stage separation](#stage-separation) for what it
  still can).
- **Its own icons:** after building, the RC deploy copies
  `presence_app/web_rc/` (favicon and app icons with a huge "RC" on red;
  see [App icon](app-icon.md)) over the web build, so its browser tabs
  look different from production's, and titles the app **"🧪 Presence
  RC"** (the build's `PRESENCE_STAGE=rc`, and the built `index.html` and
  `manifest.json` rewritten).
- **Per-stage templates:** `user-data.yaml` exports
  `${AWS::StackName}-bucket(-arn)`, and `identity.yaml` imports its bucket
  by `UserDataStackName` and names the pool `IdentityPoolName`. The defaults
  keep prod's names, and a change set against the prod stacks showed no
  changes.
- **Its own GitHub role,** `presence-github-deploy-rc` (in
  `github-deploy.yaml`, repository variable `AWS_DEPLOY_RC_ROLE_ARN`):
  it trusts only `*RC*` tag runs and manual runs from `main`, and the
  workflow also refuses anything but an RC tag (`X.Y.Z-RC` or
  `X.Y.Z-RC<n>`) or `main` whose commit is on `main`. Its permissions are
  the prod role's, generated from the same definition for the
  `presence-rc` prefix and `rc` stage (see [GitHub access](#github-access)).
- **Smoke test:** the same checks against `https://rc.presence.nu01.com/`.
- Google sign-in on the RC needs `https://rc.presence.nu01.com` among the
  web OAuth client's authorized JavaScript origins.

## GitHub access

- The workflows have no AWS keys. They exchange GitHub's OIDC token for
  the `presence-github-deploy` role (Deploy) or `presence-github-deploy-rc`
  (Deploy RC), from
  [presence_infra/github-deploy.yaml](../presence_infra/github-deploy.yaml),
  whose ARNs are the repository variables `AWS_DEPLOY_ROLE_ARN` and
  `AWS_DEPLOY_RC_ROLE_ARN`.
- The prod role trusts only `*GA` tag runs, the RC role `*RC*` tag runs
  and manual runs from `main`, so the jobs have no `environment:`, which
  would change that subject. The repository uses GitHub's **immutable
  OIDC subject claims** (`use_immutable_subject`), so tokens identify it
  as `repo:prodbytes@<owner id>/presence@<repo id>:ref:…` rather than
  `repo:prodbytes/presence:ref:…`; both roles trust both forms
  (`GitHubImmutableRepository` and `GitHubRepository`).
- Before deploying, both workflows check out full history and refuse a
  commit that isn't on `main` (`git merge-base --is-ancestor <commit>
  origin/main`); see [Release builds](release.md#release-trust).

### Permissions, per stage, from one definition

`github-deploy.yaml` uses `Fn::ForEach` (the `AWS::LanguageExtensions`
transform) over the two stage prefixes, `presence` (prod) and
`presence-rc` (RC), so both stages get the same policies, differing only
in prefix, `presence:stage` tag value and domain. For each stage it makes:

- **`<prefix>-github-deploy-stacks`** (managed policy): CloudFormation on
  `<prefix>-*` stacks and the `Serverless` and `LanguageExtensions`
  transforms; S3 on `<prefix>-*` buckets; the Lambda actions
  CloudFormation's function and permission handlers call (no `lambda:*`,
  no `InvokeFunction`) on `<prefix>-*` functions; the HTTP API; DynamoDB
  `<prefix>-*` tables (TTL included); `<prefix>-*` IoT policies and the IoT
  endpoint lookup ([live sync](live-sync.md)); and IAM on `<prefix>-*`
  roles:
  - `CreateRole`, `PutRolePolicy`, `PutRolePermissionsBoundary`,
    `UpdateRole`, `UpdateRoleDescription` and `AttachRolePolicy` only when
    `iam:PermissionsBoundary` is the stage's boundary, and
    `AttachRolePolicy` only for `AWSLambdaBasicExecutionRole`
    (`iam:PolicyARN`), the one managed policy the stacks attach;
  - `PassRole` only to `lambda.amazonaws.com` and
    `cognito-identity.amazonaws.com`;
  - denied: anything on the `presence-github-deploy*` roles or the
    `presence-github-deploy` stack, `DeleteRolePermissionsBoundary`
    anywhere, and changing the artifact buckets' settings.
- **`<prefix>-github-deploy-edge`**: the [health check](health-check.md)'s
  Route 53 health checks, `<prefix>-*` alarms and SNS topics; DNS records
  only for the stage's domain and names under it
  (`route53:ChangeResourceRecordSetsNormalizedRecordNames`: prod
  `presence.nu01.com` and `*.presence.nu01.com`, which covers
  `sh.presence.nu01.com` and validation records; RC
  `rc.presence.nu01.com` and `*.rc.presence.nu01.com`); and the resources
  that have no name to scope by, through their **`presence:stage` tag**:
  - CloudFront distributions (update, delete, invalidate) and ACM
    certificates (delete, update options) only with the stage's tag;
    Cognito identity pools (update, delete) likewise;
  - tagging only with the stage's tag and only resources with that tag or
    none yet (a new one); untagging never removes `presence:stage`;
  - CloudFront functions by name (`<prefix>-*`);
  - creating distributions, functions, certificates, pools, origin access
    controls and response headers policies, and reading CloudFront, ACM
    and pools, stay account-wide (nothing existing is changed by them).
- **`<prefix>-app-boundary`**, the **permissions boundary** every role the
  stage's stacks create must carry (the auth API's function roles, the
  identity pool's authenticated role): the functions' logs
  (`/aws/lambda/<prefix>-*`), the `<prefix>-*` tables, the
  `<prefix>-user-data-*` bucket, the stage's identity pool (by tag;
  `IfExists`, so it can't break sign-in if Cognito leaves the key out),
  `GetId`, `iot:AttachPolicy`, and live sync on `presence/<stage>/*`
  topics. `scripts/deploy.sh` passes it to `identity.yaml` and the auth API
  (`PermissionsBoundary`; SAM's `Globals.Function.PermissionsBoundary`).
  So a deploy can't create a role reaching past its stage: an RC function
  can't read prod's tables or bucket, or mint tokens for prod's pool.
- **`<prefix>-sam-artifacts-<account>`**, the stage's **SAM artifact
  bucket** (private, encrypted, objects expire after 30 days).
  `scripts/deploy.sh` runs `sam deploy --s3-bucket <it> --s3-prefix
  <stack>`; `samconfig.toml` no longer sets `resolve_s3`, so SAM's shared
  `aws-sam-cli-managed-default` bucket, which both stages could write, is
  no longer used (or allowed). Its settings are the administrator's.

The prod role's `presence-*` prefix also covers `presence-rc-*` and
`presence-sh`: prod is the more trusted stage. The RC role's covers only
`presence-rc-*`.

### Stage separation

What the RC role still can't be kept from, in the same account:

- **HTTP APIs:** API Gateway HTTP APIs have only IDs; `/apis/*` stays
  account-wide, so the RC role could change prod's API (routes,
  integrations). Tag-based conditions on API Gateway's sub-resources
  weren't adopted (they'd need every route and integration tagged).
- **Origin access controls and response headers policies:** only IDs and
  no tags, so the RC role could update or delete prod's (e.g. weaken its
  CSP or break its bucket access).
- **`cognito-identity:SetIdentityPoolRoles`** has no resource to scope:
  the RC role could set prod's pool's roles, though only to `presence-rc-*`
  roles (`PassRole`), whose trust is the RC pool, so it would break prod
  sign-in rather than reach prod data.
- **Route 53 health checks** have no names: either role can change any.
- `iot:DescribeEndpoint`, `cloudformation:ListExports` and creating the
  untaggable CloudFront resources are account-wide (read-only or new
  resources).
- The account also holds other projects' stacks; both roles are kept to
  Presence's names, tags and records.

**Recommended:** move the release candidate to its **own AWS account**
(an AWS Organizations member account with its own OIDC provider, role,
zone delegation for `rc.presence.nu01.com` and SAM bucket). Account
boundaries separate everything above, with no tags to keep right. Not
done yet.

### Setting it up, and updating it

An administrator deploys the stack (it creates IAM resources and uses
`Fn::ForEach`); the commands are in
[presence_infra/README.md](../presence_infra/README.md). Run it again
whenever `github-deploy.yaml` changes, before the next deploy.

**Moving to the boundaries and tags** (this change; once, in this
order):

1. With admin credentials, tag the existing resources of both stages:
   `bash scripts/tag-stage-resources.sh prod` and `… rc` (the
   distributions and certificates of `presence-web`, `presence-sh` and
   `presence-rc-web`, and both identity pools; `DRY_RUN=1` lists them).
   Without the tags, the new policies refuse to update them.
2. Merge the change to `main`.
3. With admin credentials, update `presence-github-deploy` (the command in
   `presence_infra/README.md`, now with `CAPABILITY_AUTO_EXPAND`). From
   here, deploys from before this change fail (SAM's shared bucket is no
   longer allowed); deploys from `main` work.
4. Cut the RC and GA releases as usual. Their deploys add the tags to the
   templates and attach the boundary to the existing roles
   (`PutRolePermissionsBoundary`; the roles' policies are unchanged, so no
   `PutRolePolicy` runs on a role without one). If one fails on IAM, run
   it once by hand with admin credentials (`TAG=<tag> bash
   scripts/deploy.sh`, `STAGE=rc` for the RC), then go back to the
   workflows.

### Settings

- The Google web client ID comes from the repository variable
  `GOOGLE_WEB_CLIENT_ID`, and rbacr's from the repository secret
  `RBACR_TOKEN` (a root's token) and the variables `RBACR_URL` and
  `RBACR_SYSTEM` (unset: `https://rbacr.nu01.com`, GA rbacr, and
  `presence`). Prod accepts only GA rbacr; local development uses rbacr's
  RC ([Local CDN](local-cdn.md)); see
  [Auth API](auth-api.md). Who is a root is rbacr's root list, not a
  deploy setting (the old `PRESENCE_ROOT_DOMAINS` and
  `PRESENCE_ROOT_EMAILS` variables are unused and can be deleted).
- **Local development syncs with the prod bucket and pool:** the prod
  user-data bucket's CORS allows `https://local.presence.nu01.com:8443` and
  `http://localhost:8080`, and the dev app uses prod's
  `USER_DATA_BUCKET`/`COGNITO_IDENTITY_POOL_ID` from `.env` (see [Cloud
  sync](cloud-sync.md)). A development build (or a bug in one) can write
  real users' prod data, under the developer's own identity. Recommended:
  a separate `presence-dev` stage (its own user-data and identity stacks,
  CORS for the local origins only), and dropping the local origins from
  prod's CORS. Not done yet.

## Response headers

`site.yaml` has two CloudFront response headers policies instead of AWS's
managed security-headers one. Both keep its headers (HSTS one year,
`X-Content-Type-Options: nosniff`, `Referrer-Policy:
strict-origin-when-cross-origin`, `X-XSS-Protection: 1; mode=block`), with
`X-Frame-Options: DENY` instead of `SAMEORIGIN`:

- **`<stack>-app`** (`/app*`): a Content Security Policy for what the web
  app loads, and `Permissions-Policy: camera=(self), microphone=(self),
  geolocation=(self)`:
  - `default-src 'self'`; `object-src 'none'`; `base-uri 'self'`;
    `form-action 'self'`; `frame-ancestors 'none'` (nothing may frame it);
    `manifest-src 'self'`; `worker-src 'self' blob:`.
  - `script-src 'self' 'wasm-unsafe-eval' 'unsafe-eval'
    https://www.gstatic.com/flutter-canvaskit/
    https://accounts.google.com/gsi/`: CanvasKit, which Flutter loads from
    gstatic, and Google Identity Services. `'wasm-unsafe-eval'` compiles
    CanvasKit's and TensorFlow Lite's WebAssembly. **`'unsafe-eval'`** is
    needed by TensorFlow Lite's Emscripten glue (`tflite_web_api_cc.js`:
    embind builds its bindings with `new Function()`), which [subject
    recognition](recognition.md) loads from `tfjs/`; without it loading a
    model fails with an `EvalError`. Dropping it would need a
    TensorFlow Lite build without dynamic execution.
  - `style-src 'self' 'unsafe-inline' https://accounts.google.com/gsi/`:
    **`'unsafe-inline'`** because Flutter's web engine injects `<style>`
    elements and `style` attributes; there's no nonce support for those.
  - `connect-src 'self' blob: data: https://www.gstatic.com
    https://fonts.gstatic.com https://accounts.google.com
    https://tile.openstreetmap.org https://*.amazonaws.com
    wss://*.amazonaws.com`: the auth API, CanvasKit and Flutter's fallback
    fonts, Google sign-in, map tiles, and AWS (Cognito
    `cognito-identity.<region>.amazonaws.com`, the user-data bucket
    `<bucket>.s3.<region>.amazonaws.com`, and live sync's MQTT over
    `wss://<id>-ats.iot.<region>.amazonaws.com`). `blob:`: the app reads
    back the clips and frames it recorded with `fetch()`.
  - `img-src 'self' data: blob: https://tile.openstreetmap.org
    https://*.googleusercontent.com https://*.amazonaws.com`;
    `media-src 'self' data: blob: https://*.amazonaws.com`; `font-src
    'self' data: https://fonts.gstatic.com`; `frame-src
    https://accounts.google.com`.
- **`<stack>-index`** (`/`): `default-src 'none'`, the redirect script
  allowed by its SHA-256 hash, `img-src 'self'`, `base-uri`/`form-action
  'none'`, `frame-ancestors 'none'`, and camera, microphone and location
  off. If `presence_index/site/index.html`'s `<script>` changes, update the
  hash in `site.yaml` (the page's meta refresh still redirects meanwhile).
- `/api/*` and `/health` (JSON) have no headers policy, as before; the
  install URL keeps the managed one.

## Verified

- The boundaries and tag scoping (2026-10-07): `github-deploy.yaml`
  passes `aws cloudformation validate-template` and cfn-lint; its
  `Fn::ForEach` expansion, with each stage's values filled in, passes IAM
  Access Analyzer's `validate-policy` (only "redundant resource"
  suggestions), and `aws iam simulate-custom-policy` on the RC policies
  allows creating a `presence-rc-*` role only with the RC boundary,
  attaching only `AWSLambdaBasicExecutionRole`, updating a distribution,
  certificate or pool only when tagged `rc`, tagging one already tagged
  `prod` never, writing only its own SAM bucket, and changing records only
  under `rc.presence.nu01.com`; and refuses the prod role its own role,
  its stack, and `DeleteRolePermissionsBoundary`. Every managed policy is
  under IAM's 6,144-character limit (the largest about 5,650). SAM
  translates `Globals.Function.PermissionsBoundary` onto all six function
  roles. Not yet deployed (see the steps above).
- The app's CSP (2026-10-07), injected into the live
  https://presence.nu01.com/app/ in headless Chrome (Playwright, fake
  camera): the consent screen, the camera after **I agree**, the Google
  button, a startup clip, and a TensorFlow Lite model loaded through
  `tfjs/` all worked with no CSP violations (removing `'unsafe-eval'`
  made the model fail; without `blob:` in `connect-src` reading back a
  clip was refused, so it's there). The index policy still redirects `/`
  to `/app/` with the meta refresh removed.
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
