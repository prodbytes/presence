#!/usr/bin/env bash
# Deploys Presence to production, https://presence.nu01.com, or with
# STAGE=rc to the release-candidate site, https://rc.presence.nu01.com
# (its own stacks, presence-rc-*, and its own bucket and identity pool):
#   1. deploys the user data stacks (presence_infra/user-data.yaml: the
#      bucket; presence_infra/identity.yaml: the Cognito identity pool and
#      live sync's IoT policy), and looks up the account's AWS IoT data
#      endpoint (live sync)
#   2. builds the Flutter web app for /app/ (make web, WEB_BASE_HREF=/app/),
#      with the pool, bucket and IoT endpoint from step 1 and rbacr's URL
#      and system (the app asks rbacr for its roles itself)
#   3. deploys the auth API (sam build + sam deploy: presence_api_auth, stack
#      presence-auth-api / presence-rc-auth-api: also the Presence session
#      issuer, https://<site>/api/auth, whose tokens every API accepts) and
#      its health check
#      (presence_health, stack presence-health / presence-rc-health: GET
#      /health, which imports the auth API's table exports): an existing
#      health stack first, so it lets go of exports the auth API drops; a
#      new stage's after, once the exports it imports exist; and the
#      payments API (presence_api_payments, stack presence-payments /
#      presence-rc-payments: the Stripe Payment Links, /api/payments/*,
#      whose authorizer trusts the auth API's session issuer)
#   4. deploys the site (CloudFormation presence_infra/site.yaml:
#      presence-web: certificate, bucket, CloudFront, DNS, and the Route 53
#      health check of /health with its alarm emails)
#   5. uploads the site pages (/, /privacy, /tos, /delete-account) and the web build (/app/), and
#      invalidates the CloudFront cache
#   6. smoke-tests the live site (and, once the APIs enforce the origin
#      secret, that their own execute-api hosts refuse direct calls with
#      403): /app/version.json must report this
#      version, / must be the index page, /privacy, /tos and /delete-account the legal pages, and /api/auth/profile must refuse
#      a request without a token (401: the route and its authorizer are live),
#      and so must /api/payments/links,
#      and /api/auth/anonymous must report RBAC mode, the session issuer's
#      /.well-known/openid-configuration must name https://<site>/api/auth
#      and its jwks.json an RSA key, and /health must say every dependency
#      is ok
#
# Order across systems when sessions first ship (specs/sessions.md):
# rbacr with RBACR_TRUSTED_ISSUERS naming this stage's issuer first (the
# app sends rbacr the session token), then this deploy (the backends, then
# the web app), then the Android and iOS builds. presence-github-deploy
# must be updated before it (KMS and SSM permissions).
#
# Every role the stacks create carries the stage's permissions boundary
# (<prefix>-app-boundary), and SAM uploads to the stage's own bucket
# (<prefix>-sam-artifacts-<account>), under each stack's own prefix; both
# come from the presence-github-deploy stack
# (presence_infra/github-deploy.yaml), which must be deployed first. If the deploy fails, it prints the version that
# was live before and how to put it back.
#
# Run by .github/workflows/deploy.yml on *GA tags (deploy-rc.yml on *RC*
# tags, STAGE=rc), or by hand with admin credentials. Settings, from the
# environment:
#   TAG          the release tag, X.Y.Z-GA: its X.Y must match the version
#                files and its Z becomes the build's Z (default: none, so Z
#                is the current time)
#   STAGE        prod (default) or rc
#   AWS_REGION   default us-east-1 (CloudFront certificates live there)
#   SKIP_BUILD   1 to deploy an existing presence_app/build/web
#   GOOGLE_WEB_CLIENT_ID  the web OAuth client the identity pool trusts
#   HOSTED_ZONE_ID        the Route 53 zone of presence.nu01.com
#                (both default to the repo's .env, from the private repo)
#   INGEST_CONCURRENCY  the cloud detector's reserved concurrency (default 0:
#                none; the account's Lambda quota must leave 10 unreserved)
#   GOOGLE_DEVICE_CLIENT_ID  presence-streamer's device sign-in client, whose
#                ID tokens the auth API exchanges for sessions too (optional; also .env)
#   APPLE_CLIENT_IDS  Sign in with Apple's clients, the iOS bundle ID
#                (default com.nu01.presence; also .env)
#   APPLE_SIGNIN_KEY_ID, APPLE_SIGNIN_KEY_PARAMETER  Sign in with Apple's
#                key, to revoke users' Apple tokens when they delete their
#                account: the key's ID and the SSM SecureString parameter an
#                administrator put the .p8 in (never the key itself; both
#                or neither; also .env), with APPLE_TEAM_ID, the team (as
#                the App Store build's)
#   PRESENCE_HEALTH_EMAILS who is emailed when the /health check fails or
#                recovers, comma-separated (default julio+health@nu01.com;
#                also from .env). Each must confirm AWS's subscription email.
#   PERMISSIONS_BOUNDARY  the roles' boundary ARN (default: the stage's,
#                arn:aws:iam::<account>:policy/<prefix>-app-boundary)
#   SAM_ARTIFACT_BUCKET   where sam deploy uploads (default: the stage's,
#                <prefix>-sam-artifacts-<account>)
#   RBACR_TOKEN  an rbacr API token owned by an rbacr root: rbacr keeps every
#                role (who may use the app, sync with the cloud, administer
#                it; rbacr's root list makes roots), and subscriptions (at
#                nu01.com) and vouchers grant there. Never given to the app,
#                which asks rbacr with the user's own token. Required, from the environment (the
#                RBACR_TOKEN secret in CI) or .env: without it nobody has a role.
#   ORIGIN_SECRET what the site's CloudFront sends the APIs so they answer
#                only through it (specs/origin-check.md): letters, digits, _
#                and -, 32 or more (also .env). Default: derived from
#                RBACR_TOKEN and the stage (an HMAC), so CI needs no other
#                secret. Changing it (or RBACR_TOKEN) makes the APIs refuse
#                the site for the minutes until the site is deployed too.
#   RBACR_URL    rbacr's origin (default https://rbacr.nu01.com, GA rbacr,
#                the only one prod accepts; also .env)
#   RBACR_SYSTEM the rbacr system of the app's roles (default presence; also .env)
#   STRIPE_MONTHLY_LINK, STRIPE_YEARLY_LINK  the Premium plans' Stripe
#                Payment Links until an admin saves others in the Admin tab
#                (default: the links below; also .env; empty: not offered)
#   RBACR_GRANT_TOKEN  an rbacr root's API token the payments API grants and
#                revokes premium with for App Store and Google Play
#                subscriptions (may be the same token as RBACR_TOKEN; also
#                .env; the RBACR_GRANT_TOKEN secret in CI). Unset: store
#                purchases are off (the verify route answers 503).
#   GOOGLE_PLAY_SECRET  the Secrets Manager secret (name, under the stage's
#                prefix: presence/... or presence-rc/...) with the Google
#                service account's key file for Google Play purchases
#                (also .env). Unset: Google Play purchases are off.
#   STORE_ALLOW_SANDBOX  true or false: App Store sandbox and Google Play
#                test purchases count (default: true for rc, false for
#                prod; set true on prod while a build is in App Review)
# Needs the AWS CLI, the SAM CLI, JDK 25, Maven and Flutter (all in devbox).
set -euo pipefail

