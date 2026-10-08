#!/usr/bin/env bash
# tests/fm-quota-intake.test.sh - the mandatory pre-spawn usage-limit read.
#
# bin/fm-quota-intake.sh is the enforcement half of the captain's routing
# rule "read every window, every reset time, and every plan size before
# choosing a worker": record captures quota-axi --full for the default store
# and every enabled account store into one private timestamped record and
# prints the full table, and gate refuses any launch unless that record is
# fresh, covers the chosen account/store/provider, and carries the whole
# table content for that provider: plan size, the 5h and 7d windows (plus
# every model-specific one) each as a USED percent with its reset time, and a
# non-empty Notes entry. These tests pin both halves hermetically (a fake
# quota-axi on PATH, no real credential store):
#   1. record shape: every window with its used percent and reset time,
#      spendPriority, runway, the plan size from every source, and the Notes
#      column joined from accounts.json notes and crew-dispatch.json
#      model_notes.
#   2. the record is private (0600) and retention keeps the newest 50.
#   3. a failed store read is recorded as failed and still fails the run.
#   4. gate refusals: no record, stale record, uncovered account, uncovered
#      store, an exhausted account (window and reset time named), a 100%-used
#      (0% remaining) window, a model-scoped window without evidence, an
#      unmappable harness/model provider family, a missing 7d window (a 5h
#      window is required only when the provider publishes one), and a
#      provider with no Notes entry.
#   5. gate passes print the chosen candidate's full window table (zai).
#   6. the test bypass is explicit and prints that it bypassed.
#   7. the cached-read exception: a fresh statusline cache converts USED
#      percentages to remaining and is marked cached; a stale one fails
#      closed.
#   8. the real bin/fm-spawn.sh refuses without a record and passes on one
#      seeded by the real recorder, and the real bin/fm-control.sh relaunch
#      gate refuses BEFORE the running agent is stopped and passes on a real
#      record.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

INTAKE="$ROOT/bin/fm-quota-intake.sh"
CONTROL="$ROOT/bin/fm-control.sh"

# fm_test_tmproot's own cleanup trap fires when its command substitution exits,
# so recreate the root before resolving it and clean it up from this file's trap.
TMP_ROOT=$(fm_test_tmproot fm-quota-intake)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK_TMPS=()

quota_intake_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  rm -rf "$TMP_ROOT"
  fm_test_cleanup
}
trap quota_intake_cleanup EXIT

fm_git_identity fmtest fmtest@example.invalid

# --- snapshots ---------------------------------------------------------------

# The healthy baseline: claude 5h+7d, codex 5h+weekly, zai 5h+weekly, every
# window with a percent remaining and a reset time. Plan labels come from
# quota-axi (claude=max, codex=prolite); zai carries none so its plan falls
# through to unknown.
cat > "$TMP_ROOT/snap-base.json" <<'EOF'
{"schemaVersion":5,"providers":[
 {"provider":"claude","label":"Max","plan":"max","state":{"status":"fresh"},
  "windows":[
   {"id":"five_hour","label":"5h","kind":"five_hour","percentUsed":10,"percentRemaining":90,"resetsAt":"2026-09-29T15:19:59Z"},
   {"id":"seven_day","label":"7d","kind":"seven_day","percentUsed":7,"percentRemaining":93,"resetsAt":"2026-10-05T17:59:59Z"}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
   {"scope":"all_models","status":"known","effectivePercentRemaining":90,"boundedBy":["five_hour","seven_day"],"limitingWindowIds":["five_hour"],"runway":{"status":"through_reset","projectionConfidence":"established"},"selection":{"status":"known","spendPriority":0.4}}]}},
 {"provider":"codex","label":"ProLite","plan":"prolite","state":{"status":"fresh"},
  "windows":[
   {"id":"five_hour","label":"5h","kind":"five_hour","percentUsed":3,"percentRemaining":97,"resetsAt":"2026-09-29T19:00:00Z"},
   {"id":"weekly","label":"week","kind":"weekly","percentUsed":8,"percentRemaining":92,"resetsAt":"2026-10-04T05:00:39.000Z","windowSeconds":604800}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
   {"scope":"all_models","status":"known","effectivePercentRemaining":92,"boundedBy":["five_hour","weekly"],"limitingWindowIds":["weekly"],"runway":{"status":"through_reset","projectionConfidence":"established"},"selection":{"status":"known","spendPriority":1.1213}}]}},
 {"provider":"zai","label":"GLM","state":{"status":"fresh"},
  "windows":[
   {"id":"five_hour","label":"5h","kind":"five_hour","percentUsed":88,"percentRemaining":12,"resetsAt":"2026-09-29T18:00:00Z"},
   {"id":"weekly","label":"week","kind":"weekly","percentUsed":29,"percentRemaining":71,"resetsAt":"2026-10-04T05:00:39.000Z"}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
   {"scope":"all_models","status":"known","effectivePercentRemaining":12,"boundedBy":["five_hour","weekly"],"limitingWindowIds":["five_hour"],"runway":{"status":"through_reset","projectionConfidence":"established"},"selection":{"status":"known","spendPriority":2.7}}]}}]}
EOF

# Claude exhausted now: the all_models runway is exhausted_now, limited by the
# 5h window, and that window sits at 0% with a named reset time.
cat > "$TMP_ROOT/snap-exhausted.json" <<'EOF'
{"schemaVersion":5,"providers":[
 {"provider":"claude","label":"Max","plan":"max","state":{"status":"fresh"},
  "windows":[
   {"id":"five_hour","label":"5h","kind":"five_hour","percentUsed":100,"percentRemaining":0,"resetsAt":"2026-09-29T16:00:00Z"},
   {"id":"seven_day","label":"7d","kind":"seven_day","percentUsed":7,"percentRemaining":93,"resetsAt":"2026-10-05T17:59:59Z"}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
   {"scope":"all_models","status":"known","effectivePercentRemaining":0,"boundedBy":["five_hour","seven_day"],"limitingWindowIds":["five_hour"],"runway":{"status":"exhausted_now","projectionConfidence":"established"},"selection":{"status":"known","spendPriority":-3.5}}]}}]}
EOF

# A model-scoped bound whose window has no evidence: the model:opus-special
# row is bounded by opus_weekly, but no such window exists in windows[].
cat > "$TMP_ROOT/snap-modelscope.json" <<'EOF'
{"schemaVersion":5,"providers":[
 {"provider":"claude","label":"Max","plan":"max","state":{"status":"fresh"},
  "windows":[
   {"id":"five_hour","label":"5h","kind":"five_hour","percentUsed":10,"percentRemaining":90,"resetsAt":"2026-09-29T15:19:59Z"},
   {"id":"seven_day","label":"7d","kind":"seven_day","percentUsed":7,"percentRemaining":93,"resetsAt":"2026-10-05T17:59:59Z"}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
   {"scope":"all_models","status":"known","effectivePercentRemaining":90,"boundedBy":["five_hour","seven_day"],"limitingWindowIds":["five_hour"],"runway":{"status":"through_reset","projectionConfidence":"established"},"selection":{"status":"known","spendPriority":0.4}},
   {"scope":"model:opus-special","status":"known","effectivePercentRemaining":40,"boundedBy":["opus_weekly"],"limitingWindowIds":["opus_weekly"],"runway":{"status":"through_reset","projectionConfidence":"established"},"selection":{"status":"known","spendPriority":0.9}}]}}]}
