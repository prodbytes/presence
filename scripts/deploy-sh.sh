#!/usr/bin/env bash
# Deploys https://sh.presence.nu01.com, which serves scripts/install.sh,
# and scripts/install-streamer.sh at /streamer:
#   1. deploys the presence-sh stack (presence_sh/template.yaml: certificate,
#      bucket, CloudFront, DNS)
#   2. uploads both scripts and invalidates the CloudFront cache
#   3. smoke-tests the live URLs: / and /install.sh must return
#      install.sh, /streamer and /streamer.sh install-streamer.sh, byte for
#      byte, and plain http must be refused
#
# Run by .github/workflows/deploy.yml on *GA tags, after scripts/deploy.sh,
# or by hand with admin credentials. Settings, from the environment:
#   AWS_REGION      default us-east-1 (CloudFront certificates live there)
#   HOSTED_ZONE_ID  the Route 53 zone of presence.nu01.com (default: the
#                   repo's .env, from the private repo)
set -euo pipefail

cd "$(dirname "$0")/.."
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
STACK=presence-sh
DOMAIN=sh.presence.nu01.com

if [[ -z "${HOSTED_ZONE_ID:-}" && -f .env ]]; then
  HOSTED_ZONE_ID="$(sed -n 's/^HOSTED_ZONE_ID=//p' .env | tail -1)"
fi
if [[ -z "${HOSTED_ZONE_ID:-}" ]]; then
  echo "error: HOSTED_ZONE_ID isn't set (environment or .env; see .env.example)" >&2
  exit 1
fi

stack_output() { # stack_output <output key>
  aws cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

# 1. The stack
echo "==> deploying $STACK (https://$DOMAIN/)"
aws cloudformation deploy --stack-name "$STACK" \
  --template-file presence_sh/template.yaml \
  --parameter-overrides "DomainName=$DOMAIN" "HostedZoneId=$HOSTED_ZONE_ID" \
  --no-fail-on-empty-changeset
bucket="$(stack_output ScriptBucketName)"
distribution="$(stack_output DistributionId)"
echo "    bucket: $bucket, distribution: $distribution"

# 2. The scripts. text/plain so a browser shows them rather than
# downloading them; edge caches keep them 5 minutes, and the invalidation
# clears them now.
for script in install.sh:install.sh install-streamer.sh:streamer.sh; do
  echo "==> uploading scripts/${script%%:*} as ${script#*:}"
  aws s3 cp "scripts/${script%%:*}" "s3://$bucket/${script#*:}" \
    --content-type "text/plain; charset=utf-8" --cache-control "public, max-age=300" \
    --only-show-errors
done
invalidation="$(aws cloudfront create-invalidation --distribution-id "$distribution" \
  --paths '/*' --query Invalidation.Id --output text)"
echo "    waiting for invalidation $invalidation"
aws cloudfront wait invalidation-completed --distribution-id "$distribution" --id "$invalidation"

# 3. Smoke test
echo "==> checking https://$DOMAIN/"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for check in /:install.sh /install.sh:install.sh /streamer:install-streamer.sh /streamer.sh:install-streamer.sh; do
  path="${check%%:*}" want="scripts/${check#*:}"
  ok=
  for _ in $(seq 1 30); do # DNS for a new record can take a minute
    if curl -fsS -o "$tmp/got" "https://$DOMAIN$path" 2>/dev/null && cmp -s "$tmp/got" "$want"; then
      ok=1
      break
    fi
    sleep 10
  done
  if [[ -z "$ok" ]]; then
    echo "error: https://$DOMAIN$path doesn't serve $want" >&2
    exit 1
  fi
  echo "    $path: ok"
done
status="$(curl -s -o /dev/null -w '%{http_code}' "http://$DOMAIN/")"
if [[ "$status" != 403 ]]; then
  echo "error: http://$DOMAIN/ answered $status, not 403" >&2
  exit 1
fi
echo "    http: refused (403)"
echo "==> done: curl -fsSL https://$DOMAIN | sh, and curl -fsSL https://$DOMAIN/streamer | sh -s -- <profile>"