cd "$(dirname "$0")/.."
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
STAGE="${STAGE:-prod}"
case "$STAGE" in
  prod)
    stack_prefix=presence
    DOMAIN=presence.nu01.com
    # Local development syncs with the prod bucket (see specs/cloud-sync.md
    # and specs/deploy.md: a separate dev bucket is recommended).
    ORIGINS="https://$DOMAIN,https://local.presence.nu01.com:8443,http://localhost:8080"
    ;;
  rc)
    stack_prefix=presence-rc
    DOMAIN=rc.presence.nu01.com
    ORIGINS="https://$DOMAIN"
    ;;
  *) echo "error: STAGE must be prod or rc (got '$STAGE')" >&2; exit 2 ;;
esac
SITE_STACK=$stack_prefix-web
AUTH_STACK=$stack_prefix-auth-api
HEALTH_STACK=$stack_prefix-health
INGEST_STACK=$stack_prefix-ingest
PAYMENTS_STACK=$stack_prefix-payments
USER_DATA_STACK=$stack_prefix-user-data
IDENTITY_STACK=$stack_prefix-identity

if [[ "${TAG:-}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-.*)?$ ]]; then
  export VERSION_Z="${BASH_REMATCH[3]}"
  tag_xy="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
elif [[ -n "${TAG:-}" ]]; then
  echo "error: TAG '$TAG' isn't X.Y.Z[-suffix]" >&2
  exit 2
fi
# Fixes the build number too, so the build and the check below agree.
export BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%s)}"
source scripts/version.sh
if [[ -n "${tag_xy:-}" && "$tag_xy" != "$VERSION_X.$VERSION_Y" ]]; then
  echo "error: tag $TAG is version $tag_xy, but version.X.txt/version.Y.txt say $VERSION_X.$VERSION_Y" >&2
  exit 1
fi
echo "==> deploying version $VERSION to https://$DOMAIN/ ($STAGE, $AWS_REGION)"

