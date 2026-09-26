# Sourced by the run scripts. DART_DEFINES holds a --dart-define for each
# allowed setting: from the environment when it's set there (scripts/deploy.sh
# sets the cloud IDs), otherwise from the repo's .env (see .env.example).
#
# Only the names below are passed: anything given to Flutter is compiled
# into the app (readable in the web bundle), so secrets in .env, such as
# the client secret, must never be listed here. These are all public
# identifiers.
_allowed=(GOOGLE_WEB_CLIENT_ID GOOGLE_IOS_CLIENT_ID AWS_REGION COGNITO_IDENTITY_POOL_ID USER_DATA_BUCKET)
_env="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
DART_DEFINES=()
[[ -f "$_env" ]] || echo "note: no .env; Google sign-in will say it isn't set up (see .env.example)" >&2
for _name in "${_allowed[@]}"; do
  _value="${!_name:-}"
  if [[ -z "$_value" && -f "$_env" ]]; then
    _value="$(sed -n "s/^${_name}=//p" "$_env" | tail -1)"
  fi
  [[ -n "$_value" ]] && DART_DEFINES+=(--dart-define="${_name}=${_value}")
done
unset _allowed _env _name _value
