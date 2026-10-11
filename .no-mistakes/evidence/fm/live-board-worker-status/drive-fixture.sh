#!/usr/bin/env bash
# Evidence driver: builds a throwaway firstmate home plus one registered second
# mate home, gives their tasks workers in different states, and runs the real
# `bin/fm-live-board.sh build`. Usage: drive-fixture.sh <worktree> <fixture-root>
set -euo pipefail
ROOT=$1
FX=$2
# shellcheck disable=SC1091
. "$ROOT/tests/lib.sh"
trap - EXIT INT TERM HUP QUIT

make_home() {
  local home="$FX/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  chmod 700 "$home" "$home/data" "$home/state" "$home/config"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi lavish-axi
  printf '%s\n' "$home"
}
in_home() {
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_NO_OPEN=1 "$@"
}
tasks_in() { local home=$1; shift; (cd "$home" && tasks-axi "$@" >/dev/null); }
worker() {  # <home> <id> <busy|idle> [meta-line...]
  local home=$1 id=$2 now=$3 gen event=stop
  shift 3
  mkdir -p "$home/projects/wt-$id"
  fm_write_meta "$home/state/$id.meta" 'kind=ship' 'harness=claude' "window=firstmate:fm-$id" \
    "worktree=$home/projects/wt-$id" "$@"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$id")
  [ "$now" = idle ] || event=user-prompt-submit
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" "$id" "$now" --gen "$gen" --source claude-hook --event "$event"
}

home=$(make_home main)
mate=$(make_home mate)
mkdir -p "$mate/bin"
printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
printf 'ai-desk\n' > "$mate/.fm-secondmate-home"
printf -- '- shop [no-mistakes] - fixture (added 2026-01-01)\n- claims [no-mistakes] - fixture (added 2026-01-01)\n' > "$home/data/projects.md"
printf -- '- ai-desk - fixture (home: %s; scope: fixture; projects: desk; added 2026-07-11)\n- lost-desk - fixture (home: %s/no-such-home; scope: fixture; projects: desk; added 2026-07-11)\n' \
  "$mate" "$FX" > "$home/data/secondmates.md"
printf '%s\n' '{"schema":"fm-live-board-projects.v1","projects":[{"name":"Webshop","match":[{"repo":"shop"}]},{"name":"Claims portal","match":[{"repo":"claims"}]},{"name":"Help desk","match":[{"repo":"desk"}]}]}' \
  > "$home/config/live-board-projects.json"
printf '%s\n' '{"schema":"fm-live-board-config.v1","enabled":true,"refresh_seconds":60}' > "$home/config/live-board.json"

for row in 'w-doing|busy|shop|Build the new checkout' 'w-stuck|idle|shop|Fix the payment error' \
  'w-paused|idle|shop|Wait for the supplier release' 'w-finished|idle|shop|Tidy the product page' \
  'w-lost|idle|shop|Speed up search' 'w-ask|idle|shop|Set up the courier integration' \
  'w-val|busy|claims|Add the claim form' 'w-merge|busy|claims|Export claims to a spreadsheet' \
  'c-doing|busy|claims|Rework the claims inbox'; do
  IFS='|' read -r id now repo title <<<"$row"
  tasks_in "$home" add "$id" "$title" --repo "$repo" --kind ship --start
  worker "$home" "$id" "$now" "project=$repo"
done
stamp=$(date +%s)
printf 'working [at=%s]: wiring the basket into the new checkout page\n' "$stamp" > "$home/state/w-doing.status"
printf 'blocked [at=%s]: the payment sandbox keeps refusing our test card\n' "$stamp" > "$home/state/w-stuck.status"
printf 'paused [at=%s]: waiting for the supplier to publish their release\n' "$stamp" > "$home/state/w-paused.status"
printf 'done [at=%s]: product page tidied and checked on a phone\n' "$stamp" > "$home/state/w-finished.status"
printf 'needs-decision [at=%s]: which courier should we use for the launch\n' "$stamp" > "$home/state/w-ask.status"
printf 'working [at=%s]: building the claim form fields\n' "$stamp" > "$home/state/w-val.status"
printf 'working [at=%s]: writing the spreadsheet export\n' "$stamp" > "$home/state/w-merge.status"
printf 'working [at=%s]: sorting the inbox by urgency\n' "$stamp" > "$home/state/c-doing.status"

tasks_in "$mate" add cr-answer "Answer the refund question" --repo desk --kind scout --start
tasks_in "$mate" add cr-wrap "Wrap up the desk report" --repo desk --kind ship --start
tasks_in "$mate" add cr-waiting "Not started yet" --repo desk --kind ship
worker "$mate" cr-answer busy 'kind=scout' 'project=desk'
worker "$mate" cr-wrap idle 'project=desk' 'pr=https://github.com/acme/desk/pull/7'
printf 'done [at=%s]: desk report written and checked\n' "$stamp" > "$mate/state/cr-wrap.status"

in_home "$home" "$ROOT/bin/fm-live-board.sh" build
in_home "$home" "$ROOT/bin/fm-fleet-snapshot.sh" --live-board-input > "$FX/input.json"
