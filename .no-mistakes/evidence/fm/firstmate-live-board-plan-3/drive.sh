#!/usr/bin/env bash
# Live CLI drive of captain question context + guarded answers + live board, isolated FM_HOME.
set -u
ROOT=$1; H=$(mktemp -d /tmp/fm-lab-ctx.XXXXXX)
mkdir -p $H/data $H/state $H/config $H/projects $H/fakebin
cp $ROOT/.tasks.toml $H/.tasks.toml
printf '## In flight\n\n## Queued\n\n## Done\n' > $H/data/backlog.md
for b in tmux treehouse no-mistakes gh gh-axi; do printf '#!/bin/sh\nexit 0\n' > $H/fakebin/$b; chmod +x $H/fakebin/$b; done
TA=$(command -v tasks-axi)
cap(){ PATH="$H/fakebin:$PATH" REAL_TASKS_AXI=$TA FM_HOME=$H FM_STATE_OVERRIDE=$H/state FM_DATA_OVERRIDE=$H/data FM_CONFIG_OVERRIDE=$H/config $ROOT/bin/fm-captain-hold.sh "$@"; }
board(){ FM_HOME=$H FM_ROOT_OVERRIDE=$ROOT $ROOT/bin/fm-live-board-snapshot.sh; }
step(){ printf '\n=== %s\n' "$*"; }
step "S1 hold with owner context (release mode, options, recommendation, subject)"
printf '%s' '{"schema":"fm-captain-question.v1","close":"release","options":[{"value":"gold","label":"Gold-only plan"},{"value":"revise","label":"Revise scope"}],"recommendation":"gold","subject":{"artifact":"pricing-page","version":"1.2.0"}}' > $H/ctx.json
FM_CAPTAIN_HOLD_NOW=2026-10-09T10:00:00Z cap hold demo-1 --title "Pick pricing plan" --reason "Captain picks plan" --repo webshop --context-file $H/ctx.json; echo "exit=$?"
ID=$(cap open demo-1 --identity); echo "open identity: $ID"
step "S1 board shows project-grouped question with context"
board | jq '.projects[] | select(any(.questions[]; .id=="demo-1")) | {project: (.name // .project // .id), questions: [.questions[] | select(.id=="demo-1")]}'
step "S2 changing published context within active lifecycle refuses, row unchanged"
cp $H/data/backlog.md $H/before; jq -c '.recommendation="revise"' $H/ctx.json > $H/ctx2.json
cap hold demo-1 --reason x --context-file $H/ctx2.json; echo "exit=$?"; cmp -s $H/before $H/data/backlog.md && echo "backlog unchanged"
step "S3 malformed contexts refuse before mutation"
for c in '{"schema":"fm-captain-question.v2","close":"done"}' '{"schema":"fm-captain-question.v1"}' '{"schema":"fm-captain-question.v1","close":"done","recommendation":"made-up"}' '{"schema":"fm-captain-question.v1","close":"done","answer_mode":"auto"}' 'not json'; do
  printf '%s' "$c" > $H/bad.json; FM_CAPTAIN_HOLD_NOW=2026-10-09T10:05:00Z cap hold demo-bad --reason r --context-file $H/bad.json 2>&1; echo "exit=$? input=$c"; done
cap open demo-bad --identity >/dev/null 2>&1 && echo "BUG demo-bad held" || echo "demo-bad never created/held"
step "S4 wrong close mode (done vs owner release) refuses, no mutation"
printf 'demo-1\tgold\tGold-only plan\tdone\t%s\n' "$ID" | cap answers --source lab; echo "exit=$?"; cmp -s $H/before $H/data/backlog.md && echo "backlog unchanged"
step "S5 guarded answer with matching mode + lifecycle releases"
printf 'demo-1\tgold\tGold-only plan\trelease\t%s\n' "$ID" | cap answers --source lab; echo "exit=$?"
(cd $H && tasks-axi show demo-1 --full) | grep -E 'state:|held:|Captain answer lifecycle|Captain question context' 
step "S5b exact replay is idempotent"
cp $H/data/backlog.md $H/after1; printf 'demo-1\tgold\tGold-only plan\trelease\t%s\n' "$ID" | cap answers --source lab; echo "exit=$?"; cmp -s $H/after1 $H/data/backlog.md && echo "backlog unchanged on replay"
step "S6 same-second re-hold: stale old-lifecycle answer refuses"
FM_CAPTAIN_HOLD_NOW=2026-10-09T10:00:00Z cap hold demo-1 --reason "new gate" --context-file $H/ctx.json; NEW=$(cap open demo-1 --identity); echo "new identity: $NEW"
cp $H/data/backlog.md $H/held2; printf 'demo-1\tgold\tGold-only plan\trelease\t%s\n' "$ID" | cap answers --source lab; echo "exit=$?"; cmp -s $H/held2 $H/data/backlog.md && echo "backlog unchanged"
step "S7 re-hold without context -> board shows legacy, not answerable"
printf 'demo-1\tgold\tGold-only plan\trelease\t%s\n' "$NEW" | cap answers --source lab >/dev/null; FM_CAPTAIN_HOLD_NOW=2026-10-09T10:00:00Z cap hold demo-1 --reason "unannotated gate"
board | jq -c '.projects[].questions[] | select(.id=="demo-1") | {id,context_status,answerable}'
step "S8 done-mode context closes task"
printf '%s' '{"schema":"fm-captain-question.v1","close":"done"}' > $H/d.json
FM_CAPTAIN_HOLD_NOW=2026-10-09T11:00:00Z cap hold demo-2 --title "Approve copy" --reason "Approve copy" --repo docs --context-file $H/d.json
I2=$(cap open demo-2 --identity); printf 'demo-2\tyes\tApproved\tdone\t%s\n' "$I2" | cap answers --source lab; echo "exit=$?"
(cd $H && tasks-axi show demo-2 --full) | grep -E 'state:'
step "S9 legacy unguarded answer (no lifecycle field) still works"
FM_CAPTAIN_HOLD_NOW=2026-10-09T12:00:00Z cap hold demo-3 --title "Old style" --reason "legacy" --repo docs
printf 'demo-3\tok\tOK\n' | cap answers --source lab; echo "exit=$?"
(cd $H && tasks-axi show demo-3 --full) | grep -E 'state:'
step "S10 contexts codec (pure stdin) + board renders"
printf '{"records":[{"structured":true,"hold_kind":"captain","state":"queued","hold_set":"2026-10-09T10:00:00Z","body_lines":["Captain hold set: 2026-10-09T10:00:00Z","Captain question context: {\\"close\\":\\"done\\",\\"lifecycle\\":\\"2026-10-09T10:00:00Z#0\\",\\"options\\":[],\\"recommendation\\":null,\\"schema\\":\\"fm-captain-question.v1\\",\\"subject\\":null}"]}]}' | cap contexts | jq -c '.records[0].question_context'
board | jq -c '{projects: [.projects[] | {name: (.name // .project // .id), q: [.questions[] | {id,context_status,answerable}]}]}'
rm -rf $H
