#!/usr/bin/env bash
# Opt-in startup System One probe. FM_DISPATCH_CANARY=1 makes one trivial Choice call.
set -u
[ "${FM_DISPATCH_CANARY:-0}" = 1 ] || exit 0
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
or_key=${OPENROUTER_API_KEY:-} ts_key=${TYPESAFE_API_KEY:-}
export -n or_key ts_key 2>/dev/null || true
unset OPENROUTER_API_KEY TYPESAFE_API_KEY
fmx_dispatch_route "$or_key" "$ts_key" "$FM_HOME/.env"
unset or_key ts_key
[ -n "$TS_KEY" ] || { echo "DISPATCH_CANARY: off ($TS_KEY_NAME absent)" >&2; exit 0; }
command -v jq >/dev/null && command -v curl >/dev/null || { echo 'DISPATCH_CANARY: FAIL missing jq or curl' >&2; exit 1; }
response=$(mktemp) || exit 1
trap 'rm -f "$response"' EXIT
payload=$(jq -nc --arg model "$TS_MODEL" '{model:$model,state:{probe:"health"},questions:{probe:{type:"choice",instructions:"Choose the only option.",criteria:{ready:"The system is ready."}}}}')
http=$(printf '%s' "$payload" | curl -sS --max-time 5 -o "$response" -w '%{http_code}' -X POST "$TS_BASE/v1/systemone" \
  -H 'Content-Type: application/json' -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$TS_KEY") --data-binary @- 2>/dev/null) || http=000
if [ "$http" != 200 ] || ! jq -e '.answers.probe.choice == "ready" and (.answers.probe.confidence | type) == "number"' "$response" >/dev/null 2>&1; then
  echo "DISPATCH_CANARY: FAIL (http $http or invalid Choice response)" >&2
  exit 1
fi
echo 'DISPATCH_CANARY: ok'