EOF

# Zai with a fully spent weekly window: runway is fine but the window itself
# is at 0% remaining with a named reset.
cat > "$TMP_ROOT/snap-zeropct.json" <<'EOF'
{"schemaVersion":5,"providers":[
 {"provider":"claude","label":"Max","plan":"max","state":{"status":"fresh"},
  "windows":[
   {"id":"five_hour","label":"5h","kind":"five_hour","percentUsed":10,"percentRemaining":90,"resetsAt":"2026-09-29T15:19:59Z"},
   {"id":"seven_day","label":"7d","kind":"seven_day","percentUsed":7,"percentRemaining":93,"resetsAt":"2026-10-05T17:59:59Z"}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
   {"scope":"all_models","status":"known","effectivePercentRemaining":90,"boundedBy":["five_hour","seven_day"],"limitingWindowIds":["five_hour"],"runway":{"status":"through_reset","projectionConfidence":"established"},"selection":{"status":"known","spendPriority":0.4}}]}},
 {"provider":"zai","label":"GLM","state":{"status":"fresh"},
  "windows":[
   {"id":"five_hour","label":"5h","kind":"five_hour","percentUsed":50,"percentRemaining":50,"resetsAt":"2026-09-29T18:00:00Z"},
   {"id":"weekly","label":"week","kind":"weekly","percentUsed":100,"percentRemaining":0,"resetsAt":"2026-10-04T05:00:39.000Z"}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
   {"scope":"all_models","status":"known","effectivePercentRemaining":0,"boundedBy":["five_hour","weekly"],"limitingWindowIds":["weekly"],"runway":{"status":"through_reset","projectionConfidence":"established"},"selection":{"status":"known","spendPriority":0.2}}]}}]}
EOF

# The same spent zai weekly window, but recorded with only its used percent
# (no percentRemaining): the gate must still see it as 100% used.
jq '(.providers[] | select(.provider == "zai") | .windows[] | select(.id == "weekly")) |= del(.percentRemaining)' \
  "$TMP_ROOT/snap-zeropct.json" > "$TMP_ROOT/snap-usedonly.json"

# No claude provider at all: the live personal Claude read is missing, which
# is the cached-read exception's trigger.
cat > "$TMP_ROOT/snap-codexonly.json" <<'EOF'
{"schemaVersion":5,"providers":[
 {"provider":"codex","label":"ProLite","plan":"prolite","state":{"status":"fresh"},
  "windows":[
   {"id":"five_hour","label":"5h","kind":"five_hour","percentUsed":3,"percentRemaining":97,"resetsAt":"2026-09-29T19:00:00Z"},
   {"id":"weekly","label":"week","kind":"weekly","percentUsed":8,"percentRemaining":92,"resetsAt":"2026-10-04T05:00:39.000Z","windowSeconds":604800}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
   {"scope":"all_models","status":"known","effectivePercentRemaining":92,"boundedBy":["five_hour","weekly"],"limitingWindowIds":["weekly"],"runway":{"status":"through_reset","projectionConfidence":"established"},"selection":{"status":"known","spendPriority":1.1213}}]}}]}
EOF

# Codex without its five-hour window: an otherwise healthy baseline whose
# codex provider publishes no 5h window, which the gate must accept.
cat > "$TMP_ROOT/snap-nofive.json" <<'EOF'
{"schemaVersion":5,"providers":[
 {"provider":"claude","label":"Max","plan":"max","state":{"status":"fresh"},
  "windows":[
   {"id":"five_hour","label":"5h","kind":"five_hour","percentUsed":10,"percentRemaining":90,"resetsAt":"2026-09-29T15:19:59Z"},
   {"id":"seven_day","label":"7d","kind":"seven_day","percentUsed":7,"percentRemaining":93,"resetsAt":"2026-10-05T17:59:59Z"}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
   {"scope":"all_models","status":"known","effectivePercentRemaining":90,"boundedBy":["five_hour","seven_day"],"limitingWindowIds":["five_hour"],"runway":{"status":"through_reset","projectionConfidence":"established"},"selection":{"status":"known","spendPriority":0.4}}]}},
 {"provider":"codex","label":"ProLite","plan":"prolite","state":{"status":"fresh"},
  "windows":[
   {"id":"weekly","label":"week","kind":"weekly","percentUsed":8,"percentRemaining":92,"resetsAt":"2026-10-04T05:00:39.000Z","windowSeconds":604800}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
   {"scope":"all_models","status":"known","effectivePercentRemaining":92,"boundedBy":["weekly"],"limitingWindowIds":["weekly"],"runway":{"status":"through_reset","projectionConfidence":"established"},"selection":{"status":"known","spendPriority":1.1213}}]}}]}
EOF

# The live Codex ProLite shape: quota-axi reports only the weekly window,
# with its used percent, reset time, and plan label (next to a healthy claude
# read, so the cached-read exception stays out of the way).
cat > "$TMP_ROOT/snap-prolite.json" <<'EOF'
{"schemaVersion":5,"providers":[
 {"provider":"claude","label":"Max","plan":"max","state":{"status":"fresh"},
  "windows":[
   {"id":"five_hour","label":"5h","kind":"five_hour","percentUsed":10,"percentRemaining":90,"resetsAt":"2026-09-29T15:19:59Z"},
   {"id":"seven_day","label":"7d","kind":"seven_day","percentUsed":7,"percentRemaining":93,"resetsAt":"2026-10-05T17:59:59Z"}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
   {"scope":"all_models","status":"known","effectivePercentRemaining":90,"boundedBy":["five_hour","seven_day"],"limitingWindowIds":["five_hour"],"runway":{"status":"through_reset","projectionConfidence":"established"},"selection":{"status":"known","spendPriority":0.4}}]}},
 {"provider":"codex","label":"ProLite","plan":"prolite","state":{"status":"fresh"},
  "windows":[
   {"id":"weekly","label":"Weekly","kind":"weekly","percentUsed":44,"percentRemaining":56,"resetsAt":"2026-10-04T05:00:38.000Z","windowSeconds":604800}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
   {"scope":"all_models","status":"known","effectivePercentRemaining":56,"boundedBy":["weekly"],"limitingWindowIds":["weekly"],"runway":{"status":"through_reset","projectionConfidence":"established"},"selection":{"status":"known","spendPriority":0.2341}}]}}]}
EOF

# Codex publishing no windows at all: nothing to launch against.
jq '(.providers[] | select(.provider == "codex")) |= (.windows = [] | .quotaSemantics.effectiveAvailability[0].boundedBy = [] | .quotaSemantics.effectiveAvailability[0].limitingWindowIds = [])' \
  "$TMP_ROOT/snap-prolite.json" > "$TMP_ROOT/snap-nowindows.json"

