#!/usr/bin/env bash
# Deploys Presence to production, https://presence.nu01.com, or with
# STAGE=rc to the release-candidate site, https://rc.presence.nu01.com
# (its own stacks, presence-rc-*, and its own bucket and identity pool):
#   1. deploys the user data stacks (presence_infra/user-data.yaml: the
#      bucket; presence_infra/identity.yaml: the Cognito identity pool and
#      live sync's IoT policy), and looks up the account's AWS IoT data
#      endpoint (live sync)
#   2. builds the Flutter web app for /app/ (make web, WEB_BASE_HREF=/app/),
#      with the pool, bucket and IoT endpoint from step 1
#   3. deploys the auth API (sam build + sam deploy: presence_api_auth, stack
#      presence-auth-api / presence-rc-auth-api)
#   4. deploys the site (CloudFormation presence_infra/site.yaml:
#      presence-web: certificate, bucket, CloudFront, DNS, and the Route 53
#      health check of /health with its alarm emails)
#   5. uploads the index page (/) and the web build (/app/), and
#      invalidates the CloudFront cache
#   6. smoke-tests the live site: /app/version.json must report this
#      version, / must be the index page, and /api/auth must refuse a
#      request without a token (401: the route and its authorizer are live),
#      and /api/auth/anonymous must report RBAC mode, and /health must say
#      every dependency is ok
#
# Every role the stacks create carries the stage's permissions boundary
# (<prefix>-app-boundary), and SAM uploads to the stage's own bucket
# (<prefix>-sam-artifacts-<account>); both come from the
# presence-github-deploy stack (presence_infra/github-deploy.yaml), which
# must be deployed first. If the deploy fails, it prints the version that
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
#   PRESENCE_HEALTH_EMAILS who is emailed when the /health check fails or
#                recovers, comma-separated (default julio+health@nu01.com;
#                also from .env). Each must confirm AWS's subscription email.
#   PERMISSIONS_BOUNDARY  the roles' boundary ARN (default: the stage's,
#                arn:aws:iam::<account>:policy/<prefix>-app-boundary)
#   SAM_ARTIFACT_BUCKET   where sam deploy uploads (default: the stage's,
#                <prefix>-sam-artifacts-<account>)
#   RBACR_TOKEN  an rbacr API token owned by an rbacr root: rbacr keeps every
#                role (who may use the app, sync with the cloud, administer
#                it; rbacr's root list makes roots), and memberships and
#                vouchers grant there. Required, from the environment (the
#                RBACR_TOKEN secret in CI) or .env: without it nobody has a role.
#   RBACR_URL    rbacr's origin (default https://rbacr.nu01.com, GA rbacr,
#                the only one prod accepts; also .env)
#   RBACR_SYSTEM the rbacr system of the app's roles (default presence; also .env)
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

# 1. User data: the bucket, then the identity pool (which imports it)
echo "==> deploying $USER_DATA_STACK and $IDENTITY_STACK"
aws cloudformation deploy --stack-name "$USER_DATA_STACK" \
  --template-file presence_infra/user-data.yaml \
  --parameter-overrides "AllowedOrigins=$ORIGINS" \
  --no-fail-on-empty-changeset
aws cloudformation deploy --stack-name "$IDENTITY_STACK" \
  --template-file presence_infra/identity.yaml --capabilities CAPABILITY_IAM \
  --parameter-overrides "GoogleWebClientId=$GOOGLE_WEB_CLIENT_ID" \
    "UserDataStackName=$USER_DATA_STACK" "IdentityPoolName=$stack_prefix" \
    "Stage=$STAGE" "PermissionsBoundary=$PERMISSIONS_BOUNDARY" \
  --no-fail-on-empty-changeset
# The app reads these at build time (scripts/dart-defines.sh).
export USER_DATA_BUCKET COGNITO_IDENTITY_POOL_ID IOT_ENDPOINT
USER_DATA_BUCKET="$(stack_output "$USER_DATA_STACK" UserDataBucketName)"
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
echo "    bucket: $USER_DATA_BUCKET, identity pool: $COGNITO_IDENTITY_POOL_ID"
echo "    live sync: policy $LIVE_POLICY_NAME, endpoint $IOT_ENDPOINT"

