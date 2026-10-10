# presence_infra

The production (and release-candidate) infrastructure, as CloudFormation
templates.

| Template | Stack | Holds |
|---|---|---|
| [site.yaml](site.yaml) | `presence-web` | https://presence.nu01.com: the ACM certificate (DNS-validated in the `nu01.com` zone), a private S3 bucket, a CloudFront distribution with its response headers policies (CSP, Permissions-Policy), the Route 53 A/AAAA aliases, and the `/health` check with its alarm |
| [user-data.yaml](user-data.yaml) | `presence-user-data` | The bucket for users' clips and events: private, encrypted, versioned, S3 Intelligent-Tiering, with CORS for the app's origins |
| [identity.yaml](identity.yaml) | `presence-identity` | The Cognito identity pool (Google sign-in only) and the role that lets each signed-in user read and write their own `<identityId>/` prefix, and use live sync on their own MQTT topics (`presence/<stage>/<identityId>/*`), with the `presence-live-sync` IoT policy the auth API attaches to each identity. See [specs/cloud-sync.md](../specs/cloud-sync.md) and [specs/live-sync.md](../specs/live-sync.md) |
| [github-deploy.yaml](github-deploy.yaml) | `presence-github-deploy` | The GitHub OIDC identity provider, the `presence-github-deploy` role (Deploy workflow, `*GA` tags) and the `presence-github-deploy-rc` role (Deploy RC workflow: `*RC*` tags and manual runs from `main`); per stage, from one `Fn::ForEach` definition: the deploy policies, the permissions boundary of every role the stage's stacks create (`<prefix>-app-boundary`), and the SAM artifact bucket (`<prefix>-sam-artifacts-<account>`) |

The install URL, https://sh.presence.nu01.com, is its own component:
[presence_sh/](../presence_sh) (stack `presence-sh`, deployed by
`scripts/deploy-sh.sh`).

`scripts/deploy.sh` deploys every stack except `presence-github-deploy`, in
this order: `presence-user-data`, `presence-identity`, the auth API
(`presence-auth-api`, SAM), then `presence-web`. With `STAGE=rc` it deploys the
release candidate's own copies (`presence-rc-user-data`,
`presence-rc-identity`, `presence-rc-auth-api` and `presence-rc-web`) for
https://rc.presence.nu01.com; `*RC*` tags do that through
[deploy-rc.yml](../.github/workflows/deploy-rc.yml).

## The distribution

It mirrors the local Floci one ([presence_floci/](../presence_floci)):

| Path | Origin |
|---|---|
| default (`/`) | S3 `index.html`, the [index page](../presence_index) that redirects to `/app/` |
| `/app*` | S3 `app/`, the Flutter web build (`--base-href /app/`). A CloudFront Function redirects `/app` to `/app/` and maps directory URIs to `index.html` |
| `/api/*` | The [auth API](../presence_api_auth)'s HTTP API (stack `presence-auth-api`), not cached, with every viewer header but `Host` forwarded |
| `/health` | The [health check](../presence_health)'s HTTP API (stack `presence-health`), not cached |

Every file is uploaded with `Cache-Control: no-cache`, because Flutter's web
files aren't content-hashed. Each deploy also invalidates `/*`.

## Deploying

Push a GA tag (`bash scripts/release-ga.sh`, on `main`). The
[Deploy workflow](../.github/workflows/deploy.yml) checks the tag's commit
is on `main`, then runs [scripts/deploy.sh](../scripts/deploy.sh), which:

1. checks the stage's permissions boundary and SAM artifact bucket exist
   (they come from `presence-github-deploy`);
2. deploys `user-data.yaml` and `identity.yaml` (with the boundary on the
   authenticated role, and the pool tagged with its stage), and looks up
   the AWS IoT endpoint;
3. builds the web app for `/app/`;
4. deploys the auth API, then the `/health` check (SAM: `presence_api_auth`,
   then `presence_health`, which imports the auth API's table exports;
   uploading to the stage's artifact bucket, with the boundary on every
   function role);
5. deploys `site.yaml` (certificate and distribution tagged with the
   stage);
6. uploads the content and invalidates the cache;
7. smoke-tests the live site: `/app/version.json` reports the tag's
   version, `/` is the index, `/api/auth/profile` answers 401 without a token,
   `/api/auth/anonymous` reports RBAC, and `/health` is ok with this
   version.

If any step fails it prints the version that was live before and how to
redeploy it. Then the workflow deploys the install URL
(`scripts/deploy-sh.sh`).

`scripts/deploy.sh` also runs by hand with admin credentials (inside
devbox): `TAG=0.1.<Z>-GA bash scripts/deploy.sh`.

## One-time setup

1. Deploy the GitHub roles. The stack creates IAM resources and expands
   `Fn::ForEach`, so it's done by an administrator:

   ```bash
   aws cloudformation deploy --region us-east-1 \
     --stack-name presence-github-deploy \
     --template-file presence_infra/github-deploy.yaml \
     --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
     --parameter-overrides "HostedZoneId=$HOSTED_ZONE_ID"   # from the private .env
   ```

   The prod role trusts only tokens for `*GA` tags, the RC role `*RC*`
   tags and `main`, each in both subject forms:
   `repo:prodbytes/presence:ref:…` and the immutable
   `repo:prodbytes@288014477/presence@1387180019:ref:…`
   (`GitHubImmutableRepository`; the repository uses immutable OIDC
   subject claims). Each stage's permissions cover its own `<prefix>-*`
   stacks, buckets, functions, tables, IoT policies, alarms and topics;
   its `<prefix>-*` IAM roles only with its permissions boundary on them
   (passed only to Lambda and Cognito); CloudFront distributions, ACM
   certificates and Cognito identity pools only with its `presence:stage`
   tag; and DNS records only under its domain. See
   [specs/deploy.md](../specs/deploy.md#github-access) for the details and
   what can't be separated by stage in one account. Run the same command
   again whenever `github-deploy.yaml` changes, before the next deploy.

   Resources created before the `presence:stage` tags existed need them
   once, before the stack is updated:
   `bash scripts/tag-stage-resources.sh prod` and `… rc` (admin
   credentials; `DRY_RUN=1` lists what it would tag).

2. Set the repository variable to the stack's `DeployRoleArn` output:

   ```bash
   gh variable set AWS_DEPLOY_ROLE_ARN --body "<DeployRoleArn>"
   gh variable set AWS_DEPLOY_RC_ROLE_ARN --body "<RcDeployRoleArn>"
   gh variable set HOSTED_ZONE_ID --body "<the zone ID, HOSTED_ZONE_ID in the private .env>"
   ```

3. In the Google Cloud Console, add `https://presence.nu01.com` and
   `https://rc.presence.nu01.com` to the web OAuth client's **Authorized
   JavaScript origins**.