# Claude without its seven-day window: an otherwise healthy baseline whose
# table lacks the claude 7d row instead.
cat > "$TMP_ROOT/snap-noseven.json" <<'EOF'
{"schemaVersion":5,"providers":[
 {"provider":"claude","label":"Max","plan":"max","state":{"status":"fresh"},
  "windows":[
   {"id":"five_hour","label":"5h","kind":"five_hour","percentUsed":10,"percentRemaining":90,"resetsAt":"2026-09-29T15:19:59Z"}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
   {"scope":"all_models","status":"known","effectivePercentRemaining":90,"boundedBy":["five_hour"],"limitingWindowIds":["five_hour"],"runway":{"status":"through_reset","projectionConfidence":"established"},"selection":{"status":"known","spendPriority":0.4}}]}},
 {"provider":"codex","label":"ProLite","plan":"prolite","state":{"status":"fresh"},
  "windows":[
   {"id":"five_hour","label":"5h","kind":"five_hour","percentUsed":3,"percentRemaining":97,"resetsAt":"2026-09-29T19:00:00Z"},
   {"id":"weekly","label":"week","kind":"weekly","percentUsed":8,"percentRemaining":92,"resetsAt":"2026-10-04T05:00:39.000Z","windowSeconds":604800}],
  "quotaSemantics":{"status":"known","effectiveAvailability":[
   {"scope":"all_models","status":"known","effectivePercentRemaining":92,"boundedBy":["five_hour","weekly"],"limitingWindowIds":["weekly"],"runway":{"status":"through_reset","projectionConfidence":"established"},"selection":{"status":"known","spendPriority":1.1213}}]}}]}
EOF

# --- fixture builders --------------------------------------------------------

# make_fake_quota_axi <dir> <snapshot> -> echoes a fakebin with a quota-axi
# that always prints <snapshot> (the recorder pins the store env; the fake
# deliberately ignores it so one snapshot serves every store).
make_fake_quota_axi() {
  local fakebin="$1/fakebin" snap=$2
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\ncat -- %q\n' "$snap" > "$fakebin/quota-axi"
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
}

# make_home <name> -> echoes a fixture home with state/, config/, and a
# throwaway user-home whose default store paths the recorder and the gate see
# identically (every store env pinned empty).
make_home() {
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/config" "$home/user-home"
  # The default Notes source every fixture home carries: crew-dispatch's
  # model_notes keyed by provider. Tests that must prove the no-notes
  # refusal remove or replace this file.
  printf '%s\n' '{"model_notes":{"claude":"personal max line","codex":"codex pool line","zai":"glm coding line"}}' \
    > "$home/config/crew-dispatch.json"
  printf '%s\n' "$home"
}

# newest_record <home> -> the newest intake record path.
newest_record() {
  local f
  f=$(find "$1/state/quota-intake" -maxdepth 1 -name 'quota-*.json' 2>/dev/null | LC_ALL=C sort | tail -n 1)
  [ -n "$f" ] || return 1
  printf '%s\n' "$f"
}

# run_record <home> <fakebin> [VAR=VAL...] -> runs the real recorder with the
# store env pinned; echoes combined output, exit code in $?.
run_record() {
  local home=$1 fakebin=$2; shift 2
  env HOME="$home/user-home" CLAUDE_CONFIG_DIR= PI_CODING_AGENT_DIR= CODEX_HOME= \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" PATH="$fakebin:$PATH" \
    "$@" "$INTAKE" record 2>&1
}

# run_gate <home> [gate args...] -> runs the real gate with the test bypass
# STRIPPED (lib.sh exports it suite-wide; every refusal here must be real)
# and the store env pinned exactly like run_record.
run_gate() {
  local home=$1; shift
  env -u FM_QUOTA_INTAKE_TEST_BYPASS \
    HOME="$home/user-home" CLAUDE_CONFIG_DIR= PI_CODING_AGENT_DIR= CODEX_HOME= \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$INTAKE" gate "$@" 2>&1
}

# seed_record <home> <snapshot> [accounts-json-body] -> runs the real recorder
# against a fresh fake quota-axi, failing the test if the record run itself
# does not succeed.
seed_record() {
  local home=$1 snap=$2 accounts=${3:-} fakebin out rc
  [ -z "$accounts" ] || printf '%s\n' "$accounts" > "$home/config/accounts.json"
  fakebin=$(make_fake_quota_axi "$home/quota-fake" "$snap")
  out=$(run_record "$home" "$fakebin"); rc=$?
  [ "$rc" -eq 0 ] || fail "seeding the intake record failed (rc=$rc): $out"
}

