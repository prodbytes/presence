#!/usr/bin/env bash
# Copies the roles the auth API's UserRoles table declared, before rbacr
# kept them, into rbacr: presence_user becomes a grant of free, and
# presence_admin one of admin, in rbacr's presence system (RBACR_SYSTEM).
# Other roles (presence_root comes from rbacr's root list now) are skipped.
#
#   scripts/migrate-roles-to-rbacr.sh            # dry run: counts only
#   scripts/migrate-roles-to-rbacr.sh --apply    # grants in rbacr
#
# Safe to run again: rbacr keeps a grant that already gives the role for
# good (G2). Emails are people's: only counts are printed.
#
# Environment (else .env, as scripts/deploy.sh):
#   STAGE        prod (default, stack presence-auth-api) or rc
#                (presence-rc-auth-api)
#   AWS_REGION   default us-east-1
#   RBACR_TOKEN  an rbacr root's API token (required)
#   RBACR_URL    default https://rbacr.nu01.com
#   RBACR_SYSTEM default presence
# Needs the AWS CLI (read access to the table), curl and python3.
set -euo pipefail

cd "$(dirname "$0")/.."

apply=0
case "${1:-}" in
  --apply) apply=1 ;;
  "") ;;
  *) echo "usage: $0 [--apply]" >&2; exit 2 ;;
esac

STAGE="${STAGE:-prod}"
AWS_REGION="${AWS_REGION:-us-east-1}"
case "$STAGE" in
  prod) stack=presence-auth-api ;;
  rc) stack=presence-rc-auth-api ;;
  *) echo "error: STAGE must be prod or rc" >&2; exit 1 ;;
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

table="$(aws cloudformation describe-stacks --region "$AWS_REGION" --stack-name "$stack" \
  --query "Stacks[0].Outputs[?OutputKey=='UserRolesTableName'].OutputValue" --output text)"
if [[ -z "$table" || "$table" == None ]]; then
  echo "error: $stack has no UserRolesTableName output" >&2
  exit 1
fi
echo "==> $stack: $table -> $RBACR_URL, system $RBACR_SYSTEM$([[ $apply == 1 ]] || echo " (dry run)")"

work="$(umask 077 && mktemp -d)"
trap 'rm -rf "$work"' EXIT
# The token goes in a header file, never on a command line (ps).
printf 'authorization: Bearer %s\n' "$RBACR_TOKEN" >"$work/auth"

aws dynamodb scan --region "$AWS_REGION" --table-name "$table" \
  --projection-expression "email, #roles" --expression-attribute-names '{"#roles":"roles"}' \
  --output json >"$work/items.json"

# One JSON grant body per line: {"role": ..., "grantee": ...}. Roles were
# a string set, a list of strings or one string (UserRoles).
python3 -I - "$work/items.json" >"$work/grants" 2>"$work/skipped" <<'PY'
import json, sys

AS = {"presence_user": "free", "presence_admin": "admin"}
skipped = 0
for item in json.load(open(sys.argv[1]))["Items"]:
    email = item.get("email", {}).get("S", "").strip().lower()
    roles = item.get("roles", {})
    names = roles.get("SS") or [v.get("S", "") for v in roles.get("L", [])] or [roles.get("S", "")]
    for name in {n.strip() for n in names if n and n.strip()}:
        if email and name in AS:
            print(json.dumps({"role": AS[name], "grantee": email}))
        else:
            skipped += 1
print(skipped, file=sys.stderr)
PY

total="$(grep -c . "$work/grants" || true)"
echo "    $total grant(s) to make, $(cat "$work/skipped") other role(s) skipped"
[[ $apply == 1 ]] || { echo "    dry run: nothing granted (--apply to grant)"; exit 0; }

granted=0 failed=0
while IFS= read -r body; do
  status="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -H @"$work/auth" \
    -H 'content-type: application/json' --data "$body" \
    "$RBACR_URL/api/systems/$RBACR_SYSTEM/grants")" || status=000
  if [[ "$status" == 201 ]]; then
    granted=$((granted + 1))
  else
    failed=$((failed + 1))
    echo "    a grant failed: HTTP $status" >&2
  fi
done <"$work/grants"
echo "    granted $granted, failed $failed"
[[ $failed == 0 ]]
