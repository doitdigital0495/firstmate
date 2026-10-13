#!/usr/bin/env bash
# Build a real live board in a throwaway home with workers at several stages and
# projects with every delivery mode, then copy board.html into the evidence dir.
set -u
ROOT=${1:?worktree}
EV=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$ROOT/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-live-board-evidence)
home="$TMP_ROOT/lab"
mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
chmod 700 "$home" "$home/data" "$home/state" "$home/config"
cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
fakebin=$(fm_fakebin "$home")
fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi lavish-axi
printf '{"schema":"fm-live-board-config.v1","enabled":true,"refresh_seconds":60}\n' > "$home/config/live-board.json"
printf '%s\n' \
  '- shop [no-mistakes] - fixture (added 2026-01-01)' \
  '- site [direct-PR +yolo preview-on-push] - fixture (added 2026-01-01)' \
  '- notes [local-only] - fixture (added 2026-01-01)' \
  '- platform [no-mistakes-prod-only] - fixture (added 2026-01-01)' \
  '- quiet-repo [direct-PR] - idle fixture (added 2026-01-01)' > "$home/data/projects.md"
in_home() { PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
  LAVISH_AXI_NO_OPEN=1 "$@"; }
tasks_in() { (cd "$home" && tasks-axi "$@" >/dev/null); }
worker() { local id=$1 now=$2 proj=$3 gen event=stop
  mkdir -p "$home/projects/wt-$id"
  fm_write_meta "$home/state/$id.meta" 'kind=ship' 'harness=claude' "window=firstmate:fm-$id" \
    "worktree=$home/projects/wt-$id" "project=$proj"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$id")
  [ "$now" = idle ] || event=user-prompt-submit
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" "$id" "$now" --gen "$gen" --source claude-hook --event "$event"; }
for row in 'ev-checkout|busy|shop|Build the new checkout' 'ev-pay|idle|shop|Fix the payment error' \
  'ev-supplier|idle|site|Wait for the supplier release' 'ev-done|idle|site|Tidy the product page' \
  'ev-docs|busy|platform|Write the onboarding guide'; do
  IFS='|' read -r id now proj title <<<"$row"
  tasks_in add "$id" "$title" --repo "$proj" --kind ship --start
  worker "$id" "$now" "$proj"
done
s=$(date +%s)
printf 'working [at=%s]: wiring the basket into the new checkout page\n' "$s" > "$home/state/ev-checkout.status"
printf 'blocked [at=%s]: the payment sandbox keeps refusing our test card\n' "$s" > "$home/state/ev-pay.status"
printf 'paused [at=%s]: waiting for the supplier to publish their release\n' "$s" > "$home/state/ev-supplier.status"
printf 'done [at=%s]: product page tidied and checked on a phone\n' "$s" > "$home/state/ev-done.status"
printf 'working [at=%s]: drafting the first-week checklist\n' "$s" > "$home/state/ev-docs.status"
in_home "$ROOT/bin/fm-live-board.sh" build
cp "$home/data/live-board/board.html" "$EV/board.html"
# Stage coverage straight from the real projection over the collected input.
in_home "$ROOT/bin/fm-fleet-snapshot.sh" --live-board-input > "$TMP_ROOT/in.json"
for edit in 'validating (running)|working' 'parked at review: 3 finding(s)|parked' 'parked at test: 1 finding(s)|parked' \
  'ci running|working' 'checks green: PR ready for review|done' 'run completed|done'; do
  IFS='|' read -r detail state <<<"$edit"
  jq --arg d "$detail" --arg st "$state" '(.tasks[] | select(.id == "ev-checkout") | .current_state) |= . + {state:$st,source:"run-step",detail:$d}' \
    "$TMP_ROOT/in.json" > "$TMP_ROOT/e.json"
  printf '%-40s -> ' "run-step $state: $detail"
  "$ROOT/bin/fm-live-board-snapshot.sh" --json --input "$TMP_ROOT/e.json" \
    | jq -r -L "$ROOT/bin" 'include "fm-live-board-projects"; lb_view(null)
      | ([.workers[] | select(.id == "ev-checkout")][0] // {stage:"(not listed: finished)"}) | "\(.stage) | \(.doing // "")"'
done
fm_test_cleanup