# What was live before, so a failed deploy can say how to put it back.
previous="$(curl -fsS --max-time 20 "https://$DOMAIN/app/version.json?deploy=$BUILD_NUMBER" 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null)" || previous=""
if [[ ! "$previous" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  previous=""
fi
echo "    live before: ${previous:-unknown}"
on_exit() {
  local status=$?
  [[ $status -eq 0 ]] && return
  local kind=GA workflow=deploy.yml prefix=""
  if [[ "$STAGE" == rc ]]; then kind=RC workflow=deploy-rc.yml prefix="STAGE=rc "; fi
  local now
  now="$(curl -fsS --max-time 20 "https://$DOMAIN/app/version.json?failed=$BUILD_NUMBER" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null)" || now=""
  {
    echo
    echo "error: the deploy of $VERSION to https://$DOMAIN/ failed (exit $status)."
    echo "  live before this deploy: ${previous:-unknown}; live now: ${now:-unknown}"
    if [[ -n "$previous" ]]; then
      # The previous release's tag, if this checkout has it (CI's may not).
      local tag
      tag="$(git tag --list "$previous-$kind*" 2>/dev/null | tail -1)"
      tag="${tag:-$previous-$kind}"
      echo "  to put $previous back, re-run the $workflow workflow for its tag:"
      if [[ "$STAGE" == rc ]]; then
        echo "    gh workflow run $workflow -f tag=$tag"
      else
        echo "    gh run list --workflow $workflow --branch $tag   # then: gh run rerun <id>"
      fi
      echo "  or by hand, with admin credentials:"
      echo "    git checkout $tag && ${prefix}TAG=$tag bash scripts/deploy.sh"
    fi
  } >&2
}
trap on_exit EXIT

stack_output() { # stack_output <stack> <output key>
  aws cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}

# Private settings: from the environment, else the private .env.
for name in GOOGLE_WEB_CLIENT_ID HOSTED_ZONE_ID; do
  if [[ -z "${!name:-}" && -f .env ]]; then
    printf -v "$name" '%s' "$(sed -n "s/^$name=//p" .env | tail -1)"
  fi
  if [[ -z "${!name:-}" ]]; then
    echo "error: $name isn't set (environment or .env; see .env.example)" >&2
    exit 1
  fi
done

# Optional: the streamer's device sign-in client (environment, else .env).
if [[ -z "${GOOGLE_DEVICE_CLIENT_ID:-}" && -f .env ]]; then
  GOOGLE_DEVICE_CLIENT_ID="$(sed -n 's/^GOOGLE_DEVICE_CLIENT_ID=//p' .env | tail -1)"
fi
GOOGLE_DEVICE_CLIENT_ID="${GOOGLE_DEVICE_CLIENT_ID:-}"

# Sign in with Apple (environment, else .env): its clients, and the key that
# revokes users' Apple tokens (optional: all three or none). Only the key's
# SSM parameter name is passed, never the key.
for name in APPLE_CLIENT_IDS APPLE_TEAM_ID APPLE_SIGNIN_KEY_ID APPLE_SIGNIN_KEY_PARAMETER; do
  if [[ -z "${!name:-}" && -f .env ]]; then
    printf -v "$name" '%s' "$(sed -n "s/^$name=//p" .env | tail -1)"
  fi
done
APPLE_CLIENT_IDS="${APPLE_CLIENT_IDS:-com.nu01.presence}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
APPLE_SIGNIN_KEY_ID="${APPLE_SIGNIN_KEY_ID:-}"
APPLE_SIGNIN_KEY_PARAMETER="${APPLE_SIGNIN_KEY_PARAMETER:-}"
if [[ ! "$APPLE_CLIENT_IDS" =~ ^[A-Za-z0-9.-]+(,[A-Za-z0-9.-]+)*$ ]]; then
  echo "error: APPLE_CLIENT_IDS must be comma-separated bundle IDs" >&2
  exit 1
fi
apple_key=()
if [[ -n "$APPLE_SIGNIN_KEY_ID$APPLE_SIGNIN_KEY_PARAMETER" ]]; then
  if [[ ! "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ || ! "$APPLE_SIGNIN_KEY_ID" =~ ^[A-Z0-9]{10}$
        || ! "$APPLE_SIGNIN_KEY_PARAMETER" =~ ^/$stack_prefix/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$ ]]; then
    echo "error: APPLE_TEAM_ID and APPLE_SIGNIN_KEY_ID must be Apple's 10-character IDs and APPLE_SIGNIN_KEY_PARAMETER an SSM parameter under /$stack_prefix/ (both key settings, or neither)" >&2
    exit 1
  fi
  apple_key=("AppleTeamId=$APPLE_TEAM_ID" "AppleKeyId=$APPLE_SIGNIN_KEY_ID" "AppleKeyParameter=$APPLE_SIGNIN_KEY_PARAMETER")
  echo "    Sign in with Apple: $APPLE_CLIENT_IDS, with a key for revocation"
else
  echo "    Sign in with Apple: $APPLE_CLIENT_IDS (no key: Apple tokens aren't revoked at account deletion)"
fi

# Health alarm emails: from the environment, else .env, else the default.
if [[ -z "${PRESENCE_HEALTH_EMAILS:-}" && -f .env ]]; then
  PRESENCE_HEALTH_EMAILS="$(sed -n 's/^PRESENCE_HEALTH_EMAILS=//p' .env | tail -1)"
fi
PRESENCE_HEALTH_EMAILS="${PRESENCE_HEALTH_EMAILS:-julio+health@nu01.com}"
if [[ ! "$PRESENCE_HEALTH_EMAILS" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+(,[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+)*$ ]]; then
  echo "error: PRESENCE_HEALTH_EMAILS must be comma-separated emails" >&2
  exit 1
fi
echo "    health alarm emails: $(tr ',' '\n' <<<"$PRESENCE_HEALTH_EMAILS" | grep -c .)"

# The stage's permissions boundary and SAM bucket (presence-github-deploy).
account="$(aws sts get-caller-identity --query Account --output text)"
PERMISSIONS_BOUNDARY="${PERMISSIONS_BOUNDARY:-arn:aws:iam::$account:policy/$stack_prefix-app-boundary}"
SAM_ARTIFACT_BUCKET="${SAM_ARTIFACT_BUCKET:-$stack_prefix-sam-artifacts-$account}"
if ! aws iam get-policy --policy-arn "$PERMISSIONS_BOUNDARY" >/dev/null 2>&1; then
  echo "error: the permissions boundary $PERMISSIONS_BOUNDARY doesn't exist (or isn't readable)." >&2
  echo "  An administrator deploys it with presence-github-deploy first (presence_infra/README.md)." >&2
  exit 1
fi
if ! aws s3api head-bucket --bucket "$SAM_ARTIFACT_BUCKET" >/dev/null 2>&1; then
  echo "error: the SAM artifact bucket $SAM_ARTIFACT_BUCKET doesn't exist (or isn't readable)." >&2
  echo "  An administrator deploys it with presence-github-deploy first (presence_infra/README.md)." >&2
  exit 1
fi
echo "    boundary: $PERMISSIONS_BOUNDARY, SAM bucket: $SAM_ARTIFACT_BUCKET"
# rbacr, which keeps every role: from the environment, else .env. The token
# is never logged. Required: without it nobody would have a role.
for name in RBACR_TOKEN RBACR_URL RBACR_SYSTEM; do
  if [[ -z "${!name:-}" && -f .env ]]; then
    printf -v "$name" '%s' "$(sed -n "s/^$name=//p" .env | tail -1)"
  fi
done
RBACR_URL="${RBACR_URL:-https://rbacr.nu01.com}"
RBACR_SYSTEM="${RBACR_SYSTEM:-presence}"
if [[ -z "${RBACR_TOKEN:-}" ]]; then
  echo "error: RBACR_TOKEN isn't set (environment or .env); without rbacr nobody has a role" >&2
  exit 1
fi
if [[ ! "$RBACR_TOKEN" =~ ^[A-Za-z0-9_-]+$ || ! "$RBACR_URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$
      || ! "$RBACR_SYSTEM" =~ ^[a-z0-9][a-z0-9_.:-]{0,62}$ ]]; then
  echo "error: RBACR_TOKEN must be a token, RBACR_URL an https origin and RBACR_SYSTEM an rbacr system ID" >&2
  exit 1
fi
# Prod's roles are GA rbacr's, never the RC's (local development's).
if [[ "$STAGE" == prod && "$RBACR_URL" != https://rbacr.nu01.com ]]; then
  echo "error: prod uses GA rbacr (https://rbacr.nu01.com), not $RBACR_URL" >&2
  exit 1
fi
echo "    rbacr: $RBACR_URL, system $RBACR_SYSTEM, with a token"
# The origin secret: from the environment, else .env, else derived from the
# rbacr token (read from the environment, so it's never on a command line).
# Never logged.
if [[ -z "${ORIGIN_SECRET:-}" && -f .env ]]; then
  ORIGIN_SECRET="$(sed -n 's/^ORIGIN_SECRET=//p' .env | tail -1)"
fi
if [[ -z "${ORIGIN_SECRET:-}" ]]; then
  ORIGIN_SECRET="$(RBACR_TOKEN="$RBACR_TOKEN" python3 -c '
import hashlib, hmac, os, sys
print(hmac.new(os.environ["RBACR_TOKEN"].encode(), ("presence-origin-" + sys.argv[1]).encode(),
               hashlib.sha256).hexdigest())' "$STAGE")"
fi
if [[ ! "$ORIGIN_SECRET" =~ ^[A-Za-z0-9_-]{32,}$ ]]; then
  echo "error: ORIGIN_SECRET must be 32 or more letters, digits, _ or -" >&2
  exit 1
fi
# The Premium plans' Stripe Payment Links (public checkout pages), the
# payments API's defaults until an admin saves others: from the
# environment, else .env, else these.
for name in STRIPE_MONTHLY_LINK STRIPE_YEARLY_LINK; do
  if [[ -z "${!name+set}" && -f .env ]] && grep -q "^$name=" .env; then
    printf -v "$name" '%s' "$(sed -n "s/^$name=//p" .env | tail -1)"
  fi
done
STRIPE_MONTHLY_LINK="${STRIPE_MONTHLY_LINK-https://buy.stripe.com/dRm9AT6F71VfbaN1tl2Ji03}"
STRIPE_YEARLY_LINK="${STRIPE_YEARLY_LINK-https://buy.stripe.com/dRm9AT6F71VfbaN1tl2Ji03}"
for name in STRIPE_MONTHLY_LINK STRIPE_YEARLY_LINK; do
  if [[ ! "${!name}" =~ ^(https://([a-z0-9-]+\.)*stripe\.com(/[A-Za-z0-9._~%-]*)*)?$ ]]; then
    echo "error: $name must be empty or an https link on stripe.com" >&2
    exit 1
  fi
done
echo "    payment links: monthly ${STRIPE_MONTHLY_LINK:-none}, yearly ${STRIPE_YEARLY_LINK:-none}"
# Store purchases (App Store, Google Play): from the environment, else .env.
# Off unless RBACR_GRANT_TOKEN is set; the token is never logged.
for name in RBACR_GRANT_TOKEN GOOGLE_PLAY_SECRET STORE_ALLOW_SANDBOX; do
  if [[ -z "${!name:-}" && -f .env ]]; then
    printf -v "$name" '%s' "$(sed -n "s/^$name=//p" .env | tail -1)"
  fi
done
RBACR_GRANT_TOKEN="${RBACR_GRANT_TOKEN:-}"
GOOGLE_PLAY_SECRET="${GOOGLE_PLAY_SECRET:-}"
if [[ -z "${STORE_ALLOW_SANDBOX:-}" ]]; then
  if [[ "$STAGE" == rc ]]; then STORE_ALLOW_SANDBOX=true; else STORE_ALLOW_SANDBOX=false; fi
fi
if [[ -n "$RBACR_GRANT_TOKEN" && ! "$RBACR_GRANT_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "error: RBACR_GRANT_TOKEN must be an rbacr API token" >&2
  exit 1
fi
if [[ -n "$GOOGLE_PLAY_SECRET" && ! "$GOOGLE_PLAY_SECRET" =~ ^$stack_prefix/[A-Za-z0-9/_+=.@-]{1,200}$ ]]; then
  echo "error: GOOGLE_PLAY_SECRET must be a secret name under $stack_prefix/" >&2
  exit 1
fi
if [[ "$STORE_ALLOW_SANDBOX" != true && "$STORE_ALLOW_SANDBOX" != false ]]; then
  echo "error: STORE_ALLOW_SANDBOX must be true or false" >&2
  exit 1
fi
echo "    store purchases: $([[ -n "$RBACR_GRANT_TOKEN" ]] && echo "App Store$([[ -n "$GOOGLE_PLAY_SECRET" ]] && echo ", Google Play ($GOOGLE_PLAY_SECRET)")" || echo off), sandbox $STORE_ALLOW_SANDBOX"

# 1. User data: the bucket, then the identity pool (which imports it)
echo "==> deploying $USER_DATA_STACK and $IDENTITY_STACK"
# The bucket notifies the ingest stack's function (presence_ingest), which
# needs the bucket first: deployed with the function it has (none on a new
# stage), then again below once the ingest stack is up.
ingest_function_arn() {
  stack_output "$INGEST_STACK" IngestFunctionArn 2>/dev/null || true
}
deploy_user_data() {
  aws cloudformation deploy --stack-name "$USER_DATA_STACK" \
    --template-file presence_infra/user-data.yaml \
    --parameter-overrides "AllowedOrigins=$ORIGINS" "IngestFunctionArn=$1" \
    --no-fail-on-empty-changeset
}
INGEST_ARN="$(ingest_function_arn)"
[[ "$INGEST_ARN" == None ]] && INGEST_ARN=
deploy_user_data "$INGEST_ARN"
aws cloudformation deploy --stack-name "$IDENTITY_STACK" \
  --template-file presence_infra/identity.yaml --capabilities CAPABILITY_IAM \
  --parameter-overrides "GoogleWebClientId=$GOOGLE_WEB_CLIENT_ID" \
    "UserDataStackName=$USER_DATA_STACK" "IdentityPoolName=$stack_prefix" \
    "Stage=$STAGE" "PermissionsBoundary=$PERMISSIONS_BOUNDARY" \
  --no-fail-on-empty-changeset
# The app reads these at build time (scripts/dart-defines.sh).
export USER_DATA_BUCKET COGNITO_IDENTITY_POOL_ID IOT_ENDPOINT FEEDBACK_TABLE
USER_DATA_BUCKET="$(stack_output "$USER_DATA_STACK" UserDataBucketName)"
# Feedback and Help's table, which the app reads and writes itself.
FEEDBACK_TABLE="$(stack_output "$USER_DATA_STACK" FeedbackTableName)"
# The auth API deletes a deleted account's messages from it (sam deploy
# refuses an empty override, so it must be there).
if [[ ! "$FEEDBACK_TABLE" =~ ^[A-Za-z0-9_.-]{3,255}$ ]]; then
  echo "error: unexpected feedback table '$FEEDBACK_TABLE'" >&2
  exit 1
fi
COGNITO_IDENTITY_POOL_ID="$(stack_output "$IDENTITY_STACK" IdentityPoolId)"
# Live sync: the policy the auth API attaches to each identity, and the
# account's MQTT endpoint (not a CloudFormation attribute). Public values.
LIVE_POLICY_NAME="$(stack_output "$IDENTITY_STACK" LivePolicyName)"
IOT_ENDPOINT="$(aws iot describe-endpoint --endpoint-type iot:Data-ATS \
  --query endpointAddress --output text)"
if [[ ! "$IOT_ENDPOINT" =~ ^[a-z0-9]+-ats\.iot\.[a-z0-9-]+\.amazonaws\.com$ ]]; then
  echo "error: unexpected AWS IoT endpoint '$IOT_ENDPOINT'" >&2
  exit 1
fi
echo "    bucket: $USER_DATA_BUCKET, identity pool: $COGNITO_IDENTITY_POOL_ID, feedback: $FEEDBACK_TABLE"
echo "    live sync: policy $LIVE_POLICY_NAME, endpoint $IOT_ENDPOINT"

# presence-streamer's cloud detector (presence_ingest): its model first
# (checked by SHA-256), then the stack, then the bucket's notification of it.
echo "==> deploying $INGEST_STACK"
bash scripts/models.sh presence_ingest/IngestFunction/models
(
  cd presence_ingest
  sam build
  sam deploy --stack-name "$INGEST_STACK" --region "$AWS_REGION" \
    --s3-bucket "$SAM_ARTIFACT_BUCKET" --s3-prefix "$INGEST_STACK" \
    --parameter-overrides "UserDataBucket=$USER_DATA_BUCKET" \
      "PermissionsBoundary=$PERMISSIONS_BOUNDARY" \
      "IngestConcurrency=${INGEST_CONCURRENCY:-0}" \
    --no-confirm-changeset --no-fail-on-empty-changeset
)
NEW_INGEST_ARN="$(ingest_function_arn)"
if [[ ! "$NEW_INGEST_ARN" =~ ^arn:aws:lambda:[a-z0-9-]+:[0-9]{12}:function:$stack_prefix-[A-Za-z0-9_-]+$ ]]; then
  echo "error: unexpected ingest function '$NEW_INGEST_ARN'" >&2
  exit 1
fi
if [[ "$NEW_INGEST_ARN" != "$INGEST_ARN" ]]; then
  echo "==> notifying $NEW_INGEST_ARN of streamer jobs"
  deploy_user_data "$NEW_INGEST_ARN"
fi

# 2. The web app
# The app asks rbacr itself: it reads these at build time (scripts/dart-defines.sh); never the token.
export RBACR_URL RBACR_SYSTEM
if [[ "${SKIP_BUILD:-}" != 1 ]]; then
  echo "==> building the web app for /app/"
  WEB_BASE_HREF=/app/ PRESENCE_STAGE="$STAGE" bash scripts/make.sh web
fi
# The RC's own icons (a huge "RC" on red), so its tabs never pass for
# production's: presence_app/web_rc/ over the build's favicon and icons.
# Its title too, before the app sets it (AppVersion.title).
if [[ "$STAGE" == rc ]]; then
  cp -R presence_app/web_rc/. presence_app/build/web/
  python3 - <<'PY'
import json
web = "presence_app/build/web"
with open(f"{web}/index.html", encoding="utf-8") as f:
    html = f.read()
html = html.replace("<title>Presence</title>", "<title>🧪 Presence RC</title>")
with open(f"{web}/index.html", "w", encoding="utf-8") as f:
    f.write(html)
with open(f"{web}/manifest.json", encoding="utf-8") as f:
    manifest = json.load(f)
manifest["name"] = "🧪 Presence RC"
manifest["short_name"] = "Presence RC"
with open(f"{web}/manifest.json", "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=4)
PY
  grep -q '<title>🧪 Presence RC</title>' presence_app/build/web/index.html
  echo "    RC icons and title in place"
fi
test -f presence_app/build/web/index.html
built="$(python3 -c 'import json; print(json.load(open("presence_app/build/web/version.json"))["version"])')"
if [[ "$built" != "$VERSION" ]]; then
  echo "error: presence_app/build/web is version $built, not $VERSION" >&2
  exit 1
fi

# 3. The auth API and its health check, which imports the auth API's table
# exports. CloudFormation refuses to remove an export another stack
# imports, so an existing health stack is deployed first: its new template
# stops importing what the auth API drops in this deploy, and still imports
# only exports the deployed auth API has. A new stage's comes after the
# auth API, whose exports it imports must exist first. So an export the
# health check newly imports must ship in an earlier deploy than the import.
# The health stack needs nothing from the auth API's outputs, so either
# order gets the same parameters.
deploy_health() {
  echo "==> deploying $HEALTH_STACK"
  # The same settings the auth API got, to check them; rbacr's URL only (the
  # token is required above, so the auth API has one), never the token.
  (
    cd presence_health
    sam build
    sam deploy --stack-name "$HEALTH_STACK" --region "$AWS_REGION" \
      --s3-bucket "$SAM_ARTIFACT_BUCKET" --s3-prefix "$HEALTH_STACK" \
      --parameter-overrides "AuthStackName=$AUTH_STACK" "Version=$VERSION" \
        "GoogleWebClientId=$GOOGLE_WEB_CLIENT_ID" "PermissionsBoundary=$PERMISSIONS_BOUNDARY" \
        "IdentityPoolId=$COGNITO_IDENTITY_POOL_ID" "UserDataBucket=$USER_DATA_BUCKET" \
        "RbacrUrl=$RBACR_URL" ${origin_override[@]+"${origin_override[@]}"} \
      --no-confirm-changeset --no-fail-on-empty-changeset
  )
}
# The APIs refuse requests without the origin secret only once the site
# already sends it (its OriginVerified output): on the first deploy with it
# the site starts sending it, and the APIs enforce it from the next. So the
# site's own requests are never refused while it rolls out.
api_origin_secret=""
if [[ "$(aws cloudformation describe-stacks --stack-name "$SITE_STACK" \
      --query "Stacks[0].Outputs[?OutputKey=='OriginVerified'].OutputValue" \
      --output text 2>/dev/null)" == true ]]; then
  api_origin_secret="$ORIGIN_SECRET"
  echo "==> the APIs answer only through the site (origin secret enforced)"
else
  echo "==> the site starts sending the origin secret; the APIs enforce it from the next deploy"
fi
# sam deploy refuses an empty override ("OriginSecret=" isn't a valid
# format), so without the secret it's left out and the templates' default
# (empty: not enforced) applies.
origin_override=()
[[ -n "$api_origin_secret" ]] && origin_override=("OriginSecret=$api_origin_secret")
health_first=0
if aws cloudformation describe-stacks --stack-name "$HEALTH_STACK" >/dev/null 2>&1; then
  health_first=1
  deploy_health
fi
echo "==> deploying $AUTH_STACK"
(
  cd presence_api_auth
  sam build
  sam deploy --stack-name "$AUTH_STACK" --region "$AWS_REGION" \
    --s3-bucket "$SAM_ARTIFACT_BUCKET" --s3-prefix "$AUTH_STACK" \
    --parameter-overrides "GoogleWebClientId=$GOOGLE_WEB_CLIENT_ID" \
      "GoogleDeviceClientId=$GOOGLE_DEVICE_CLIENT_ID" \
      "DomainName=$DOMAIN" "AppleClientIds=$APPLE_CLIENT_IDS" ${apple_key[@]+"${apple_key[@]}"} \
      "PermissionsBoundary=$PERMISSIONS_BOUNDARY" \
      "IdentityPoolId=$COGNITO_IDENTITY_POOL_ID" "UserDataBucket=$USER_DATA_BUCKET" \
      "IotPolicyName=$LIVE_POLICY_NAME" "FeedbackTable=$FEEDBACK_TABLE" \
      "RbacrUrl=$RBACR_URL" "RbacrToken=$RBACR_TOKEN" "RbacrSystem=$RBACR_SYSTEM" \
      "LocalCloud=false" ${origin_override[@]+"${origin_override[@]}"} \
    --no-confirm-changeset --no-fail-on-empty-changeset
)
api_domain="$(stack_output "$AUTH_STACK" ApiDomain)"
echo "    API origin: $api_domain"
session_issuer="$(stack_output "$AUTH_STACK" SessionIssuer)"
if [[ "$session_issuer" != "https://$DOMAIN/api/auth" ]]; then
  echo "error: the auth API's session issuer is '$session_issuer', want https://$DOMAIN/api/auth" >&2
  exit 1
fi
echo "    session issuer: $session_issuer"
if [[ "$health_first" != 1 ]]; then
  deploy_health
fi
health_domain="$(stack_output "$HEALTH_STACK" ApiDomain)"
echo "    health origin: $health_domain"
# The store settings are optional: an empty one is left out (sam deploy
# refuses "RbacrGrantToken="), and the template's default (off) applies.
store_overrides=()
[[ -n "$RBACR_GRANT_TOKEN" ]] && store_overrides+=("RbacrGrantToken=$RBACR_GRANT_TOKEN")
[[ -n "$GOOGLE_PLAY_SECRET" ]] && store_overrides+=("GooglePlaySecretName=$GOOGLE_PLAY_SECRET")
[[ -n "$STORE_ALLOW_SANDBOX" ]] && store_overrides+=("StoreAllowSandbox=$STORE_ALLOW_SANDBOX")
echo "==> deploying $PAYMENTS_STACK"
(
  cd presence_api_payments
  sam build
  sam deploy --stack-name "$PAYMENTS_STACK" --region "$AWS_REGION" \
    --s3-bucket "$SAM_ARTIFACT_BUCKET" --s3-prefix "$PAYMENTS_STACK" \
    --parameter-overrides "SessionIssuer=$session_issuer" \
      "PermissionsBoundary=$PERMISSIONS_BOUNDARY" \
      "MonthlyLink=$STRIPE_MONTHLY_LINK" "YearlyLink=$STRIPE_YEARLY_LINK" \
      "RbacrUrl=$RBACR_URL" "RbacrToken=$RBACR_TOKEN" "RbacrSystem=$RBACR_SYSTEM" \
      ${store_overrides[@]+"${store_overrides[@]}"} \
      ${origin_override[@]+"${origin_override[@]}"} \
    --no-confirm-changeset --no-fail-on-empty-changeset
)
payments_domain="$(stack_output "$PAYMENTS_STACK" ApiDomain)"
echo "    payments origin: $payments_domain"

# 4. The site
echo "==> deploying $SITE_STACK"
# AUTO_EXPAND: the template's Fn::ForEach (AWS::LanguageExtensions).
aws cloudformation deploy --stack-name "$SITE_STACK" \
  --template-file presence_infra/site.yaml --capabilities CAPABILITY_AUTO_EXPAND \
  --parameter-overrides "DomainName=$DOMAIN" "Stage=$STAGE" \
    "HostedZoneId=$HOSTED_ZONE_ID" "ApiDomainName=$api_domain" \
    "HealthApiDomainName=$health_domain" \
    "PaymentsApiDomainName=$payments_domain" \
    "RbacrUrl=$RBACR_URL" \
    "HealthNotificationEmails=$PRESENCE_HEALTH_EMAILS" \
    "OriginSecret=$ORIGIN_SECRET" \
  --no-fail-on-empty-changeset
bucket="$(stack_output "$SITE_STACK" SiteBucketName)"
distribution="$(stack_output "$SITE_STACK" DistributionId)"
echo "    bucket: $bucket, distribution: $distribution"

# 5. The content. Flutter's web files aren't content-hashed, so browsers
# revalidate everything (no-cache); CloudFront is invalidated below.
echo "==> uploading"
# The site's own pages (presence_index/site: the index, /privacy, /tos, /delete-account and
# their stylesheet) at the root; never under app/, which is the app's.
aws s3 sync presence_index/site/ "s3://$bucket/" --exclude "app/*" \
  --cache-control no-cache --only-show-errors
aws s3 sync presence_app/build/web/ "s3://$bucket/app/" --delete --cache-control no-cache --only-show-errors
invalidation="$(aws cloudfront create-invalidation --distribution-id "$distribution" \
  --paths '/*' --query Invalidation.Id --output text)"
echo "    waiting for invalidation $invalidation"
aws cloudfront wait invalidation-completed --distribution-id "$distribution" --id "$invalidation"

# 6. Smoke test (retried: on a first deploy DNS and the edge take a moment)
echo "==> checking https://$DOMAIN/"
check() {
  local live
  live="$(curl -fsS --max-time 20 "https://$DOMAIN/app/version.json?deploy=$BUILD_NUMBER" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')" || return 1
  [[ "$live" == "$VERSION" ]] || { echo "    /app/version.json says $live, want $VERSION"; return 1; }
  curl -fsS --max-time 20 "https://$DOMAIN/" | grep -q "location.replace('/app/'" || { echo "    / isn't the index page"; return 1; }
  curl -fsS --max-time 20 -o /dev/null "https://$DOMAIN/app/" || { echo "    /app/ failed"; return 1; }
  curl -fsS --max-time 20 "https://$DOMAIN/privacy" | grep -q "<title>Privacy Policy" || { echo "    /privacy isn't the privacy policy"; return 1; }
  curl -fsS --max-time 20 "https://$DOMAIN/tos" | grep -q "<title>Terms of Service" || { echo "    /tos isn't the terms of service"; return 1; }
  curl -fsS --max-time 20 "https://$DOMAIN/delete-account" | grep -q "<title>Delete your account" || { echo "    /delete-account isn't the account deletion page"; return 1; }
  local auth
  auth="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://$DOMAIN/api/auth/profile")"
  [[ "$auth" == 401 ]] || { echo "    /api/auth/profile without a token answered $auth, want 401"; return 1; }
  local payments
  payments="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://$DOMAIN/api/payments/links")"
  [[ "$payments" == 401 ]] || { echo "    /api/payments/links without a token answered $payments, want 401"; return 1; }
  # The session issuer, which the APIs' JWT authorizers and rbacr fetch
  # through the site: it names itself, and its key set has an RSA key.
  local discovery
  discovery="$(curl -fsS --max-time 20 "https://$DOMAIN/api/auth/.well-known/openid-configuration")" \
    || { echo "    /api/auth/.well-known/openid-configuration failed"; return 1; }
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d.get("issuer")==sys.argv[2] and d.get("jwks_uri")==sys.argv[2]+"/.well-known/jwks.json" else 1)' \
    "$discovery" "https://$DOMAIN/api/auth" \
    || { echo "    openid-configuration answered $discovery, want issuer https://$DOMAIN/api/auth"; return 1; }
  curl -fsS --max-time 20 "https://$DOMAIN/api/auth/.well-known/jwks.json" \
    | python3 -c 'import json,sys; k=json.load(sys.stdin)["keys"]; sys.exit(0 if k and all(x.get("kty")=="RSA" and x.get("kid") and x.get("n") for x in k) else 1)' \
    || { echo "    /api/auth/.well-known/jwks.json has no RSA key"; return 1; }
  # Apple's notifications route has no authorizer: a body Apple didn't sign is 400 (503 while store purchases are off).
  payments="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X POST -H 'content-type: application/json' \
    --data '{}' "https://$DOMAIN/api/payments/store/apple-notifications")"
  [[ "$payments" == 400 || "$payments" == 503 ]] || { echo "    an unsigned App Store notification answered $payments, want 400 or 503"; return 1; }
  # Never DEV in AWS: that would give anonymous users every role. And AWS
  # must have every expected setting.
  local anonymous
  anonymous="$(curl -fsS --max-time 20 "https://$DOMAIN/api/auth/anonymous")" || { echo "    /api/auth/anonymous failed"; return 1; }
  [[ "$anonymous" == '{"mode":"RBAC","roles":["presence_anonymous"],"settings":{"oidc":true,"aws":true,"rbacr":true}}' ]] \
    || { echo "    /api/auth/anonymous answered $anonymous, want RBAC with presence_anonymous only and every setting"; return 1; }
  # What the Route 53 health check polls (presence_health): every
  # dependency must be ok, and the health stack must be this release.
  local health
  health="$(curl -s --max-time 20 "https://$DOMAIN/health")"
  [[ "$health" == '{"status":"ok",'* ]] || { echo "    /health answered $health, want status ok"; return 1; }
  [[ "$health" == *"\"version\":\"$VERSION\""* ]] || { echo "    /health answered $health, want version $VERSION"; return 1; }
  # Enforced: the APIs' own hosts refuse what didn't come through the site
  # (the site's answers above show it sends the right secret).
  if [[ -n "$api_origin_secret" ]]; then
    local direct
    direct="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://$api_domain/api/auth/anonymous")"
    [[ "$direct" == 403 ]] || { echo "    https://$api_domain/api/auth/anonymous answered $direct, want 403"; return 1; }
    direct="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://$health_domain/health")"
    [[ "$direct" == 403 ]] || { echo "    https://$health_domain/health answered $direct, want 403"; return 1; }
  fi
}
for attempt in $(seq 1 30); do
  if check; then
    echo "==> https://$DOMAIN/ serves version $VERSION"
    exit 0
  fi
  echo "    not yet (attempt $attempt/30); retrying in 20 s"
  sleep 20
done
echo "error: https://$DOMAIN/ didn't serve version $VERSION" >&2
exit 1
