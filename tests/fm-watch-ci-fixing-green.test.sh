#!/usr/bin/env bash
# Recognition of a no-mistakes run stuck at ci=fixing while the forge is green,
# through the watcher's real queue interface. Only the crew-state verdict is
# stubbed through FM_CREW_STATE_BIN (its documented test seam) and the forge
# through a `gh` on PATH; no endpoint, harness process, model call or network is
# needed. Nothing here may merge, tear down or otherwise act on the lane.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-ci-fixing-green)
export FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$TMP_ROOT/state"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE" "$TMP_ROOT/bin"

STUB="$TMP_ROOT/crew-state-stub.sh"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "${FM_CREW_STATE_NO_FORGE:-0}" >> "$FM_STATE_OVERRIDE/.stub-calls"
cat "$FM_STATE_OVERRIDE/$1.crew-state-line" 2>/dev/null || printf 'state: unknown · source: none · no metadata for %s\n' "$1"
EOF
chmod +x "$STUB"
export FM_CREW_STATE_BIN="$STUB"

# The forge: `gh pr view <url> --json ...` prints the payload kept in
# <state>/.gh-json and records every call, so a test can prove when the forge
# was and was not read. A missing payload is a failed read.
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_STATE_OVERRIDE/.gh-calls"
[ -f "$FM_STATE_OVERRIDE/.gh-json" ] || exit 1
cat "$FM_STATE_OVERRIDE/.gh-json"
EOF
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"

# shellcheck source=bin/fm-watch.sh
. "$ROOT/bin/fm-watch.sh"

CI_FIXING_GREEN_SCAN_SECS=0
CI_FIXING_GREEN_HOLD_SECS=900
PAUSE_RESURFACE_SECS=10000

PR=https://github.com/o/r/pull/7
FIXING="state: working · source: run-step · validating (fixing) · ci step: fixing · pr: $PR · run: r1"
GREEN='{"state":"OPEN","isDraft":false,"statusCheckRollup":[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SKIPPED"},{"__typename":"StatusContext","context":"ci/x","state":"SUCCESS"}]}'

