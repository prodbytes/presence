#!/bin/sh
# Creates the Presence CloudFront distribution in Floci. It only routes, as
# the deployed CloudFront would; the app and the API run on their own dev
# servers:
#   /app*   -> Flutter dev server  (http://$PRESENCE_ORIGIN_HOST:$FLUTTER_WEB_PORT)
#   /api/*  -> sam local start-api (http://$PRESENCE_ORIGIN_HOST:$SAM_API_PORT)
#   *       -> presence_index      (http://$PRESENCE_ORIGIN_HOST:$INDEX_PORT),
#              whose / redirects to /app/
# Paths are forwarded as is (CloudFront can't strip a prefix), so the app is
# served under /app/ (--base-href /app/) and the API routes start with /api/.
#
# Nothing is cached. Every viewer header except Host, plus all cookies and
# query strings, is forwarded (like AWS's managed AllViewerExceptHostHeader
# policy). The origins therefore see Host: $PRESENCE_ORIGIN_HOST:<port>, which
# the Flutter dev server writes into its debug-channel (hot reload) URL. Floci
# can't carry that WebSocket, so the origin host is a *.localhost name: the
# browser resolves it to loopback and connects to the dev server directly,
# while compose.yaml maps it to the Docker host inside this container.
set -eu

ORIGIN_HOST="${PRESENCE_ORIGIN_HOST:-dev.presence.localhost}"
ALIAS="${PRESENCE_CDN_ALIAS:-presence.localhost}"
# A public name for the same machine (A record to 127.0.0.1 in Route 53), for
# Google sign-in, whose JavaScript origins must end in a public TLD.
PUBLIC_HOST="${PRESENCE_PUBLIC_HOST:-local.presence.nu01.com}"
WEB_PORT="${FLUTTER_WEB_PORT:-8080}"
API_PORT="${SAM_API_PORT:-3000}"
INDEX_PORT="${INDEX_PORT:-8081}"

cache_policy=$(aws cloudfront create-cache-policy \
  --query CachePolicy.Id --output text \
  --cache-policy-config '{
    "Name": "presence-no-cache",
    "MinTTL": 0, "DefaultTTL": 0, "MaxTTL": 0,
    "ParametersInCacheKeyAndForwardedToOrigin": {
      "EnableAcceptEncodingGzip": false,
      "EnableAcceptEncodingBrotli": false,
      "HeadersConfig": {"HeaderBehavior": "none"},
      "CookiesConfig": {"CookieBehavior": "none"},
      "QueryStringsConfig": {"QueryStringBehavior": "none"}
    }
  }')

origin_request_policy=$(aws cloudfront create-origin-request-policy \
  --query OriginRequestPolicy.Id --output text \
  --origin-request-policy-config '{
    "Name": "presence-all-viewer-except-host",
    "HeadersConfig": {"HeaderBehavior": "allExcept", "Headers": {"Quantity": 1, "Items": ["Host"]}},
    "CookiesConfig": {"CookieBehavior": "all"},
    "QueryStringsConfig": {"QueryStringBehavior": "all"}
  }')

origin() {
  printf '{"Id": "%s", "DomainName": "%s", "CustomOriginConfig": {"HTTPPort": %s, "HTTPSPort": 443, "OriginProtocolPolicy": "http-only"}}' \
    "$1" "$ORIGIN_HOST" "$2"
}

behavior() {
  printf '"TargetOriginId": "%s", "ViewerProtocolPolicy": "allow-all", "CachePolicyId": "%s", "OriginRequestPolicyId": "%s", "AllowedMethods": {"Quantity": 7, "Items": ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"], "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}}' \
    "$1" "$cache_policy" "$origin_request_policy"
}

distribution=$(aws cloudfront create-distribution \
  --query 'Distribution.Id' --output text \
  --distribution-config "{
    \"CallerReference\": \"presence-local\",
    \"Comment\": \"Presence local CDN\",
    \"Enabled\": true,
    \"Aliases\": {\"Quantity\": 2, \"Items\": [\"$ALIAS\", \"$PUBLIC_HOST\"]},
    \"Origins\": {\"Quantity\": 3, \"Items\": [$(origin app "$WEB_PORT"), $(origin api "$API_PORT"), $(origin index "$INDEX_PORT")]},
    \"DefaultCacheBehavior\": {$(behavior index)},
    \"CacheBehaviors\": {\"Quantity\": 2, \"Items\": [
      {\"PathPattern\": \"/app*\", $(behavior app)},
      {\"PathPattern\": \"/api/*\", $(behavior api)}
    ]}
  }")

echo "presence: CloudFront distribution $distribution serves http://$ALIAS:4566/ and https://$PUBLIC_HOST:8443/ (index, /app/, /api/)"
