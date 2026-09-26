# presence_infra

The production infrastructure, as CloudFormation templates. The events API
has its own SAM template
([presence_api_events/template.yaml](../presence_api_events/template.yaml)).

| Template | Stack | Holds |
|---|---|---|
| [site.yaml](site.yaml) | `presence-web` | https://presence.nu01.com: the ACM certificate (DNS-validated in the `nu01.com` zone), a private S3 bucket, a CloudFront distribution and the Route 53 A/AAAA aliases |
| [user-data.yaml](user-data.yaml) | `presence-user-data` | The bucket for users' clips and events: private, encrypted, versioned, with CORS for the app's origins |
| [identity.yaml](identity.yaml) | `presence-identity` | The Cognito identity pool (Google sign-in only) and the role that lets each signed-in user read and write their own `<identityId>/` prefix. See [specs/cloud-sync.md](../specs/cloud-sync.md) |
| [github-deploy.yaml](github-deploy.yaml) | `presence-github-deploy` | The GitHub OIDC identity provider and the `presence-github-deploy` role that the Deploy workflow assumes |

`scripts/deploy.sh` deploys every stack except `presence-github-deploy`, in
this order: `presence-user-data`, `presence-identity`, then the API
(`presence-api-events`), then `presence-web`.

## The distribution

It mirrors the local Floci one ([presence_floci/](../presence_floci)):

| Path | Origin |
|---|---|
| default (`/`) | S3 `index.html`, the [index page](../presence_index) that redirects to `/app/` |
| `/app*` | S3 `app/`, the Flutter web build (`--base-href /app/`). A CloudFront Function redirects `/app` to `/app/` and maps directory URIs to `index.html` |
| `/api/*` | API Gateway (`presence-api-events`, origin path `/Prod`), not cached, with every viewer header but `Host` forwarded |

Every file is uploaded with `Cache-Control: no-cache`, because Flutter's web
files aren't content-hashed. Each deploy also invalidates `/*`.

## Deploying

Push a GA tag (`bash scripts/release-ga.sh`). The
[Deploy workflow](../.github/workflows/deploy.yml) then runs
[scripts/deploy.sh](../scripts/deploy.sh), which:

1. builds the web app for `/app/`;
2. deploys the API (SAM);
3. deploys `site.yaml`;
4. uploads the content and invalidates the cache;
5. checks that `https://presence.nu01.com/app/version.json` reports the tag's
   version.

`scripts/deploy.sh` also runs by hand with admin credentials (inside
devbox): `TAG=0.1.<Z>-GA bash scripts/deploy.sh`.

## One-time setup

1. Deploy the GitHub role. It creates IAM resources, so it's done by an
   administrator, once:

   ```bash
   aws cloudformation deploy --region us-east-1 \
     --stack-name presence-github-deploy \
     --template-file presence_infra/github-deploy.yaml \
     --capabilities CAPABILITY_NAMED_IAM \
     --parameter-overrides "HostedZoneId=$HOSTED_ZONE_ID"   # from the private .env
   ```

   The role trusts only tokens for `repo:prodbytes/presence:ref:refs/tags/*GA`.
   Its permissions cover the Presence stacks: CloudFormation, S3, Lambda,
   API Gateway, the `presence-*` IAM roles (passed only to Lambda and
   Cognito), Cognito identity pools, CloudFront, ACM, and the `nu01.com`
   zone.

2. Set the repository variable to the stack's `DeployRoleArn` output:

   ```bash
   gh variable set AWS_DEPLOY_ROLE_ARN --body "<DeployRoleArn>"
   gh variable set HOSTED_ZONE_ID --body "<the zone ID, HOSTED_ZONE_ID in the private .env>"
   ```

3. In the Google Cloud Console, add `https://presence.nu01.com` to the web
   OAuth client's **Authorized JavaScript origins**.
