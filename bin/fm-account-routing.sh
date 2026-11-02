#!/usr/bin/env bash
# fm-account-routing.sh on|off|status - atomic per-home cross-account kill switch.
# fm-account-routing.sh audit - account coverage of config/crew-dispatch.json:
#   every rung of a provider lists every account declaring that provider (exit 1
#   on a gap); a provider served by one account is noted as a single point.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
# shellcheck source=bin/fm-account-lib.sh
. "$SCRIPT_DIR/fm-account-lib.sh"
[ "$#" -eq 1 ] || { echo 'usage: fm-account-routing.sh on|off|status|audit' >&2; exit 2; }
case "$1" in on|off|status|audit) ;; *) echo 'usage: fm-account-routing.sh on|off|status|audit' >&2; exit 2 ;; esac
file=$CONFIG/accounts.json
fm_account_registry_valid "$file" || { echo "error: missing or malformed account registry: $file" >&2; exit 1; }
if [ "$1" = audit ]; then
  report=$(fm_account_registry_problems "$file"; fm_account_dispatch_problems "$file" "$CONFIG/crew-dispatch.json"; fm_account_coverage_gaps "$file" "$CONFIG/crew-dispatch.json")
  if [ -z "$report" ]; then echo 'account coverage: complete'; exit 0; fi
  printf '%s\n' "$report"
  if printf '%s\n' "$report" | grep -qv '^single point: '; then exit 1; fi
  exit 0
fi
# Homes without an explicit switch may not acquire cross-home routing by toggling.
jq -e '.crossAccount.enabled | type == "boolean"' "$file" >/dev/null || {
  echo 'error: this home has no crossAccount switch' >&2; exit 1;
}
if [ "$1" != status ]; then
  [ ! -L "$file" ] || { echo 'error: refusing symlinked account registry' >&2; exit 1; }
  tmp=$(mktemp "$CONFIG/.accounts.json.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  chmod 600 "$tmp"
  if [ "$1" = on ]; then value=true; else value=false; fi
  jq --argjson enabled "$value" '.crossAccount.enabled = $enabled' "$file" > "$tmp"
  mv -f "$tmp" "$file"
  trap - EXIT
fi
if fm_account_enabled "$file"; then echo 'cross-account routing: on'; else echo 'cross-account routing: off'; fi
