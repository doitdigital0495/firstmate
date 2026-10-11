#!/usr/bin/env bash
# Evidence driver, second page. Validation and merge/CI statuses are read from a
# real no-mistakes run, which a throwaway home cannot hold. This takes the board
# input the real collector produced for the fixture home, sets the resolved
# current state of two workers to the readings bin/fm-crew-state.sh emits for a
# running review and a green pull request, and then runs the same steps
# `fm-live-board.sh build` runs: the real snapshot, the real view and the shipped
# template. Usage: drive-run-states.sh <worktree> <fixture-root>
set -euo pipefail
ROOT=$1
FX=$2
jq '(.tasks[] | select(.id == "w-val") | .current_state)
      |= . + {state:"working",source:"run-step",detail:"validating (running)"}
  | (.tasks[] | select(.id == "w-merge") | .current_state)
      |= . + {state:"done",source:"run-step",detail:"checks green: PR ready for review (still monitoring for merge/close)"}' \
  "$FX/input.json" > "$FX/input-run-states.json"
"$ROOT/bin/fm-live-board-snapshot.sh" --json --input "$FX/input-run-states.json" > "$FX/snapshot-run-states.json"
map=$(cat "$FX/main/config/live-board-projects.json")
jq -c -L "$ROOT/bin" --argjson map "$map" 'include "fm-live-board-projects";
  {refresh_seconds:60, view:lb_view($map),
   board:(if (.pull_requests.repos | type) == "array" then .pull_requests.repos |= map(del(.prs)) else . end)}' \
  "$FX/snapshot-run-states.json" > "$FX/payload.json"
json=$(cat "$FX/payload.json")
printf '%s' "${json//</\\u003c}" > "$FX/payload.json"
BOARD_DATA="$FX/payload.json" perl -pe 'BEGIN { local $/; open my $f, "<", $ENV{BOARD_DATA} or die; $data = <$f>; close $f }
  s/^__FM_LIVE_BOARD_DATA__$/$data/' "$ROOT/bin/fm-live-board-template.html" > "$FX/board-run-states.html"
jq -c '.view.workers.statuses' "$FX/payload.json"
