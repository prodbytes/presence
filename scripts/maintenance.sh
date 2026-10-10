#!/usr/bin/env bash
# Maintenance mode without the app. rbacr decides it: the system's
# maintenance flag in rbacr (and maintenance by itself while rbacr fails its
# health check), so this switches that flag, as the Admin tab's switch does
# for a root, and keeps the sorry screen's message in the auth API's
# SystemTable.
#
#   scripts/maintenance.sh                     # rbacr's health and flag, and the message
#   scripts/maintenance.sh on ["message"]      # the sorry screen, with a message
#   scripts/maintenance.sh off
#
# Running apps follow within a minute (the auth API reuses rbacr's answer
# for 10 s). rbacr's own system page switches the flag too, without a
# message.
#
# Environment (else .env, as scripts/deploy.sh):
#   STAGE        prod (default, stack presence-auth-api) or rc
#                (presence-rc-auth-api)
#   AWS_REGION   default us-east-1
#   RBACR_TOKEN  an rbacr root's API token (required)
#   RBACR_URL    default https://rbacr.nu01.com (the RC's: https://rc.rbacr.nu01.com)
#   RBACR_SYSTEM default presence
# Needs the AWS CLI (read and write access to the table), curl and python3.
set -euo pipefail

cd "$(dirname "$0")/.."

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

for name in RBACR_TOKEN RBACR_URL RBACR_SYSTEM; do
  if [[ -z "${!name:-}" && -f .env ]]; then
    printf -v "$name" '%s' "$(sed -n "s/^$name=//p" .env | tail -1)"
  fi
done
RBACR_URL="${RBACR_URL:-https://rbacr.nu01.com}"
RBACR_SYSTEM="${RBACR_SYSTEM:-presence}"
if [[ ! "${RBACR_TOKEN:-}" =~ ^[A-Za-z0-9_-]+$ || ! "$RBACR_URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$
      || ! "$RBACR_SYSTEM" =~ ^[a-z0-9][a-z0-9_.:-]{0,62}$ ]]; then
  echo "error: RBACR_TOKEN must be a token, RBACR_URL an https origin and RBACR_SYSTEM an rbacr system ID" >&2
  exit 1
fi

table="$(aws cloudformation describe-stacks --stack-name "$stack" \
  --query "Stacks[0].Outputs[?OutputKey=='SystemTableName'].OutputValue" --output text)"
if [[ -z "$table" || "$table" == None ]]; then
  echo "error: $stack has no SystemTableName output (deploy this version first)" >&2
  exit 1
fi

work="$(umask 077 && mktemp -d)"
trap 'rm -rf "$work"' EXIT
# The token goes in a header file, never on a command line (ps).
printf 'authorization: Bearer %s\n' "$RBACR_TOKEN" >"$work/auth"
system_url="$RBACR_URL/api/systems/$RBACR_SYSTEM"

if [[ "$action" == status ]]; then
  health="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$RBACR_URL/health" || true)"
  if [[ "$health" != 200 ]]; then
    echo "maintenance mode on: rbacr's health check failed (HTTP ${health:-none})"
  else
    curl -fsS --max-time 10 -H @"$work/auth" "$system_url" -o "$work/system.json" \
      || { echo "maintenance mode on: rbacr didn't answer the flag"; exit 0; }
    python3 -c '
import json, sys
on = json.load(open(sys.argv[1])).get("maintenance") is True
print("maintenance mode " + ("on" if on else "off") + " (rbacr: healthy, flag " + ("on" if on else "off") + ")")
' "$work/system.json"
  fi
  aws dynamodb get-item --table-name "$table" --consistent-read \
    --key '{"id":{"S":"maintenance"}}' --output json |
    python3 -c '
import datetime, json, sys
data = sys.stdin.read()  # empty when the item was never written
item = (json.loads(data) if data.strip() else {}).get("Item") or {}
if not item:
    sys.exit()
on = item.get("on", {}).get("BOOL", False)
line = "last switched here: " + ("on" if on else "off")
if "since" in item:
    since = datetime.datetime.fromtimestamp(int(item["since"]["N"]) / 1000, datetime.timezone.utc)
    line += " at " + since.isoformat(timespec="minutes")
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
if os.environ["ON"] != "on":
    message = ""
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
flag=false
[[ "$action" == on ]] && flag=true
# rbacr first: it decides; then the message, which only goes with it.
curl -fsS --max-time 10 -X PATCH -H @"$work/auth" -H 'content-type: application/json' \
  --data "{\"maintenance\":$flag}" -o /dev/null "$system_url" \
  || { echo "error: rbacr didn't switch maintenance (is the token a root's?)" >&2; exit 1; }
aws dynamodb put-item --table-name "$table" --item "$item"
echo "maintenance mode $action ($STAGE, rbacr $RBACR_URL); running apps follow within a minute"