reset_case() {
  rm -f -- "$STATE"/* "$STATE"/.[!.]* "$CONFIG"/*
  : > "$CONFIG/ci-fixing-green"
  CI_FIXING_GREEN=
}

lane() {  # <task> <crew-state line> [meta kind]
  printf 'working [at=1000]: on it\n' > "$STATE/$1.status"
  printf 'worktree=%s\nkind=%s\n' "$TMP_ROOT" "${3:-ship}" > "$STATE/$1.meta"
  printf '%s\n' "$2" > "$STATE/$1.crew-state-line"
}

forge() {  # <json>
  printf '%s\n' "$1" > "$STATE/.gh-json"
}

count_wakes() {
  if [ -f "$FM_WAKE_QUEUE" ]; then wc -l < "$FM_WAKE_QUEUE" | tr -d ' '; else printf 0; fi
}

count_forge_reads() {
  if [ -f "$STATE/.gh-calls" ]; then wc -l < "$STATE/.gh-calls" | tr -d ' '; else printf 0; fi
}

test_unarmed_home_reads_nothing() {
  reset_case
  rm -f "$CONFIG/ci-fixing-green"
  forge "$GREEN"
  lane worker "$FIXING"
  printf 'worker\tr1\t1000\t0\n' > "$STATE/.ci-fixing-green"
  ci_fixing_green_tick 100000
  ci_fixing_green_tick 200000
  [ "$(count_wakes)" = 0 ] || fail "an unarmed home woke on a stuck ci=fixing run"
  [ ! -e "$STATE/.stub-calls" ] || fail "an unarmed home spent a crew-state read"
  [ "$(count_forge_reads)" = 0 ] || fail "an unarmed home read the forge"
  [ ! -e "$STATE/.ci-fixing-green" ] || fail "an unarmed home kept an earlier ledger"
  pass "without config/ci-fixing-green the tick reads nothing, wakes nothing and drops its ledger"
}

test_only_the_minted_components_classify() {
  reset_case
  lane fixing "$FIXING"
  lane nopr 'state: working · source: run-step · validating (fixing) · ci step: fixing · run: r2'
  lane norun "state: working · source: run-step · ci step: fixing · pr: $PR"
  lane plain "state: working · source: run-step · ci running · pr: $PR · run: r3"
  lane roundfix "state: working · source: run-step · validating (fixing) · run: r4"
  lane parked "state: parked · source: run-step · parked at ci · ci step: fixing · pr: $PR · run: r5"
  lane pane "state: working · source: pane · ci step: fixing · pr: $PR · run: r6"
  lane prose "state: working · source: run-step · status said ci step: fixing pr: $PR run: r7"
  lane spaced "state: working · source: run-step · ci step: fixing · pr: $PR extra · run: r8"
  [ "$(crew_ci_fixing_run fixing)" = "r1 $PR" ] || fail "the minted components did not classify: $(crew_ci_fixing_run fixing)"
  for task in nopr norun plain roundfix parked pane prose spaced missing; do
    if crew_ci_fixing_run "$task" >/dev/null; then fail "$task was classified as a ci=fixing run"; fi
  done
  grep -qv ' 1$' "$STATE/.stub-calls" && fail "a classification read did not skip the forge"
  pass "only the whole ci-step, run and pr components of a run-step verdict classify, and the crew-state forge read is skipped"
}

test_forge_green_is_strict() {
  reset_case
  rm -f "$STATE/.gh-json"
  pr_forge_checks_green "$PR" && fail "an unreadable forge read counted as green"
  forge "$GREEN"
  pr_forge_checks_green "$PR" || fail "an all-green open PR was not green"
  grep -F "pr view $PR" "$STATE/.gh-calls" >/dev/null || fail "the forge was not asked about the named PR"
  forge '{"state":"OPEN","isDraft":false,"statusCheckRollup":[]}'
  pr_forge_checks_green "$PR" && fail "a PR with no checks counted as green"
  forge '{"state":"OPEN","isDraft":false,"statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"IN_PROGRESS","conclusion":null}]}'
  pr_forge_checks_green "$PR" && fail "a pending check counted as green"
  forge '{"state":"OPEN","isDraft":false,"statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"FAILURE"}]}'
  pr_forge_checks_green "$PR" && fail "a failed check counted as green"
  forge '{"state":"OPEN","isDraft":false,"statusCheckRollup":[{"__typename":"StatusContext","context":"c","state":"PENDING"}]}'
  pr_forge_checks_green "$PR" && fail "a pending status context counted as green"
  forge '{"state":"MERGED","isDraft":false,"statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"}]}'
  pr_forge_checks_green "$PR" && fail "a merged PR counted as landable"
  forge '{"state":"OPEN","isDraft":true,"statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"}]}'
  pr_forge_checks_green "$PR" && fail "a draft PR counted as landable"
  forge 'not json'
  pr_forge_checks_green "$PR" && fail "garbage counted as green"
  forge "$GREEN"
  pr_forge_checks_green 'https://gitlab.com/o/r/-/merge_requests/3' && fail "another forge counted as green"
  pr_forge_checks_green 'not a url' && fail "a non-URL counted as green"
  pass "only an open, non-draft PR whose every reported check is green reads as forge green"
}

test_wakes_once_at_the_hold_naming_the_pr() {
  reset_case
  lane worker "$FIXING"
  forge "$GREEN"
  ci_fixing_green_tick 1000
  ci_fixing_green_tick 1899
  [ "$(count_wakes)" = 0 ] || fail "a lane woke before the hold elapsed"
  [ "$(count_forge_reads)" = 0 ] || fail "the forge was read before the hold elapsed"
  ci_fixing_green_tick 1900
  [ "$(count_wakes)" = 1 ] || fail "a stuck lane with a green forge did not wake at the hold"
  [ "$CI_FIXING_GREEN" = "check: run stuck at ci=fixing with forge green: worker $PR run r1 900s (threshold 900s)" ] \
    || fail "unexpected wake reason: $CI_FIXING_GREEN"
  grep -F 'ci-fixing-green' "$FM_WAKE_QUEUE" >/dev/null || fail "the wake was not durably queued as a check"
  ci_fixing_green_tick 1901
  ci_fixing_green_tick 11899
  [ "$(count_wakes)" = 1 ] || fail "an escalated lane repeated before the recheck cadence"
  ci_fixing_green_tick 11900
  [ "$(count_wakes)" = 2 ] || fail "an escalated lane did not repeat on the recheck cadence"
  [ "$CI_FIXING_GREEN" = "check: run stuck at ci=fixing with forge green: worker $PR run r1 10900s (threshold 900s)" ] \
    || fail "the repeat did not carry the whole age: $CI_FIXING_GREEN"
  pass "a ci=fixing lane with a green forge wakes once at the hold, naming the PR, then once per recheck cadence"
}

test_silent_unless_forge_green() {
  reset_case
  lane worker "$FIXING"
  forge '{"state":"OPEN","isDraft":false,"statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"IN_PROGRESS","conclusion":null}]}'
  ci_fixing_green_tick 1000
  ci_fixing_green_tick 5000
  [ "$(count_wakes)" = 0 ] || fail "a lane with a pending check woke"
  [ "$(count_forge_reads)" -ge 1 ] || fail "the forge was never consulted past the hold"
  rm -f "$STATE/.gh-json"
  ci_fixing_green_tick 6000
  [ "$(count_wakes)" = 0 ] || fail "an unreadable forge woke"
  forge "$GREEN"
  ci_fixing_green_tick 7000
  [ "$(count_wakes)" = 1 ] || fail "the lane did not wake once the forge turned green"
  [ "$CI_FIXING_GREEN" = "check: run stuck at ci=fixing with forge green: worker $PR run r1 6000s (threshold 900s)" ] \
    || fail "the age did not count from first sight of the reading: $CI_FIXING_GREEN"
  pass "a lane stays silent while the forge is pending, red or unreadable and wakes when it turns green"
}

test_episode_resets_and_scope() {
  reset_case
  forge "$GREEN"
  lane worker "$FIXING"
  ci_fixing_green_tick 1000
  printf '%s\n' "state: working · source: run-step · ci running · pr: $PR · run: r1" > "$STATE/worker.crew-state-line"
  ci_fixing_green_tick 1500
  printf '%s\n' "$FIXING" > "$STATE/worker.crew-state-line"
  ci_fixing_green_tick 2000
  ci_fixing_green_tick 2899
  [ "$(count_wakes)" = 0 ] || fail "a lane that left the reading kept its earlier clock"
  printf '%s\n' "${FIXING//run: r1/run: r9}" > "$STATE/worker.crew-state-line"
  ci_fixing_green_tick 2900
  ci_fixing_green_tick 3799
  [ "$(count_wakes)" = 0 ] || fail "a different run inherited the previous run's clock"
  ci_fixing_green_tick 3800
  [ "$(count_wakes)" = 1 ] || fail "the new run did not wake on its own clock"

  reset_case
  forge "$GREEN"
  lane mate "$FIXING" secondmate
  printf 'working [at=1000]: no meta\n' > "$STATE/nometa.status"
  printf '%s\n' "$FIXING" > "$STATE/nometa.crew-state-line"
  ci_fixing_green_tick 1000
  ci_fixing_green_tick 5000
  [ "$(count_wakes)" = 0 ] || fail "a secondmate or a task with no meta record woke"
  [ ! -e "$STATE/.stub-calls" ] || fail "a secondmate or a task with no meta record paid a crew-state read"
  pass "leaving the reading or changing run starts a fresh episode, and secondmates and meta-less tasks are never read"
}

test_scan_throttle_and_joined_wake() {
  reset_case
  forge "$GREEN"
  lane one "$FIXING"
  lane two "${FIXING//run: r1/run: r2}"
  CI_FIXING_GREEN_SCAN_SECS=300
  ci_fixing_green_tick 1000
  ci_fixing_green_tick 1299
  [ "$(wc -l < "$STATE/.stub-calls" | tr -d ' ')" = 2 ] || fail "the scan ran inside its interval"
  ci_fixing_green_tick 1900
  [ "$(count_wakes)" = 1 ] || fail "two due lanes queued more than one wake"
  case "$CI_FIXING_GREEN" in
    "check: run stuck at ci=fixing with forge green: one $PR run r1 900s (threshold 900s); two $PR run r2 900s (threshold 900s)") ;;
    *) fail "two due lanes were not joined into one wake: $CI_FIXING_GREEN" ;;
  esac
  CI_FIXING_GREEN_SCAN_SECS=0
  pass "the scan runs once per interval and simultaneously due lanes share one wake"
}

test_watcher_loop() {
  local dir="$TMP_ROOT/watcher-loop" pid i=0
  mkdir -p "$dir/state" "$dir/config"
  : > "$dir/config/ci-fixing-green"
  fm_test_track_watcher_state "$dir/state"
  touch "$dir/state/home-summary.json"
  printf 'working [at=1000]: on it\n' > "$dir/state/worker.status"
  printf 'worktree=%s\nkind=ship\n' "$dir" > "$dir/state/worker.meta"
  printf '%s\n' "$FIXING" > "$dir/state/worker.crew-state-line"
  printf '%s\n' "$GREEN" > "$dir/state/.gh-json"
  # A ledger an earlier watcher left behind: the episode clock survives a restart.
  printf 'worker\tr1\t1000\t0\n' > "$dir/state/.ci-fixing-green"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_CREW_STATE_BIN="$STUB" \
    bash "$ROOT/bin/fm-watch.sh" > "$dir/out" 2> "$dir/err" &
  pid=$!
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "real watcher failed to wake on a stuck ci=fixing run"
  fi
  wait "$pid" || fail "real watcher exited unsuccessfully: $(cat "$dir/err")"
  grep -F "check: run stuck at ci=fixing with forge green: worker $PR run r1 " "$dir/out" >/dev/null \
    || fail "real watcher did not print the stuck-run wake: $(cat "$dir/out")"
  grep -F 'ci-fixing-green' "$dir/state/.wake-queue" >/dev/null \
    || fail "real watcher did not durably queue the stuck-run wake"
  pass "the actual watcher wakes and exits on a stuck ci=fixing run, keeping the clock across a restart"
}

fm_test_run test_unarmed_home_reads_nothing test_only_the_minted_components_classify test_forge_green_is_strict \
  test_wakes_once_at_the_hold_naming_the_pr test_silent_unless_forge_green \
  test_episode_resets_and_scope test_scan_throttle_and_joined_wake test_watcher_loop