file_mode() {  # <path> -> numeric mode, GNU then BSD stat
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

# --- 1. record shape: every window, reset, plan source ----------------------

test_record_shape() {
  local home geris out rec
  home=$(make_home shape)
  geris=$home/geris-store
  mkdir -p "$geris/claude" "$geris/pi" "$geris/codex"
  # The live model_notes shape: bare provider keys next to harness-scoped
  # model keys, which must never become providers of their own.
  printf '%s\n' '{"model_notes":{"claude":"personal max line","codex":"codex pool line","zai":"glm coding line","claude/opus":"opus line","pi/openai-codex/gpt-6-luna":"luna line","pi/zai/glm-5.3":"glm 5.3 line"}}' \
    > "$home/config/crew-dispatch.json"
  seed_record "$home" "$TMP_ROOT/snap-base.json" \
    '{"crossAccount":{"enabled":true},"plans":{"codex":"pro"},"accounts":{"geris":{"claude":"'"$geris"'/claude","pi":"'"$geris"'/pi","codex":"'"$geris"'/codex","plans":{"claude":"geris-max"}}}}'
  rec=$(newest_record "$home") || fail "no intake record was written"

  # Every window of every provider of both accounts, with its used percent
  # and reset time, plus spendPriority, runway, the plan size from each of its
  # three sources, and the Notes column from both notes sources.
  jq -e '
    .schemaVersion == 2 and
    .accounts[0].account == "default" and .accounts[1].account == "geris" and
    ([.accounts[] | .readStatus] | all(. == "ok")) and
    ([.accounts[0].providers[] | select(.provider == "claude") | .windows[] |
      (.percentRemaining | type) == "number" and (.resetsAt | type) == "string"] | length) == 2 and
    ([.accounts[0].providers[] | select(.provider == "claude") | .windows[] | .percentUsed] == [10, 7]) and
    ([.accounts[0].providers[] | select(.provider == "claude") | .scopes[] | .effectivePercentUsed] == [10]) and
    ([.accounts[0].providers[] | select(.provider == "codex") | .windows[] | .percentUsed] == [3, 8]) and
    ([.accounts[0].providers[] | select(.provider == "zai") | .windows[] | .id] | sort) == ["five_hour","weekly"] and
    ([.accounts[0].providers[] | select(.provider == "codex") | .plan] == ["pro"]) and
    ([.accounts[0].providers[] | select(.provider == "codex") | .planSource] == ["accounts.json"]) and
    ([.accounts[0].providers[] | select(.provider == "claude") | .plan] == ["max"]) and
    ([.accounts[0].providers[] | select(.provider == "claude") | .planSource] == ["quota-axi"]) and
    ([.accounts[0].providers[] | select(.provider == "zai") | .plan] == ["unknown"]) and
    ([.accounts[0].providers[] | select(.provider == "zai") | .planSource] == ["unknown"]) and
    ([.accounts[0].providers[] | select(.provider == "claude") | .spendPriority] == [0.4]) and
    ([.accounts[0].providers[] | select(.provider == "claude") | .runway] == ["through_reset"]) and
    ([.accounts[0].providers[] | select(.provider == "claude") | .notes] == ["personal max line"]) and
    ([.accounts[0].providers[] | select(.provider == "codex") | .notes] == ["codex pool line"]) and
    ([.accounts[0].providers[] | select(.provider == "claude") | .modelNotes] == [{"claude/opus": "opus line"}]) and
    ([.accounts[0].providers[] | select(.provider == "codex") | .modelNotes] == [{"pi/openai-codex/gpt-6-luna": "luna line"}]) and
    ([.accounts[0].providers[] | select(.provider == "zai") | .modelNotes] == [{"pi/zai/glm-5.3": "glm 5.3 line"}]) and
    ([.accounts[1].providers[] | select(.provider == "claude") | .plan] == ["geris-max"]) and
    ([.accounts[1].providers[] | select(.provider == "claude") | .planSource] == ["accounts.json:geris"])
  ' "$rec" >/dev/null || fail "the record does not carry every window, used percent, reset, plan source, and notes"

  # The full table lands on stdout so it reaches the transcript, with every
  # window as a USED percent (remaining is never shown alone).
  run_record "$home" "$(make_fake_quota_axi "$home/quota-fake2" "$TMP_ROOT/snap-base.json")" > "$TMP_ROOT/shape-table.txt" || true
  assert_grep "account=default status=ok" "$TMP_ROOT/shape-table.txt" "the table must list the default account"
  assert_grep "account=geris status=ok" "$TMP_ROOT/shape-table.txt" "the table must list every enabled account"
  assert_grep "provider=claude status=ok plan=max (quota-axi) quota-axi=max spendPriority=0.4 runway=through_reset notes=personal max line" \
    "$TMP_ROOT/shape-table.txt" "the table must show the claude provider row with its notes"
  assert_grep "model=claude/opus notes=opus line" \
    "$TMP_ROOT/shape-table.txt" "the table must join the harness-scoped model note under its provider"
  assert_grep "window=five_hour used=10% resets=2026-09-29T15:19:59Z source=live" \
    "$TMP_ROOT/shape-table.txt" "the table must show the 5h window with used and reset"
  assert_grep "window=seven_day used=7% resets=2026-10-05T17:59:59Z source=live" \
    "$TMP_ROOT/shape-table.txt" "the table must show the 7d window"
  assert_grep "window=weekly used=8%" "$TMP_ROOT/shape-table.txt" "the table must show the codex weekly window"
  assert_grep "provider=codex status=ok plan=pro (accounts.json)" \
    "$TMP_ROOT/shape-table.txt" "the table must show the declared plan size and its source"
  ! grep -q 'remaining=' "$TMP_ROOT/shape-table.txt" \
    || fail "the table must never show remaining alone; used percents only"
  pass "record: every window with its used percent and reset, spendPriority, runway, plan size, and notes from every source, printed in full"
}

# --- 2. the record is private and retention keeps 50 ------------------------

test_record_private_and_retention() {
  local home fakebin i first last count
  home=$(make_home private)
  fakebin=$(make_fake_quota_axi "$home/quota-fake" "$TMP_ROOT/snap-base.json")
  run_record "$home" "$fakebin" >/dev/null || fail "the first record run failed"
  first=$(newest_record "$home")
  [ "$(file_mode "$first")" = 600 ] \
    || fail "the intake record must be private (0600), got $(file_mode "$first")"

  # Default retention is 50: after 52 runs the two oldest are pruned and the
  # newest survives. The first-written name is always among the two
  # lexically smallest (the epoch prefix dominates; a same-second tie can
  # only be with the second run, and both are pruned together).
  for i in $(seq 2 52); do
    run_record "$home" "$fakebin" >/dev/null || fail "record run $i failed"
  done
  last=$(newest_record "$home")
  count=$(find "$home/state/quota-intake" -name 'quota-*.json' | wc -l)
  [ "$count" -eq 50 ] || fail "retention must keep exactly 50 records, kept $count"
  [ ! -e "$first" ] || fail "the oldest record must be pruned"
  [ -e "$last" ] || fail "the newest record must survive retention"
  pass "record: private (0600) timestamped records with retention of the newest 50"
}

# --- 3. a failed store read is recorded and fails the run -------------------

test_record_failed_store() {
  local home fakebin out rc rec
  home=$(make_home failed)
  fakebin=$(make_fake_quota_axi "$home/quota-fake" "$TMP_ROOT/snap-base.json")
  # A quota-axi that cannot read this store at all.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/quota-axi"
  chmod +x "$fakebin/quota-axi"
  out=$(run_record "$home" "$fakebin"); rc=$?
  [ "$rc" -ne 0 ] || fail "a failed store read must exit nonzero"
  rec=$(newest_record "$home") || fail "a failed read must still write a record"
  jq -e '.accounts[0].readStatus == "failed" and (.accounts[0].providers | length) == 0' \
    "$rec" >/dev/null || fail "the failed entry must be recorded as readStatus=failed"
  assert_contains "$out" "read failed:" "the table must name the failed read"
  pass "record: a failed store read is recorded as failed, printed, and exits nonzero"
}

# --- 4-6. gate refusals and passes -------------------------------------------

test_gate_refusals() {
  local home out rc
  home=$(make_home gates)
  seed_record "$home" "$TMP_ROOT/snap-base.json"

  # No record at all.
  out=$(run_gate "$home" --harness codex); rc=$?
  expect_code 0 "$rc" "gate: a freshly seeded record must admit codex (sanity)"
  assert_contains "$out" "provider=codex" "gate: the sanity pass must name the provider"
  rm -rf -- "$home/state/quota-intake"
  out=$(run_gate "$home" --harness codex); rc=$?
  expect_code 3 "$rc" "gate: no record must refuse"
  assert_contains "$out" "no intake record exists" "gate: the no-record refusal must say so"
  seed_record "$home" "$TMP_ROOT/snap-base.json"

  # Stale record: anything older than the freshness window refuses.
  out=$(FM_QUOTA_INTAKE_MAX_AGE=-1 run_gate "$home" --harness codex); rc=$?
  expect_code 3 "$rc" "gate: a stale record must refuse"
  assert_contains "$out" "run bin/fm-quota-intake.sh now" "gate: the stale refusal must demand a fresh read"

  # Uncovered account.
  out=$(run_gate "$home" --harness codex --account geris); rc=$?
  expect_code 3 "$rc" "gate: an account the record does not cover must refuse"
  assert_contains "$out" "does not cover account 'geris'" "gate: the uncovered-account refusal must name the account"

  # Uncovered store.
  out=$(run_gate "$home" --harness codex --codex-store /elsewhere/codex); rc=$?
  expect_code 3 "$rc" "gate: a store the record does not cover must refuse"
  assert_contains "$out" "does not cover the chosen store /elsewhere/codex" \
    "gate: the uncovered-store refusal must name the store"

  # Unmappable provider family.
  out=$(run_gate "$home" --harness omp --model unmapped/prefix); rc=$?
  expect_code 3 "$rc" "gate: an unmappable harness/model must refuse"
  assert_contains "$out" "no quota provider family can be established" \
    "gate: the provider-mapping refusal must refuse to guess"

  # One record, one launch: a preview marks nothing, the consuming launch
  # spends the record, and every later launch or preview on it refuses.
  out=$(run_gate "$home" --harness codex); rc=$?
  expect_code 0 "$rc" "gate: a preview must not spend the record"
  out=$(run_gate "$home" --harness codex --consume); rc=$?
  expect_code 0 "$rc" "gate: the first consuming launch must pass"
  out=$(run_gate "$home" --harness claude --consume); rc=$?
  expect_code 3 "$rc" "gate: a second launch on a spent record must refuse"
  assert_contains "$out" "was already spent on a launch" "gate: the spent refusal must say so"
  out=$(run_gate "$home" --harness codex); rc=$?
  expect_code 3 "$rc" "gate: a preview on a spent record must refuse too"
  seed_record "$home" "$TMP_ROOT/snap-base.json"
  out=$(run_gate "$home" --harness claude --consume); rc=$?
  expect_code 0 "$rc" "gate: a new intake must admit the next launch"

  pass "gate: refuses on no record, stale record, uncovered account or store, an unmappable provider family, and a record already spent on a launch"
}

test_gate_exhausted_account() {
  local home geris out rc
  home=$(make_home exhausted)
  geris=$home/geris-store
  mkdir -p "$geris/claude" "$geris/pi" "$geris/codex"
  seed_record "$home" "$TMP_ROOT/snap-exhausted.json" \
    '{"crossAccount":{"enabled":true},"accounts":{"geris":{"claude":"'"$geris"'/claude","pi":"'"$geris"'/pi","codex":"'"$geris"'/codex"}}}'
  out=$(run_gate "$home" --harness claude --account geris --claude-store "$geris/claude"); rc=$?
  expect_code 3 "$rc" "gate: an exhausted account must refuse"
  assert_contains "$out" "exhausted_now" "gate: the refusal must name the exhausted runway"
  assert_contains "$out" "(window five_hour)" "gate: the refusal must name the limiting window"
  assert_contains "$out" "resetting at 2026-09-29T16:00:00Z" "gate: the refusal must name the reset time"
  pass "gate: an exhausted account is refused naming the window and its reset time"
}

test_gate_zero_percent_window() {
  local home out rc
  home=$(make_home zeropct)
  seed_record "$home" "$TMP_ROOT/snap-zeropct.json"
  out=$(run_gate "$home" --harness pi --model zai/glm-4.7); rc=$?
  expect_code 3 "$rc" "gate: a 0% window must refuse"
  assert_contains "$out" "window weekly is at 100% used (0% remaining) and resets at 2026-10-04T05:00:39.000Z" \
    "gate: the refusal must name the spent window and its reset time"
  home=$(make_home usedonly)
  seed_record "$home" "$TMP_ROOT/snap-usedonly.json"
  out=$(run_gate "$home" --harness pi --model zai/glm-4.7); rc=$?
  expect_code 3 "$rc" "gate: a window with only percentUsed 100 must refuse"
  assert_contains "$out" "window weekly is at 100% used" \
    "gate: the used-only refusal must name the spent window"
  pass "gate: a 0% window is refused naming the window and its reset time"
}

test_gate_model_scoped_window() {
  local home out rc
  home=$(make_home modelscope)
  seed_record "$home" "$TMP_ROOT/snap-modelscope.json"
  out=$(run_gate "$home" --harness claude --model opus-special); rc=$?
  expect_code 3 "$rc" "gate: a model-scoped window without evidence must refuse"
  assert_contains "$out" "windows without a known used percent or reset time: opus_weekly" \
    "gate: the refusal must name the missing model-scoped window"
  pass "gate: a model-scoped window without percent or reset evidence is refused"
}

test_gate_zai_pass_prints_table() {
  local home out rc
  home=$(make_home zaipass)
  seed_record "$home" "$TMP_ROOT/snap-base.json"
  out=$(run_gate "$home" --harness pi --model zai/glm-4.7); rc=$?
  expect_code 3 "$rc" "gate: a zai candidate with an unknown plan size must refuse"
  assert_contains "$out" "the plan size for provider zai on account default is unknown" \
    "gate: the refusal must name the unknown plan size"
  seed_record "$home" "$TMP_ROOT/snap-base.json" '{"plans":{"zai":"glm-coding-pro"},"accounts":{}}'
  out=$(run_gate "$home" --harness pi --model zai/glm-4.7); rc=$?
  expect_code 0 "$rc" "gate: a measured zai candidate must pass"
  assert_contains "$out" "PASS" "gate: the pass must be visible"
  assert_contains "$out" "plan=glm-coding-pro (accounts.json)" "gate: the pass must name the plan size"
  assert_contains "$out" "provider=zai" "gate: the pass must name the provider"
  assert_contains "$out" "notes=glm coding line" "gate: the pass must carry the Notes column"
  assert_contains "$out" "scope=all_models status=known used=88%" \
    "gate: the pass must show the scope's used percent"
  assert_contains "$out" "window=five_hour used=88% resets=2026-09-29T18:00:00Z source=live" \
    "gate: the pass must print the 5h window row as used"
  assert_contains "$out" "window=weekly used=29% resets=2026-10-04T05:00:39.000Z source=live" \
    "gate: the pass must print the weekly window row as used"
  ! grep -q 'remaining=' <<<"$out" \
    || fail "the gate pass table must never show remaining alone"
  pass "gate: a passing candidate prints its full window table with used percents and notes"
}

# --- 5. gate refuses records missing table content ---------------------------

test_gate_table_content() {
  local home out rc

  # A codex provider that publishes no five-hour window: the 5h window is only
  # required when published, so the gate passes and shows the 5h cell as not
  # published instead of a number.
  home=$(make_home nofive)
  seed_record "$home" "$TMP_ROOT/snap-nofive.json"
  out=$(run_gate "$home" --harness codex); rc=$?
  expect_code 0 "$rc" "gate: a provider that publishes no 5h window must pass: $out"
  assert_contains "$out" "window=five_hour used=not published by provider" \
    "gate: the pass must show the unpublished 5h cell"
  assert_contains "$out" "window=weekly used=8% resets=2026-10-04T05:00:39.000Z source=live" \
    "gate: the pass must show the weekly used percent and reset"

  # The live Codex ProLite shape (weekly window only) passes the same way.
  home=$(make_home prolite)
  seed_record "$home" "$TMP_ROOT/snap-prolite.json"
  out=$(run_gate "$home" --harness pi --model openai-codex/gpt-6-luna); rc=$?
  expect_code 0 "$rc" "gate: the live Codex ProLite shape must pass: $out"
  assert_contains "$out" "plan=prolite (quota-axi)" "gate: the ProLite pass must name the plan"
  assert_contains "$out" "window=five_hour used=not published by provider" \
    "gate: the ProLite pass must show the unpublished 5h cell"
  assert_contains "$out" "window=weekly used=44% resets=2026-10-04T05:00:38.000Z source=live" \
    "gate: the ProLite pass must show the weekly used percent and reset"

  # A provider publishing no windows at all is still refused.
  home=$(make_home nowindows)
  seed_record "$home" "$TMP_ROOT/snap-nowindows.json"
  out=$(run_gate "$home" --harness codex); rc=$?
  expect_code 3 "$rc" "gate: a provider with no windows must refuse"
  assert_contains "$out" "the seven-day usage window (used percent and reset time) is missing for provider codex" \
    "gate: the no-windows refusal must name the missing seven-day window"

  # A claude provider without its seven-day window: same refusal, 7d named.
  home=$(make_home noseven)
  seed_record "$home" "$TMP_ROOT/snap-noseven.json"
  out=$(run_gate "$home" --harness claude); rc=$?
  expect_code 3 "$rc" "gate: a provider missing its 7d window must refuse"
  assert_contains "$out" "the seven-day usage window (used percent and reset time) is missing for provider claude on account default" \
    "gate: the 7d refusal must name the provider and the missing window"

  # No notes anywhere: both notes sources absent, so the Notes column would
  # be empty and the gate refuses; declaring the note in accounts.json and
  # re-reading the intake must admit the launch again.
  home=$(make_home nonotes)
  rm -f "$home/config/crew-dispatch.json"
  seed_record "$home" "$TMP_ROOT/snap-base.json" '{"plans":{},"accounts":{}}'
  out=$(run_gate "$home" --harness codex); rc=$?
  expect_code 3 "$rc" "gate: a provider with no Notes entry must refuse"
  assert_contains "$out" "no notes are recorded for provider codex on account default; declare them in config/accounts.json top-level notes or config/crew-dispatch.json model_notes" \
    "gate: the no-notes refusal must point at both notes sources"
  seed_record "$home" "$TMP_ROOT/snap-base.json" '{"notes":{"codex":"declared pool note"},"plans":{},"accounts":{}}'
  out=$(run_gate "$home" --harness codex); rc=$?
  expect_code 0 "$rc" "gate: a declared accounts.json note must admit the launch"
  assert_contains "$out" "notes=declared pool note" "gate: the pass must print the declared note"

  # Notes only in harness-scoped model_notes keys: the chosen model's note
  # admits the launch, by full key or by the bare model string.
  home=$(make_home modelkeys)
  printf '%s\n' '{"model_notes":{"claude/opus":"opus line","pi/openai-codex/gpt-6-luna":"luna line"}}' \
    > "$home/config/crew-dispatch.json"
  seed_record "$home" "$TMP_ROOT/snap-base.json" '{"plans":{},"accounts":{}}'
  out=$(run_gate "$home" --harness claude --model sonnet); rc=$?
  expect_code 3 "$rc" "gate: a model without any note must refuse"
  assert_contains "$out" "no notes are recorded for provider claude" "gate: the refusal must name the provider"
  out=$(run_gate "$home" --harness codex --model pi/openai-codex/gpt-6-luna); rc=$?
  expect_code 0 "$rc" "gate: a harness-scoped model note must admit the launch: $out"
  assert_contains "$out" "notes=luna line" "gate: the pass must print the model note"
  seed_record "$home" "$TMP_ROOT/snap-base.json"
  out=$(run_gate "$home" --harness pi --model openai-codex/gpt-6-luna); rc=$?
  expect_code 0 "$rc" "gate: a bare model string must find its harness-scoped note: $out"
  assert_contains "$out" "notes=luna line" "gate: the suffix-matched pass must print the model note"

  pass "gate: an unpublished 5h window passes as not published; a missing 7d window or Notes entry is refused"
}

test_gate_test_bypass() {
  local home out rc
  home=$(make_home bypass)
  # No record, and the suite-wide test bypass explicitly enabled.
  out=$(env FM_QUOTA_INTAKE_TEST_BYPASS=1 \
    HOME="$home/user-home" CLAUDE_CONFIG_DIR= PI_CODING_AGENT_DIR= CODEX_HOME= \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$INTAKE" gate --harness claude 2>&1); rc=$?
  expect_code 0 "$rc" "bypass: the test escape hatch must pass without a record"
  assert_contains "$out" "TEST BYPASS" "bypass: the bypass must say it checked nothing"
  pass "gate: the FM_QUOTA_INTAKE_TEST_BYPASS escape hatch is explicit and loud"
}

# --- 7. the cached-read exception -------------------------------------------

write_statusline_cache() {  # <home> <line>
  mkdir -p "$home/user-home/.claude/tmp"
  printf '%s\n' "$2" > "$home/user-home/.claude/tmp/sl-quota.txt"
}

test_cached_fallback_fresh() {
  local home fakebin out rc rec
  home=$(make_home cachefresh)
  fakebin=$(make_fake_quota_axi "$home/quota-fake" "$TMP_ROOT/snap-codexonly.json")
  write_statusline_cache "$home" 'cl personal 5h 42% (1h 12m) | 7d 61% (Wed 17:00)'
  printf '%s\n' '{"plans":{"claude":"max-20x"},"accounts":{}}' > "$home/config/accounts.json"
  out=$(run_record "$home" "$fakebin"); rc=$?
  [ "$rc" -eq 0 ] || fail "a fresh usable cache must keep the record run green: $out"
  rec=$(newest_record "$home")
  jq -e '([.accounts[0].providers[] | select(.provider == "claude")] | length == 1) and
    ([.accounts[0].providers[] | select(.provider == "claude") | .readStatus] == ["cached"]) and
    ([.accounts[0].providers[] | select(.provider == "claude") | .plan] == ["max-20x"]) and
    ([.accounts[0].providers[] | select(.provider == "claude") | .windows[] | .percentRemaining] == [58, 39]) and
    ([.accounts[0].providers[] | select(.provider == "claude") | .windows[] | .percentUsed] == [42, 61]) and
    ([.accounts[0].providers[] | select(.provider == "claude") | .scopes[] | .effectivePercentUsed] == [61]) and
    ([.accounts[0].providers[] | select(.provider == "claude") | .notes] == ["personal max line"]) and
    (all(.accounts[0].providers[] | select(.provider == "claude") | .windows[]; (.resetsAt | type) == "string"))' \
    "$rec" >/dev/null || fail "the cached entry must store the statusline USED percents with resets and notes"
  assert_contains "$out" "provider=claude status=cached" "the table must mark the cached read"
  assert_contains "$out" "window=five_hour used=42%" "the table must show the statusline's own 5h used percent"
  assert_contains "$out" "source=cached" "the table must mark every cached window"
  out=$(run_gate "$home" --harness claude); rc=$?
  expect_code 0 "$rc" "gate: a fresh cached read must pass the gate"
  assert_contains "$out" "source=cached" "gate: the pass must mark the windows as cached"
  pass "cached read: a fresh statusline cache is recorded with its own used percents, marked cached, and gates"
}

test_cached_fallback_stale() {
  local home fakebin out rc now
  home=$(make_home cachestale)
  fakebin=$(make_fake_quota_axi "$home/quota-fake" "$TMP_ROOT/snap-codexonly.json")
  write_statusline_cache "$home" 'cl personal 5h 42% (1h 12m) | 7d 61% (Wed 17:00)'
  now=$(date -u +%s)
  fm_touch_epoch $(( now - 4000 )) "$home/user-home/.claude/tmp/sl-quota.txt"
  out=$(run_record "$home" "$fakebin"); rc=$?
  [ "$rc" -ne 0 ] || fail "a stale cache must fail the record run closed"
  jq -e '[.accounts[0].providers[] | select(.provider == "claude" and .readStatus == "failed")] | length == 1' \
    "$(newest_record "$home")" >/dev/null || fail "the stale-cache claude entry must be recorded as failed"
  out=$(run_gate "$home" --harness claude); rc=$?
  expect_code 3 "$rc" "gate: a stale cache must refuse the launch"
  assert_contains "$out" "the claude read failed" "gate: the refusal must name the failed read"
  pass "cached read: a statusline cache older than 30 minutes fails closed"
}

# --- 8. the real spawn and relaunch gates ------------------------------------

test_real_spawn_gate() {
  local home proj fakebin wt out rc
  home=$(make_home spawngate)
  proj=$TMP_ROOT/spawn-proj
  fm_git_init_commit "$proj"
  fm_git_add_origin "$proj" "$TMP_ROOT/spawn-origin.git"
  wt=$TMP_ROOT/spawn-wt
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn-fake")
  cp "$(make_fake_quota_axi "$TMP_ROOT/spawn-quota" "$TMP_ROOT/snap-base.json")/quota-axi" "$fakebin/quota-axi"

  # Refusal: no record, the suite-wide bypass stripped, nothing created.
  fm_test_spawn_brief "$home" spawn-refused "quota gate refusal intent"
  out=$( unset FM_QUOTA_INTAKE_TEST_BYPASS
    # shellcheck disable=SC2030 # The pin is deliberately local to this spawn run's subshell.
    export CODEX_HOME=
    fm_test_run_spawn "$home" "$wt" "$fakebin" spawn-refused "$proj" codex --mode no-mistakes --yolo off ); rc=$?
  [ "$rc" -ne 0 ] || fail "fm-spawn must refuse without an intake record"
  assert_contains "$out" "quota intake gate: refusing - no intake record exists" \
    "fm-spawn: the refusal must be the quota gate's"
  assert_contains "$out" "spawn-refused was not launched; the quota intake gate refused it and nothing was created" \
    "fm-spawn: the refusal must state nothing was created"
  assert_absent "$home/state/spawn-refused.meta" "fm-spawn: a refused launch must record no meta"

  # Pass: the real recorder seeds the record the real gate then reads.
  fm_test_spawn_brief "$home" spawn-passed "quota gate pass intent"
  run_record "$home" "$fakebin" >/dev/null || fail "seeding the spawn home's record failed"
  out=$( unset FM_QUOTA_INTAKE_TEST_BYPASS
    # shellcheck disable=SC2030,SC2031 # The pin is deliberately local to this spawn run's subshell.
    export CODEX_HOME=
    fm_test_run_spawn "$home" "$wt" "$fakebin" spawn-passed "$proj" codex --mode no-mistakes --yolo off ); rc=$?
  expect_code 0 "$rc" "fm-spawn: a fresh covering record must admit the launch"$'\n'"$out"
  assert_contains "$out" "spawned spawn-passed" "fm-spawn: the launch should succeed"
  assert_present "$home/state/spawn-passed.meta" "fm-spawn: the launch should record meta"

  # The launch spent that record: the next spawn must re-read every limit.
  fm_test_spawn_brief "$home" spawn-reused "quota gate reuse intent"
  out=$( unset FM_QUOTA_INTAKE_TEST_BYPASS
    # shellcheck disable=SC2031 # The pin is deliberately local to this spawn run's subshell.
    export CODEX_HOME=
    fm_test_run_spawn "$home" "$wt" "$fakebin" spawn-reused "$proj" codex --mode no-mistakes --yolo off ); rc=$?
  [ "$rc" -ne 0 ] || fail "fm-spawn must refuse a second launch on an already spent record"
  assert_contains "$out" "was already spent on a launch" "fm-spawn: the reuse refusal must be the quota gate's"
  assert_absent "$home/state/spawn-reused.meta" "fm-spawn: a refused reuse must record no meta"
  pass "fm-spawn: refuses without a record (nothing created), launches on a real seeded record, and refuses to reuse it"
}

test_worker_pin_record_covers_the_pinned_store() {
  local home ambient claude_pin pi_pin rec out rc proj wt fakebin
  home=$(make_home pinned)
  ambient=$home/ambient-claude
  claude_pin=$home/pinned-claude
  pi_pin=$home/pinned-pi
  mkdir -p "$ambient" "$claude_pin" "$pi_pin"
  : > "$claude_pin/.credentials.json"
  printf '%s\n' "$claude_pin" > "$home/config/claude-account"
  printf '%s\nzai\n' "$pi_pin" > "$home/config/pi-account"
  printf '%s\n' '{"plans":{"zai":"glm-coding-pro"},"accounts":{}}' > "$home/config/accounts.json"
  fakebin=$(make_fake_quota_axi "$home/quota-fake" "$TMP_ROOT/snap-base.json")

  out=$(run_record "$home" "$fakebin" CLAUDE_CONFIG_DIR="$ambient") || fail "the pinned home's record failed: $out"
  rec=$(newest_record "$home") || fail "no intake record was written for the pinned home"
  jq -e --arg c "$claude_pin" --arg p "$pi_pin" \
    '.accounts[0].account == "default" and .accounts[0].stores.claude == $c and .accounts[0].stores.pi == $p' \
    "$rec" >/dev/null || fail "the default record must read the pinned Claude and Pi roots, not the ambient store"

  # The gate exactly as fm-spawn and fm-control relaunch call it under a pin.
  out=$(run_gate "$home" --harness claude --claude-store "$claude_pin"); rc=$?
  expect_code 0 "$rc" "a pinned Claude launch must pass on the home's own record"$'\n'"$out"
  out=$(run_gate "$home" --harness pi --model zai/glm-5.3 --pi-store "$pi_pin"); rc=$?
  expect_code 0 "$rc" "a pinned Pi launch must pass on the home's own record"$'\n'"$out"
  out=$(run_gate "$home" --harness claude --claude-store "$ambient"); rc=$?
  expect_code 3 "$rc" "the ambient store the pin overrides must stay uncovered"
  assert_contains "$out" "does not cover the chosen store $ambient" "the refusal must name the uncovered store"

  # The real fm-spawn under the pin, with ambient CLAUDE_CONFIG_DIR elsewhere.
  proj=$TMP_ROOT/pinned-proj
  fm_git_init_commit "$proj"
  fm_git_add_origin "$proj" "$TMP_ROOT/pinned-origin.git"
  wt=$TMP_ROOT/pinned-wt
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/pinned-spawn-fake")
  cp "$(make_fake_quota_axi "$TMP_ROOT/pinned-spawn-quota" "$TMP_ROOT/snap-base.json")/quota-axi" "$fakebin/quota-axi"
  # shellcheck disable=SC2016  # Expanded by the stub at run time.
  printf '#!/usr/bin/env bash\n[ "${1:-}" = auth ] || exit 0\n[ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" ]\n' > "$fakebin/claude"
  chmod +x "$fakebin/claude"
  run_record "$home" "$fakebin" CLAUDE_CONFIG_DIR="$ambient" >/dev/null || fail "re-seeding the pinned home's record failed"
  fm_test_spawn_brief "$home" spawn-pinned "pinned quota gate intent"
  out=$( unset FM_QUOTA_INTAKE_TEST_BYPASS
    FM_TEST_CLAUDE_CONFIG_DIR=$ambient fm_test_run_spawn "$home" "$wt" "$fakebin" spawn-pinned "$proj" claude --mode no-mistakes --yolo off ); rc=$?
  expect_code 0 "$rc" "fm-spawn: a pinned Claude launch must pass the real quota gate"$'\n'"$out"
  assert_contains "$out" "quota-intake gate: PASS" "fm-spawn: the pass must be the real gate's"
  assert_present "$home/state/spawn-pinned.meta" "fm-spawn: the pinned launch should record meta"
  pass "a pinned home's intake record covers the pinned Claude and Pi roots, so pinned spawns and relaunches pass the real gate"
}

# The same lifecycle-modelling tmux stub as tests/fm-control-relaunch.test.sh:
# the harness's exit command stops the agent, and a launch-brief literal
# starts the harness named in `becomes`.
make_relaunch_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit)
          printf 'zsh' > "$D/command"
          ;;
        *'encode launch-brief'*)
          cat "$D/becomes" > "$D/command"
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ -s "$D/composer" ]; then
      printf '╭────╮\n│ %s  │\n╰────╯\n' "$(cat "$D/composer")"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows)
    [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
  new-session)
    shift
    ses=
    while [ $# -gt 0 ]; do
      case "$1" in
        -s) ses=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$ses" >> "$D/created-sessions"
    exit 0 ;;
  new-window)
    shift
    name=
    while [ $# -gt 0 ]; do
      case "$1" in
        -n) name=${2:-}; shift 2 ;;
        -c|-t) shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$name" >> "$D/windows"
    printf '%s\n' "$name" >> "$D/created-windows"
    printf '@9\n'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
}