# 2. The web app
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

# 3. The auth API
echo "==> deploying $AUTH_STACK"
(
  cd presence_api_auth
  sam build
  sam deploy --stack-name "$AUTH_STACK" --region "$AWS_REGION" \
    --s3-bucket "$SAM_ARTIFACT_BUCKET" --s3-prefix "$AUTH_STACK" \
    --parameter-overrides "Version=$VERSION" "GoogleWebClientId=$GOOGLE_WEB_CLIENT_ID" \
      "PermissionsBoundary=$PERMISSIONS_BOUNDARY" \
      "IdentityPoolId=$COGNITO_IDENTITY_POOL_ID" "UserDataBucket=$USER_DATA_BUCKET" \
      "IotPolicyName=$LIVE_POLICY_NAME" \
      "RbacrUrl=$RBACR_URL" "RbacrToken=$RBACR_TOKEN" "RbacrSystem=$RBACR_SYSTEM" \
    --no-confirm-changeset --no-fail-on-empty-changeset
)
api_domain="$(stack_output "$AUTH_STACK" ApiDomain)"
echo "    API origin: $api_domain"

# 4. The site
echo "==> deploying $SITE_STACK"
# AUTO_EXPAND: the template's Fn::ForEach (AWS::LanguageExtensions).
aws cloudformation deploy --stack-name "$SITE_STACK" \
  --template-file presence_infra/site.yaml --capabilities CAPABILITY_AUTO_EXPAND \
  --parameter-overrides "DomainName=$DOMAIN" "Stage=$STAGE" \
    "HostedZoneId=$HOSTED_ZONE_ID" "ApiDomainName=$api_domain" \
    "HealthNotificationEmails=$PRESENCE_HEALTH_EMAILS" \
  --no-fail-on-empty-changeset
bucket="$(stack_output "$SITE_STACK" SiteBucketName)"
distribution="$(stack_output "$SITE_STACK" DistributionId)"
echo "    bucket: $bucket, distribution: $distribution"

# 5. The content. Flutter's web files aren't content-hashed, so browsers
# revalidate everything (no-cache); CloudFront is invalidated below.
echo "==> uploading"
aws s3 cp presence_index/site/index.html "s3://$bucket/index.html" \
  --cache-control no-cache --content-type "text/html; charset=utf-8" --only-show-errors
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
  local auth
  auth="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://$DOMAIN/api/auth")"
  [[ "$auth" == 401 ]] || { echo "    /api/auth without a token answered $auth, want 401"; return 1; }
  # Never DEV in AWS: that would give anonymous users every role. And AWS
  # must have every expected setting.
  local anonymous
  anonymous="$(curl -fsS --max-time 20 "https://$DOMAIN/api/auth/anonymous")" || { echo "    /api/auth/anonymous failed"; return 1; }
  # Maintenance mode (on or off, as an admin left it) isn't the deploy's
  # business: it's checked to be there, then left out.
  [[ "$anonymous" == *',"maintenance":{"on":'* ]] || { echo "    /api/auth/anonymous answered $anonymous, want its maintenance mode"; return 1; }
  anonymous="${anonymous%%,\"maintenance\":*}}"
  [[ "$anonymous" == '{"mode":"RBAC","roles":["presence_anonymous"],"settings":{"oidc":true,"aws":true,"rbacr":true}}' ]] \
    || { echo "    /api/auth/anonymous answered $anonymous, want RBAC with presence_anonymous only and every setting"; return 1; }
  # What the Route 53 health check polls: every dependency must be ok, and
  # the API must be this release.
  local health
  health="$(curl -s --max-time 20 "https://$DOMAIN/health")"
  [[ "$health" == '{"status":"ok",'* ]] || { echo "    /health answered $health, want status ok"; return 1; }
  [[ "$health" == *"\"version\":\"$VERSION\""* ]] || { echo "    /health answered $health, want version $VERSION"; return 1; }
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
