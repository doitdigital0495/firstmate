#!/usr/bin/env bash
# Behavior test for tools/quota-weekly-report.py: build a small fake Claude store
# and firstmate home, run the report through its command line, and check the
# metrics it derives. Also proves it never prints message text.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

REPORT="$ROOT/tools/quota-weekly-report.py"
TMP_ROOT=$(fm_test_tmproot quota-weekly-report)
STORE="$TMP_ROOT/claude-a"
HOME_DIR="$TMP_ROOT/fmhome"
SM_CWD="$TMP_ROOT/secondmate-home"
WORKER_CWD="$TMP_ROOT/.treehouse/proj-abc123/1/proj"
mkdir -p "$STORE/projects/p" "$HOME_DIR/state" "$SM_CWD" "$WORKER_CWD"
: > "$SM_CWD/.fm-secondmate-home"
END='2026-11-12T00:00:00+00:00'
END_EPOCH=$(date -u -d "$END" +%s 2>/dev/null) || { echo "skip: GNU date required for the fixture"; exit 0; }

# turn <session> <msg-id> <epoch> <model> <cwd> <branch> <input> <cache-read> <output> [bash command]
turn() {
  local sid=$1 mid=$2 ts=$3 model=$4 cwd=$5 branch=$6 inp=$7 cr=$8 out=$9 cmd=${10:-}
  jq -cn --arg sid "$sid" --arg mid "$mid" --arg ts "$(date -u -d "@$ts" +%Y-%m-%dT%H:%M:%SZ)" \
    --arg model "$model" --arg cwd "$cwd" --arg br "$branch" --arg cmd "$cmd" \
    --argjson inp "$inp" --argjson cr "$cr" --argjson out "$out" '
    {type:"assistant", sessionId:$sid, requestId:("req-"+$mid), timestamp:$ts, cwd:$cwd, gitBranch:$br,
     message:{id:$mid, model:$model,
       usage:{input_tokens:$inp, output_tokens:$out, cache_read_input_tokens:$cr, cache_creation_input_tokens:0},
       content:(if $cmd == "" then [{type:"text", text:"SECRET-MESSAGE-TEXT"}]
                else [{type:"tool_use", name:"Bash", input:{command:$cmd}}] end)}}'
}

NOW=$((END_EPOCH - 86400))       # inside the current window
BEFORE=$((END_EPOCH - 9 * 86400)) # inside the prior window
{
  # Worker session: a bare sleep, a sanctioned loop, and two fm/ branches.
  turn w1 m1 "$NOW" claude-opus-5-5 "$WORKER_CWD" fm/task-a 1000000 0 1000 'sleep 60 && gh pr checks 3'
  turn w1 m2 "$((NOW + 1))" claude-opus-5-5 "$WORKER_CWD" fm/task-a 1000000 0 1000 'until true; do sleep 30; done'
  turn w1 m3 "$((NOW + 2))" claude-opus-5-5 "$WORKER_CWD" fm/task-b 1000000 0 1000 'ls'
  turn w1 m3 "$((NOW + 2))" claude-opus-5-5 "$WORKER_CWD" fm/task-b 1000000 0 1000 'ls'
  # Secondmate: one tiny turn at large context.
  turn s1 m4 "$NOW" claude-sonnet-5-5 "$SM_CWD" '' 10 200000 50
  # Unpriced model and a prior-window turn.
  turn x1 m5 "$NOW" claude-mystery-9-9 "$WORKER_CWD" fm/task-c 1000 0 10
  turn w2 m6 "$BEFORE" claude-opus-5-5 "$WORKER_CWD" fm/task-d 1000000 0 1000 'sleep 90'
} > "$STORE/projects/p/session.jsonl"
printf '%s flag\n%s flag\n' "$((NOW + 5))" "$((NOW + 6))" > "$HOME_DIR/state/task-a.wait-flags"

OUT="$TMP_ROOT/report.md"
python3 -I "$REPORT" --end "$END" --days 7 --home "$HOME_DIR" --store "$STORE" --jobs 1 --out "$OUT" \
  || fail "the report run failed"
[ -s "$OUT" ] || fail "no report written"

grep -q 'Transcripts read: 1' "$OUT" || fail "expected one transcript read: $(head -5 "$OUT")"
# w1: 3 deduplicated turns of opus 1M input at $4/MTok = $4 each, plus 1000 out at $20/MTok = $0.02
# shellcheck disable=SC2016 # The dollar sign is a literal pattern byte, not an expansion.
grep -Eq '^\| estimated spend \| \$12\.0[0-9] \|' "$OUT" || fail "unexpected current-window spend: $(grep 'estimated spend' "$OUT")"
grep -Eq '^\| unpriced turns .* \| 1 \|' "$OUT" || fail "the unknown model must be counted as unpriced: $(grep unpriced "$OUT")"
grep -Eq '^\| sleep-then-check turns \| 1 \|' "$OUT" || fail "expected one sleep-then-check turn (the loop is sanctioned): $(grep 'sleep-then' "$OUT")"
grep -Eq '^\| worker poll loops \| 2 \|' "$OUT" || fail "expected two worker poll-loop turns: $(grep 'poll loops' "$OUT")"
grep -Eq '^\| secondmate tiny turns \| 1 \|' "$OUT" || fail "expected one secondmate tiny turn: $(grep 'tiny' "$OUT")"
grep -Eq '^\| multi-task sessions \| 1 \|' "$OUT" || fail "expected one multi-task session: $(grep multi "$OUT")"
grep -Eq '^\| guard sleep-then-check flags \(tasks\) \| 2 \(1\) \|' "$OUT" || fail "expected two logged guard flags on one task: $(grep guard "$OUT")"
grep -Eq '^\| secondmate \|' "$OUT" || fail "the by-role table must list the secondmate"
! grep -q 'SECRET-MESSAGE-TEXT' "$OUT" || fail "the report must never carry message text"

# No store at all is a valid empty report, not an error.
python3 -I "$REPORT" --end "$END" --home "$HOME_DIR" --store "$TMP_ROOT/missing" --jobs 1 > "$TMP_ROOT/empty.md" \
  || fail "an empty store must not fail the run"
grep -q 'Transcripts read: 0' "$TMP_ROOT/empty.md" || fail "empty run must report zero transcripts"

pass "tools/quota-weekly-report.py derives spend, poll-loop, sleep-then-check, tiny-turn, multi-task and guard-flag metrics without message text"
echo "all quota-weekly-report tests passed"
