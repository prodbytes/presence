#!/usr/bin/env bash
# One-time, by an administrator: tags a stage's existing CloudFront
# distributions, ACM certificates and Cognito identity pool with
# presence:stage=<stage>, the tag the deploy roles are scoped by
# (presence_infra/github-deploy.yaml). The templates add the same tags on
# their next deploy; this only lets that deploy (and the deploy roles) touch
# resources created before the tags existed.
#
#   bash scripts/tag-stage-resources.sh prod|rc
#
# Run it for both stages before updating presence-github-deploy. DRY_RUN=1
# prints what it would tag. Needs admin credentials (tagging any
# distribution, certificate and identity pool).
set -euo pipefail

stage="${1:-}"
case "$stage" in
  prod) stacks=(presence-web presence-sh presence-identity) ;;
  rc) stacks=(presence-rc-web presence-rc-identity) ;;
  *) echo "usage: $0 prod|rc" >&2; exit 2 ;;
esac
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
account="$(aws sts get-caller-identity --query Account --output text)"

run() {
  echo "    $*"
  [[ "${DRY_RUN:-}" == 1 ]] || "$@"
}

for stack in "${stacks[@]}"; do
  if ! aws cloudformation describe-stacks --stack-name "$stack" >/dev/null 2>&1; then
    echo "==> $stack: no such stack, skipped"
    continue
  fi
  echo "==> $stack"
  while read -r type id; do
    case "$type" in
      AWS::CloudFront::Distribution)
        run aws cloudfront tag-resource \
          --resource "arn:aws:cloudfront::$account:distribution/$id" \
          --tags "Items=[{Key=presence:stage,Value=$stage}]"
        ;;
      AWS::CertificateManager::Certificate)
        run aws acm add-tags-to-certificate --certificate-arn "$id" \
          --tags "Key=presence:stage,Value=$stage"
        ;;
      AWS::Cognito::IdentityPool)
        run aws cognito-identity tag-resource \
          --resource-arn "arn:aws:cognito-identity:$AWS_REGION:$account:identitypool/$id" \
          --tags "presence:stage=$stage"
        ;;
    esac
  done < <(aws cloudformation describe-stack-resources --stack-name "$stack" \
    --query "StackResources[?ResourceType=='AWS::CloudFront::Distribution' || ResourceType=='AWS::CertificateManager::Certificate' || ResourceType=='AWS::Cognito::IdentityPool'].[ResourceType,PhysicalResourceId]" \
    --output text)
done
echo "==> done ($stage)"
