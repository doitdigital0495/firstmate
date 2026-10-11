#!/usr/bin/env bash
# Evidence driver: build a real live board from a throwaway home with workers in
# several states (own home + a registered second mate) and print the board path.
# Usage: drive-board.sh <worktree-root> <scratch-dir>
set -eu
ROOT_ARG=$1
TMP_ROOT=$2
# shellcheck disable=SC1091
. "$ROOT_ARG/tests/lib.sh"
LIVE="$ROOT/bin/fm-live-board.sh"
ENABLED='{"schema":"fm-live-board-config.v1","enabled":true,"refresh_seconds":60}'

make_home() {
  local home="$TMP_ROOT/$1" fakebin
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
worker() {
  local home=$1 id=$2 now=$3 gen event=stop
  shift 3
  mkdir -p "$home/projects/wt-$id"
  fm_write_meta "$home/state/$id.meta" 'kind=ship' 'harness=claude' "window=firstmate:fm-$id" \
    "worktree=$home/projects/wt-$id" "$@"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$id")
  [ "$now" = idle ] || event=user-prompt-submit
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" "$id" "$now" --gen "$gen" --source claude-hook --event "$event"
}

home=$(make_home captain)
mate=$(make_home mate)
mkdir -p "$mate/bin"
printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
printf 'ai-desk\n' > "$mate/.fm-secondmate-home"
printf '%s\n' "$ENABLED" > "$home/config/live-board.json"
printf -- '- shop [no-mistakes] - fixture (added 2026-01-01)\n- quiet [local-only] - fixture (added 2026-01-01)\n' > "$home/data/projects.md"
printf -- '- ai-desk - fixture (home: %s; scope: fixture; projects: desk; added 2026-07-11)\n' "$mate" > "$home/data/secondmates.md"
printf '%s\n' '{"schema":"fm-live-board-projects.v1","projects":[{"name":"Web shop","description":"The online shop","match":[{"repo":"shop"}]},{"name":"Help desk","match":[{"repo":"desk"}]}]}' \
  > "$home/config/live-board-projects.json"

for row in 'ln-doing|busy|Build the new checkout' 'ln-stuck|idle|Fix the payment error' \
  'ln-paused|idle|Wait for the supplier release' 'ln-finished|idle|Tidy the product page' \
  'ln-lost|idle|Speed up search' 'ln-askw|idle|Choose the invoice layout'; do
  id=${row%%|*}; row=${row#*|}
  tasks_in "$home" add "$id" "${row#*|}" --repo shop --kind ship --start
  worker "$home" "$id" "${row%%|*}" 'project=shop'
done
stamp=$(date +%s)
printf 'working [at=%s]: wiring the basket into the new checkout page\n' "$stamp" > "$home/state/ln-doing.status"
printf 'blocked [at=%s]: the payment sandbox keeps refusing our test card\n' "$stamp" > "$home/state/ln-stuck.status"
printf 'paused [at=%s]: waiting for the supplier to publish their release\n' "$stamp" > "$home/state/ln-paused.status"
printf 'done [at=%s]: product page tidied and checked on a phone\n' "$stamp" > "$home/state/ln-finished.status"
printf 'paused [at=%s]: two invoice layouts are ready, waiting for a pick\n' "$stamp" > "$home/state/ln-askw.status"
in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold ln-askw --reason "Pick the invoice layout." >/dev/null \
  || echo "note: could not put a captain hold on the in-flight ln-askw" >&2
tasks_in "$home" add ln-next-top "Add order tracking" --repo shop --kind ship --priority 1
tasks_in "$home" add ln-next-b "Rename the basket" --repo shop --kind ship
tasks_in "$home" add ln-gated "Launch the loyalty scheme" --repo shop --kind ship --blocked-by ln-doing
tasks_in "$home" add ln-held "Switch payment provider" --repo shop --kind ship
tasks_in "$home" hold ln-held --reason "The supplier contract is still being signed" --kind external --until 2099-01-01
tasks_in "$home" add ln-ask "Which courier?" --repo shop --kind captain
in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold ln-ask --reason "Pick a courier." >/dev/null

tasks_in "$mate" add cr-answer "Answer the refund question" --repo desk --kind scout --start
tasks_in "$mate" add cr-waiting "Draft the desk handbook" --repo desk --kind ship
tasks_in "$mate" add cr-held "Pick the desk tool" --repo desk --kind ship
tasks_in "$mate" hold cr-held --reason "The vendor has not sent a quote" --kind external --until 2099-01-01
worker "$mate" cr-answer busy 'kind=scout' 'project=desk' 'pr=https://github.com/acme/desk/pull/7'

in_home "$home" "$LIVE" build
in_home "$home" "$ROOT/bin/fm-live-board-snapshot.sh" --json > "$TMP_ROOT/snapshot.json"
