#!/bin/sh
# Creates the Presence CloudFront distribution in Floci:
#   /events*  -> SAM API      (http://$PRESENCE_ORIGIN_HOST:$SAM_API_PORT)
#   *         -> Flutter web  (http://$PRESENCE_ORIGIN_HOST:$FLUTTER_WEB_PORT)
# Served at http://$PRESENCE_CDN_ALIAS:<floci port>/. Nothing is cached, and
# every viewer header except Host, plus all cookies and query strings, is
# forwarded (like AWS's managed AllViewerExceptHostHeader policy).
set -eu

ORIGIN_HOST="${PRESENCE_ORIGIN_HOST:-host.docker.internal}"
ALIAS="${PRESENCE_CDN_ALIAS:-presence.localhost}"
WEB_PORT="${FLUTTER_WEB_PORT:-8080}"
API_PORT="${SAM_API_PORT:-3000}"

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
  printf '"TargetOriginId": "%s", "ViewerProtocolPolicy": "allow-all", "CachePolicyId": "%s", "OriginRequestPolicyId": "%s", "AllowedMethods": {"Quantity": %s, "Items": %s, "CachedMethods": {"Quantity": 2, "Items": ["GET", "HEAD"]}}' \
    "$1" "$cache_policy" "$origin_request_policy" "$2" "$3"
}

distribution=$(aws cloudfront create-distribution \
  --query 'Distribution.Id' --output text \
  --distribution-config "{
    \"CallerReference\": \"presence-local\",
    \"Comment\": \"Presence local CDN\",
    \"Enabled\": true,
    \"Aliases\": {\"Quantity\": 1, \"Items\": [\"$ALIAS\"]},
    \"Origins\": {\"Quantity\": 2, \"Items\": [$(origin app "$WEB_PORT"), $(origin api "$API_PORT")]},
    \"DefaultCacheBehavior\": {$(behavior app 3 '["GET", "HEAD", "OPTIONS"]')},
    \"CacheBehaviors\": {\"Quantity\": 1, \"Items\": [
      {\"PathPattern\": \"/events*\", $(behavior api 7 '["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]')}
    ]}
  }")

echo "presence: CloudFront distribution $distribution serves http://$ALIAS:4566/"
