#!/usr/bin/env bash
# Separate home-local live-board projection, never a Bearings status-page mode.
# Usage: fm-live-board-snapshot.sh [--json] [--input FILE] [--prs FILE]
# Default: collect exactly one fm-fleet-snapshot.sh --live-board-input snapshot.
# --input renders a previously collected fm-live-board-input.v1, without reads
# of operational state. Unsupported/malformed input fails without partial output.
# Output contract: fm-live-board.v1; schema validation and projection are owned
# by bin/fm-live-board-snapshot.jq. Fields: revision (SHA-256 of payload before
# revision), collected_at/epoch, collection_duration_seconds, home {key,label},
# coverage, omissions[], warnings[], counts, projects[], recently_finished[]
# and pull_requests.
# Each project has a home-qualified key, name/label, registration, counts,
# tasks[] and questions[]. recently_finished lists structured done backlog rows
# whose done/merged date falls in the 14 days before collection as
# {key,id,project,title,finished}, newest first, so a board can show progress.
# Project identity is backlog repo first, metadata project second, else Unassigned;
# conflicting structured identities are disclosed, never guessed from prose.
# Open backlog rows and metadata-only workers are retained. Done backlog rows
# are excluded from projects even if their metadata remains. Duplicate ids remain visible with
# row-qualified keys and warnings, not conflated into an answerable identity.
# Queued/program/held backlog-only rows are not fabricated workers. Runtime done
# with open backlog is finished-awaiting-processing, not merged or landed.
# Current state/source and last meaningful history remain distinct. History uses
# the canonical reader's strict generation-bound event/milestone projection.
# Every open captain hold across all buckets is a question. Valid owner-authored
# context supplies lifecycle, explicit close mode and labelled options; its
# storage/guard contract (including the optional question text and option
# detail) belongs to fm-captain-hold.sh. Missing/invalid/stale
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
# --prs names one fm-live-board-prs.v1 document (bin/fm-live-board-prs.sh owns
# it); this command reads no forge itself. pull_requests is {status,
# collected_at_epoch, repos[]} with status not-collected when no file was
# given, unreadable when the file is not that document (neither fails the
# snapshot), else collected. Each repo is {project, forge, status, reason,
# prs[]} and each pull request {number, url, state, draft, task, title,
# summary, at, deploy}. task is the ship branch without the project's
# registered prefix, or null; at is the merge, close or open time. title is
# the cleaned title and summary a one-to-three-sentence manager note drawn
# from the description, or null when the description is missing or too
# technical; lbp_summary in bin/fm-live-board-prs.jq is the one rule. deploy is
# {outcome, why, runs[{name,result}], more_runs}, the result of the runs its
# merge started, decided by lbp_deploy there: succeeded, failed, running,
# not-deployed, none or unknown. No description
# text beyond that summary leaves this projection, and only canonical GitHub
# /pull/<number> and Azure DevOps /pullrequest/<number> links are kept.
# Only allowlisted fields leave this projection: no backlog bodies, raw status,
# terminal output, action commands, private file paths or arbitrary links. Only
# recorded https PR /pull/<number> links are retained. Operational text must
# itself be secret-free; publishing this home remains an explicit later opt-in.
# This command changes no home state, starts no service and spends no model turns.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; }
input='' prs=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) shift ;;
    --input) [ "$#" -ge 2 ] && [ -z "$input" ] || { usage >&2; exit 2; }; input=$2; shift 2 ;;
    --prs) [ "$#" -ge 2 ] && [ -z "$prs" ] || { usage >&2; exit 2; }; prs=$2; shift 2 ;;
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
printf 'null\n' > "$tmp/prs.json"
if [ -n "$prs" ]; then
  jq -c 'if type == "object" then . else "unreadable" end' "$prs" > "$tmp/prs.json" 2>/dev/null \
    && [ "$(wc -l < "$tmp/prs.json" | tr -d '[:space:]')" = 1 ] || printf '"unreadable"\n' > "$tmp/prs.json"
fi
jq -S -L "$SCRIPT_DIR" --arg home_key "home-$home_hash" --slurpfile prs "$tmp/prs.json" -f "$SCRIPT_DIR/fm-live-board-snapshot.jq" "$tmp/input.json" > "$tmp/board.json"
revision=$(hash < "$tmp/board.json")
jq --arg revision "$revision" '. + {revision:$revision}' "$tmp/board.json"
