#!/usr/bin/env bash
# Manual live drive of the live-board snapshot + captain question context.
set -u
ROOT=/home/daan/.no-mistakes/worktrees/cf62ac6bfd91/01M4ESZN1P5HB502VQPF78WW8D
H=$(mktemp -d /tmp/fm-board-drive/home.XXXX)
mkdir -p "$H/data" "$H/state" "$H/config" "$H/projects" "$H/fakebin"
cp "$ROOT/.tasks.toml" "$H/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$H/data/backlog.md"
for b in tmux treehouse no-mistakes gh gh-axi; do printf '#!/bin/sh\nexit 0\n' > "$H/fakebin/$b"; chmod +x "$H/fakebin/$b"; done
export PATH="$H/fakebin:$PATH" FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" REAL_TASKS_AXI=$(command -v tasks-axi)
cap() { "$ROOT/bin/fm-captain-hold.sh" "$@"; }
step() { printf '\n===== %s =====\n' "$*"; }

step "seed backlog: 2 tasks in repo alpha, 1 in beta, 1 unassigned"
(cd "$H" && tasks-axi add alpha-build "build alpha widget" --kind ship --repo alpha --start >/dev/null \
  && tasks-axi add alpha-pick "pick alpha rollout" --kind ship --repo alpha --queue >/dev/null \
  && tasks-axi add beta-docs "beta docs pass" --kind docs --repo beta --queue >/dev/null \
  && tasks-axi add loose-note "loose note" --queue >/dev/null) && echo seeded

step "hold alpha-pick WITH owner context (close=release, 2 options, recommendation)"
cat > "$H/ctx.json" <<'EOF'
{"schema":"fm-captain-question.v1","close":"release","options":[{"value":"canary","label":"Canary first"},{"value":"all","label":"Roll out to all"}],"recommendation":"canary","subject":{"artifact":"alpha-rollout","version":"1.0.0"}}
EOF
FM_CAPTAIN_HOLD_NOW=2026-10-09T08:00:00Z cap hold alpha-pick --reason "Canary or full rollout?" --repo alpha --context-file "$H/ctx.json"; echo "exit=$?"

step "hold beta-docs WITHOUT context (legacy hold) priority 1"
(cd "$H" && tasks-axi update beta-docs --priority 1 >/dev/null 2>&1)
FM_CAPTAIN_HOLD_NOW=2026-10-09T09:00:00Z cap hold beta-docs --reason "Publish docs now?" --repo beta; echo "exit=$?"

step "ADVERSARIAL: malformed contexts refuse before mutation"
cp "$H/data/backlog.md" "$H/before"
(cd "$H" && tasks-axi add alpha-x "another alpha call" --repo alpha --queue >/dev/null)
cp "$H/data/backlog.md" "$H/before"
for bad in \
  '{"schema":"fm-captain-question.v1"}' \
  '{"schema":"fm-captain-question.v1","close":"merge"}' \
  '{"schema":"fm-captain-question.v2","close":"done"}' \
  '{"schema":"fm-captain-question.v1","close":"done","actions":"rm -rf"}' \
  '{"schema":"fm-captain-question.v1","close":"done","options":[{"value":"reconcile","label":"x"}]}' \
  '{"schema":"fm-captain-question.v1","close":"done","recommendation":"invented"}' \
  '{"schema":"fm-captain-question.v1","close":"done","lifecycle":"forged#0"}' \
  'not json'; do
  printf '%s\n' "$bad" > "$H/bad.json"
  out=$(cap hold alpha-x --reason "bad ctx" --repo alpha --context-file "$H/bad.json" 2>&1); rc=$?
  printf 'rc=%s  input=%s  -> %s\n' "$rc" "$bad" "$out"
