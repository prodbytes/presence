#!/usr/bin/env bash
# Switches maintenance mode with AWS credentials, without the app: for when
# no admin can reach the Admin tab (in maintenance mode, signed-out admins
# see only the sorry message too, and so can't sign in to switch it off).
#
#   scripts/maintenance.sh                     # says whether it's on
#   scripts/maintenance.sh on ["message"]      # the sorry screen, with a message
#   scripts/maintenance.sh off
#
# Running apps follow within a minute. Writes the auth API's SystemTable
# item {"id": "maintenance", ...}, as POST /api/auth/maintenance does, with
# "by" set to the AWS caller's ARN.
#
# Environment:
#   STAGE        prod (default, stack presence-auth-api) or rc
#                (presence-rc-auth-api)
#   AWS_REGION   default us-east-1
# Needs the AWS CLI (read and write access to the table) and python3.
set -euo pipefail

STAGE="${STAGE:-prod}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
case "$STAGE" in
  prod) stack=presence-auth-api ;;
  rc) stack=presence-rc-auth-api ;;
  *) echo "error: STAGE must be prod or rc" >&2; exit 2 ;;
esac

action="${1:-status}"
case "$action" in
  status | off) [[ $# -le 1 ]] || { echo "usage: $0 [status|on [message]|off]" >&2; exit 2; } ;;
  on) [[ $# -le 2 ]] || { echo "usage: $0 on [message]" >&2; exit 2; } ;;
  *) echo "usage: $0 [status|on [message]|off]" >&2; exit 2 ;;
esac

table="$(aws cloudformation describe-stacks --stack-name "$stack" \
  --query "Stacks[0].Outputs[?OutputKey=='SystemTableName'].OutputValue" --output text)"
if [[ -z "$table" || "$table" == None ]]; then
  echo "error: $stack has no SystemTableName output (deploy this version first)" >&2
  exit 1
fi

if [[ "$action" == status ]]; then
  aws dynamodb get-item --table-name "$table" --consistent-read \
    --key '{"id":{"S":"maintenance"}}' --output json |
    python3 -c '
import datetime, json, sys
data = sys.stdin.read()  # empty when the item was never written
item = (json.loads(data) if data.strip() else {}).get("Item") or {}
on = item.get("on", {}).get("BOOL", False)
line = "maintenance mode " + ("on" if on else "off")
if "since" in item:
    since = datetime.datetime.fromtimestamp(int(item["since"]["N"]) / 1000, datetime.timezone.utc)
    line += " since " + since.isoformat(timespec="minutes")
by = item.get("by", {}).get("S", "")
print(line + (" by " + by if by else ""))
message = item.get("message", {}).get("S", "")
if message:
    print("message: " + message)
'
  exit 0
fi

by="$(aws sts get-caller-identity --query Arn --output text)"
# The item as JSON, built by python so the message needs no shell quoting.
item="$(ON="$action" MESSAGE="${2:-}" BY="$by" python3 -c '
import json, os, time
message = "".join(c for c in os.environ["MESSAGE"].strip() if c == "\n" or c >= " ")
if len(message) > 500:
    raise SystemExit("error: the message must be at most 500 characters")
print(json.dumps({
    "id": {"S": "maintenance"},
    "on": {"BOOL": os.environ["ON"] == "on"},
    "message": {"S": message},
    "since": {"N": str(int(time.time() * 1000))},
    "by": {"S": os.environ["BY"]},
}))
')"
aws dynamodb put-item --table-name "$table" --item "$item"
echo "maintenance mode $action ($STAGE); running apps follow within a minute"
