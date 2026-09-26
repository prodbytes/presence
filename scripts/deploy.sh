#!/usr/bin/env bash
# Deploys Presence to production, https://presence.nu01.com:
#   1. builds the Flutter web app for /app/ (make web, WEB_BASE_HREF=/app/)
#   2. deploys the events API (sam build + sam deploy: presence-api-events)
#   3. deploys the site (CloudFormation presence_infra_web/site.yaml:
#      presence-web: certificate, bucket, CloudFront, DNS)
#   4. uploads the index page (/) and the web build (/app/), and
#      invalidates the CloudFront cache
#   5. smoke-tests the live site: /app/version.json must report this
#      version, / must be the index page and /api/events must answer
#
# Run by .github/workflows/deploy.yml on *GA tags, or by hand with admin
# credentials. Settings, from the environment:
#   TAG          the release tag, X.Y.Z-GA: its X.Y must match the version
#                files and its Z becomes the build's Z (default: none, so Z
#                is the current time)
#   AWS_REGION   default us-east-1 (CloudFront certificates live there)
#   SKIP_BUILD   1 to deploy an existing presence_app/build/web
# Needs the AWS CLI, the SAM CLI, JDK 25, Maven and Flutter (all in devbox).
set -euo pipefail

cd "$(dirname "$0")/.."
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
API_STACK=presence-api-events
SITE_STACK=presence-web
DOMAIN=presence.nu01.com

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
echo "==> deploying version $VERSION to https://$DOMAIN/ ($AWS_REGION)"

stack_output() { # stack_output <stack> <output key>
  aws cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}

# 1. The web app
if [[ "${SKIP_BUILD:-}" != 1 ]]; then
  echo "==> building the web app for /app/"
  WEB_BASE_HREF=/app/ bash scripts/make.sh web
fi
test -f presence_app/build/web/index.html
built="$(python3 -c 'import json; print(json.load(open("presence_app/build/web/version.json"))["version"])')"
if [[ "$built" != "$VERSION" ]]; then
  echo "error: presence_app/build/web is version $built, not $VERSION" >&2
  exit 1
fi

# 2. The events API
echo "==> deploying $API_STACK"
(
  cd presence_api_events
  sam build
  sam deploy --stack-name "$API_STACK" --region "$AWS_REGION" \
    --no-confirm-changeset --no-fail-on-empty-changeset
)
api_domain="$(stack_output "$API_STACK" ApiDomain)"
echo "    API origin: $api_domain"

# 3. The site
echo "==> deploying $SITE_STACK"
aws cloudformation deploy --stack-name "$SITE_STACK" \
  --template-file presence_infra_web/site.yaml \
  --parameter-overrides "ApiDomainName=$api_domain" "DomainName=$DOMAIN" \
  --no-fail-on-empty-changeset
bucket="$(stack_output "$SITE_STACK" SiteBucketName)"
distribution="$(stack_output "$SITE_STACK" DistributionId)"
echo "    bucket: $bucket, distribution: $distribution"

# 4. The content. Flutter's web files aren't content-hashed, so browsers
# revalidate everything (no-cache); CloudFront is invalidated below.
echo "==> uploading"
aws s3 cp presence_index/site/index.html "s3://$bucket/index.html" \
  --cache-control no-cache --content-type "text/html; charset=utf-8" --only-show-errors
aws s3 sync presence_app/build/web/ "s3://$bucket/app/" --delete --cache-control no-cache --only-show-errors
invalidation="$(aws cloudfront create-invalidation --distribution-id "$distribution" \
  --paths '/*' --query Invalidation.Id --output text)"
echo "    waiting for invalidation $invalidation"
aws cloudfront wait invalidation-completed --distribution-id "$distribution" --id "$invalidation"

# 5. Smoke test (retried: on a first deploy DNS and the edge take a moment)
echo "==> checking https://$DOMAIN/"
check() {
  local live
  live="$(curl -fsS --max-time 20 "https://$DOMAIN/app/version.json?deploy=$BUILD_NUMBER" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')" || return 1
  [[ "$live" == "$VERSION" ]] || { echo "    /app/version.json says $live, want $VERSION"; return 1; }
  curl -fsS --max-time 20 "https://$DOMAIN/" | grep -q "location.replace('/app/'" || { echo "    / isn't the index page"; return 1; }
  curl -fsS --max-time 20 -o /dev/null "https://$DOMAIN/app/" || { echo "    /app/ failed"; return 1; }
  curl -fsS --max-time 20 "https://$DOMAIN/api/events" | grep -q '"events"' || { echo "    /api/events failed"; return 1; }
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
