#!/usr/bin/env bash
# fm-account-routing.sh on|off|status - atomic per-home cross-account kill switch.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
# shellcheck source=bin/fm-account-lib.sh
. "$SCRIPT_DIR/fm-account-lib.sh"
[ "$#" -eq 1 ] || { echo 'usage: fm-account-routing.sh on|off|status' >&2; exit 2; }
case "$1" in on|off|status) ;; *) echo 'usage: fm-account-routing.sh on|off|status' >&2; exit 2 ;; esac
file=$CONFIG/accounts.json
fm_account_registry_valid "$file" || { echo "error: missing or malformed account registry: $file" >&2; exit 1; }
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
