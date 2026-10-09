#!/usr/bin/env bash
# Build a throwaway firstmate home shaped like the captain's real complaint:
# four named projects, ~150 queued tasks, four held questions (three with
# owner context incl. question text + option detail, one legacy with none),
# a running worker with noisy status, and a recently finished row.
# Usage: captain-fixture.sh <worktree-root> <home-dir> [map|nomap|badmap]
set -eu
ROOT=$1 HOME_DIR=$2 MODE=${3:-map}
rm -rf "$HOME_DIR"; mkdir -p "$HOME_DIR"/{data,state,config,projects,fakebin}
chmod 700 "$HOME_DIR" "$HOME_DIR"/{data,state,config}
cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
for t in tmux treehouse no-mistakes gh gh-axi lavish-axi; do printf '#!/bin/sh\nexit 0\n' > "$HOME_DIR/fakebin/$t"; chmod +x "$HOME_DIR/fakebin/$t"; done
printf -- '- reports-app [no-mistakes] - fixture (added 2026-01-01)\n- geris-assistant [direct-PR] - fixture (added 2026-01-01)\n- misc-tools [direct-PR] - fixture (added 2026-01-01)\n' > "$HOME_DIR/data/projects.md"
run() { PATH="$HOME_DIR/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" LAVISH_AXI_NO_OPEN=1 "$@"; }
t() { (cd "$HOME_DIR" && tasks-axi "$@" >/dev/null); }

t add prod-report-kpi "Production report KPI tiles" --repo reports-app --kind ship
t add emb-report-totals "Emballage report totals" --repo reports-app --kind ship
t add apar-ageing "APAR ageing buckets" --repo reports-app --kind ship
t add geris-ai-rag "Geris AI assistant retrieval" --repo geris-assistant --kind ship
t add prod-report-done "Production report date filter" --repo reports-app --kind ship
for i in $(seq 1 150); do t add "misc-chore-$i" "Some chore $i nobody cares about" --repo misc-tools --kind ship; done
t add prod-report-q "Production report question" --repo reports-app --kind captain --priority 1
t add emb-report-q "Emballage report question" --repo reports-app --kind captain
t add apar-q "apar-q" --repo reports-app --kind captain
t add geris-ai-legacy "Geris AI legacy hold" --repo geris-assistant --kind captain

cat > "$HOME_DIR/ctx1.json" <<'J'
{"schema":"fm-captain-question.v1","close":"done","question":"Should the production report count rework hours as productive time?","options":[{"value":"count","label":"Count them","detail":"Totals match the planning sheet; productivity looks about 6 percent higher."},{"value":"separate","label":"Show separately","detail":"Adds a rework column; totals drop to direct hours only."}],"recommendation":"separate"}
J
cat > "$HOME_DIR/ctx2.json" <<'J'
{"schema":"fm-captain-question.v1","close":"release","question":"Emballage report: include returned crates still at the customer?","options":[{"value":"include","label":"Include","detail":"Balance shows everything we own, wherever it is."},{"value":"exclude","label":"Exclude"}]}
J
cat > "$HOME_DIR/ctx3.json" <<'J'
{"schema":"fm-captain-question.v1","close":"done","question":"Which ageing buckets do you want on the APAR report?\nPick the set finance uses.","options":[{"value":"30-60-90","label":"30 / 60 / 90 days","detail":"Standard; matches Exact Online."},{"value":"weekly","label":"Weekly up to 12 weeks","detail":"Finer, but four times as many columns."}],"recommendation":"30-60-90"}
J
run "$ROOT/bin/fm-captain-hold.sh" hold prod-report-q --reason "Totals disagree with planning sheet." --context-file "$HOME_DIR/ctx1.json" >/dev/null
run "$ROOT/bin/fm-captain-hold.sh" hold emb-report-q --reason "Crate balance definition." --context-file "$HOME_DIR/ctx2.json" >/dev/null
run "$ROOT/bin/fm-captain-hold.sh" hold apar-q --reason "Bucket layout." --context-file "$HOME_DIR/ctx3.json" >/dev/null
run "$ROOT/bin/fm-captain-hold.sh" hold geris-ai-legacy --reason "Which tone should the assistant use with drivers?" >/dev/null

printf 'kind=ship\nharness=claude\nproject=reports-app\npr=https://github.com/example/reports-app/pull/77\n' > "$HOME_DIR/state/prod-report-kpi.meta"
printf 'working [at=%s]: KPI tiles render on fm/prod-report-kpi, see data/prod-report-kpi/report.md run=01ABCDEFGHJKMNPQRSTVWXYZ01\n' "$(date +%s)" > "$HOME_DIR/state/prod-report-kpi.status"
printf 'kind=ship\nharness=claude\nproject=geris-assistant\n' > "$HOME_DIR/state/geris-ai-rag.meta"
printf 'blocked [at=%s]: waiting on index rebuild of the embeddings store\n' "$(date +%s)" > "$HOME_DIR/state/geris-ai-rag.status"
t done prod-report-done --pr https://github.com/example/reports-app/pull/70

printf '%s\n' '{"schema":"fm-live-board-config.v1","enabled":true,"refresh_seconds":60}' > "$HOME_DIR/config/live-board.json"
case "$MODE" in
  map) cat > "$HOME_DIR/config/live-board-projects.json" <<'J'
{"schema":"fm-live-board-projects.v1","projects":[
 {"name":"Production report","description":"Daily production KPIs for the plant.","match":[{"id":"prod-report-*"}]},
 {"name":"Emballage report","description":"Crate and pallet balances per customer.","match":[{"id":"emb-report-*"}]},
 {"name":"APAR report","match":[{"id":"apar-*"}]},
 {"name":"Geris AI assistant","match":[{"repo":"geris-assistant"}]}]}
J
  ;;
  badmap) printf '{"schema":"fm-live-board-projects.v1","projects":[{"name":"X","match":[{"branch":"x"}]}]}\n' > "$HOME_DIR/config/live-board-projects.json" ;;
esac
run "$ROOT/bin/fm-live-board.sh" build
