#!/usr/bin/env bash
# Behavior tests for bin/fm-suggestions.sh, driven only through its commands and
# a real tasks-axi backlog in a throwaway home: follow-ups stay off the backlog,
# intake de-duplicates, unpicked suggestions expire into a never-deleted archive,
# picks file rows, urgent findings reach a captain hold, and teardown's check
# names any follow-up with no recorded outcome.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SUGGESTIONS="$ROOT/bin/fm-suggestions.sh"
TASKS="$ROOT/bin/fm-tasks-axi.sh"
TMP_ROOT=$(fm_test_tmproot fm-suggestions)
DAY=86400
T0=1800000000

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

# Runs the command in <home> with the clock at T0 plus <days>.
at() {  # <home> <days> <args...>
  local home=$1 days=$2
  shift 2
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SUGGESTIONS_NOW=$((T0 + days * DAY)) "$SUGGESTIONS" "$@"
}

tasks() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$TASKS" "$@"
}

row_count() {  # <home>
  tasks "$1" list | sed -n 's/^count: //p'
}

test_a_follow_up_waits_off_the_backlog() {
  local home out
  home=$(make_home waits)
  out=$(at "$home" 0 add --origin scout-a --item 1 --title "Harden the parser" \
    --file-line bin/x.sh:12 --size S --kind hardening --risk "bad input aborts" --repo fm)
  assert_contains "$out" "suggested sg-" "intake did not record a suggestion"
  assert_equals "0" "$(row_count "$home")" "a follow-up became a backlog row"
  out=$(at "$home" 3 digest)
  assert_contains "$out" "1 suggested task, oldest 3d" "digest did not lead with the summary line"
  assert_contains "$out" "Harden the parser (bin/x.sh:12) - risk: bad input aborts" "digest lost a field"
  assert_equals "1" "$(at "$home" 3 summary --json | jq '.count')" "summary miscounted"
  assert_equals "3" "$(at "$home" 3 summary --json | jq '.oldest_age_days')" "summary misaged"
  pass "a follow-up is listed as a suggestion and files no backlog row"
}

test_an_empty_list_reports_nothing() {
  local home
  home=$(make_home empty)
  assert_equals "" "$(at "$home" 0 summary)" "an empty list printed a line"
  assert_equals "0" "$(at "$home" 0 summary --json | jq '.count')" "an empty list had a count"
  assert_equals "null" "$(at "$home" 0 summary --json | jq '.oldest_age_days')" "an empty list had an age"
  pass "an empty list reports no line, a zero count and no age"
}