done
python3 -c 'import json;print(json.dumps({"schema":"fm-captain-question.v1","close":"done","options":[{"value":"o%d"%i,"label":"L"*119} for i in range(12)],"pad":"x"*9000}))' > "$H/big.json"
out=$(cap hold alpha-x --reason "big" --context-file "$H/big.json" 2>&1); echo "rc=$? oversize -> $out"
cmp -s "$H/before" "$H/data/backlog.md" && echo "backlog UNCHANGED after all refused contexts" || echo "BACKLOG MUTATED"

step "live-board snapshot (default collection path)"
"$ROOT/bin/fm-live-board-snapshot.sh" --json > "$H/board.json"; echo "exit=$?"
jq '{schema, revision:(.revision|length), home, counts, projects:[.projects[]|{key,"label":.label,counts,
     tasks:[.tasks[]|{id,state}], questions:[.questions[]|{id,priority,answerable,context_status,close,options,recommendation,lifecycle}]}], warnings:[.warnings[]|.kind]}' "$H/board.json"

step "privacy: board must not contain backlog body text or home path"
grep -c "$H" "$H/board.json" | sed 's/^/home-path occurrences: /'
grep -c 'Captain question context' "$H/board.json" | sed 's/^/raw-body-marker occurrences: /'

step "determinism: re-render from --input twice -> identical revision"
"$ROOT/bin/fm-fleet-snapshot.sh" --live-board-input > "$H/input.json"
r1=$("$ROOT/bin/fm-live-board-snapshot.sh" --input "$H/input.json" | jq -r .revision)
r2=$("$ROOT/bin/fm-live-board-snapshot.sh" --input "$H/input.json" | jq -r .revision)
echo "r1=$r1"; echo "r2=$r2"; [ "$r1" = "$r2" ] && echo "revision deterministic"

step "ADVERSARIAL: malformed --input fails without partial output"
echo '{"schema":"fm-live-board-input.v0"}' > "$H/badin.json"
out=$("$ROOT/bin/fm-live-board-snapshot.sh" --input "$H/badin.json" 2>/dev/null); echo "rc=$? stdout-bytes=${#out}"

step "guarded answer: lifecycle from open --identity"
id_life=$(cap open alpha-pick --identity); echo "identity=$id_life"
cp "$H/data/backlog.md" "$H/held"
echo "-- wrong close mode (done vs owner release):"
printf 'alpha-pick\tcanary\tCanary first\tdone\t%s\n' "$id_life" | cap answers --source "drive" ; echo "rc=$?"
echo "-- stale lifecycle:"
printf 'alpha-pick\tcanary\tCanary first\trelease\t%s\n' "2026-10-08T00:00:00Z#0" | cap answers --source "drive" ; echo "rc=$?"
cmp -s "$H/held" "$H/data/backlog.md" && echo "backlog UNCHANGED after refused answers" || echo "BACKLOG MUTATED"
echo "-- guarded answer on context-less hold beta-docs:"
bl=$(cap open beta-docs --identity)
cp "$H/data/backlog.md" "$H/held2"
printf 'beta-docs\tyes\tYes\tdone\t%s\n' "$bl" | cap answers --source "drive"; echo "rc=$?"
cmp -s "$H/held2" "$H/data/backlog.md" && echo "backlog UNCHANGED (context-less hold not guarded-answerable)" || echo "BACKLOG MUTATED"
echo "-- correct guarded answer:"
printf 'alpha-pick\tcanary\tCanary first\trelease\t%s\n' "$id_life" | cap answers --source "drive"; echo "rc=$?"
echo "-- exact replay:"
printf 'alpha-pick\tcanary\tCanary first\trelease\t%s\n' "$id_life" | cap answers --source "drive"; echo "rc=$?"
(cd "$H" && tasks-axi show alpha-pick --full) | grep -E 'state:|held:|Captain answer lifecycle|Resolution mode|Captain question context'

step "board after answer: alpha-pick question gone, task back in queue"
"$ROOT/bin/fm-live-board-snapshot.sh" | jq '[.projects[]|{"label":.label, questions:[.questions[].id], tasks:[.tasks[]|{id,state}]}]'
echo "HOME=$H"
