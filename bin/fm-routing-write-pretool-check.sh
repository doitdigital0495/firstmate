#!/usr/bin/env bash
# Claude/Pi routing-store write seatbelt, using the primary scope predicate.
# Usage: <PreToolUse JSON> | bin/fm-routing-write-pretool-check.sh [--claude]
# Allow/inert: silent exit 0. Deny: exit 2 and reason on stderr, no stdout.
# Only a genuine primary home is scoped; workers remain inert. Sanctioned
# writers run normally because only the tool's own targets are classified.
# Policy and limits: bin/fm-routing-write-policy.mjs. No submitted code is run.
set -eu
case "${1:-}" in
  --help|-h)
    printf '%s\n' 'Usage: fm-routing-write-pretool-check.sh [--claude] < PreToolUse.json' \
      'Blocks direct primary Write/Edit targets and Bash redirects to routing stores.' \
      'Use fm-dispatch-resolve.sh/fm-spawn.sh, fm-control.sh pick, fm-host-mirror.sh hook, or lavish-axi instead.'
    exit 0 ;;
  --claude|'') ;;
  *) echo 'routing write guard: unknown argument' >&2; exit 2 ;;
esac
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_root_matches "$ROOT" || exit 0
STATE=${FM_STATE_OVERRIDE:-${FM_HOME:-$ROOT}/state}
if ! command -v node >/dev/null 2>&1; then
  echo '[routing-write-seatbelt] node unavailable; refusing unchecked tool call' >&2
  exit 2
fi
exec node "$SCRIPT_DIR/fm-routing-write-policy.mjs" "$ROOT" "$STATE" "$HOME"