test_intake_deduplicates_against_earlier_suggestions() {
  local home first out id
  home=$(make_home dedupe-suggestions)
  first=$(at "$home" 0 add --origin scout-a --item 1 --title "Fix the Parser!" --file-line bin/x.sh:12 --kind defect)
  id=${first#suggested }
  out=$(at "$home" 1 add --origin scout-b --item 1 --title "fix the  parser")
  assert_contains "$out" "repeat sg-" "a reworded title was not a repeat"
  assert_contains "$out" " $id" "the repeat did not name its target"
  out=$(at "$home" 1 add --origin scout-c --item 1 --title "Different words" --file-line bin/x.sh:12 --kind defect)
  assert_contains "$out" " $id" "the same file:line and kind was not a repeat"
  out=$(at "$home" 1 add --origin scout-d --item 1 --title "Other finding" --file-line bin/x.sh:12 --kind doc-nit)
  assert_contains "$out" "suggested sg-" "another kind at the same line was swallowed as a repeat"
  assert_equals "2" "$(at "$home" 1 summary --json | jq '.count')" "repeats counted as waiting work"
  assert_contains "$(at "$home" 1 digest)" "seen 3 times" "the digest did not show the repeats"
  pass "intake merges a repeated suggestion, raises its count and keeps a different kind"
}

test_large_stores_keep_repeat_detection_and_expiry() {
  local home first id out store bytes
  home=$(make_home large-stores)
  first=$(at "$home" 0 add --origin seed --item 1 --title "Fixture finding 0")
  id=${first#suggested }
  # Build a realistic store without thousands of CLI calls. Each record stays
  # small, but both stores and the eventual expiry batch exceed Linux's 128 KiB
  # per-argument limit (and stay below ordinary total argv limits).
  jq -c '. as $r | range(0;1000) as $i | $r
    | .id = (if $i == 0 then $r.id else "sg-fixture-\($i)" end)
    | .origin = "fixture-\($i)" | .title = "Fixture finding \($i)"
    | .risk = ("x" * 256)' "$home/data/suggestions.jsonl" > "$home/data/large.jsonl"
  mv "$home/data/large.jsonl" "$home/data/suggestions.jsonl"
  for store in suggestions.jsonl suggestions-not-picked.jsonl; do
    if [ "$store" = suggestions-not-picked.jsonl ]; then
      jq -c '.id += "-archived" | .origin += "-archived" | .title += " archived"
        | .outcome = "expired"' "$home/data/suggestions.jsonl" > "$home/data/$store"
    fi
    bytes=$(wc -c < "$home/data/$store")
    [ "$bytes" -gt 400000 ] || fail "large-store fixture is too small: $bytes"
  done
  out=$(at "$home" 0 add --origin fixture-0 --item 1 --title "Retry with changed wording" 2>&1)
  assert_equals "$first" "$out" "large-store intake was not idempotent"
  out=$(at "$home" 0 add --origin repeat --item 1 --title "FIXTURE finding 0!" 2>&1)
  assert_equals "repeat" "${out%% *}" "large-store repeat lookup failed: $out"
  assert_contains "$out" " $id" "large-store repeat lost its target"
  assert_equals "1000" "$(at "$home" 0 summary --json | jq '.count')" "large summary failed"
  mkdir -p "$home/data/repeat"
  printf '## Follow-ups\n1. Recorded repeat\n' > "$home/data/repeat/report.md"
  assert_equals "ok repeat: every follow-up has a recorded outcome" "$(at "$home" 0 check repeat 2>&1)" "large-store check failed"
  out=$(at "$home" 30 expire 2>&1)
  assert_equals "expired 1000" "$out" "large expiry batch failed"
  assert_equals "expired 0" "$(at "$home" 30 expire 2>&1)" "large expiry was not idempotent"
  assert_equals "2000" "$(at "$home" 30 archive --json | jq 'length')" "large expiry lost archive records"
  out=$(at "$home" 31 add --origin archived-repeat --item 1 --title "Fixture finding 0 archived" 2>&1)
  assert_equals "repeat" "${out%% *}" "large archive repeat lookup failed: $out"
  assert_contains "$out" " $id-archived" "large archive repeat lost its target"
  pass "stores above 400 KB preserve intake, repeats, summary, check and batch expiry"
}

test_large_backlog_keeps_repeat_detection() {
  local home out body n
  home=$(make_home large-backlog)
  # Each CLI argument fits, but the parsed backlog JSON exceeds 128 KiB.
  body=$(printf '%060000d' 0)
  for n in 1 2 3; do
    tasks "$home" add "large-row-$n" "Large backlog target $n" --kind ship --body "$body" >/dev/null
  done
  out=$(at "$home" 0 add --origin scout-a --item 1 --title "large backlog TARGET 1" 2>&1)
  assert_contains "$out" " large-row-1" "large backlog repeat lookup failed: $out"
  assert_equals "repeat" "${out%% *}" "large backlog was not a repeat: $out"
  pass "a backlog above 128 KiB still de-duplicates intake"
}

test_intake_deduplicates_against_open_rows() {
  local home out
  home=$(make_home dedupe-rows)
  tasks "$home" add queued-row "Rotate the token" --kind ship --body "see bin/y.sh:7 for it" >/dev/null
  tasks "$home" add closed-row "Already finished work" --kind ship >/dev/null
  tasks "$home" "done" closed-row >/dev/null
  out=$(at "$home" 0 add --origin scout-a --item 1 --title "rotate the TOKEN")
  assert_equals "repeat" "${out%% *}" "a matching open title was not a repeat"
  assert_contains "$out" " queued-row" "the repeat did not name the open row"
  out=$(at "$home" 0 add --origin scout-a --item 2 --title "Something else" --file-line bin/y.sh:7)
  assert_contains "$out" " queued-row" "a row naming the file:line was not a repeat"
  out=$(at "$home" 0 add --origin scout-a --item 3 --title "Near miss" --file-line bin/y.sh:70)
  assert_equals "suggested" "${out%% *}" "bin/y.sh:70 matched a row naming bin/y.sh:7"
  out=$(at "$home" 0 add --origin scout-a --item 4 --title "already finished work")
  assert_equals "suggested" "${out%% *}" "a closed row counted as open"
  assert_equals "2" "$(row_count "$home")" "intake changed the backlog"
  pass "intake merges into open rows, respects line numbers and ignores closed rows"
}

test_intake_refuses_when_the_backlog_is_unreadable() {
  local home fakebin out rc
  home=$(make_home unreadable)
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nexit 7\n' > "$fakebin/tasks-axi"
  chmod +x "$fakebin/tasks-axi"
  out=$(PATH="$fakebin:$PATH" at "$home" 0 add --origin scout-a --item 1 --title "Anything" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "intake passed without reading the backlog: $out"
  assert_contains "$out" "cannot read the backlog" "the refusal gave no reason"
  assert_equals "" "$(at "$home" 0 summary)" "a refused intake recorded a suggestion"
  pass "intake refuses rather than skipping de-duplication on an unreadable backlog"
}

test_repeating_an_intake_changes_nothing() {
  local home first second
  home=$(make_home idempotent)
  first=$(at "$home" 0 add --origin scout-a --item 1 --title "Fix it")
  second=$(at "$home" 2 add --origin scout-a --item 1 --title "Fix it")
  assert_equals "$first" "$second" "repeating an intake changed its result"
  assert_equals "1" "$(wc -l < "$home/data/suggestions.jsonl" | tr -d ' ')" "repeating an intake added a record"
  assert_equals "1" "$(at "$home" 2 summary --json | jq '.count')" "repeating an intake changed the count"
  pass "the same report item recorded twice stays one suggestion"
}

test_unpicked_suggestions_expire_into_the_archive() {
  local home id out
  home=$(make_home expiry)
  id=$(at "$home" 0 add --origin scout-a --item 1 --title "Old lead")
  id=${id#suggested }
  at "$home" 20 add --origin scout-a --item 2 --title "New lead" >/dev/null
  assert_equals "expired 0" "$(at "$home" 29 expire)" "a suggestion expired early"
  assert_equals "2" "$(at "$home" 29 summary --json | jq '.count')" "the count dropped early"

  # Past due, the summary already leaves it out, read-only.
  assert_equals "1" "$(at "$home" 30 summary --json | jq '.count')" "a past-due suggestion still counted"
  assert_equals "10" "$(at "$home" 30 summary --json | jq '.oldest_age_days')" "a past-due suggestion still set the age"
  assert_equals "2" "$(wc -l < "$home/data/suggestions.jsonl" | tr -d ' ')" "summary rewrote the list"

  assert_equals "expired 1" "$(at "$home" 30 expire)" "expiry did not move the record"
  assert_equals "expired 0" "$(at "$home" 31 expire)" "expiry was not idempotent"
  out=$(at "$home" 31 archive --json)
  printf '%s' "$out" | jq -e --arg id "$id" 'length == 1 and .[0].id == $id and .[0].outcome == "expired"' >/dev/null \
    || fail "the archive did not keep the expired suggestion: $out"
  assert_contains "$(at "$home" 31 archive)" "Old lead" "the plain archive lost the record"
  assert_not_contains "$(at "$home" 31 digest)" "Old lead" "an expired suggestion stayed in the digest"
  pass "an unpicked suggestion expires at 30 days into the archive and is kept"
}

test_expiry_recovers_from_a_crash_before_the_list_rewrite() {
  local home
  home=$(make_home expiry-crash)
  at "$home" 0 add --origin scout-a --item 1 --title "Lead" >/dev/null
  # The state a crash leaves: appended to the archive, still in the list.
  jq -c '.outcome = "expired"' "$home/data/suggestions.jsonl" > "$home/data/suggestions-not-picked.jsonl"
  assert_equals "expired 1" "$(at "$home" 30 expire)" "the retried expiry did not converge"
  assert_equals "1" "$(at "$home" 30 archive --json | jq 'length')" "the retry archived the record twice"
  assert_equals "" "$(at "$home" 30 summary)" "the record stayed in the list"
  pass "a retried expiry after a crash archives each record once"
}

test_a_repeat_does_not_revive_an_expired_suggestion() {
  local home out id
  home=$(make_home expired-repeat)
  id=$(at "$home" 0 add --origin scout-a --item 1 --title "Old lead")
  id=${id#suggested }
  at "$home" 30 expire >/dev/null
  out=$(at "$home" 31 add --origin scout-b --item 1 --title "old lead")
  assert_contains "$out" " $id" "a repeat of an archived suggestion did not name it"
  assert_equals "" "$(at "$home" 31 summary)" "a repeat revived an expired suggestion"
  pass "a repeat of an expired suggestion is recorded and stays not picked"
}

test_a_pick_files_a_queued_row_once() {
  local home id out row
  home=$(make_home pick)
  id=$(at "$home" 0 add --origin scout-a --item 1 --title "Fix the parser, (really)" --file-line bin/x.sh:12 \
    --size S --kind defect --risk "aborts" --repo fm)
  id=${id#suggested }
  out=$(at "$home" 1 pick "$id")
  row=${out##* }
  assert_contains "$out" "picked $id " "pick did not report the row"
  assert_equals "$row" "$(tasks "$home" list --state queued --kind ship | sed -n 's/^  \([^,]*\),.*/\1/p')" "pick did not queue a ship row"
  assert_contains "$(tasks "$home" show "$row" --full)" "bin/x.sh:12" "the row lost the evidence"
  assert_equals "" "$(at "$home" 1 summary)" "a picked suggestion stayed waiting"
  assert_equals "$out" "$(at "$home" 2 pick "$id")" "a second pick changed the result"
  assert_equals "1" "$(row_count "$home")" "a second pick filed another row"
  out=$(at "$home" 2 add --origin scout-b --item 1 --title "fix the parser really")
  assert_contains "$out" " $id" "a picked suggestion no longer de-duplicates"
  pass "a pick files one queued row with its evidence and later repeats merge"
}

test_a_retried_pick_reuses_a_row_filed_before_a_crash() {
  local home id out row
  home=$(make_home pick-crash)
  id=$(at "$home" 0 add --origin scout-a --item 1 --title "Fix it")
  id=${id#suggested }
  row=$(at "$home" 0 pick "$id")
  row=${row##* }
  # The state a crash leaves: the row exists, the record still says suggested.
  jq -c '.outcome = "suggested" | .target = null' "$home/data/suggestions.jsonl" > "$home/data/s.tmp"
  mv "$home/data/s.tmp" "$home/data/suggestions.jsonl"
  out=$(at "$home" 0 pick "$id")
  assert_equals "picked $id $row" "$out" "the retried pick did not reuse the row"
  assert_equals "1" "$(row_count "$home")" "the retried pick filed a duplicate"
  pass "a retried pick reuses the row a crashed pick already filed"
}

test_an_archived_suggestion_can_still_be_picked() {
  local home id out
  home=$(make_home pick-archive)
  id=$(at "$home" 0 add --origin scout-a --item 1 --title "Old lead" --kind research)
  id=${id#suggested }
  at "$home" 30 expire >/dev/null
  out=$(at "$home" 40 pick "$id")
  assert_contains "$out" "picked $id" "an archived suggestion could not be picked"
  assert_equals "picked" "$(at "$home" 40 archive --json | jq -r '.[0].outcome')" "the archive lost the pick"
  tasks "$home" list --kind scout | grep -q 'old-lead' || fail "a research suggestion did not default to a scout row"
  pass "an archived suggestion stays pickable and research defaults to a scout"
}

test_pick_refuses_what_is_not_waiting() {
  local home out rc id target
  home=$(make_home pick-refuse)
  out=$(at "$home" 0 pick sg-nope 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "picking an unknown id passed"
  target=$(at "$home" 0 add --origin scout-a --item 1 --title "Target")
  target=${target#suggested }
  id=$(at "$home" 0 add --origin scout-a --item 2 --title "Target again")
  id=${id#suggested }
  at "$home" 0 bundle "$id" --into "$target" >/dev/null
  out=$(at "$home" 0 pick "$id" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "picking a bundled suggestion passed: $out"
  assert_contains "$out" "already bundled ($target)" "the refusal did not name the bundle"
  assert_equals "0" "$(row_count "$home")" "a refused pick filed a row"
  pass "pick refuses an unknown or already bundled suggestion"
}

test_bundle_folds_suggestions_into_one_candidate() {
  local home a b out rc
  home=$(make_home bundle)
  a=$(at "$home" 0 add --origin scout-a --item 1 --title "Nit one")
  a=${a#suggested }
  b=$(at "$home" 0 add --origin scout-a --item 2 --title "Polish pass")
  b=${b#suggested }
  out=$(at "$home" 0 bundle "$a" --into sg-missing 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a missing bundle target passed: $out"
  assert_equals "2" "$(at "$home" 0 summary --json | jq '.count')" "a refused bundle changed the list"
  at "$home" 0 bundle "$a" --into "$b" >/dev/null || fail "a valid bundle was refused"
  assert_equals "1" "$(at "$home" 0 summary --json | jq '.count')" "a bundled suggestion stayed a candidate"
  pass "bundle folds a nit into one candidate and refuses a missing target"
}

test_security_and_data_loss_reach_a_captain_hold_at_once() {
  local home risk out row n=0
  home=$(make_home escalate)
  for risk in "security: leaks the token" "Data-loss if the rewrite crashes"; do
    n=$((n + 1))
    out=$(at "$home" 0 add --origin scout-a --item "$n" --title "Urgent finding $n" --file-line "bin/z.sh:$n" --risk "$risk")
    assert_equals "escalated" "${out%% *}" "'$risk' did not escalate"
    row=${out##* }
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
      "$ROOT/bin/fm-captain-hold.sh" open "$row" >/dev/null || fail "'$risk' did not open a captain call"
  done
  assert_equals "" "$(at "$home" 0 summary)" "an escalated finding sat in the waiting list"
  out=$(at "$home" 0 add --origin scout-b --item 1 --title "Plain question" --kind question --hold)
  assert_equals "escalated" "${out%% *}" "--hold did not take the captain-hold path"
  out=$(at "$home" 0 add --origin scout-a --item 9 --title "Plain stale doc" --risk "securityless wording is fine")
  assert_equals "suggested" "${out%% *}" "a risk merely starting with the letters escalated"
  pass "security and data-loss findings and --hold open captain calls instead of waiting"
}

test_an_urgent_finding_is_not_hidden_by_a_lookalike() {
  local home out before
  home=$(make_home escalate-dedupe)
  at "$home" 0 add --origin scout-a --item 1 --title "Token leak" >/dev/null
  out=$(at "$home" 1 add --origin scout-b --item 1 --title "token leak" --risk "security: real exposure")
  assert_equals "escalated" "${out%% *}" "a waiting lookalike hid a security finding"
  assert_equals "" "$(at "$home" 1 summary)" "the lookalike stayed waiting after the escalation"
  before=$(row_count "$home")
  out=$(at "$home" 2 add --origin scout-c --item 1 --title "Token leak!" --risk "security: real exposure")
  assert_equals "repeat" "${out%% *}" "a second report of an escalated finding opened another hold"
  assert_equals "$before" "$(row_count "$home")" "a repeat of an escalation added a row"
  pass "an urgent finding escalates past a lookalike and later reports merge into it"
}

test_a_failed_hold_records_nothing() {
  local home fakebin out rc
  home=$(make_home hold-fails)
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nexit 7\n' > "$fakebin/tasks-axi"
  chmod +x "$fakebin/tasks-axi"
  out=$(PATH="$fakebin:$PATH" at "$home" 0 add --origin scout-a --item 1 --title "Leak" --risk "security: yes" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a failed captain hold reported success: $out"
  assert_contains "$(at "$home" 0 check scout-a --report /dev/null)" "ok" "check broke"
  [ ! -s "$home/data/suggestions.jsonl" ] || fail "a failed hold still recorded an outcome"
  pass "a failed captain hold records no outcome, so the intake can retry"
}

test_a_corrupt_store_is_refused_not_overwritten() {
  local home out rc before
  home=$(make_home corrupt)
  at "$home" 0 add --origin scout-a --item 1 --title "Lead" >/dev/null
  printf 'not json\n' >> "$home/data/suggestions.jsonl"
  before=$(cat "$home/data/suggestions.jsonl")
  out=$(at "$home" 1 add --origin scout-a --item 2 --title "Another" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "intake passed on a corrupt store: $out"
  assert_contains "$out" "cannot parse" "the refusal gave no reason"
  out=$(at "$home" 40 expire 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expiry passed on a corrupt store: $out"
  assert_equals "$before" "$(cat "$home/data/suggestions.jsonl")" "a corrupt store was rewritten"
  pass "a corrupt store refuses every write and keeps its bytes"
}

test_concurrent_intake_loses_nothing() {
  local home n pids=()
  home=$(make_home concurrent)
  for n in 1 2 3 4 5 6; do
    at "$home" 0 add --origin scout-a --item "$n" --title "Concurrent finding number $n of the batch $((n * 7919))" >/dev/null &
    pids+=("$!")
  done
  for n in "${pids[@]}"; do wait "$n" || fail "a concurrent intake failed"; done
  assert_equals "6" "$(at "$home" 0 summary --json | jq '.count')" "concurrent intake lost a record"
  pass "concurrent intake keeps every record"
}

test_check_names_each_follow_up_without_an_outcome() {
  local home report out rc
  home=$(make_home check)
  assert_contains "$(at "$home" 0 check task-a)" "no report" "a missing report did not pass"
  mkdir -p "$home/data/task-a"
  report="$home/data/task-a/report.md"
  cat > "$report" <<'EOF'
# Report

## Steps
1. A step that is not a follow-up

## Follow-ups
1. First lead
2. Second lead
3) Third lead

## Appendix
7. Not a follow-up either
EOF
  out=$(at "$home" 0 check task-a)
  rc=$?
  [ "$rc" -eq 1 ] || fail "check passed with no outcomes recorded: $out"
  assert_contains "$out" "without a recorded outcome: 1 2 3" "check did not name every item"
  at "$home" 0 add --origin task-a --item 1 --title "First lead" >/dev/null
  at "$home" 0 add --origin task-a --item 2 --title "first lead" >/dev/null
  out=$(at "$home" 0 check task-a)
  rc=$?
  [ "$rc" -eq 1 ] || fail "check passed with one item left: $out"
  assert_contains "$out" "outcome: 3" "a repeat outcome did not count as recorded"
  at "$home" 0 add --origin task-a --item 3 --title "Third lead" >/dev/null
  at "$home" 30 expire >/dev/null
  out=$(at "$home" 30 check task-a) || fail "check did not count expired outcomes: $out"
  printf '## Follow-ups\nNone.\n' > "$report"
  mkdir -p "$home/no-jq"
  for tool in dirname date awk; do ln -s "$(command -v "$tool")" "$home/no-jq/$tool"; done
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" PATH="$home/no-jq" /bin/bash "$SUGGESTIONS" check task-a 2>&1) \
    || fail "check needed jq for a report with no follow-ups: $out"
  assert_contains "$(at "$home" 30 check task-a)" "no numbered follow-ups" "an empty section did not pass"
  pass "check names every unrecorded follow-up and accepts any recorded outcome"
}

fm_test_run \
  test_a_follow_up_waits_off_the_backlog \
  test_an_empty_list_reports_nothing \
  test_intake_deduplicates_against_earlier_suggestions \
  test_large_stores_keep_repeat_detection_and_expiry \
  test_large_backlog_keeps_repeat_detection \
  test_intake_deduplicates_against_open_rows \
  test_intake_refuses_when_the_backlog_is_unreadable \
  test_repeating_an_intake_changes_nothing \
  test_unpicked_suggestions_expire_into_the_archive \
  test_expiry_recovers_from_a_crash_before_the_list_rewrite \
  test_a_repeat_does_not_revive_an_expired_suggestion \
  test_a_pick_files_a_queued_row_once \
  test_a_retried_pick_reuses_a_row_filed_before_a_crash \
  test_an_archived_suggestion_can_still_be_picked \
  test_pick_refuses_what_is_not_waiting \
  test_bundle_folds_suggestions_into_one_candidate \
  test_security_and_data_loss_reach_a_captain_hold_at_once \
  test_an_urgent_finding_is_not_hidden_by_a_lookalike \
  test_a_failed_hold_records_nothing \
  test_a_corrupt_store_is_refused_not_overwritten \
  test_concurrent_intake_loses_nothing \
  test_check_names_each_follow_up_without_an_outcome