# new_relaunch_case <name> [id] -> echoes a case dir with a live codex ship
# task, mirroring tests/fm-control-relaunch.test.sh's proven fixture.
new_relaunch_case() {
  local id=${2:-q1} dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/user-home" "$dir/home/config" "$dir/fake"
  # The relaunch gate needs a Notes source exactly like any other launch.
  printf '%s\n' '{"model_notes":{"codex":"codex pool line","claude":"personal max line"}}' \
    > "$dir/home/config/crew-dispatch.json"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'codex' > "$dir/fake/command"
  printf 'codex' > "$dir/fake/becomes"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' fmses > "$dir/fake/session-name"
  make_relaunch_tmux_stub "$dir"
  fm_git_worktree "$dir/proj" "$dir/wt" "task-$id"
  mkdir -p "$dir/home/data/$id"
  cat > "$dir/home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the relaunch quota gate for $id.

## Firstmate spec
Preserve the task while replacing its agent process.
EOF
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$dir/wt"
    echo "project=$dir/proj"
    echo "harness=codex"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
  } > "$dir/home/state/$id.meta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' fmses > "$dir/fake/session-name"
  printf '%s\n' "$dir/wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-$id")
  printf '%s\n' "$dir"
}

# run_relaunch_control <case-dir> <args...> -> the real fm-control.sh with the
# suite-wide quota bypass STRIPPED, so the pre-stop gate reads a real record.
run_relaunch_control() {
  local dir=$1; shift
  env -u FM_QUOTA_INTAKE_TEST_BYPASS -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION \
    -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/home/user-home" CLAUDE_CONFIG_DIR= PI_CODING_AGENT_DIR= CODEX_HOME= \
    FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$@" 2>&1
}

