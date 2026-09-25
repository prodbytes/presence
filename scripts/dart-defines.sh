# Sourced by the run scripts. DART_DEFINES holds a --dart-define for each
# allowed setting found in the repo's .env (see .env.example).
#
# Only the names below are passed: anything given to Flutter is compiled
# into the app (readable in the web bundle), so secrets in .env, such as
# the client secret, must never be listed here.
_allowed=(GOOGLE_WEB_CLIENT_ID GOOGLE_IOS_CLIENT_ID)
_env="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
DART_DEFINES=()
if [[ -f "$_env" ]]; then
  for _name in "${_allowed[@]}"; do
    _value="$(sed -n "s/^${_name}=//p" "$_env" | tail -1)"
    [[ -n "$_value" ]] && DART_DEFINES+=(--dart-define="${_name}=${_value}")
  done
else
  echo "note: no .env; Google sign-in will say it isn't set up (see .env.example)" >&2
fi
unset _allowed _env _name _value
