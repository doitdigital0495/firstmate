#!/usr/bin/env bash
# Seed a disposable firstmate lab home with work in every live-board lane and
# four captain questions. Usage: setup-lab.sh <worktree> <lab-home>
set -eu
ROOT=$1
LAB=$2

fm() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" FM_PROCEVENT_CLAIM_ROOT="$LAB/procevent-claims" "$@"; }
t() { (cd "$LAB" && fm tasks-axi "$@" >/dev/null); }
worker() {  # <id> <busy|idle>
  local id=$1 now=$2 gen event=stop
  mkdir -p "$LAB/projects/wt-$id"
  printf '%s\n' 'kind=ship' 'harness=claude' "window=firstmate:fm-$id" \
    "worktree=$LAB/projects/wt-$id" 'project=shop' > "$LAB/state/$id.meta"
  gen=$(fm "$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" "$id")
  [ "$now" = idle ] || event=user-prompt-submit
  fm "$ROOT/bin/fm-busy-event.sh" apply "$LAB/state" "$id" "$now" --gen "$gen" --source claude-hook --event "$event"
}

cp "$ROOT/.tasks.toml" "$LAB/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
printf -- '- shop [no-mistakes] - fixture (added 2026-01-01)\n' > "$LAB/data/projects.md"
printf '%s\n' '{"schema":"fm-live-board-config.v1","enabled":true,"refresh_seconds":60}' > "$LAB/config/live-board.json"
cat > "$LAB/config/live-board-projects.json" <<'JSON'
{"schema":"fm-live-board-projects.v1","projects":[
  {"name":"Web shop","description":"The new checkout and everything around it.","match":[{"repo":"shop"}]}]}
JSON

# Doing now / charted (stuck, paused, finished)
for row in 'ln-doing|busy|Build the new checkout' 'ln-stuck|idle|Fix the payment error' \
  'ln-paused|idle|Wait for the supplier release' 'ln-finished|idle|Tidy the product page'; do
  id=${row%%|*}; row=${row#*|}
  t add "$id" "${row#*|}" --repo shop --kind ship --start
  worker "$id" "${row%%|*}"
done
stamp=$(date +%s)
printf 'working [at=%s]: wiring the basket into the new checkout page\n' "$stamp" > "$LAB/state/ln-doing.status"
printf 'blocked [at=%s]: the payment sandbox keeps refusing our test card\n' "$stamp" > "$LAB/state/ln-stuck.status"
printf 'paused [at=%s]: waiting for the supplier to publish their release\n' "$stamp" > "$LAB/state/ln-paused.status"
printf 'done [at=%s]: product page tidied and checked on a phone\n' "$stamp" > "$LAB/state/ln-finished.status"

# Next: queued, nothing in the way
t add ln-next-top "Add order tracking" --repo shop --kind ship --priority 1
t add ln-next-low "Polish the footer" --repo shop --kind ship --priority 3
t add ln-next-b "Rename the basket" --repo shop --kind ship
t add ln-next-c "Refresh the icons" --repo shop --kind ship

# Charted next: will not start on its own
t add ln-gated "Launch the loyalty scheme" --repo shop --kind ship --blocked-by ln-doing
t add ln-held "Switch payment provider" --repo shop --kind ship
t hold ln-held --reason "The supplier contract is still being signed" --kind external --until 2099-01-01

# Captain questions
t add q-carrier "Which carrier?" --repo shop --kind captain --priority 1
t add q-window "Move the maintenance window?" --repo shop --kind captain
t add q-name "Name the release" --repo shop --kind captain
t add q-later "Pick a loyalty partner" --repo shop --kind captain
# Work that only waits on the captain's answer about the window.
cat > "$LAB/ctx-carrier.json" <<'JSON'
{"schema":"fm-captain-question.v1","close":"done",
 "about":"The web shop needs one company to deliver the spring orders to customers.",
 "purpose":"Your pick lets the team book the deliveries. Until you pick, spring orders cannot be sent out.",
 "question":"Who should ship the spring orders?",
 "options":[{"value":"dhl","label":"DHL","detail":"Next-day delivery, about 8 percent dearer."},
  {"value":"postnl","label":"PostNL","detail":"Two-day delivery at today's price, which is why it is recommended."}],
 "recommendation":"postnl"}
JSON
cat > "$LAB/ctx-window.json" <<'JSON'
{"schema":"fm-captain-question.v1","close":"release",
 "about":"The nightly maintenance of the shop overlaps with the busiest ordering hour.",
 "purpose":"Your pick lets the paused maintenance work continue at the hour you choose.",
 "question":"Should the maintenance window move?",
 "options":[{"value":"keep","label":"Keep 22:00","detail":"Nothing changes; some evening orders are slow."},
  {"value":"move","label":"Move to 03:00","detail":"Maintenance runs when almost nobody orders."}],
 "recommendation":"move"}
JSON
cat > "$LAB/ctx-name.json" <<'JSON'
{"schema":"fm-captain-question.v1","close":"done",
 "about":"The next release of the shop still has no name.",
 "purpose":"The name goes on the announcement to the business. Without it the announcement waits."}
JSON
fm "$ROOT/bin/fm-captain-hold.sh" hold q-carrier --reason "Pick a carrier." --context-file "$LAB/ctx-carrier.json" >/dev/null
fm "$ROOT/bin/fm-captain-hold.sh" hold q-window --reason "Load overlaps." --context-file "$LAB/ctx-window.json" >/dev/null
fm "$ROOT/bin/fm-captain-hold.sh" hold q-name --reason "Free answer." --context-file "$LAB/ctx-name.json" >/dev/null
fm "$ROOT/bin/fm-captain-hold.sh" hold q-later --reason "Decide after the summer." --until 2099-01-01 >/dev/null
echo "seeded: $LAB"