test_relaunch_pre_stop_gate() {
  local dir out rc rec
  # Refusal: no record, and the running agent must stay exactly as it was.
  dir=$(new_relaunch_case relaunch-refused q1)
  cp "$dir/home/state/q1.meta" "$dir/meta.before"
  out=$(run_relaunch_control "$dir" q1 relaunch --note "quota gate check"); rc=$?
  [ "$rc" -ne 0 ] || fail "relaunch must refuse without an intake record"
  assert_contains "$out" "not released onto its quota windows yet; the running agent was left untouched and nothing changed" \
    "relaunch: the refusal must name the quota gate and the untouched agent"
  [ "$(cat "$dir/fake/command")" = codex ] \
    || fail "a refused relaunch must not stop the agent (command flipped to $(cat "$dir/fake/command"))"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused relaunch must send nothing to the pane"
  [ ! -e "$dir/home/state/q1.control-relaunch" ] || fail "a refused relaunch must not create a journal"
  cmp -s "$dir/home/state/q1.meta" "$dir/meta.before" \
    || fail "a refused relaunch must leave the record untouched"

  # Pass: the real recorder seeds the home's record, and the whole
  # transaction - pre-stop gate, stop, replacement launch - runs on it.
  dir=$(new_relaunch_case relaunch-passed q2)
  rec=$(make_fake_quota_axi "$dir/quota-fake" "$TMP_ROOT/snap-base.json")
  run_record "$dir/home" "$rec" >/dev/null || fail "seeding the relaunch home's record failed"
  out=$(run_relaunch_control "$dir" q2 relaunch --note "quota record present"); rc=$?
  expect_code 0 "$rc" "relaunch: a fresh covering record must let the relaunch through"$'\n'"$out"
  assert_contains "$out" "relaunched q2 harness=codex" "relaunch: the transaction should complete"
  assert_contains "$(cat "$dir/fake/literal")" "/quit" "relaunch: the agent must have been stopped on the pass path"
  [ "$(cat "$dir/fake/command")" = codex ] \
    || fail "relaunch: the replacement agent must be running after the pass path"

  # A task bound to a named account relaunches onto that account's stores
  # without --account: both the pre-stop preview and fm-spawn's own gate must
  # check the recorded account's entry, not the default one.
  dir=$(new_relaunch_case relaunch-geris q3)
  mkdir -p "$dir/geris/claude" "$dir/geris/pi" "$dir/geris/codex" "$dir/home/config"
  {
    echo "account=geris"
    echo "claude_config_dir=$dir/geris/claude"
    echo "pi_agent_dir=$dir/geris/pi"
    echo "codex_home=$dir/geris/codex"
  } >> "$dir/home/state/q3.meta"
  printf '%s\n' '{"crossAccount":{"enabled":true},"accounts":{"geris":{"claude":"'"$dir"'/geris/claude","pi":"'"$dir"'/geris/pi","codex":"'"$dir"'/geris/codex"}}}' \
    > "$dir/home/config/accounts.json"
  rec=$(make_fake_quota_axi "$dir/quota-fake" "$TMP_ROOT/snap-base.json")
  run_record "$dir/home" "$rec" >/dev/null || fail "seeding the named-account relaunch record failed"
  out=$(run_relaunch_control "$dir" q3 relaunch --note "named account relaunch"); rc=$?
  expect_code 0 "$rc" "relaunch: a named-account task must relaunch on a covering record"$'\n'"$out"
  assert_contains "$out" "account=geris provider=codex" "relaunch: the gate must check the recorded account"
  assert_contains "$out" "relaunched q3 harness=codex" "relaunch: the named-account transaction should complete"
  pass "fm-control relaunch: the quota gate refuses before the agent is stopped and passes on a real record, named accounts included"
}

test_record_shape
test_record_private_and_retention
test_record_failed_store
test_gate_refusals
test_gate_exhausted_account
test_gate_zero_percent_window
test_gate_model_scoped_window
test_gate_table_content
test_gate_zai_pass_prints_table
test_gate_test_bypass
test_cached_fallback_fresh
test_cached_fallback_stale
test_real_spawn_gate
test_worker_pin_record_covers_the_pinned_store
test_relaunch_pre_stop_gate
