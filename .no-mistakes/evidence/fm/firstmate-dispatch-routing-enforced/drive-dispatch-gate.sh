#!/usr/bin/env bash
# Live driver for the dispatch receipt gate: runs the real bin/fm-spawn.sh and
# bin/fm-dispatch-resolve.sh from the gate worktree against a disposable lab
# home (bin/fm-lab-home.sh create). Usage: drive-dispatch-gate.sh <worktree>
set -u
WT=$1
cd "$WT" || exit 2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null 2>&1
mkdir -p "$LAB/tmux" "$LAB/proj" "$LAB/work"
git -C "$LAB/proj" init -q -b main
git -C "$LAB/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

fm() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"
}
run() {  # prints the command, its output, and its exit code
  printf '\n$ %s\n' "$*"
  "$@" 2>&1
  printf '[exit %s]\n' "$?"
}
step() { printf '\n==================== %s ====================\n' "$*"; }
brief() {  # <id> <intent>
  mkdir -p "$LAB/data/$1"
  printf '# Task\n## Captain'"'"'s intent\n%s\n\n## Firstmate spec\nOne small change.\n' "$2" > "$LAB/data/$1/brief.md"
}
accounting() {  # <row> -> $LAB/work/accounting.json, one entry per candidate
  mkdir -p "$LAB/state/quota-intake"
  # NOTE: a placeholder quota-intake record name; choose only needs the home to hold the named record.
  [ -f "$LAB/state/quota-intake/quota-lab.json" ] || printf '{}\n' > "$LAB/state/quota-intake/quota-lab.json"
  jq --arg row "$1" '
    (if $row == "default" then .default else .rules[($row | ltrimstr("rule_") | tonumber) - 1].use end)
    | (if type == "array" then . else [.] end)
    | map({harness, model: (.model // ""), effort: (.effort // ""), account: (.account // ""),
           catalog: "lab", plan: "lab", quotaIntakeRecord: "quota-lab.json",
           spendPriority: 1, eligible: true, reason: "ok"})' \
    "$LAB/config/crew-dispatch.json" > "$LAB/work/accounting.json"
  printf 'lab: routed from row %s\n' "$1" > "$LAB/work/rationale.txt"
}
SHIP=(--mode no-mistakes --yolo off)
TABLE='{"rules":[{"when":"current events","use":{"harness":"grok","model":"grok-4","effort":"high"}}],"default":[{"harness":"codex","model":"gpt-5","effort":"medium"},{"harness":"claude","model":"sonnet","effort":"high"}]}'

step "S0 home with NO routing rows: nothing is demanded (gate is silent, launch proceeds to the next gate)"
brief lab-norows-a0 "No table in this home."
run fm bin/fm-spawn.sh lab-norows-a0 "$LAB/proj" --harness claude --model opus --effort high "${SHIP[@]}"

printf '%s\n' "$TABLE" > "$LAB/config/crew-dispatch.json"
step "S1 the table's rows"
run fm bin/fm-dispatch-resolve.sh rows

step "S2 hand-picked ship (personal Claude, Opus, high) with no receipt"
brief lab-ship-a1 "Fix the typo in the README."
run fm bin/fm-spawn.sh lab-ship-a1 "$LAB/proj" --harness claude --model opus --effort high "${SHIP[@]}"
run ls "$LAB/state"

step "S3 hand-picked scout with no receipt"
brief lab-scout-a2 "Find where the typo comes from."
run fm bin/fm-spawn.sh lab-scout-a2 "$LAB/proj" --scout --harness claude --model opus --effort high

step "S4 resolver is off in this home (no key): no receipt, so the hand-pick stays refused"
run fm env -u OPENROUTER_API_KEY -u TYPESAFE_API_KEY bin/fm-dispatch-resolve.sh "$LAB/data/lab-ship-a1/brief.md" --project proj --task lab-ship-a1
run fm bin/fm-spawn.sh lab-ship-a1 "$LAB/proj" --harness claude --model opus --effort high "${SHIP[@]}"

step "S5 choose refuses a profile that is not a candidate of the named row"
accounting default
run fm bin/fm-dispatch-resolve.sh choose "$LAB/data/lab-ship-a1/brief.md" --row default --task lab-ship-a1 \
  --harness claude --model opus --effort high \
  --accounting-file "$LAB/work/accounting.json" --rationale-file "$LAB/work/rationale.txt"

step "S6 choose a real candidate (codex gpt-5 medium), then launch a DIFFERENT effort: refused, receipt not spent"
run fm bin/fm-dispatch-resolve.sh choose "$LAB/data/lab-ship-a1/brief.md" --row default --task lab-ship-a1 \
  --harness codex --model gpt-5 --effort medium \
  --accounting-file "$LAB/work/accounting.json" --rationale-file "$LAB/work/rationale.txt"
run fm bin/fm-spawn.sh lab-ship-a1 "$LAB/proj" --harness codex --model gpt-5 --effort high "${SHIP[@]}"
run fm bin/fm-spawn.sh lab-ship-a1 "$LAB/proj" --harness claude --model opus --effort high "${SHIP[@]}"
run ls "$LAB/state/dispatch-receipt"

step "S7 that receipt does not admit another task's brief"
brief lab-ship-a3 "A different task entirely."
run fm bin/fm-spawn.sh lab-ship-a3 "$LAB/proj" --harness codex --model gpt-5 --effort medium "${SHIP[@]}"

step "S8 environment variables do not switch the gate off for a ship"
run fm env FM_DISPATCH_PARENT_ADMITTED=lab-ship-a3 FM_DISPATCH_RECEIPT_MAX_AGE=99999999 \
  bin/fm-spawn.sh lab-ship-a3 "$LAB/proj" --harness claude --model opus --effort high "${SHIP[@]}"

step "S9 the receipt's own profile passes the dispatch gate (the launch then meets the NEXT gate, quota intake)"
run fm bin/fm-spawn.sh lab-ship-a1 "$LAB/proj" --harness codex --model gpt-5 --effort medium "${SHIP[@]}"
run fm bin/fm-dispatch-resolve.sh gate --task lab-ship-a1 --brief "$LAB/data/lab-ship-a1/brief.md" --harness codex --model gpt-5 --effort medium

step "S10 one receipt, one launch: consume it, then the same launch is refused"
run fm bin/fm-dispatch-resolve.sh gate --task lab-ship-a1 --brief "$LAB/data/lab-ship-a1/brief.md" --harness codex --model gpt-5 --effort medium --consume
run fm bin/fm-dispatch-resolve.sh gate --task lab-ship-a1 --brief "$LAB/data/lab-ship-a1/brief.md" --harness codex --model gpt-5 --effort medium
run ls "$LAB/state/dispatch-receipt"

step "S11 editing the row after the receipt was issued makes the receipt stale"
brief lab-ship-a4 "Stale row task."
run fm bin/fm-dispatch-resolve.sh choose "$LAB/data/lab-ship-a4/brief.md" --row default --task lab-ship-a4 \
  --harness codex --model gpt-5 --effort medium \
  --accounting-file "$LAB/work/accounting.json" --rationale-file "$LAB/work/rationale.txt"
printf '%s\n' "${TABLE/\"effort\":\"medium\"/\"effort\":\"low\"}" > "$LAB/config/crew-dispatch.json"
run fm bin/fm-spawn.sh lab-ship-a4 "$LAB/proj" --harness codex --model gpt-5 --effort medium "${SHIP[@]}"
printf '%s\n' "$TABLE" > "$LAB/config/crew-dispatch.json"

step "S12 editing the brief after the receipt was issued unbinds it"
printf '\nAlso rewrite the whole module.\n' >> "$LAB/data/lab-ship-a4/brief.md"
run fm bin/fm-spawn.sh lab-ship-a4 "$LAB/proj" --harness codex --model gpt-5 --effort medium "${SHIP[@]}"

step "S13 a raw launch command with no captain override"
brief lab-raw-a5 "Raw command task."
run fm bin/fm-spawn.sh lab-raw-a5 "$LAB/proj" "custom-agent --flag" "${SHIP[@]}"

step "S14 captain override: empty words refused; real words are logged and listed; it admits only that task and profile"
: > "$LAB/work/empty.txt"
run fm bin/fm-dispatch-resolve.sh override "$LAB/data/lab-ship-a3/brief.md" --task lab-ship-a3 \
  --harness claude --model opus --effort high --words-file "$LAB/work/empty.txt"
printf 'Launch lab-ship-a3 on personal Claude Opus high, just this once.\n' > "$LAB/work/words.txt"
run fm bin/fm-dispatch-resolve.sh override "$LAB/data/lab-ship-a3/brief.md" --task lab-ship-a3 \
  --harness claude --model opus --effort high --words-file "$LAB/work/words.txt"
run fm bin/fm-dispatch-resolve.sh overrides --recent
run jq -c '{task, profile, words: (.words // .override.words)}' "$LAB/data/dispatch-overrides.jsonl"
run fm bin/fm-spawn.sh lab-ship-a3 "$LAB/proj" --harness claude --model opus --effort xhigh "${SHIP[@]}"
run fm bin/fm-dispatch-resolve.sh gate --task lab-ship-a3 --brief "$LAB/data/lab-ship-a3/brief.md" --harness claude --model opus --effort high
run fm bin/fm-spawn.sh lab-ship-a1 "$LAB/proj" --harness claude --model opus --effort high "${SHIP[@]}"

step "S15 a malformed table fails closed"
printf '{"rules": [\n' > "$LAB/config/crew-dispatch.json"
run fm bin/fm-spawn.sh lab-ship-a3 "$LAB/proj" --harness claude --model opus --effort high "${SHIP[@]}"

step "teardown"
run find "$LAB/state" -maxdepth 1 -name '*.meta'
printf 'no worker meta recorded and no pane created in any step above; lab home removed on exit\n'
