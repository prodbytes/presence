#!/bin/sh
# Deploys the auth API (presence_api_auth/template.yaml, built on the host by
# scripts/build-auth-api.sh and mounted at /opt/presence-auth-api) into Floci
# as the stack presence-local-auth-api: the same Java Lambdas, HTTP API with
# its Google JWT authorizer, and DynamoDB tables as in AWS. Floci
# runs the functions in Docker containers (hence the Docker socket in
# compose.yaml) and verifies Google ID tokens against Google's JWKS.
#
# CloudFront only reaches private origins allowlisted by exact name
# (compose.yaml), but CloudFormation gives the stack's HTTP API a random ID.
# So the stack provides the functions and tables, and the HTTP API that
# CloudFront uses is created here with the fixed ID "$API_ID" (Floci's
# floci:override-id tag): the same Google JWT authorizer and routes as
# template.yaml's AuthHttpApi. Its host, $API_ID.execute-api.localhost.floci.io,
# is written to /tmp/presence-api-host, which 10-cloudfront.sh routes /api/*
# to. Keep the routes below in step with template.yaml, except GET /health:
# it checks AWS resources (the identity pool and bucket in .env are AWS's,
# not Floci's), so it's AWS only, like the Route 53 health check.
#
# Without GOOGLE_WEB_CLIENT_ID the API runs in DEV mode: only the public
# GET /api/auth/anonymous route is created, and it gives the anonymous user
# every role (presence.auth.ExecutionMode).
set -eu

BUILD=/opt/presence-auth-api
STACK=presence-local-auth-api
API_ID="${PRESENCE_API_ID:-presence}"
rm -f /tmp/presence-api-host

CLIENT_ID="${GOOGLE_WEB_CLIENT_ID:-}"
if [ -z "$CLIENT_ID" ]; then
  echo "presence: GOOGLE_WEB_CLIENT_ID isn't set (.env); auth API in DEV mode" >&2
fi
if [ ! -f "$BUILD/template.yaml" ]; then
  echo "presence: no auth API build in $BUILD (scripts/build-auth-api.sh); no local auth API" >&2
  exit 0
fi

# The host's CPU, so Floci runs the Lambdas without emulation (arm64 on
# Apple silicon, x86_64 on GitHub Codespaces).
case "$(uname -m)" in
  aarch64 | arm64) ARCH=arm64 ;;
  *) ARCH=x86_64 ;;
esac

aws s3 mb s3://presence-local-sam >/dev/null
aws cloudformation package --template-file "$BUILD/template.yaml" \
  --s3-bucket presence-local-sam --output-template-file /tmp/presence-auth-api.yaml >/dev/null
# The root allowlist, from .env: domains default to the template's (nu01.com).
aws cloudformation deploy --stack-name "$STACK" \
  --template-file /tmp/presence-auth-api.yaml --capabilities CAPABILITY_IAM \
  --parameter-overrides "GoogleWebClientId=$CLIENT_ID" "Architecture=$ARCH" \
    "IdentityPoolId=${COGNITO_IDENTITY_POOL_ID:-}" "UserDataBucket=${USER_DATA_BUCKET:-}" \
    "RootDomains=${PRESENCE_ROOT_DOMAINS:-nu01.com}" "RootEmails=${PRESENCE_ROOT_EMAILS:-}" >/dev/null

function_arn() { # function_arn <logical ID>
  name=$(aws cloudformation describe-stack-resource --stack-name "$STACK" \
    --logical-resource-id "$1" --query StackResourceDetail.PhysicalResourceId --output text)
  aws lambda get-function --function-name "$name" --query Configuration.FunctionArn --output text
}

api=$(aws apigatewayv2 create-api --name presence-local-auth --protocol-type HTTP \
  --tags "floci:override-id=$API_ID" --query ApiId --output text)
if [ "$api" != "$API_ID" ]; then
  echo "presence: the auth API got ID $api, not $API_ID; CloudFront won't reach it" >&2
  exit 1
fi
route() { # route <"METHOD /path"> <function logical ID> [authorizer ID]
  integration=$(aws apigatewayv2 create-integration --api-id "$api" \
    --integration-type AWS_PROXY --integration-uri "$(function_arn "$2")" \
    --payload-format-version 2.0 --query IntegrationId --output text)
  if [ -n "${3:-}" ]; then
    aws apigatewayv2 create-route --api-id "$api" --route-key "$1" \
      --authorization-type JWT --authorizer-id "$3" \
      --target "integrations/$integration" >/dev/null
  else
    aws apigatewayv2 create-route --api-id "$api" --route-key "$1" \
      --target "integrations/$integration" >/dev/null
  fi
}
# Public, as in template.yaml: the execution mode and the anonymous roles.
route "GET /api/auth/anonymous" AuthFunction
if [ -n "$CLIENT_ID" ]; then
  # As in template.yaml: only Google ID tokens issued for the web client.
  authorizer=$(aws apigatewayv2 create-authorizer --api-id "$api" --name GoogleIdToken \
    --authorizer-type JWT --identity-source '$request.header.Authorization' \
    --jwt-configuration "Issuer=https://accounts.google.com,Audience=$CLIENT_ID" \
    --query AuthorizerId --output text)
  route "GET /api/auth" AuthFunction "$authorizer"
  route "POST /api/auth/membership" MembershipFunction "$authorizer"
  route "GET /api/auth/membership" AdminFunction "$authorizer"
  route "POST /api/auth/membership/grant" AdminFunction "$authorizer"
  route "POST /api/auth/membership/dismiss" AdminFunction "$authorizer"
  route "POST /api/auth/voucher" VoucherFunction "$authorizer"
  route "GET /api/auth/vouchers" AdminFunction "$authorizer"
  route "POST /api/auth/vouchers" AdminFunction "$authorizer"
  route "POST /api/auth/vouchers/delete" AdminFunction "$authorizer"
  # Profiles. Without an identity pool (COGNITO_IDENTITY_POOL_ID), only the
  # listing answers; the others say cloud sync isn't set up (503).
  route "POST /api/auth/credentials" ProfileFunction "$authorizer"
  route "GET /api/auth/profile" ProfileFunction "$authorizer"
  route "POST /api/auth/profile/link-code" ProfileFunction "$authorizer"
  route "POST /api/auth/profile/link" ProfileFunction "$authorizer"
  route "POST /api/auth/profile/unlink" ProfileFunction "$authorizer"
  route "POST /api/auth/profile/devices/remove" ProfileFunction "$authorizer"
fi
aws apigatewayv2 create-stage --api-id "$api" --stage-name '$default' --auto-deploy >/dev/null

echo "$api.execute-api.localhost.floci.io" > /tmp/presence-api-host
mode=RBAC; [ -n "$CLIENT_ID" ] || mode=DEV
echo "presence: auth API $api deployed ($STACK, $mode)"
