#!/usr/bin/env bash
# Seed a throwaway Firstmate home for the live-board gate run and build the
# real board from it. Usage: seed-home.sh <worktree> <home-dir>
# Fleet backends (tmux, treehouse, no-mistakes, gh) are stubbed so nothing
# touches the operator's fleet; the task store, hold lifecycle, worker busy
# records, snapshot and board build are the real scripts.
set -eu
ROOT=$1
home=$2
# shellcheck disable=SC1091
. "$ROOT/tests/lib.sh"
trap - EXIT INT TERM

mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
chmod 700 "$home" "$home/data" "$home/state" "$home/config"
cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
fakebin=$(fm_fakebin "$home")
fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi

in_home() {
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    LAVISH_AXI_NO_OPEN=1 "$@"
}
t() { (cd "$home" && tasks-axi "$@" >/dev/null); }
worker() {  # <id> <busy|idle> [meta-line...]
  local id=$1 now=$2 gen event=stop
  shift 2
  mkdir -p "$home/projects/wt-$id"
  fm_write_meta "$home/state/$id.meta" 'kind=ship' 'harness=claude' "window=firstmate:fm-$id" \
    "worktree=$home/projects/wt-$id" "$@"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$id")
  [ "$now" = idle ] || event=user-prompt-submit
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" "$id" "$now" --gen "$gen" --source claude-hook --event "$event"
}

printf -- '- web-shop [no-mistakes] - fixture (added 2026-01-01)\n' > "$home/data/projects.md"
printf '%s\n' '{"schema":"fm-live-board-config.v1","enabled":true,"refresh_seconds":60}' > "$home/config/live-board.json"
printf '%s\n' '{"schema":"fm-live-board-projects.v1","projects":[{"name":"Web shop relaunch","description":"The new web shop that opens in spring.","match":[{"repo":"web-shop"}]}]}' \
  > "$home/config/live-board-projects.json"

stamp=$(date +%s)
# Doing now: a worker is busy on it.
t add ws-checkout "Build the new checkout" --repo web-shop --kind ship --start
worker ws-checkout busy 'project=web-shop'
printf 'working [at=%s]: wiring the basket into the new checkout page\n' "$stamp" > "$home/state/ws-checkout.status"
# Charted next: a stuck worker, a finished-not-wrapped worker.
t add ws-payment "Fix the payment error" --repo web-shop --kind ship --start
worker ws-payment idle 'project=web-shop'
printf 'blocked [at=%s]: the payment sandbox keeps refusing our test card\n' "$stamp" > "$home/state/ws-payment.status"
# Next: queued, nothing in the way.
t add ws-tracking "Add order tracking" --repo web-shop --kind ship --priority 1
t add ws-footer "Polish the footer" --repo web-shop --kind ship
# Charted next: waits on other work, on an outside hold.
t add ws-loyalty "Launch the loyalty scheme" --repo web-shop --kind ship --blocked-by ws-checkout
t add ws-provider "Switch payment provider" --repo web-shop --kind ship
t hold ws-provider --reason "The supplier contract is still being signed" --kind external --until 2099-01-01

# Questions for the captain.
t add ws-carrier "Which carrier?" --repo web-shop --kind captain --priority 1
cat > "$home/ctx-carrier.json" <<'JSON'
{"schema":"fm-captain-question.v1","close":"done",
 "about":"The web shop needs one company to deliver the spring orders to customers.",
 "purpose":"Your pick lets the team book the deliveries. Until you pick, spring orders cannot be sent out.",
 "question":"Who should ship the spring orders?",
 "options":[{"value":"dhl","label":"DHL","detail":"Next-day delivery, about 8 percent dearer."},
  {"value":"postnl","label":"PostNL","detail":"Two-day delivery at today's price, which is why it is recommended."}],
 "recommendation":"postnl"}
JSON
in_home "$ROOT/bin/fm-captain-hold.sh" hold ws-carrier --reason "Pick a carrier." --context-file "$home/ctx-carrier.json" >/dev/null

# A piece of work paused on a captain decision; answering releases it.
t add ws-banner "Put the spring banner on the home page" --repo web-shop --kind ship
cat > "$home/ctx-banner.json" <<'JSON'
{"schema":"fm-captain-question.v1","close":"release",
 "about":"The home page gets a banner for the spring sale, and there are two designs.",
 "purpose":"Your pick tells the team which design to build. Until you pick, the banner is not built.",
 "question":"Which banner design should go on the home page?",
 "options":[{"value":"photo","label":"Photo banner","detail":"A large product photo. Looks richer, loads a little slower on phones."},
  {"value":"plain","label":"Plain banner","detail":"Text on a colour. Loads fastest and is ready a day sooner."}],
 "recommendation":"plain"}
JSON
in_home "$ROOT/bin/fm-captain-hold.sh" hold ws-banner --reason "Pick a banner." --context-file "$home/ctx-banner.json" >/dev/null

# A question answered in the captain's own words (no options).
t add ws-name "Name the release" --repo web-shop --kind captain
cat > "$home/ctx-name.json" <<'JSON'
{"schema":"fm-captain-question.v1","close":"done",
 "about":"The spring relaunch of the web shop still has no name.",
 "purpose":"The name goes on the announcement to customers. Without it the announcement waits."}
JSON
in_home "$ROOT/bin/fm-captain-hold.sh" hold ws-name --reason "Free answer." --context-file "$home/ctx-name.json" >/dev/null

# A question the captain put off until a later day: not answered, so it stays.
t add ws-partner "Pick a loyalty partner" --repo web-shop --kind captain
in_home "$ROOT/bin/fm-captain-hold.sh" hold ws-partner --reason "Decide after the summer." --until 2099-01-01 >/dev/null

in_home "$ROOT/bin/fm-live-board.sh" build
