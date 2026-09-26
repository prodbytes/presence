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
| `/api/*` | API Gateway (origin path `/Prod`): the [events API](events-api.md). Not cached, with every viewer header but `Host` forwarded |

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
  - [presence_api_events/template.yaml](../presence_api_events/template.yaml)
    (SAM), stack `presence-api-events`. Its `ApiDomain` output is the
    distribution's API origin.
  - Everything is in `us-east-1` (account 712151682816).
- **Content:** files are uploaded with `Cache-Control: no-cache`, because
  Flutter's web files aren't content-hashed, and every deploy invalidates
  `/*`. Unknown paths return 404 (the bucket policy allows `ListBucket` for
  the distribution).
- **`scripts/deploy.sh`** first deploys `user-data.yaml` and
  `identity.yaml` ([cloud sync](cloud-sync.md)). It then builds the web app
  for `/app/` (`make web` with `WEB_BASE_HREF=/app/`), with the version from
  the tag and the identity pool and bucket IDs. After that it runs
  `sam build` and `sam deploy`, deploys `site.yaml`, uploads, invalidates,
  and **smoke-tests the live site**: `/app/version.json` must report the
  tag's version, `/` must be the index page, and `/app/` and `/api/events`
  must answer. It retries for up to 10 minutes.

## GitHub access

- The workflow has no AWS keys. It exchanges GitHub's OIDC token for the
  `presence-github-deploy` role
  ([presence_infra/github-deploy.yaml](../presence_infra/github-deploy.yaml)),
  whose ARN is the repository variable `AWS_DEPLOY_ROLE_ARN`.
- The role trusts only `repo:prodbytes/presence:ref:refs/tags/*GA`, so the
  job has no `environment:`, which would change that subject. Its
  permissions are limited to the Presence stacks: CloudFormation, S3,
  Lambda, API Gateway, `presence-*` IAM roles, CloudFront, ACM and the
  `nu01.com` zone.
- An administrator deploys that stack once (it creates IAM resources); the
  commands are in [presence_infra/README.md](../presence_infra/README.md).
- The Google web client ID comes from the repository variable
  `GOOGLE_WEB_CLIENT_ID`.

## Verified

- `TAG=0.1.0-GA bash scripts/deploy.sh`, run by hand with admin
  credentials, created both stacks, uploaded, and passed its smoke test.
- On the live site:
  - `/`, `/app/`, `/app/version.json` (`0.1.0`) and `/api/events`
    (`{"events":[]}`) return 200;
  - `/app` returns 301 to `/app/`, `http://` redirects to `https://`, and
    unknown paths return 404;
  - responses carry HSTS, `X-Frame-Options`, `X-Content-Type-Options` and
    `Referrer-Policy`;
  - headless Chrome opening https://presence.nu01.com/ ended on `/app/`,
    with the app rendered (camera view, Clip, Ready) and no failed requests.

## Known limitations

- The GitHub role stack isn't deployed yet. Creating IAM resources needs an
  administrator, so until it exists (and `AWS_DEPLOY_ROLE_ARN` is set), a
  GA tag's Deploy run fails at the AWS login step.
- Google sign-in on the live site needs `https://presence.nu01.com` among
  the web OAuth client's authorized JavaScript origins.
- The events API has no authorizer, so `/api/events` is public.
