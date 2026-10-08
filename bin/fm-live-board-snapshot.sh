#!/usr/bin/env bash
# Separate home-local live-board projection, never a Bearings status-page mode.
# Usage: fm-live-board-snapshot.sh [--json] [--input FILE]
# Default: collect exactly one fm-fleet-snapshot.sh --live-board-input snapshot.
# --input renders a previously collected fm-live-board-input.v1, without reads
# of operational state. Unsupported/malformed input fails without partial output.
# Output contract: fm-live-board.v1; schema validation and projection are owned
# by bin/fm-live-board-snapshot.jq. Fields: revision (SHA-256 of payload before
# revision), collected_at/epoch, collection_duration_seconds, home {key,label},
# coverage, omissions[], warnings[], counts, and projects[]. Each project has
# a home-qualified key, name/label, registration, counts, tasks[] and questions[].
# Project identity is backlog repo first, metadata project second, else Unassigned;
# conflicting structured identities are disclosed, never guessed from prose.
# Open backlog rows and metadata-only workers are retained. Done backlog rows
# are excluded even if their metadata remains. Duplicate ids remain visible with
# row-qualified keys and warnings, not conflated into an answerable identity.
# Queued/program/held backlog-only rows are not fabricated workers. Runtime done
# with open backlog is finished-awaiting-processing, not merged or landed.
# Current state/source and last meaningful history remain distinct. History uses
# the canonical reader's strict generation-bound event/milestone projection.
# Every open captain hold across all buckets is a question. Valid owner-authored
# context supplies lifecycle, explicit close mode and labelled options; its
# storage/guard contract belongs to fm-captain-hold.sh. Missing/invalid/stale
# context and ambiguous identity stay visible but not answerable, with owner
# review warnings. This projection starts no listener or answer delivery.
# Unregistered keyed status decisions remain owner-registration warnings.
# Question order: numeric priority (unset as 5), then oldest hold_set or since
# (unknown last), id and row key. Projects: urgent calls, other calls,
# active work, queued work, idle; ties by label/key. Tasks: blocked/parked,
# working, finished, paused, queued, unknown; ties by since/id/key.
# No Bearings caps apply; counts are exact for the local structured inventory.
# Unstructured work, missing registry, inventory gaps and uncollected other homes
# are explicit. Registered-home board exports are a separate follow-on slice.
# Only allowlisted fields leave this projection: no backlog bodies, raw status,
# terminal output, action commands, private file paths or arbitrary links. Only
# recorded https PR /pull/<number> links are retained. Operational text must
# itself be secret-free; publishing this home remains an explicit later opt-in.
# This command changes no home state, starts no service and spends no model turns.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; }
input=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) shift ;;
    --input) [ "$#" -ge 2 ] && [ -z "$input" ] || { usage >&2; exit 2; }; input=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
command -v jq >/dev/null 2>&1 || { echo 'fm-live-board-snapshot: jq not found' >&2; exit 1; }
hash() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  else echo 'fm-live-board-snapshot: SHA-256 tool not found' >&2; return 1; fi
}
tmp=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-live-board.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
if [ -n "$input" ]; then cp -- "$input" "$tmp/input.json"
else "$SCRIPT_DIR/fm-fleet-snapshot.sh" --live-board-input > "$tmp/input.json"; fi
home=$(jq -er 'select(.schema == "fm-live-board-input.v1") | .fm_home | select(type == "string" and length > 0)' "$tmp/input.json")
home_hash=$(printf '%s' "$home" | hash)
jq -S -L "$SCRIPT_DIR" --arg home_key "home-$home_hash" -f "$SCRIPT_DIR/fm-live-board-snapshot.jq" "$tmp/input.json" > "$tmp/board.json"
revision=$(hash < "$tmp/board.json")
jq --arg revision "$revision" '. + {revision:$revision}' "$tmp/board.json"
